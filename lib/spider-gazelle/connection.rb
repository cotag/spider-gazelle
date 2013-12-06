require 'stringio'


module SpiderGazelle
    class Connection
        Hijack = Struct.new(:socket, :env)


        RACK = 'rack'.freeze            # used for filtering headers
        CLOSE = "close".freeze
        CONNECTION = "Connection".freeze
        CONTENT_LENGTH = "Content-Length".freeze
        TRANSFER_ENCODING = "Transfer-Encoding".freeze
        CHUNKED = "chunked".freeze
        COLON_SPACE = ': '.freeze
        EOF = "0\r\n\r\n".freeze
        CRLF = "\r\n".freeze


        def self.on_progress(data, socket); end
        DUMMY_PROGRESS = self.method(:on_progress)
        ASYNC_RESPONSE = [-1, :async]


        # For Gazelle
        attr_reader :state, :parsing
        # For Request
        attr_reader :port, :tls, :loop, :socket


        def initialize(gazelle, loop, socket, port, state, app, queue)
            # A single parser instance per-connection (supports pipelining)
            @state = state
            @pending = []

            # Work callback for thread pool processing
            @request = nil
            @work = method(:work)

            # Called after the work on the thread pool is complete
            @send_response = method(:send_response)
            @send_error = method(:send_error)

            # Used to chain promises (ensures requests are processed in order)
            @process_next = method(:process_next)
            @current_worker = queue # keep track of work queue head to prevent unintentional GC
            @queue_worker = queue   # start queue with an existing resolved promise (::Libuv::Q::ResolvedPromise.new(@loop, true))
            
            # Socket for writing the response
            @socket = socket
            @app = app
            @port = port
            @tls = @socket.tls?
            @loop = loop
            @gazelle = gazelle

            # Remove connection if the socket closes
            socket.finally &method(:unlink)
        end

        # Lazy eval the IP
        def remote_ip
            @remote_ip ||= @socket.peername[0]
        end

        # Creates a new request state object
        def start_parsing
            @parsing = Request.new(self, @app)
        end

        # Chains the work in a promise queue
        def finished_parsing
            if !@state.keep_alive?
                @parsing.keep_alive = false
                @socket.stop_read   # we don't want to do any more work then we need to
            end
            @parsing.upgrade = @state.upgrade?
            @pending.push @parsing
            @queue_worker = @queue_worker.then @process_next
        end

        # The parser encountered an error
        def parsing_error
            # TODO::log error (available in the @request object)
            p "parsing error #{@state.error}"

            # We no longer care for any further requests from this client
            # however we will finish processing any valid pipelined requests before shutting down
            @socket.stop_read
            @queue_worker = @queue_worker.then do
                # TODO:: send response (400 bad request)
                @socket.shutdown
            end
        end

        # Schedule send
        def response(data)
            @loop.schedule
        end


        protected


        def send_response(result)
            # As we have come back from another thread the socket may have closed
            # This check is an optimisation, the call to write and shutdown would fail safely

            if @request.hijacked
                unlink              # unlink the management of the socket
                        
                # Pass the hijack response to the captor using the promise
                # This forwards the socket and environment as well as moving
                #  continued execution onto the event loop.
                @request.hijacked.resolve(Hijack.new(@socket, @request.env))

            elsif !@socket.closed
                status, headers, body = result

                if ASYNC_RESPONSE.include? status
                    # TODO:: wait for the response
                    # return async.promise

                else
                    headers[CONNECTION] = CLOSE if @request.keep_alive == false

                    # If a file, stream the body in a non-blocking fashion
                    if body.respond_to? :to_path
                        if headers[CONTENT_LENGTH]
                            type = :raw
                        else
                            type = :http
                            headers[TRANSFER_ENCODING] = CHUNKED
                        end

                        write_headers(status, headers)

                        file = @loop.file(body.to_path, File::RDONLY)
                        file.progress do    # File is open and available for reading
                            file.send_file(@socket, type).finally do
                                file.close
                                if @request.keep_alive == false
                                    @socket.shutdown
                                end
                            end
                        end

                        return file
                    else
                        if headers[CONTENT_LENGTH]
                            write_headers(status, headers)

                            # Stream the response
                            body.each do |part|
                                @socket.write part
                            end
                        else
                            headers[TRANSFER_ENCODING] = CHUNKED
                            write_headers(status, headers)

                            # Stream the response
                            body.each do |part|
                                chunk = part.bytesize.to_s(16) << CRLF << part << CRLF
                                @socket.write chunk
                            end
                            @socket.write EOF
                        end

                        # TODO:: we are doing this in the response thread
                        #   as we cannot unlock a rack mutex in this thread
                        #   it seems not to matter that we do this here
                        # body.close if body.respond_to?(:close)

                        # Close the connection if required
                        if @request.keep_alive == false
                            @socket.shutdown
                        end
                    end
                end
            end

            # continue processing (don't wait for write to complete)
            # if the write fails it will close the socket
            nil
        end

        def write_headers(status, headers)
            header = "HTTP/1.1 #{status}\r\n"
            headers.each do |key, value|
                next if key.start_with? RACK

                header << key
                header << COLON_SPACE
                header << value
                header << CRLF
            end
            header << CRLF
            @socket.write header
        end

        def send_error(reason)
            puts "send error: #{reason.message}\n#{reason.backtrace.join("\n")}\n"
            # TODO:: log error reason
            # Close the socket as this is fatal (file read error, gazelle error etc)
            @socket.close
        end

        def process_next(result)
            @request = @pending.shift
            @current_worker = @loop.work @work
            @current_worker.then @send_response, @send_error   # resolves the promise with a promise
        end

        # returns the response as the result of the work
        # We support the unofficial rack async api (multi-call)
        def work
            @request.response = catch(:async) {
                @request.execute!
            }
        end

        def unlink
            if not @gazelle.nil?
                @socket.progress &DUMMY_PROGRESS        # unlink the progress callback (prevent funny business)
                @gazelle.discard(self)
                @gazelle = nil
                @state = nil
            end
        end
    end
end
