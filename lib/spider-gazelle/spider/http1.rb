# frozen_string_literal: true

require 'http-parser'     # C based, fast, http parser
require 'spider-gazelle/gazelle/request'


module SpiderGazelle
    class Spider
        class Http1
            class Callbacks
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

                def on_header_value(parser, value)
                    req = @connection.parsing
                    if req.header.frozen?
                        req.env[req.header] << value
                    else
                        header = req.header
                        header.upcase!
                        header.gsub!('-', '_')
                        header.prepend('HTTP_')
                        header.freeze
                        if req.env[header]
                            req.env[header] << ', '
                            req.env[header] << value
                        else
                            req.env[header] = String.new(value)
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


            Hijack = Struct.new :socket, :env


            def initialize(return_method, callbacks, thread, logger, gazelles)
                # The HTTP parser callbacks object for this thread
                @return_method = return_method
                @callbacks = callbacks
                @thread = thread
                @logger = logger

                @queue_response = method :queue_response
                @write_chunk = method :write_chunk
                @gazelles = gazelles

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

            def load(socket, port, app, tls)
                @socket = socket
                @port = port
                @app = app

                @remote_ip = socket.peername[0]
                @scheme = tls ? 'https' : 'http'

                set_on_close(socket)
            end

            # Only close the socket we are meaning to close
            def set_on_close(socket)
                socket.finally { on_close if socket == @socket }
            end

            def on_close
                # Unlink the progress callback (prevent funny business)
                @socket.progress DUMMY_PROGRESS
                @socket.storage = nil
                reset
                @return_method.call(self)
            end
            alias_method :unlink, :on_close

            def reset
                @app = nil
                @socket = nil
                @remote_ip = nil

                # Safe to leave these
                # @port = nil
                # @mode = nil
                # @scheme = nil

                if @processing
                    @processing.defer.reject(:socket_closed)
                end
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
                @parsing = Gazelle::Request.new @thread, @app, @port, @remote_ip, @scheme, @socket
            end

            def headers_complete
                @parsing.env['REQUEST_METHOD'] = @state.http_method.to_s
            end

            def finished_parsing
                request = @parsing
                @parsing = nil
                request.keep_alive = @state.keep_alive?
                request.upgrade = @state.upgrade?

                @thread.next_tick { after_parsing(request) }
            end

            def after_parsing(request)
                @socket.stop_read unless request.keep_alive

                # Process the async request in the same way as Mizuno
                # See: http://polycrystal.org/2012/04/15/asynchronous_responses_in_rack.html
                # Process a response that was marked as async.
                request.env['async.callback'] = proc { |data|
                    @thread.schedule { request.defer.resolve([request, data]) }
                }
                @requests << request

                process_next unless @processing
            end

            # ------------------
            # Request Processing
            # ------------------
            EMPTY_RESPONSE = [''].freeze
            def process_next
                @processing = @requests.shift
                if @processing
                    request = @processing
                    request.then @queue_response

                    @gazelles.next.schedule do
                        process_on_gazelle(request)
                    end
                end
            end

            def process_on_gazelle(request)
                result = begin
                    request.execute!
                rescue StandardError => e
                    Logger.instance.print_error e, 'framework error'
                    request.keep_alive = false
                    [500, {}, EMPTY_RESPONSE]
                end

                if request.is_async && !request.hijacked
                    if result.nil? && !request.defer.resolved?
                        # TODO:: setup timeout for async response
                    end
                else
                    # Complete the current request
                    request.defer.resolve([request, result])
                end
            rescue Exception => error
                Logger.instance.print_error error, 'critical error'
                Reactor.instance.shutdown
            end

            # ----------------
            # Response Sending
            # ----------------
            def queue_response(response)
                @responses << response
                send_next_response unless @transmitting

                # Processing will be set to nil if the array is empty
                process_next
            end

            def send_next_response
                request, result = @responses.shift
                @transmitting = request
                return unless request

                if request.hijacked
                    # Unlink the management of the socket
                    # Then forward the raw socket to the upgrade handler
                    socket = @socket
                    unlink
                    request.hijacked.resolve Hijack.new(socket, request.env)

                elsif @socket.closed
                    body = result[2]
                    body.close if body.respond_to?(:close)
                else
                    status, headers, body = result
                    send_body = request.env['REQUEST_METHOD'] != 'HEAD'

                    # If a file, stream the body in a non-blocking fashion
                    if body.respond_to? :to_path
                        begin
                            file = @thread.file body.to_path, File::RDONLY, wait: true

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

                            # Send the body in parallel without blocking the next request in dev
                            # Also if this is a head request we still want the body closed
                            body.close if body.respond_to?(:close)
                            data_written = false

                            statprom = file.stat wait: false
                            statprom.then do |stats|
                                #etag = ::Digest::MD5.hexdigest "#{stats[:st_mtim][:tv_sec]}#{body.to_path}"
                                #if etag == request.env[HTTP_ETAG]
                                #    header = NOT_MODIFIED_304.dup
                                #    add_header(header, ETAG, etag)
                                #    header << "\r\n"
                                #    @socket.write header
                                #    return
                                #end
                                #headers[ETAG] ||= etag

                                if headers['Content-Length']
                                    type = :raw
                                else
                                    type = :http
                                    headers['Transfer-Encoding'] = 'chunked'
                                end

                                data_written = true
                                write_headers request.keep_alive, status, headers

                                if send_body
                                    # File is open and available for reading
                                    promise = file.send_file(@socket, using: type)
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
                        rescue => err
                            @logger.warn "Error reading file: #{err}"
                            send_internal_error
                        end
                    else
                        # Optimize the response
                        begin
                            if body.size < 2
                                headers['Content-Length'] = body.size == 1 ? body[0].bytesize.to_s : '0'
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

            def write_response(request, status, headers, body)
                keep_alive = request.keep_alive

                if headers['Content-Length']
                    headers['Content-Length'] = headers['Content-Length'].to_s
                    write_headers keep_alive, status, headers

                    # Stream the response (pass directly into @socket.write)
                    body.each &@socket.method(:write)
                    @socket.shutdown if keep_alive == false
                else
                    headers['Transfer-Encoding'] = 'chunked'
                    write_headers keep_alive, status, headers

                    # Stream the response
                    body.each &@write_chunk

                    @socket.write "0\r\n\r\n"
                    @socket.shutdown if keep_alive == false
                end

                body.close if body.respond_to?(:close)
            end

            def add_header(header, key, value)
                header << key
                header << ': '
                header << value
                header << "\r\n"
            end

            def write_headers(keep_alive, status, headers)
                headers['Connection'] = 'close' if keep_alive == false

                header = String.new("HTTP/1.1 #{status} #{fetch_code(status)}\r\n")
                headers.each do |key, value|
                    next if key.start_with? 'rack'
                    value.to_s.split("\n").each {|val| add_header(header, key, val)}
                end
                header << "\r\n"
                @socket.write header
            end

            def write_chunk(part)
                chunk = part.bytesize.to_s(16) << "\r\n" << part << "\r\n"
                @socket.write chunk
            end

            HTTP_STATUS_CODES = Rack::Utils::HTTP_STATUS_CODES
            HTTP_STATUS_DEFAULT = proc { 'CUSTOM' }
            def fetch_code(status)
                HTTP_STATUS_CODES.fetch(status, &HTTP_STATUS_DEFAULT)
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

            def send_parsing_error
                @logger.info "Parsing error!"
                @socket.stop_read
                @socket.write "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                @socket.shutdown
            end

            def send_internal_error
                @logger.info "Internal error"
                @socket.stop_read
                @socket.write "HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                @socket.shutdown
            end
        end
    end
end
