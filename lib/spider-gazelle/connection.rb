require 'stringio'


module SpiderGazelle
    class Connection < ::Libuv::Q::DeferredPromise


        SET_INSTANCE_TYPE = proc {|inst| inst.type = :request}


        attr_reader :state, :parsing


        def initialize(loop, socket, queue) # TODO:: port information
            # initialize the promise
            super(loop, loop.defer)
            @defer.resolve(socket)  # Connection depends on the socket

            # A single parser instance per-connection (supports pipelining)
            @state = ::HttpParser::Parser.new_instance &SET_INSTANCE_TYPE
            @pending = []

            # Work callback for thread pool processing
            @request = nil
            @work = proc {
                @request.execute!
            }
            # Called after the work on the thread pool is complete
            @send_response = proc {
                @socket.write @request.response
                if !@request.keep_alive
                    @socket.shutdown
                end
                # continue processing (don't wait for write to complete)
                # if the write fails it will close the socket
                nil
            }
            @send_error = proc { |reason|
                p "send error: #{reason}"
                # log error reason
                # send response (500 internal error)
                # no need to close the socket as this isn't fatal
                nil
            }
            # Used to chain promises (ensures requests are processed in order)
            @process_next = proc {
                @request = @pending.shift
                work = @loop.work @work
                work.then @send_response, @send_error   # resolves the promise with a promise
            }
            @worker = queue  # start queue with an existing resolved promise (::Libuv::Q::ResolvedPromise.new(@loop, true))

            # Socket for writing the response
            @socket = socket
        end

        # Creates a new request state object
        def start_request(request)
            @parsing = request
        end

        # Chains the work in a promise queue
        def finished_request
            if @state.keep_alive?
                @parsing.keep_alive = true
            else
                @socket.stop_read
            end
            @parsing.prepare(@state)
            @pending.push @parsing
            @worker = @worker.then @process_next
        end

        # The parser encountered an error
        def parsing_error
            # TODO::log error (available in the @request object)
            p "parsing error #{@state.error}"

            # We no longer care for any further requests from this client
            # however we will finish processing any valid pipelined requests before shutting down
            @socket.stop_read
            @worker = @worker.then do
                # TODO:: send response (400 bad request)
                @socket.shutdown
            end
        end
    end
end
