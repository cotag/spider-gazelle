# frozen_string_literal: true

require 'websocket/driver'
require 'forwardable'

module SpiderGazelle
    class Websocket < ::Libuv::Q::DeferredPromise
        attr_reader :env, :url, :reactor, :socket


        RACK_URL_SCHEME = 'rack.url_scheme'
        HTTP_HOST = 'HTTP_HOST'
        REQUEST_URI= 'REQUEST_URI'
        HTTPS = 'https'


        extend Forwardable
        def_delegators :@driver, :start, :ping, :protocol, :ready_state, :set_header, :state, :close
        def_delegators :@socket, :write, :peername

        def initialize(tcp, env)
            @socket, @env = tcp, env

            # Initialise the promise
            super tcp.reactor, tcp.reactor.defer

            scheme = env[RACK_URL_SCHEME] == HTTPS ? 'wss://' : 'ws://'
            @url = scheme + env[HTTP_HOST] + env[REQUEST_URI]
            @driver = ::WebSocket::Driver.rack self

            # Pass data from the socket to the driver
            @socket.progress &method(:socket_read)
            @socket.finally &method(:socket_close)


            # Driver has indicated that it is closing
            # We'll close the socket after writing any remaining data
            @driver.on :close, &method(:on_close)
            @driver.on :message, &method(:on_message)
            @driver.on :error, &method(:on_error)
        end

        # Write some text to the websocket connection
        #
        # @param string [String] a string of data to be sent to the far end
        def text(string)
            @reactor.schedule { @driver.text(string.to_s) }
        end

        # Write some binary data to the websocket connection
        #
        # @param array [Array] an array of bytes to be sent to the far end
        def binary(array)
            @reactor.schedule { @driver.binary(array.to_a) }
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
            @driver.on :open, &callback
        end

        protected

        def socket_read(data, tcp)
            begin
                @driver.parse data
            rescue => e
                # Prevent hanging sockets
                @socket.close
                raise e
            end
        end

        def socket_close
            if @shutdown_called.nil?
                @defer.reject WebSocket::Driver::CloseEvent.new(1006, 'connection was closed unexpectedly')
            end
        end


        def on_message(event)
            @progress.call(event.data, self) unless @progress.nil?
        end

        def on_error(event)
            @defer.reject event
        end

        def on_close(event)
            @shutdown_called = true
            @socket.shutdown
            @defer.resolve event
        end
    end
end
