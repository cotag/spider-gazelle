require 'set'


module SpiderGazelle
    class Spider


        DEFAULT_OPTIONS = {
            :gazelle_count => ::Libuv.cpu_count || 1,
            :Host => '127.0.0.1',
            :Port => 8081
        }

        NEW_SOCKET = 's'.freeze
        KILL_GAZELLE = 'k'.freeze

        STATES = [:dead, :reanimating, :running, :squashing]
        MODES = [:thread, :process]    # TODO:: implement process


        def initialize(app, options = {})
            @spider = Libuv::Loop.new
            log = Logger.new(STDOUT)
            log.level = Logger::DEBUG
            #Logging.debug = true
            @app = Rack::CommonLogger.new(app, log)
            @options = DEFAULT_OPTIONS.merge(options)

            # Manage the set of Gazelle socket listeners
            @loops = Set.new
            @select_loop = @loops.cycle     # provides a looping enumerator for our round robin
            @accept_loop = method(:accept_loop)

            # Manage the set of Gazelle signal pipes
            @gazella = Set.new
            @accept_gazella = method(:accept_gazella)

            # Connection management
            @accept_connection = method(:accept_connection)
            @new_connection = method(:new_connection)

            @status = :dead
            @mode = :thread

            # Update the base request environment
            Request::PROTO_ENV[Request::SERVER_PORT] = @options[:port]
        end

        # Start the server (this method blocks until completion)
        def run
            return unless @status == :dead
            @status = :reanimating
            @spider.run &method(:reanimate)
        end

        # If the spider is running we will request to squash it (thread safe)
        def stop
            @squash.call
        end


        protected


        # There is a new connection pending
        # We accept it
        def new_connection(server)
            server.accept @accept_connection
        end

        # Once the connection is accepted we disable Nagles Algorithm
        # This improves performance as we are using vectored or scatter/gather IO
        # Then we send the socket, round robin, to the gazelle loops
        def accept_connection(client)
            client.enable_nodelay
            loop = @select_loop.next
            loop.write2(client, NEW_SOCKET)
        end


        # A new gazelle is ready to accept commands
        def accept_gazella(gazelle)
            p "gazelle #{@gazella.size} signal port ready"
            # add the signal port to the set
            @gazella.add gazelle
            gazelle.finally do
                @gazella.delete gazelle
            end
        end

        # A new gazelle loop is ready to accept sockets
        # We start the server as soon as the first gazelle is ready
        def accept_loop(loop)
            p "gazelle #{@loops.size} loop running"

            # start accepting connections
            if @loops.size == 0
                # Bind the socket
                @tcp = @spider.tcp
                @tcp.bind(@options[:Host], @options[:Port], @new_connection)
                @tcp.listen(1024)
                @tcp.catch do |e|
                    p "tcp bind error: #{e}"
                end
            end

            @loops.add loop      	# add the new gazelle to the set
            @select_loop.rewind     # update the enumerator with the new gazelle

            # If a gazelle dies or shuts down we update the set
            loop.finally do
                @loops.delete loop
                @select_loop.rewind

                if @loops.size == 0
                    @tcp.close
                end
            end
        end

        # Triggers the creation of gazelles
        def reanimate(logger)
            logger.progress do |level, errorid, error|
                begin
                    p "Log called: #{level}: #{errorid}\n#{error.message}\n#{error.backtrace.join("\n")}\n"
                rescue Exception
                    p 'error in gazelle logger'
                end
            end

            # Create a function for stopping the spider from another thread
            @squash = @spider.async do
                squash
            end

            # Bind the pipe for sending sockets to gazelle
            begin
                File.unlink(DELEGATE_PIPE)
            rescue
            end
            @delegator = @spider.pipe(true)
            @delegator.bind(DELEGATE_PIPE) do 
                @delegator.accept @accept_loop
            end
            @delegator.listen(128)

            # Bind the pipe for communicating with gazelle
            begin
                File.unlink(SIGNAL_PIPE)
            rescue
            end
            @signaller = @spider.pipe(true)
            @signaller.bind(SIGNAL_PIPE) do
                @signaller.accept @accept_gazella
            end
            @signaller.listen(128)


            # Launch the gazelle here
            @options[:gazelle_count].times do
                Thread.new do
                    gazelle = Gazelle.new(@app, @options)
                    gazelle.run
                end
            end

            # Signal gazelle death here
            @spider.signal(:INT) do
                squash
            end

            # Update state only once the event loop is ready
            @status = :running
        end


        # Triggers a shutdown of the gazelles.
        # We ensure the process is running here as signals can be called multiple times
        def squash
            if @status == :running

                # Update the state and close the socket
                @status = :squashing
                @tcp.close

                # Signal all the gazelle to shutdown
                promises = []
                @gazella.each do |gazelle|
                    promises << gazelle.write(KILL_GAZELLE)
                end

                # Once the signal has been sent we can stop the spider loop
                @spider.finally(*promises).finally do
                    # TODO:: need a better system for ensuring these are cleaned up
                    begin
                        @delegator.close
                        File.unlink(DELEGATE_PIPE)
                    rescue
                    end
                    begin
                        @signaller.close
                        File.unlink(SIGNAL_PIPE)
                    rescue
                    end
                    @spider.stop
                    @status = :dead
                end
            end
        end
    end
end
