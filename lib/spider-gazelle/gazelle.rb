require 'spider-gazelle/gazelle/app_store'
require 'spider-gazelle/gazelle/parser'
require 'http-parser'     # C based, fast, http parser
require 'rack'            # Ruby webserver abstraction

#require "spider-gazelle/gazelle/request"        # Holds request information and handles request processing
#require "spider-gazelle/gazelle/connection"     # Holds connection information and handles request pipelining

# Reactor aware websocket implementation
#require "spider-gazelle/upgrades/websocket"


module SpiderGazelle
    class Gazelle
        SPACE = ' '.freeze

        def initialize(thread, type)
            raise ArgumentError, "type must be one of #{MODES}" unless MODES.include?(type)
            
            @type = type
            @logger = Logger.instance
            @thread = thread
            @parser_cache = []
            @parser_count = 0

            @return_method = method(:connection_closed)
            @on_progress   = method(:on_progress)
            @set_protocol  = method(:set_protocol)

            # Register the gazelle with the signaller so we can shutdown
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
        end

        def shutdown(finished = nil)
            # Wait for the requests to finish (give them 15 seconds)
            # TODO::

            @logger.verbose { "Gazelle: #{@type} Pid: #{Process.pid} shutting down" }

            # Then stop the current thread if we are in threaded mode
            if @type == :thread
                # In threaded mode the gazelle has the power
                @thread.stop
            else
                # Both no_ipc and process need to know when the requests
                # have completed to shutdown
                finished.resolve(true)
            end
        end


        protected


        def connect_to_spider
            @pipe = @thread.pipe :ipc
            @pipe.connect(@options[0][:gazelle_ipc]) do |client|
                client.progress method(:new_connection)
                client.start_read

                authenticate
            end

            @pipe.catch do |reason|
                @logger.print_error(error)
            end

            @pipe.finally do
                if @type == :process
                    Reactor.instance.shutdown
                else
                    # Threaded mode
                    shutdown
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
            app, app_mode, port, tls = AppStore.get(app_id)

            # Prepare a parser for the socket
            parser = @parser_cache.pop || new_parser
            parser.load(socket, port, app, app_mode)

            # Hook up the socket and kick of TLS if required
            socket.progress @on_progress
            if tls
                socket.on_handshake @set_protocol
                socket.start_tls(tls)
            else
                parser.set_protocol(:http1)
            end

            # Start reading from the connection
            socket.storage = parser
            socket.start_read
        end

        def on_progress(data, socket)
            # Storage contains the parser for this connection
            parser = socket.storage
            parser.parse(data)
        end

        def set_protocol(socket, version)
            parser = socket.storage
            parser.set_protocol(version == :h2 ? :http2 : :http1)
        end

        def new_parser
            @parser_count += 1
            Parser.new(@return_method)
        end
    end
end
