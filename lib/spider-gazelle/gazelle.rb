require 'set'


module SpiderGazelle
    class Gazelle


        HTTP_META = 'HTTP_'.freeze
        REQUEST_METHOD = 'REQUEST_METHOD'.freeze    # GET, POST, etc


        attr_reader :parser_cache, :connections, :logger


        def set_instance_type(inst)
            inst.type = :request
        end
        


        def initialize(loop, logger)
            @gazelle = loop
            @connections = Set.new      # Set of active connections on this thread
            @parser_cache = []      	# Stale parser objects cached for reuse

            @logger = logger
            @app_cache = {}
            @connection_queue = ::Libuv::Q::ResolvedPromise.new(@gazelle, true)

            # A single parser instance for processing requests for each gazelle
            @parser = ::HttpParser::Parser.new(self)
            @set_instance_type = method(:set_instance_type)

            # Single progress callback for each gazelle
            @on_progress = method(:on_progress)
        end

        def run
            @gazelle.run do |logger|
                logger.progress do |level, errorid, error|
                    begin
                        msg = "Gazelle log: #{level}: #{errorid}\n#{error.message}\n#{error.backtrace.join("\n") if error.backtrace}\n"
                        @logger.error msg
                        puts msg
                    rescue Exception
                        p 'error in gazelle logger'
                    end
                end

                # A pipe used to forward connections to different threads
                @socket_server = @gazelle.pipe(true)
                @socket_server.connect(DELEGATE_PIPE) do
                    @socket_server.progress &method(:new_connection)
                    @socket_server.start_read2
                end

                # A pipe used to signal various control commands (shutdown, etc)
                @signal_server = @gazelle.pipe
                @signal_server.connect(SIGNAL_PIPE) do
                    @signal_server.progress &method(:process_signal)
                    @signal_server.start_read
                end
            end
        end


        # HTTP Parser callbacks:
        def on_message_begin(parser)
            @connection.start_parsing
        end

        def on_url(parser, url)
            @connection.parsing.url << url
        end

        def on_header_field(parser, header)
            req = @connection.parsing
            if req.header.frozen?
                req.header = header
            else
                req.header << header
            end
        end

        def on_header_value(parser, value)
            req = @connection.parsing
            if req.header.frozen?
                req.env[req.header] << value
            else
                header = req.header
                header.upcase!
                header.gsub!('-', '_')
                header.prepend(HTTP_META)
                header.freeze
                req.env[header] = value
            end
        end

        def on_headers_complete(parser)
            @connection.parsing.env[REQUEST_METHOD] = @connection.state.http_method.to_s
        end

        def on_body(parser, data)
            @connection.parsing.body << data
        end

        def on_message_complete(parser)
            @connection.finished_parsing
        end

        def discard(connection)
            @connections.delete(connection)
            @parser_cache << connection.state
        end


        protected


        def on_progress(data, socket)
            # Keep track of which connection we are processing for the callbacks
            @connection = socket.storage

            # Check for errors during the parsing of the request
            if @parser.parse(@connection.state, data)
                @connection.parsing_error
            end
        end

        def new_connection(data, socket)
            # Data == "TLS_indicator Port APP_ID"
            tls, port, app_id = data.split(' ', 3)
            app = @app_cache[app_id.to_sym] ||= AppStore.get(app_id)
            inst = @parser_cache.pop || ::HttpParser::Parser.new_instance(&@set_instance_type)

            # process any data coming from the socket
            socket.progress @on_progress
            if tls == 'T'
                # TODO:: Allow some globals for supplying the certs
                socket.start_tls(:server => true)
            end

            # Keep track of the connection
            connection = Connection.new self, @gazelle, socket, port, inst, app, @connection_queue
            @connections.add connection
            socket.storage = connection     # This allows us to re-use the one proc for parsing

            socket.start_read
        end

        def process_signal(data, pipe)
            if data == Spider::KILL_GAZELLE
                shutdown
            end
        end

        def shutdown
            # TODO:: do this nicely
            # Need to signal the connections to close
            @gazelle.stop
        end
    end
end
