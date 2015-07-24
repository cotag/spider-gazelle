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
        end

        def run!(options)
            @options = options
            @logger.verbose 'Spider Started!'.freeze
            @signaller.authenticate(options[0][:spider])
        end

        # Load gazelles and make the required bindings
        def ready
            start_gazelle_server
            load_applications.then do
                @logger.verbose "All gazelles running".freeze

                bind_application_ports
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
        def shutdown
            @running = false
        end


        protected


        # This starts the server the gazelles will be connecting to
        def start_gazelle_server
            @logger.verbose { "Spider server starting" }

            @pipe = @thread.pipe :ipc
            begin
                File.unlink SPIDER_SERVER
            rescue
            end

            check = method(:check_credentials)
            @pipe.bind(SPIDER_SERVER) do |client|
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
            @pipe.listen(128)
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

            # Load the different types of gazelles required
            @options.each do |app|
                @logger.info "Loading: #{app[:rackup]}"

                mode = app[:mode]
                loaded << load_gazelles(mode, app[:count], @options[0][:spider]) unless @loading[mode]
            end

            # Return a promise that resolves when all the gazelles are loaded
            # Gazelles will only load the applications that apply to them based on the application type
            @thread.all(*loaded)
        end

            
        def load_gazelles(mode, count, pass)
            defer = @thread.defer
            @loading[mode] = defer

            if mode == :no_ipc
                # TODO:: Load a single gazelle here
            else
                count = @counts[mode] = count || ::Libuv.cpu_count || 1
                @logger.info "#{mode.to_s.capitalize} count: #{count}"

                if mode == :thread
                    @threads = []
                    count.times { @threads << ::Libuv::Loop.new }

                    # TODO:: For each thread load a gazelle
                else
                    require 'thread'

                    # Remove the spider option
                    args = LaunchControl.instance.args - ['-s', pass]

                    # Build the command with the gazelle option
                    args = [EXEC_NAME, '-g', @password] + args
                    #cmd = "#{EXEC_NAME} -g #{@password} #{args}"

                    @logger.verbose { "Launching #{count} gazelle processes" }
                    count.times do
                        Thread.new { launch_gazelle(args) }
                    end
                end
            end

            defer.promise
        end

        def launch_gazelle(cmd)
            # Wait for the process to close
            result = system(*cmd)

            # Kill the spider if a process exits unexpectedly
            if @running
                @thread.schedule do
                    @logger.error "Gazelle process exited unexpectedly with #{result}"
                    @signaller.general_failure
                end
            end
        end

        def bind_application_ports
            @options.each_index do |id|
                options = @options[id]
                iterator = @iterators[options[:port]]

                binding = @bindings[options[:port]] = Binding.new(iterator, id.to_s, options)
                binding.bind
            end
        end
    end
end
