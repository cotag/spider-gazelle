require 'spider-gazelle'
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
            expect(env['SERVER_PORT']).to eq(80)

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

    it "should fill out the environment properly", http1: true do
        app = lambda do |env|
            expect(env['REQUEST_URI']).to eq('/?test=ing')
            expect(env['REQUEST_PATH']).to eq('/')
            expect(env['QUERY_STRING']).to eq('test=ing')
            expect(env['SERVER_NAME']).to eq('spider.gazelle.net')
            expect(env['SERVER_PORT']).to eq(3000)
            expect(env['REMOTE_ADDR']).to eq('127.0.0.1')
            expect(env['rack.url_scheme']).to eq('http')

            body = 'Hello, World!'
            [200, {'Content-Type' => 'text/plain', 'Content-Length' => body.length.to_s}, [body]]
        end

        @loop.run {
            @http1.load(@socket, @port, app, @app_mode, @tls)
            @http1.parse("GET /?test=ing HTTP/1.1\r\nHost: spider.gazelle.net:3000\r\nConnection: Close\r\n\r\n")
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
        expect(writes).to eq([
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
            "5\r\nHello\r\n", "1\r\n,\r\n", "7\r\n World!\r\n", "0\r\n\r\n"
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

    it "should process pipelined requests in order", http1: true do
        current = 0
        order = []
        app = lambda do |env|
            case env['REQUEST_PATH']
            when '/1'
                order << 1
                current = 1
                body = 'Hello, World!'
                [200, {'Content-Type' => 'text/plain', 'Content-Length' => body.length.to_s}, [body]]
            when '/2'
                order << 2
                current = 2
                body = ['Hello,', ' World!']
                [200, {'Content-Type' => 'text/plain'}, body]
            when '/3'
                order << 3
                current = 3
                body = 'Happiness'
                [200, {'Content-Type' => 'text/plain', 'Content-Length' => body.length.to_s}, [body]]
            when '/4'
                order << 4
                current = 4
                body = 'is a warm gun'
                [200, {'Content-Type' => 'text/plain', 'Content-Length' => body.length.to_s}, [body]]
            end
        end

        writes = []
        @loop.run {
            @http1.load(@socket, @port, app, @app_mode, @tls)
            @http1.parse("GET /1 HTTP/1.1\r\n\r\nGET /2 HTTP/1.1\r\n\r\nGET /3 HTTP/1.1\r\n\r\n")
            @http1.parse("GET /4 HTTP/1.1\r\nConnection: Close\r\n\r\n")

            @socket.write_cb = proc { |data|
                order << current
                writes << data
            }
        }

        expect(@shutdown_called).to be == 1
        expect(@close_called).to be == 0
        expect(order).to eq([1,1,1, 2,2,2,2,2, 3,3,3, 4,4,4])
        expect(writes).to eq([
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\n",
            "Hello, World!",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n",
            "6\r\nHello,\r\n", "7\r\n World!\r\n", "0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\n",
            "Happiness",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: close\r\n\r\n",
            "is a warm gun"
        ])
    end

    it "should process a single async request and close the connection", http1: true do
        app = lambda do |env|
            expect(env['SERVER_PORT']).to eq(80)

            Thread.new do
                body = 'Hello, World!'
                env['async.callback'].call [200, {'Content-Type' => 'text/plain', 'Content-Length' => body.length.to_s}, [body]]
            end

            throw :async
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

    it "should process pipelined async requests in order", http1: true do
        current = 0
        order = []
        app = lambda do |env|
            Thread.new do
                env['async.callback'].call case env['REQUEST_PATH']
                when '/1'
                    order << 1
                    current = 1
                    body = 'Hello, World!'
                    [200, {'Content-Type' => 'text/plain', 'Content-Length' => body.length.to_s}, [body]]
                when '/2'
                    order << 2
                    current = 2
                    body = ['Hello,', ' World!']
                    [200, {'Content-Type' => 'text/plain'}, body]
                when '/3'
                    order << 3
                    current = 3
                    body = 'Happiness'
                    [200, {'Content-Type' => 'text/plain', 'Content-Length' => body.length.to_s}, [body]]
                when '/4'
                    order << 4
                    current = 4
                    body = 'is a warm gun'
                    [200, {'Content-Type' => 'text/plain', 'Content-Length' => body.length.to_s}, [body]]
                end
            end

            throw :async
        end

        writes = []
        @loop.run {
            @http1.load(@socket, @port, app, @app_mode, @tls)
            @http1.parse("GET /1 HTTP/1.1\r\n\r\nGET /2 HTTP/1.1\r\n\r\nGET /3 HTTP/1.1\r\n\r\n")
            @http1.parse("GET /4 HTTP/1.1\r\nConnection: Close\r\n\r\n")

            @socket.write_cb = proc { |data|
                order << current
                writes << data
            }
        }

        expect(@shutdown_called).to be == 1
        expect(@close_called).to be == 0
        expect(order).to eq([1,1,1, 2,2,2,2,2, 3,3,3, 4,4,4])
        expect(writes).to eq([
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\n",
            "Hello, World!",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n",
            "6\r\nHello,\r\n", "7\r\n World!\r\n", "0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\n",
            "Happiness",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: close\r\n\r\n",
            "is a warm gun"
        ])
    end

    it "should process a single async request and not suffer from race conditions", http1: true do
        app = lambda do |env|
            expect(env['SERVER_PORT']).to eq(80)

            Thread.new do
                body = 'Hello, World!'
                env['async.callback'].call [200, {'Content-Type' => 'text/plain', 'Content-Length' => body.length.to_s}, [body]]
            end

            sleep 0.5

            throw :async
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

        # Allow the worker thread to complete so we exit cleanly
        sleep 1
    end
end
