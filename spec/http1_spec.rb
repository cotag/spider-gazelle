require 'spider-gazelle/gazelle/http1'


# TODO:: Mock logger

class MockSocket
    def initialize
        @stopped = false
        @write_cb = proc {}
    end

    attr_reader   :closed, :stopped
    attr_accessor :storage, :write_cb, :shutdown_cb, :close_cb

    def peername; ['127.0.0.1']; end
    def finally(method = nil, &block); @on_close = method || block; end
    def close; @close_cb.call; end
    def shutdown; @shutdown_cb.call; end
    def progress(_); end
    def stop_read; @stopped = true; end

    def write(data); @write_cb.call(data); end
end

class MockLogger
    def initialize
        @logged = []
    end

    attr_reader :logged

    def method_missing(methId, *args)
        @logged << methId
        p "methId: #{args}"
    end
end

describe ::SpiderGazelle::Gazelle::Http1 do
    before :each do
        @shutdown_called = 0
        @close_called = 0

        @loop = ::Libuv::Loop.default
        @timeout = @loop.timer do
            @loop.stop
            @general_failure << "test timed out"
        end
        @timeout.start(1000)


        @return ||= proc {|http1|
            @returned = http1
        }
        @logger = MockLogger.new
        @http1_callbacks ||= ::SpiderGazelle::Gazelle::Http1::Callbacks.new
        @http1 = ::SpiderGazelle::Gazelle::Http1.new(@return, @http1_callbacks, @loop, @logger)

        @socket = MockSocket.new
        @socket.shutdown_cb = proc {
            @shutdown_called += 1
            @loop.stop
        }
        @socket.close_cb = proc {
            @close_called += 1
            @loop.stop
        }

        @app_mode = :thread_pool
        @port = 80
        @tls = false
    end

    after :each do
        @timeout.close
    end

    it "should process a single request and close the connection", http1: true do
        app = lambda do |env|
            body = 'Hello, World!'
            [200, {'Content-Type' => 'text/plain', 'Content-Length' => body.length.to_s}, [body]]
        end
        writes = []

        @loop.run {
            @http1.load(@socket, @port, app, @app_mode, @tls)
            @http1.parse("GET / HTTP/1.1\r\nConnection: Close\r\n\r\n")

            @socket.write_cb = proc { |data|
                writes << data
            }
        }

        expect(@shutdown_called).to be == 1
        expect(@close_called).to be == 0
        expect(writes).to eq([
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: close\r\n\r\n",
            "Hello, World!"
        ])
    end

    it "should process a single request and keep the connection open", http1: true do
        app = lambda do |env|
            body = 'Hello, World!'
            [200, {'Content-Type' => 'text/plain', 'Content-Length' => body.length.to_s}, [body]]
        end
        writes = []

        @loop.run {
            @http1.load(@socket, @port, app, @app_mode, @tls)
            @http1.parse("GET / HTTP/1.1\r\n\r\n")

            @socket.write_cb = proc { |data|
                writes << data
                if writes.length == 2
                    @loop.next_tick do
                        @loop.stop
                    end
                end
            }
        }

        expect(@shutdown_called).to be == 0
        expect(@close_called).to be == 0
        expect(writes).to eq([
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\n",
            "Hello, World!"
        ])
    end

    it "should fill out the environment properly", http1: true do
        app = lambda do |env|
            expect(env['REQUEST_URI']).to eq('/?test=ing')
            expect(env['REQUEST_PATH']).to eq('/')
            expect(env['QUERY_STRING']).to eq('test=ing')
            expect(env['SERVER_NAME']).to eq('spider.gazelle.net')
            expect(env['SERVER_PORT']).to eq(80)
            expect(env['REMOTE_ADDR']).to eq('127.0.0.1')
            expect(env['rack.url_scheme']).to eq('http')

            body = 'Hello, World!'
            [200, {'Content-Type' => 'text/plain', 'Content-Length' => body.length.to_s}, [body]]
        end

        @loop.run {
            @http1.load(@socket, @port, app, @app_mode, @tls)
            @http1.parse("GET /?test=ing HTTP/1.1\r\nHost: spider.gazelle.net\r\nConnection: Close\r\n\r\n")
        }

        expect(@shutdown_called).to be == 1
        expect(@close_called).to be == 0
    end

    it "should respond with a chunked response", http1: true do
        app = lambda do |env|
            body = ['Hello', ',', ' World!']
            [200, {'Content-Type' => 'text/plain'}, body]
        end
        writes = []

        @loop.run {
            @http1.load(@socket, @port, app, @app_mode, @tls)
            @http1.parse("GET / HTTP/1.1\r\nConnection: Close\r\n\r\n")

            @socket.write_cb = proc { |data|
                writes << data
            }
        }

        expect(@shutdown_called).to be == 1
        expect(@close_called).to be == 0
        expect(writes).to eq(["HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n", "5\r\nHello\r\n", "1\r\n,\r\n", "7\r\n World!\r\n", "0\r\n\r\n"])
    end
end
