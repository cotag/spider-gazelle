require 'set'
require 'thread'
require 'logger'
require 'singleton'
require 'fileutils'


module SpiderGazelle
    class Spider
        include Singleton


        USE_TLS = 'T'.freeze
        NO_TLS = 'F'.freeze
        KILL_GAZELLE = 'k'.freeze

        STATES = [:reanimating, :running, :squashing, :dead]
        MODES = [:thread, :process, :no_ipc]    # TODO:: implement clustering using processes

        DEFAULT_OPTIONS = {
            :Host => '0.0.0.0',
            :Port => 8080,
            :Verbose => false
        }

        attr_reader :state, :mode, :threads, :logger


        def initialize
            # Threaded mode by default
            @status = :reanimating
            @bindings = {
                # id => [bind1, bind2]
            }

            mode = ENV['SG_MODE'] || :thread
            @mode = mode.to_sym

            if @mode == :no_ipc
                @delegate = method(:direct_delegate)
            else
                @delegate = method(:delegate)
            end
            @squash = method(:squash)


            log_path = ENV['SG_LOG'] || File.expand_path('../../../logs/server.log', __FILE__)
            dirname = File.dirname(log_path)
            unless File.directory?(dirname)
                FileUtils.mkdir_p(dirname)
            end
            @logger = ::Logger.new(log_path.to_s, 10, 4194304)

            # Keep track of the loading process
            @waiting_gazelle = 0
            @gazelle_count = 0

            # Spider always runs on the default loop
            @web = ::Libuv::Loop.default
            @gazelles_loaded = @web.defer

            # Start the server
            if @web.reactor_running?
                # Call run so we can be notified of errors
                @web.run &method(:reanimate)
            else
                # Don't block on this thread if default reactor not running
                Thread.new do
                    @web.run &method(:reanimate)
                end
            end
        end

        def run(&block)
            @web.run &block
        end

        def self.run(app, options = {})
            options = DEFAULT_OPTIONS.merge(options)

            instance.run do |logger|
                logger.progress do |level, errorid, error|
                    begin
                        puts "Log called: #{level}: #{errorid}\n#{error.message}\n#{error.backtrace.join("\n")}\n"
                    rescue Exception
                        p 'error in gazelle logger'
                    end
                end

                puts "Look out! Here comes Spider-Gazelle #{::SpiderGazelle::VERSION}!"
                puts "* Environment: #{ENV['RACK_ENV']} on #{RUBY_ENGINE || 'ruby'} #{RUBY_VERSION}"
                server = ::SpiderGazelle::Spider.instance
                server.loaded.then do
                    puts "* Loading: #{app}"

                    # yield server if block_given?

                    server.load(app, options).catch(proc {|e|
                        puts "#{e.message}\n#{e.backtrace.join("\n") unless e.backtrace.nil?}\n"
                    }).finally do
                        # This will execute if the TCP binding is lost
                        server.shutdown
                    end

                    puts "* Listening on tcp://#{options[:Host]}:#{options[:Port]}"
                end
            end
        end

        # Provides a promise that resolves when we are read to start binding applications
        #
        # @return [::Libuv::Q::Promise] that indicates when the gazelles are loaded
        def loaded
            @gazelles_loaded.promise unless @gazelles_loaded.nil?
        end

        # A thread safe method for loading and binding rack apps. The app can be pre-loaded or a rackup file
        #
        # @param app [String, Object] rackup filename or rack app
        # @param ports [Hash, Array] binding config or array of binding config
        # @return [::Libuv::Q::Promise] resolves once the app is loaded (and bound if SG is running)
        def load(app, ports = [])
            defer = @web.defer

            ports = [ports] if ports.is_a? Hash
            ports << {} if ports.empty?

            @web.schedule do
                begin
                    app_id = AppStore.load(app)
                    bindings = @bindings[app_id] ||= []

                    ports.each do |options|
                        binding = Binding.new(@web, @delegate, app_id, options)
                        bindings << binding
                    end

                    if @status == :running
                        defer.resolve(start(app, app_id))
                    else
                        defer.resolve(true)
                    end
                rescue Exception => e
                    defer.reject(e)
                end
            end

            defer.promise
        end

        # Starts the app specified. It must already be loaded
        #
        # @param app [String, Object] rackup filename or the rack app instance
        # @return [::Libuv::Q::Promise] resolves once the app is bound to the port
        def start(app, app_id = nil)
            defer = @web.defer
            app_id = app_id || AppStore.lookup(app)

            if app_id != nil && @status == :running
                @web.schedule do
                    bindings = @bindings[app_id] ||= []
                    starting = []

                    bindings.each do |binding|
                        starting << binding.bind
                    end
                    defer.resolve(::Libuv::Q.all(@web, *starting))
                end
            elsif app_id.nil?
                defer.reject('application not loaded')
            else
                defer.reject('server not running')
            end

            defer.promise
        end

        # Stops the app specified. If loaded
        #
        # @param app [String, Object] rackup filename or the rack app instance
        # @return [::Libuv::Q::Promise] resolves once the app is no longer bound to the port
        def stop(app, app_id = nil)
            defer = @web.defer
            app_id = app_id || AppStore.lookup(app)

            if !app_id.nil?
                @web.schedule do
                    bindings = @bindings[app_id]
                    closing = []

                    if bindings != nil
                        bindings.each do |binding|
                            result = binding.unbind
                            closing << result unless result.nil?
                        end
                    end
                    defer.resolve(::Libuv::Q.all(@web, *closing))
                end
            else
                defer.reject('application not loaded')
            end

            defer.promise
        end

        # Signals spider gazelle to shutdown gracefully
        def shutdown
            @signal_squash.call
        end


        protected


        # Called from the binding for sending to gazelles
        def delegate(client, tls, port, app_id)
            indicator = tls ? USE_TLS : NO_TLS
            loop = @select_handler.next
            loop.write2(client, "#{indicator} #{port} #{app_id}")
        end

        def direct_delegate(client, tls, port, app_id)
            indicator = tls ? USE_TLS : NO_TLS
            @gazelle.__send__(:new_connection, "#{indicator} #{port} #{app_id}", client)
        end

        # Triggers the creation of gazelles
        def reanimate(logger)
            # Manage the set of Gazelle socket listeners
            @threads = Set.new

            if @mode == :thread
                cpus = ::Libuv.cpu_count || 1
                cpus.times do
                    @threads << Libuv::Loop.new
                end
            elsif @mode == :no_ipc
                # TODO:: need to perform process mode as well
                @threads << @web
            end

            @handlers = Set.new
            @select_handler = @handlers.cycle     # provides a looping enumerator for our round robin
            @accept_handler = method(:accept_handler)

            # Manage the set of Gazelle signal pipes
            @gazella = Set.new
            @accept_gazella = method(:accept_gazella)

            # Create a function for stopping the spider from another thread
            @signal_squash = @web.async @squash

            # Link up the loops logger
            logger.progress method(:log)

            if @mode == :no_ipc
                @gazelle = Gazelle.new(@web, @logger, @mode)
                @gazelle_count = 1
                start_bindings
            else
                # Bind the pipe for sending sockets to gazelle
                begin
                    File.unlink(DELEGATE_PIPE)
                rescue
                end
                @delegator = @web.pipe(true)
                @delegator.bind(DELEGATE_PIPE) do 
                    @delegator.accept @accept_handler
                end
                @delegator.listen(16)

                # Bind the pipe for communicating with gazelle
                begin
                    File.unlink(SIGNAL_PIPE)
                rescue
                end
                @signaller = @web.pipe(true)
                @signaller.bind(SIGNAL_PIPE) do
                    @signaller.accept @accept_gazella
                end
                @signaller.listen(16)

                # Launch the gazelle here
                @threads.each do |thread|
                    Thread.new do
                        gazelle = Gazelle.new(thread, @logger, @mode)
                        gazelle.run
                    end
                    @waiting_gazelle += 1
                end
            end

            # Signal gazelle death here
            @web.signal :INT, @squash

            # Update state only once the event loop is ready
            @gazelles_loaded.promise
        end

        # Triggers a shutdown of the gazelles.
        # We ensure the process is running here as signals can be called multiple times
        def squash(*args)
            if @status == :running

                # Update the state and close the socket
                @status = :squashing
                @bindings.each_key do |key|
                    stop(key)
                end

                if @mode == :no_ipc
                    @web.stop
                    @status = :dead
                else
                    # Signal all the gazelle to shutdown
                    promises = []
                    @gazella.each do |gazelle|
                        promises << gazelle.write(KILL_GAZELLE)
                    end

                    # Once the signal has been sent we can stop the spider loop
                    @web.finally(*promises).finally do

                        # TODO:: need a better system for ensuring these are cleaned up
                        #  Especially when we implement live migrations and process clusters
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

                        @web.stop
                        @status = :dead
                    end
                end
            end
        end

        # A new gazelle is ready to accept commands
        def accept_gazella(gazelle)
            #puts "gazelle #{@gazella.size} signal port ready"

            # add the signal port to the set
            @gazella.add gazelle
            gazelle.finally do
                @gazella.delete gazelle
                @waiting_gazelle -= 1
                @gazelle_count -= 1
            end

            @gazelle_count += 1
            if @waiting_gazelle == @gazelle_count
                start_bindings
            end
        end

        def start_bindings
            @status = :running

            # Start any bindings that are already present
            @bindings.each_key do |key|
                start(key)
            end

            # Inform any listeners that we have completed loading
            @gazelles_loaded.resolve(@gazelle_count)
        end

        # A new gazelle loop is ready to accept sockets
        # We start the server as soon as the first gazelle is ready
        def accept_handler(handler)
            #puts "gazelle #{@handlers.size} loop running"

            @handlers.add handler       # add the new gazelle to the set
            @select_handler.rewind     # update the enumerator with the new gazelle

            # If a gazelle dies or shuts down we update the set
            handler.finally do
                @handlers.delete handler
                @select_handler.rewind

                if @status == :running && @handlers.size == 0
                    # I assume if we made it here something went quite wrong
                    squash
                end
            end
        end

        def log(*args)
            msg = ''
            err = args[-1]
            if err && err.respond_to?(:backtrace)
                msg << "unhandled exception: #{err.message} (#{args[0..-2]})"
                msg << "\n#{err.backtrace.join("\n")}" if err.respond_to?(:backtrace) && err.backtrace
            else
                msg << "unhandled exception: #{args}"
            end
            @logger.error msg
        end
    end
end
