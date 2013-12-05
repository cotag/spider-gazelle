require 'websocket/driver'


module SpiderGazelle
    # TODO:: make a promise that resolves when closed
    class Websocket < ::Libuv::Q::DeferredPromise
        attr_reader :env, :url, :driver, :socket


        def initialize(tcp, env)
            @socket, @env = tcp, env

            # Initialise the promise
            super(@socket.loop, @socket.loop.defer)

            scheme = env[Request::RACK_URLSCHEME] == Request::HTTPS_URL_SCHEME ? 'wss://' : 'ws://'
            @url = scheme + env[Request::HTTP_HOST] + env[Request::REQUEST_URI]
            @driver = ::WebSocket::Driver.rack(self)

            # Pass data from the socket to the driver
            @socket.progress &method(:socket_read)
            @socket.finally &method(:socket_close)


            # Driver has indicated that it is closing
            # We'll close the socket after writing any remaining data
            @driver.on(:close, &method(:on_close))
            @driver.on(:message, &method(:on_message))
            @driver.on(:error, &method(:on_error))
        end

        def start
            @driver.start
        end

        def text(string)
            @driver.text(string)
        end

        def binary(array)
            @driver.binary(array)
        end

        def progress(callback = nil, &blk)
            @progress = callback || blk
        end


        def write(string)
            @socket.write(string)
        end


        protected


        def socket_read(data, tcp)
            @driver.parse(data)
        end

        def socket_close
            @defer.reject({
                code: 1006,
                reason: 'connection was closed abnormally'
            })
        end


        def on_message(event)
            @progress.call(event.data, self) unless @progress.nil?
        end

        def on_error(event)
            @defer.reject(event)
        end

        def on_close(event)
            @socket.shutdown
            @defer.resolve(event)
        end
    end
end
