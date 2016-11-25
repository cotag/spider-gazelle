# frozen_string_literal: true

require 'rack' # Ruby webserver abstraction
require 'spider-gazelle/gazelle/app_store'
require 'spider-gazelle/gazelle/http1'


# Reactor aware websocket implementation
require "spider-gazelle/upgrades/websocket"


module SpiderGazelle
    class Gazelle
        def initialize(thread, type)
            raise ArgumentError, "type must be one of #{MODES}" unless MODES.include?(type)
            
            @type = type
            @logger = Logger.instance
            @thread = thread

            @http1_cache = []
            @http2_cache = []
            @return_http1 = method(:return_http1)
            @return_http2 = method(:return_http2)
            @parser_count = 0

            @on_progress   = method(:on_progress)
            @set_protocol  = method(:set_protocol)

            # Register the gazelle with the signaller so we can shutdown elegantly
            if @type == :process
                Signaller.instance.gazelle = self
            end
        end

        def run!(options)
            @options = options
            @logger.verbose { "Gazelle: #{@type} Pid: #{Process.pid} started" }

            connect_to_spider unless @type == :no_ipc

            load_required_applications
            self
        end

        def new_app(options)
            # TODO:: load this app into all of the gazelles dynamically
        end

        def new_connection(data, binding)
            socket = @pipe.check_pending
            return if socket.nil?
            process_connection(socket, data.to_i)
        rescue => e
            @logger.print_error(e)
        end

        def shutdown
            # Wait for the requests to finish
            @logger.verbose { "Gazelle: #{@type} Pid: #{Process.pid} shutting down" }
        end


        protected


        def connect_to_spider
            @pipe = @thread.pipe :ipc
            @pipe.connect(@options[0][:gazelle_ipc]) do |client|
                client.progress method(:new_connection)
                client.start_read

                authenticate
            end

            @pipe.catch do |error, backtrace|
                @logger.print_error(error, String.new, backtrace)
            end

            if @type == :process
                @pipe.finally do
                    Reactor.instance.shutdown
                end
            end
        end

        def authenticate
            @pipe.write "#{@options[0][:gazelle]} #{@type}"
        end

        def load_required_applications
            @options.each do |app|
                if app[:rackup]
                    AppStore.load(app[:rackup], app)
                elsif app[:app]
                    AppStore.add(app[:app], app)
                end
            end
        end


        # ---------------------
        # Connection Management
        # ---------------------
        def process_connection(socket, app_id)
            # Put application details in the socket storage as we negotiate protocols
            details = AppStore.get(app_id)
            socket.storage = details
            tls = details[-1]

            # Hook up the socket and kick off TLS if required
            if tls
                socket.on_handshake @set_protocol
                socket.start_tls(tls)
            else
                set_protocol(socket, :http1)
            end

            socket.start_read
            socket.enable_nodelay
        end

        def on_progress(data, socket)
            # Storage contains the parser for this connection
            parser = socket.storage
            parser.parse(data)
        end

        def set_protocol(socket, version)
            app, port, tls = socket.storage

            parser = if version == :h2
                @http2_cache.pop || new_http2_parser
            else
                @http1_cache.pop || new_http1_parser
            end

            parser.load(socket, port, app, tls)
            socket.progress @on_progress
            socket.storage = parser
        end


        def new_http1_parser
            @h1_parser_obj ||= Http1::Callbacks.new

            @parser_count += 1
            Http1.new(@return_http1, @h1_parser_obj, @thread, @logger)
        end

        def return_http1(parser)
            @http1_cache.push parser
        end

        def new_http2_parser
            raise NotImplementedError.new 'TODO:: Create HTTP2 parser class'
            @parser_count += 1
            Http2.new(@return_http2)
        end

        def return_http2(parser)
            @http2_cache << parser
        end
    end
end
