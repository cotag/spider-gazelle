
module SpiderGazelle
    class Gazelle
        class Http1
            class Http1Callbacks
                def initialize
                    @parser = ::HttpParser::Parser.new self
                end


                attr_accessor :connection
                attr_reader   :parser


                def on_message_begin(parser)
                    @connection.start_parsing
                end

                def on_url(parser, url)
                    @connection.parsing.url << url
                end

                def on_header_field(parser, header)
                    req = @connection.parsing
                    req.header.frozen? ? req.header = header : req.header << header
                end

                DASH       = '-'.freeze
                UNDERSCORE = '_'.freeze
                HTTP_META  = 'HTTP_'.freeze
                COMMA      = ', '.freeze

                def on_header_value(parser, value)
                    req = @connection.parsing
                    if req.header.frozen?
                        req.env[req.header] << value
                    else
                        header = req.header
                        header.upcase!
                        header.gsub!(DASH, UNDERSCORE)
                        header.prepend(HTTP_META)
                        header.freeze
                        if req.env[header]
                            req.env[header] << COMMA
                            req.env[header] << value
                        else
                            req.env[header] = value
                        end
                    end
                end

                def on_headers_complete(parser)
                    @connection.headers_complete
                end

                def on_body(parser, data)
                    @connection.parsing.body << data
                end

                def on_message_complete(parser)
                    @connection.finished_parsing
                end
            end


            def initialize(callbacks)
                # The HTTP parser callbacks object for this thread
                @callbacks = callbacks
                @process_next = method(:process_next)

                # The parser state for this instance
                @state = ::HttpParser::Parser.new_instance do |inst|
                    inst.type = :request
                end

                # The request pipeline
                @requests = []
            end


            attr_reader   :parsing

            HTTP = 'http'.freeze
            HTTPS = 'https'.freeze

            def load(socket, port, app, app_mode, tls)
                @socket = socket
                @port = port
                @app = app
                @mode = app_mode

                @remote_ip = socket.peername[0]
                @scheme = tls ? HTTPS : HTTP

                socket.finally &method(:on_close)
            end

            def on_close
                @socket.progress &DUMMY_PROGRESS
                reset
                @return_method.call(self)
            end

            def reset
                @socket = nil
                @port = nil
                @app = nil
                @mode = nil
                @remote_ip = nil
                # @scheme = nil  # Safe to leave this

                @requests.clear
                @state.reset!
            end

            def parse(data)
                # This works as we only ever call this from a single thread
                @callbacks.connection = self
                @callbacks.parser.parse(@state, data)
            end

            # ----------------
            # Parser Callbacks
            # ----------------
            def start_parsing
                raise NotImplementedError.new 'TODO:: build request management objects'
                @parsing = Request.new @app, @port, @remote_ip, @scheme
            end

            REQUEST_METHOD = 'REQUEST_METHOD'.freeze
            def headers_complete
                @parsing.env[REQUEST_METHOD] = @state.http_method.to_s
            end

            def finished_parsing
                request = @parsing
                @parsing = nil

                if !@state.keep_alive?
                    request.keep_alive = false
                    # We don't expect any more data
                    @socket.stop_read
                end

                request.upgrade = @state.upgrade?
                
                previous = @requests[-1] || @current
                @requests << request

                if previous
                    previous.finally @process_next
                else
                    process_next
                end
            end

            # ------------------
            # Request Processing
            # ------------------
            def process_next
                @current = @requests.shift

                raise NotImplementedError.new 'TODO:: implement request execution modes'

                case @mode
                when :thread_pool
                when :fiber_pool
                when :libuv
                when :eventmachine
                when :celluloid
                end
            end
        end
    end
end
