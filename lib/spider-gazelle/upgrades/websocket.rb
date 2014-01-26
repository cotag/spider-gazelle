require 'websocket/driver'
require 'forwardable'


module SpiderGazelle
    # TODO:: make a promise that resolves when closed
    class Websocket < ::Libuv::Q::DeferredPromise
        attr_reader :env, :url, :loop


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


        extend Forwardable
        def_delegators :@driver, :start, :ping, :protocol, :ready_state, :set_header, :state, :close
        def_delegators :@socket, :write


        # Write some text to the websocket connection
        # 
        # @param string [String] a string of data to be sent to the far end
        def text(string)
            data = string.to_s
            @loop.schedule do
                @driver.text(data)
            end
        end

        # Write some binary data to the websocket connection
        # 
        # @param array [Array] an array of bytes to be sent to the far end
        def binary(array)
            data = array.to_a
            @loop.schedule do
                @driver.binary(data)
            end
        end

        # Used to define a callback when data is received from the client
        # 
        # @param callback [Proc] the callback to be called when data is received
        def progress(callback = nil, &blk)
            @progress = callback || blk
        end

        # Used to define a callback when the websocket connection is established
        # Data sent before this callback is buffered.
        # 
        # @param callback [Proc] the callback to be triggered on establishment
        def on_open(callback = nil, &blk)
            callback ||= blk
            @driver.on(:open, &callback)
        end


        protected


        def socket_read(data, tcp)
            @driver.parse(data)
        end

        def socket_close
            if @shutdown_called.nil?
                @defer.reject(WebSocket::Driver::CloseEvent.new(1006, 'connection was closed unexpectedly'))
            end
        end


        def on_message(event)
            @progress.call(event.data, self) unless @progress.nil?
        end

        def on_error(event)
            @defer.reject(event)
        end

        def on_close(event)
            @shutdown_called = true
            @socket.shutdown
            @defer.resolve(event)
        end
    end
end
