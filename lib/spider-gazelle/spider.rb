# frozen_string_literal: true

require 'spider-gazelle/spider/app_store'      # Manages the loaded applications
require 'spider-gazelle/spider/binding'        # Holds a reference to a bound port
require 'spider-gazelle/spider/http1'          # Parses and responds to HTTP1 requests
require 'securerandom'


module SpiderGazelle
    class Spider
        include Singleton


        # This allows applications to recieve a callback once the server has
        # completed loading the applications. Port binding is in progress
        def loaded
            @load_complete.promise
        end

        # Applications can query the availability of various modes to share resources
        def in_mode?(mode)
            !!@loading[mode.to_sym]
        end

        attr_reader :logger, :threads


        def initialize
            @logger = Logger.instance
            @signaller = Signaller.instance
            @thread = @signaller.thread

            # Gazelle pipe connection management
            @gazelles = {
                # thread: [],
                # inline: gazelle_instance
            }
            @counts = {
                # process: number
                # thread: number
            }
            @loading = {}     # mode => load defer
            @bindings = {}    # port => binding
            @iterators = {}   # mode => gazelle round robin iterator
            @iterator_source = {}   # mode => gazelle thread array (iterator source)

            @running = true
            @loaded = false
            @bound = false

            @load_complete = @thread.defer
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
            load_promise = load_applications
            load_promise.then do
                # Check a shutdown request didn't occur as we were loading
                if @running
                    @logger.verbose "All gazelles running"

                    # This happends on the master thread so we don't need to check
                    # for the shutdown events here
                    bind_application_ports
                else
                    @logger.warn "A shutdown event occured while loading"
                    perform_shutdown
                end
            end

            # Provide applications with a load complete callback
            @load_complete.resolve(load_promise)
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

            @logger.verbose { "Spider Pid: #{Process.pid} shutting down (loaded #{@loaded})" }

            if @loaded
                perform_shutdown
            else
                @running = false
            end
        end


        protected


        def load_applications
            loaded = []
            @logger.info "Environment: #{ENV['RACK_ENV']} on #{RUBY_ENGINE || 'ruby'} #{RUBY_VERSION}"

            # Load the different types of gazelles required
            @options.each do |app|
                @logger.info "Loading: #{app[:rackup]}" if app[:rackup]
                AppStore.load(app[:rackup], app)

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

            if mode == :inline
                # Start the gazelle
                require 'spider-gazelle/gazelle'
                gaz = ::SpiderGazelle::Gazelle.new(@thread, mode).run!(options)
                @gazelles[:inline] = gaz

                # Setup the round robin
                itr = [gaz]
                @iterator_source[mode] = [gaz]
                @iterators[mode] = [gaz.thread].cycle

                defer.resolve(true)
            else
                require 'thread'

                count = @counts[mode] = count || ::Libuv.cpu_count || 1
                @logger.info "#{mode.to_s.capitalize} count: #{count}"

                require 'spider-gazelle/gazelle'
                reactor = Reactor.instance

                @threads = []
                loaded = []
                count.times do
                    loading = @thread.defer
                    loaded << loading.promise

                    thread = ::Libuv::Reactor.new
                    @threads << thread

                    Thread.new { load_gazelle_thread(reactor, thread, mode, options, loading) }
                end

                defer.resolve(@thread.all(*loaded).then { |gazelles|
                    @iterator_source[mode] = gazelles
                    @iterators[mode] = gazelles.map { |gaz| gaz.thread }.cycle
                })
            end

            defer.promise
        end

        def load_gazelle_thread(reactor, thread, mode, options, loading)
            # Log any unhandled errors
            thread.notifier { |*args| reactor.log(*args) }
            # Give current requests 5 seconds to complete
            thread.on_program_interrupt do
                timer = thread.timer {
                    puts "Forcing gazelle exit"
                    thread.stop
                }
                timer.unref
                timer.start(5000)
            end
            thread.run do |thread|
                # Start the gazelle
                gaz = ::SpiderGazelle::Gazelle.new(thread, :thread)
                thread.next_tick do
                    loading.resolve(gaz)
                end
                gaz.run!(options)
            end
        end

        def bind_application_ports
            @bound = true
            @loaded = true

            @options.each do |options|
                @logger.verbose { "Loading rackup #{options}" }
                iterator = @iterators[options[:mode]]

                binding = @bindings[options[:port]] = Binding.new(iterator, options)
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
            @shutdown = true
            promises = []

            @iterator_source.each do |mode, gazelles|
                # End communication with the gazelle threads
                gazelles.each do |gazelle|
                    defer = @thread.defer
                    gazelle.shutdown(defer)
                    promises << defer.promise
                end
            end

            # Finish shutdown after all signals have been sent
            @shutdown_defer.resolve(@thread.finally(*promises))
        end
    end
end
