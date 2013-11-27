require 'set'


module SpiderGazelle
    class Gazelle


        HTTP_META = 'HTTP_'.freeze
        REQUEST_METHOD = 'REQUEST_METHOD'.freeze    # GET, POST, etc


        def initialize(app, options)
            @gazelle = Libuv::Loop.new
            @connections = Set.new      # Set of active connections on this thread
            @parser_cache = []      	# Stale parser objects cached for reuse
            @connection_queue = ::Libuv::Q::ResolvedPromise.new(@gazelle, true)

            @app = app
            @options = options

            # A single parser instance for processing requests for each gazelle
            @parser = ::HttpParser::Parser.new(self)

            # Single progress callback for each gazelle
            @on_progress = method(:on_progress)
        end

        def run
            @gazelle.run do |logger|
                logger.progress do |level, errorid, error|
                    begin
                        p "Log called: #{level}: #{errorid}\n#{error.message}\n#{error.backtrace.join("\n")}\n"
                    rescue Exception
                        p 'error in gazelle logger'
                    end
                end

                # A pipe used to forward connections to different threads
                @socket_server = @gazelle.pipe(true)
                @socket_server.connect(DELEGATE_PIPE) do
                    @socket_server.progress do |data, socket|
                        new_connection(socket)
                    end
                    @socket_server.start_read2
                end

                # A pipe used to signal various control commands (shutdown, etc)
                @signal_server = @gazelle.pipe
                @signal_server.connect(SIGNAL_PIPE) do
                    @signal_server.progress do |data|
                        process_signal(data)
                    end
                    @signal_server.start_read
                end
            end
        end


        # HTTP Parser callbacks:
        def on_message_begin(parser)
            @connection.start_parsing(Request.new(@app, @options))
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


        protected


        def on_progress(data, socket)
            # Keep track of which connection we are processing for the callbacks
            @connection = socket.storage

            # Check for errors during the parsing of the request
            if @parser.parse(@connection.state, data)
                @connection.parsing_error
            end
        end

        def new_connection(socket)
            # Keep track of the connection
            connection = Connection.new @gazelle, socket, @connection_queue
            @connections.add connection
            socket.storage = connection     # This allows us to re-use the one proc for parsing

            # process any data coming from the socket
            socket.progress @on_progress
            socket.start_read

            # Remove connection if the socket closes
            socket.finally do
                @connections.delete(connection)
            end
        end

        def process_signal(data)
            if data == Spider::KILL_GAZELLE
                shutdown
            end
        end

        def shutdown
            # TODO:: do this nicely
            @gazelle.stop
        end
    end
end
