require 'stringio'


module SpiderGazelle
    class Connection
        Hijack = Struct.new(:socket, :env)


        RACK = 'rack'.freeze            # used for filtering headers
        CLOSE = 'close'.freeze
        CONNECTION = 'Connection'.freeze
        CONTENT_LENGTH = 'Content-Length'.freeze
        TRANSFER_ENCODING = 'Transfer-Encoding'.freeze
        CHUNKED = 'chunked'.freeze
        COLON_SPACE = ': '.freeze
        EOF = "0\r\n\r\n".freeze
        CRLF = "\r\n".freeze

        HTTP_11_400 = "HTTP/1.1 400 Bad Request\r\n\r\n".freeze


        def self.on_progress(data, socket); end
        DUMMY_PROGRESS = self.method(:on_progress)


        # For Gazelle
        attr_reader :state, :parsing
        # For Request
        attr_reader :tls, :port, :loop, :socket, :async_callback


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
            @write_chunk = method(:write_chunk)
            @current_worker = queue # keep track of work queue head to prevent unintentional GC
            @queue_worker = queue   # start queue with an existing resolved promise (::Libuv::Q::ResolvedPromise.new(@loop, true))
            
            # Socket for writing the response
            @socket = socket
            @app = app
            @port = port
            @tls = @socket.tls?
            @loop = loop
            @gazelle = gazelle
            @async_callback = method(:deferred_callback)

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
                @socket.stop_read   # we don't want to do any more work than we need to
            end
            @parsing.upgrade = @state.upgrade?
            @pending.push @parsing
            @queue_worker = @queue_worker.then @process_next
        end

        # The parser encountered an error
        def parsing_error
            # Grab the error
            send_error(@state.error)

            # We no longer care for any further requests from this client
            # however we will finish processing any valid pipelined requests before shutting down
            @socket.stop_read
            @queue_worker = @queue_worker.then do
                # TODO:: send response (400 bad request)
                @socket.write HTTP_11_400
                @socket.shutdown
            end
        end

        # Schedule send
        def response(data)
            @loop.schedule
        end


        protected


        # --------------
        # State handlers:
        # --------------


        # Called when an error occurs at any point while responding
        def send_error(reason)
            # Close the socket as this is fatal (file read error, gazelle error etc)
            @socket.close

            # Log the error in a worker thread
            @loop.work do
                msg = "connection error: #{reason.message}\n#{reason.backtrace.join("\n") if reason.backtrace}\n"
                puts msg
                @gazelle.logger.error msg
            end
        end

        # We use promise chaining to move the requests forward
        # This provides an elegant way to handle persistent and pipelined connections
        def process_next(result)
            @request = @pending.shift
            @current_worker = @loop.work @work
            @current_worker.then @send_response, @send_error   # resolves the promise with a promise
        end

        # returns the response as the result of the work
        # We support the unofficial rack async api (multi-call version for chunked responses)
        def work
            @request.execute!
        end

        # Unlinks the connection from the rack app
        # This occurs when requested and when the socket closes
        def unlink
            if not @gazelle.nil?
                @socket.progress &DUMMY_PROGRESS        # unlink the progress callback (prevent funny business)
                @gazelle.discard(self)
                @gazelle = nil
                @state = nil
            end
        end


        # ----------------------
        # Core response handlers:
        # ----------------------


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
                if @request.deferred
                    # Wait for the response using this promise
                    promise = @request.deferred.promise

                    # Process any responses that might have made it here first
                    if @deferred_responses
                        @deferred_responses.each &method(:respond_with)
                        @deferred_responses = nil
                    end

                    return promise

                # NOTE:: Somehow getting to here with a nil request... needs investigation
                elsif not result.nil?
                    # clear any cached responses just in case
                    # could be set by error in the rack application
                    @deferred_responses = nil if @deferred_responses

                    status, headers, body = result

                    # If a file, stream the body in a non-blocking fashion
                    if body.respond_to? :to_path
                        headers[CONNECTION] = CLOSE if @request.keep_alive == false

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
                        write_response(status, headers, body)
                    end
                end
            end

            # continue processing (don't wait for write to complete)
            # if the write fails it will close the socket
            nil
        end

        def write_response(status, headers, body)
            headers[CONNECTION] = CLOSE if @request.keep_alive == false

            if status == 304
                # TODO:: should this need its own use case?
                headers[CONTENT_LENGTH] = '0'
                write_headers(status, headers)
                @socket.shutdown if @request.keep_alive == false
            elsif headers[CONTENT_LENGTH]
                headers[CONTENT_LENGTH] = headers[CONTENT_LENGTH].to_s
                write_headers(status, headers)

                # Stream the response (pass directly into @socket.write)
                body.each &@socket.method(:write)

                if @request.deferred
                    @request.deferred.resolve(true)
                    @request.deferred = nil # prevent data being sent after completed
                end

                @socket.shutdown if @request.keep_alive == false
            else
                headers[TRANSFER_ENCODING] = CHUNKED
                write_headers(status, headers)

                # Stream the response
                body.each &@write_chunk

                if @request.deferred.nil?
                    @socket.write EOF
                    @socket.shutdown if @request.keep_alive == false
                else
                    @async_state = :chunked
                end
            end
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

        def write_chunk(part)
            chunk = part.bytesize.to_s(16) << CRLF << part << CRLF
            @socket.write chunk
        end


        # ------------------------
        # Async response functions:
        # ------------------------


        # Callback from a response that was marked async
        def deferred_callback(data)
            # We call close here, like on a regular response
            body = data[2]
            body.close if body.respond_to?(:close)
            @loop.next_tick do
                callback(data)
            end
        end

        # Process a response that was marked as async
        # Save the data if the request hasn't responded yet
        def callback(data)
            begin
                if @request.deferred && @deferred_responses.nil?
                    respond_with(data)
                else
                    @deferred_responses ||= []
                    @deferred_responses << data
                end
            rescue Exception => e
                # This provides the same level of protection that
                #  the regular responses provide
                send_error(e)
            end
        end

        # Process the async request in the same way as Mizuno
        # See: http://polycrystal.org/2012/04/15/asynchronous_responses_in_rack.html
        def respond_with(data)
            status, headers, body = data

            if @async_state.nil?
                # Respond with the headers here
                write_response(status, headers, body)
            elsif body.empty?
                @socket.write EOF
                @socket.shutdown if @request.keep_alive == false

                # Complete the request here
                deferred = @request.deferred
                @request.deferred = nil # prevent data being sent after completed
                @async_state = nil
                deferred.resolve(true)
            else
                # Send the chunks provided
                body.each &@write_chunk
            end
            nil
        end
    end
end
