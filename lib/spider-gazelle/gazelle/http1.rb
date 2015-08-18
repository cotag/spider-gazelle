
module SpiderGazelle
    class Gazelle
        class Http1
            class Http1Callbacks
                def initialize
                    @parser = ::HttpParser::Parser.new self
                    @logger = Logger.instance
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


            def initialize(return_method, callbacks, thread, logger)
                # The HTTP parser callbacks object for this thread
                @return_method = return_method
                @callbacks = callbacks
                @thread = thread
                @logger = logger

                @work = method(:work)
                @async_callback = method(:async_callback)
                @queue_response = method(:queue_response)

                # The parser state for this instance
                @state = ::HttpParser::Parser.new_instance do |inst|
                    inst.type = :request
                end

                # The request and response queues
                @requests = []
                @responses = []
            end


            attr_reader   :parsing


            def self.on_progress(data, socket); end
            DUMMY_PROGRESS = self.method :on_progress

            HTTP = 'http'.freeze
            HTTPS = 'https'.freeze

            def load(socket, port, app, app_mode, tls)
                @socket = socket
                @port = port
                @app = app
                @mode = app_mode

                case @mode
                when :thread_pool
                    @exec = method :exec_on_thread_pool
                when :fiber_pool
                    # TODO:: Implement these modes
                    @exec = method :critical_error
                when :libuv
                    @exec = method :critical_error
                when :eventmachine
                    @exec = method :critical_error
                when :celluloid
                    @exec = method :critical_error
                end

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

                @processing = nil
                @transmitting = nil

                @requests.clear
                @responses.clear
                @state.reset!
            end

            def parse(data)
                # This works as we only ever call this from a single thread
                @callbacks.connection = self
                parsing_error if @callbacks.parser.parse(@state, data)
            end

            # ----------------
            # Parser Callbacks
            # ----------------
            def start_parsing
                @parsing = Request.new @thread, @app, @port, @remote_ip, @scheme, @async_callback
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
                @requests << request
                process_next unless @processing
            end

            # ------------------
            # Request Processing
            # ------------------
            def process_next
                @processing = @requests.shift
                if @processing
                    @exec.call
                    @processing.then @queue_response
                end
            end

            def exec_on_thread_pool
                promise = @thread.work @work
                promise.catch do |error|
                    @logger.print_error error, 'critical error'
                    Reactor.instance.shutdown
                end
                promise.then do |result|
                    if @processing.is_async
                        if result.is_a? Fixnum
                            # TODO:: setup timeout for async response
                        end
                    else
                        # Complete the current request
                        @processing.defer.resolve(result)
                    end
                end
            end

            EMPTY_RESPONSE = [''.freeze].freeze
            def work
                begin
                    @processing.execute!
                rescue StandardError => e
                    @logger.print_error e, 'framework error'
                    @processing.keep_alive = false
                    [500, {}, EMPTY_RESPONSE]
                end
            end

            # Process the async request in the same way as Mizuno
            # See: http://polycrystal.org/2012/04/15/asynchronous_responses_in_rack.html
            def async_callback(data)
                @thread.schedule { callback(data) }
            end

            # Process a response that was marked as async. Save the data if the request hasn't responded yet
            def callback(data)
                request = @processing
                if request && request.deferred
                    request.defer.resolve(data)
                else
                    @logger.warn "Received async callback and there are no pending requests. Data was:\n#{data}"
                end
            end


            # ----------------
            # Response Sending
            # ----------------
            def queue_response(result)
                @responses << [@processing, result]
                send_next_response unless @transmitting

                # Processing will be set to nil if the array is empty
                process_next
            end


            HEAD = 'HEAD'.freeze
            ETAG = 'ETag'.freeze
            HTTP_ETAG = 'HTTP_ETAG'.freeze
            CONTENT_LENGTH2 = 'Content-Length'.freeze
            TRANSFER_ENCODING = 'Transfer-Encoding'.freeze
            CHUNKED = 'chunked'.freeze
            ZERO = '0'.freeze
            NOT_MODIFIED_304 = "HTTP/1.1 304 Not Modified\r\n".freeze

            def send_next_response
                request, result = @responses.shift
                @transmitting = request
                return unless request

                if request.hijacked
                    # Unlink the management of the socket
                    # Then forward the raw socket to the upgrade handler
                    unlink
                    request.hijacked.resolve [@socket, request.env]

                elsif @socket.closed
                    body = result[2]
                    body.close if body.respond_to?(:close)
                else
                    status, headers, body = result
                    send_body = request.env[REQUEST_METHOD] != HEAD

                    # If a file, stream the body in a non-blocking fashion
                    if body.respond_to? :to_path
                        file = @thread.file body.to_path, File::RDONLY

                        # Send the body in parallel without blocking the next request in dev
                        # Also if this is a head request we still want the body closed
                        body.close if body.respond_to?(:close)
                        data_written = false

                        file.progress do
                            statprom = file.stat
                            statprom.then do |stats|
                                #etag = ::Digest::MD5.hexdigest "#{stats[:st_mtim][:tv_sec]}#{body.to_path}"
                                #if etag == request.env[HTTP_ETAG]
                                #    header = NOT_MODIFIED_304.dup
                                #    add_header(header, ETAG, etag)
                                #    header << LINE_END
                                #    @socket.write header
                                #    return
                                #end
                                #headers[ETAG] ||= etag

                                if headers[CONTENT_LENGTH2]
                                    type = :raw
                                else
                                    type = :http
                                    headers[TRANSFER_ENCODING] = CHUNKED
                                end

                                data_written = true
                                write_headers request.keep_alive, status, headers

                                if send_body
                                    # File is open and available for reading
                                    promise = file.send_file(@socket, type)
                                    promise.then do
                                        file.close
                                        @socket.shutdown if request.keep_alive == false
                                    end
                                    promise.catch do |err|
                                        @logger.warn "Error sending file: #{err}"
                                        @socket.close
                                        file.close
                                    end
                                else
                                    file.close
                                    @socket.shutdown unless request.keep_alive
                                end
                            end
                            statprom.catch do |err|
                                @logger.warn "Error reading file stats: #{err}"
                                file.close
                                send_internal_error
                            end
                        end

                        file.catch do |err|
                            @logger.warn "Error reading file: #{err}"

                            if data_written
                                file.close
                                @socket.shutdown
                            else
                                send_internal_error
                            end
                        end

                        # Request has completed - send the next one
                        file.finally do
                            send_next_response
                        end
                    else
                        # Optimize the response
                        begin
                            if body.size < 2
                                headers[CONTENT_LENGTH2] = body.size == 1 ? body[0].bytesize : ZERO
                            end
                        rescue # just in case
                        end

                        keep_alive = request.keep_alive

                        if send_body
                            write_response request, status, headers, body
                        else
                            body.close if body.respond_to?(:close)
                            write_headers keep_alive, status, headers
                            @socket.shutdown if keep_alive == false
                        end

                        send_next_response
                    end
                end
            end

            CLOSE_CHUNKED = "0\r\n\r\n".freeze
            def write_response(request, status, headers, body)
                keep_alive = request.keep_alive

                if headers[CONTENT_LENGTH2]
                    headers[CONTENT_LENGTH2] = headers[CONTENT_LENGTH2].to_s
                    write_headers keep_alive, status, headers

                    # Stream the response (pass directly into @socket.write)
                    body.each &@socket.method(:write)
                    @socket.shutdown if keep_alive == false
                else
                    headers[TRANSFER_ENCODING] = CHUNKED
                    write_headers keep_alive, status, headers

                    # Stream the response
                    @write_chunk ||= method :write_chunk
                    body.each &@write_chunk

                    @socket.write CLOSE_CHUNKED
                    @socket.shutdown if keep_alive == false
                end

                body.close if body.respond_to?(:close)
            end

            COLON_SPACE = ': '.freeze
            LINE_END = "\r\n".freeze
            def add_header(header, key, value)
                header << key
                header << COLON_SPACE
                header << value
                header << LINE_END
            end

            CONNECTION = "Connection".freeze
            NEWLINE = "\n".freeze
            CLOSE = "close".freeze
            RACK = "rack".freeze
            def write_headers(keep_alive, status, headers)
                headers[CONNECTION] = CLOSE if keep_alive == false

                header = "HTTP/1.1 #{status} #{fetch_code(status)}\r\n"
                headers.each do |key, value|
                    next if key.start_with? RACK
                    value.to_s.split(NEWLINE).each {|val| add_header(header, key, val)}
                end
                header << LINE_END
                @socket.write header
            end

            HEX_ENCODED = 16
            def write_chunk(part)
                chunk = part.bytesize.to_s(HEX_ENCODED) << LINE_END << part << LINE_END
                @socket.write chunk
            end

            HTTP_STATUS_CODES = Rack::Utils::HTTP_STATUS_CODES
            HTTP_STATUS_DEFAULT = proc { 'CUSTOM'.freeze }
            def fetch_code(status)
                HTTP_STATUS_CODES.fetch(status, &HTTP_STATUS_DEFAULT)
            end

            # Unlinks the connection from the rack app
            # This occurs on upgrade requests that are handled
            def unlink
                # Unlink the progress callback (prevent funny business)
                @socket.progress &DUMMY_PROGRESS
                reset
                @return_method.call(self)
            end


            # ----------------
            # Error Management
            # ----------------
            def critical_error
                # Kill the process
                Reactor.instance.shutdown
            end

            def parsing_error
                # Stop reading from the client
                # Wait for existing requests to complete
                # Send an error response for the current request
                @socket.stop_read
                previous = @requests[-1] || @processing

                if previous
                    previous.finally do
                        send_parsing_error
                    end
                else
                    send_parsing_error
                end
            end

            ERROR_400_RESPONSE = "HTTP/1.1 400 Bad Request\r\n\r\n".freeze
            def send_parsing_error
                @logger.info "Parsing error!"
                @socket.write ERROR_400_RESPONSE
                @socket.shutdown
            end

            ERROR_500_RESPONSE = "HTTP/1.1 500 Internal Server Error\r\n\r\n".freeze
            def send_internal_error
                @socket.stop_read
                @socket.write ERROR_500_RESPONSE
                @socket.shutdown
            end
        end
    end
end
