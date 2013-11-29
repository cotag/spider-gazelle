require 'stringio'


module SpiderGazelle
    class Connection


        attr_reader :state, :parsing
        attr_accessor :queue_worker


        def initialize(loop, socket, port, state, app, queue)
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
            @loop = loop
        end

        # Lazy eval the IP
        def remote_ip
            @remote_ip ||= @socket.peername[0]
        end

        # Creates a new request state object
        def start_parsing
            @parsing = Request.new(remote_ip, @port, @app)
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


        protected


        def send_response(result)
            # As we have come back from another thread the socket may have closed
            # This check is an optimisation, the call to write and shutdown would fail safely
            if !@socket.closed
                @socket.write @request.response
                if @request.keep_alive == false
                    @socket.shutdown
                end
            end
            # continue processing (don't wait for write to complete)
            # if the write fails it will close the socket
            nil
        end

        def send_error(reason)
            p "send error: #{reason.message}\n#{reason.backtrace.join("\n")}\n"
            # log error reason
            # TODO:: send response (500 internal error)
            # no need to close the socket as this isn't fatal
            nil
        end

        def process_next(result)
            @request = @pending.shift
            @current_worker = @loop.work @work
            @current_worker.then @send_response, @send_error   # resolves the promise with a promise
        end

        def work
            @request.execute!
        end
    end
end
