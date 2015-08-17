require 'spider-gazelle/spider/binding'        # Holds a reference to a bound port
require 'securerandom'


module SpiderGazelle
    class Spider
        include Singleton


        def initialize
            @logger = Logger.instance
            @signaller = Signaller.instance
            @thread = @signaller.thread

            # Gazelle pipe connection management
            @gazelles = {
                # process: [],
                # thread: [],
                # no_ipc: gazelle_instance
            }
            @counts = {
                # process: number
                # thread: number
            }
            @loading = {}     # mode => load defer
            @bindings = {}    # port => binding
            @iterators = {}   # mode => gazelle round robin iterator

            @password = SecureRandom.hex

            @running = true
            @loaded = false
            @bound = false
        end

        def run!(options)
            @options = options
            @logger.verbose { "Spider Pid: #{Process.pid} started" }
            if options[0][:isolate]
                ready
            else
                @signaller.authenticate(options[0][:spider])
            end
        end

        # Load gazelles and make the required bindings
        def ready
            start_gazelle_server
            load_applications.then do
                # Check a shutdown request didn't occur as we were loading
                if @running
                    @logger.verbose "All gazelles running".freeze

                    # This happends on the master thread so we don't need to check
                    # for the shutdown events here
                    bind_application_ports
                else
                    @logger.warn "A shutdown event occured while loading".freeze
                    perform_shutdown
                end
            end
        end

        # Load gazelles and wait for the bindings to be sent
        def wait
            
        end

        # Pass existing bindings to the master process
        def update

        end

        # Load a second application (requires a new port binding)
        def load

        end

        # Shutdown after current requests have completed
        def shutdown(finished)
            @shutdown_defer = finished

            @logger.verbose { "Spider Pid: #{Process.pid} shutting down" }

            if @loaded
                perform_shutdown
            else
                @running = false
            end
        end


        protected


        # This starts the server the gazelles will be connecting to
        def start_gazelle_server
            @pipe_file = "#{SPIDER_SERVER}#{Process.pid}"
            @logger.verbose { "Spider server starting on #{@pipe_file}" }

            @pipe = @thread.pipe :ipc
            begin
                File.unlink @pipe_file
            rescue
            end

            check = method(:check_credentials)
            @pipe.bind(@pipe_file) do |client|
                @logger.verbose { "Gazelle <0x#{client.object_id.to_s(16)}> connection made" }

                # Shutdown if there is an error with any of the gazelles
                client.catch do |error|
                    @logger.print_error(error, "Gazelle <0x#{client.object_id.to_s(16)}> connection error")
                    @signaller.general_failure
                end

                # Client closed gracefully
                client.finally do
                    @gazelles.delete client
                    @logger.verbose { "Gazelle <0x#{client.object_id.to_s(16)}> disconnected" }
                end

                client.progress check
                client.start_read
            end

            # catch server errors
            @pipe.catch do |error|
                @logger.print_error(error)
                @signaller.general_failure
            end

            # start listening
            @pipe.listen(INTERNAL_PIPE_BACKLOG)
        end

        def check_credentials(data, gazelle)
            password, mode = data.split(' ', 2)
            mode_sym = mode.to_sym

            if password == @password && MODES.include?(mode_sym)
                @gazelles[mode_sym] ||= []
                gazelles = @gazelles[mode_sym]
                gazelles << gazelle
                @logger.verbose { "Gazelle <0x#{gazelle.object_id.to_s(16)}> connection was validated" }

                # All the gazelles have loaded. Lets start processing requests
                if gazelles.length == @counts[mode_sym]
                    @logger.verbose { "#{mode.capitalize} gazelles are ready" }

                    @iterators[mode_sym] = gazelles.cycle
                    @loading[mode_sym].resolve(true)
                end
            else
                @logger.warn "Gazelle <0x#{gazelle.object_id.to_s(16)}> connection closed due to bad credentials"
                gazelle.close
            end
        end

        def load_applications
            loaded = []
            @logger.info "Environment: #{ENV['RACK_ENV']} on #{RUBY_ENGINE || 'ruby'} #{RUBY_VERSION}"

            # Load the different types of gazelles required
            @options.each do |app|
                @logger.info "Loading: #{app[:rackup]}"

                mode = app[:mode]
                loaded << load_gazelles(mode, app[:count], @options) unless @loading[mode]
            end

            # Return a promise that resolves when all the gazelles are loaded
            # Gazelles will only load the applications that apply to them based on the application type
            @thread.all(*loaded)
        end

            
        def load_gazelles(mode, count, options)
            defer = @thread.defer
            @loading[mode] = defer

            pass = options[0][:spider]

            if mode == :no_ipc
                # Provide the password to the gazelle instance
                options[0][:gazelle] = @password

                # Start the gazelle
                require 'spider-gazelle/gazelle'
                gaz = ::SpiderGazelle::Gazelle.new(@thread, mode).run!(options)
                @gazelles[:no_ipc] = gaz

                # Setup the round robin
                @iterators[mode] = gaz
                defer.resolve(true)
            else
                require 'thread'

                # Provide the password to the gazelle instance
                options[0][:gazelle] = @password
                options[0][:gazelle_ipc] = @pipe_file

                count = @counts[mode] = count || ::Libuv.cpu_count || 1
                @logger.info "#{mode.to_s.capitalize} count: #{count}"

                if mode == :thread
                    require 'spider-gazelle/gazelle'
                    reactor = Reactor.instance

                    @threads = []
                    count.times do
                        thread = ::Libuv::Loop.new
                        @threads << thread

                        Thread.new { load_gazelle_thread(reactor, thread, mode, options) }
                    end
                else
                    # Remove the spider option
                    args = LaunchControl.instance.args - ['-s', pass]

                    # Build the command with the gazelle option
                    args = [EXEC_NAME, '-g', @password, '-f', @pipe_file] + args

                    @logger.verbose { "Launching #{count} gazelle processes" }
                    count.times do
                        Thread.new { launch_gazelle(args) }
                    end
                end
            end

            defer.promise
        end

        def load_gazelle_thread(reactor, thread, mode, options)
            thread.run do |logger|
                # Log any unhandled errors
                logger.progress reactor.method(:log)

                # Start the gazelle
                ::SpiderGazelle::Gazelle.new(thread, :thread).run!(options)
            end
        end

        def launch_gazelle(cmd)
            # Wait for the process to close
            result = system(*cmd)

            # Kill the spider if a process exits unexpectedly
            if @running
                @thread.schedule do
                    if result
                        @logger.verbose "Gazelle process exited with exit status 0".freeze
                    else
                        @logger.error "Gazelle process exited unexpectedly".freeze
                    end
                     
                    @signaller.general_failure
                end
            end
        end

        def bind_application_ports
            @bound = true
            @loaded = true

            @options.each_index do |id|
                options = @options[id]
                iterator = @iterators[options[:port]]

                binding = @bindings[options[:port]] = Binding.new(iterator, id.to_s, options)
                binding.bind
            end
        end


        # -------------------
        # Shutdown Management
        # -------------------
        def perform_shutdown
            if @bound
                # Unbind any ports we are bound to
                ports = []
                @bindings.each do |port, binding|
                    ports << binding.unbind
                end

                # Shutdown once the ports are all closed
                @thread.finally(*ports).then do
                    shutdown_gazelles
                end
            else
                shutdown_gazelles
            end
        end

        def shutdown_gazelles
            @bound = false
            promises = []

            @iterators.each do |mode, itr|
                if mode == :no_ipc
                    # itr is a gazelle in no_ipc mode
                    defer = @thread.defer
                    itr.shutdown(defer)
                    promises << defer.promise

                else
                    # Extract the array from the iterator
                    gazelles = itr.entries 1

                    # End communication with the gazelle threads / processes
                    gazelles.each do |gazelle|
                        promises << gazelle.close
                    end
                end
            end

            # Finish shutdown after all signals have been sent
            @shutdown_defer.resolve(@thread.finally(*promises))
        end
    end
end
