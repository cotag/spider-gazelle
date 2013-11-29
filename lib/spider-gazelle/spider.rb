require 'set'
require 'thread'
require 'singleton'


module SpiderGazelle
    class Spider
        include Singleton


        USE_TLS = 'T'.freeze
        NO_TLS = 'F'.freeze
        KILL_GAZELLE = 'k'.freeze

        STATES = [:reanimating, :running, :squashing, :dead]
        MODES = [:thread, :process]    # TODO:: implement process


        attr_reader :state, :threads


        def initialize
            # Threaded mode by default
            @status = :reanimating
            @mode = :thread
            @bindings = {
                # id => [bind1, bind2]
            }
            @delegate = method(:delegate)

            # Keep track of the loading process
            @waiting_gazelle = 0
            @gazelle_count = 0

            # Spider always runs on the default loop
            @web = ::Libuv::Loop.default
            @gazelles_loaded = @web.defer
            @web.run &method(:reanimate)
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

            app_id = get_id_from(app)
            if app_id != false
                @web.schedule do
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
                end
            end

            defer.promise
        end

        # A thread safe method for unloading a rack app.
        #
        # @param app [String, Object] rackup filename or the rack app instance
        # @return [::Libuv::Q::Promise] resolves once the app is loaded (and bound if SG is running)
        def unload(app)
            defer = @web.defer

            app_id = get_id_from(app)
            if app_id != false
                @web.schedule do
                    AppStore.delete(app_id)
                    defer.resolve(stop(app, app_id))
                    @bindings.delete(app_id)
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
            app_id = app_id || get_id_from(app)

            if app_id != false && @status == :running
                @web.schedule do
                    bindings = @bindings[app_id] ||= []
                    starting = []

                    bindings.each do |binding|
                        starting << binding.bind
                    end
                    defer.resolve(::Libuv::Q.all(@web, *starting))
                end
            end

            defer.promise
        end

        # Stops the app specified. If loaded
        #
        # @param app [String, Object] rackup filename or the rack app instance
        # @return [::Libuv::Q::Promise] resolves once the app is no longer bound to the port
        def stop(app, app_id = nil)
            defer = @web.defer
            app_id = app_id || get_id_from(app)

            if app_id != false
                @web.schedule do
                    bindings = @bindings[app_id]
                    closing = []

                    if @status == :running && bindings != nil
                        bindings.each do |binding|
                            closing << binding.unbind
                        end
                    end
                    defer.resolve(::Libuv::Q.all(@web, *closing))
                end
            end

            defer.promise
        end

        # Signals spider gazelle to shutdown gracefully
        def shutdown
            @squash.call
        end


        protected


        # Selects an appropriate app ID for the given app 
        def get_id_from(app, defer = nil)
            if File.exists? app.to_s
                app
            elsif app.respond_to? :call
                app.__id__
            else
                defer.reject('invalid web application') unless defer.nil?
                false
            end
        end

        # Called from the binding for sending to gazelles
        def delegate(client, tls, port, app_id)
            indicator = tls == true ? USE_TLS : NO_TLS
            loop = @select_handler.next
            loop.write2(client, "#{indicator} #{port} #{app_id}")
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

            # Manage the set of Gazelle socket listeners
            @threads = Set.new
            cpus = ::Libuv.cpu_count || 1
            cpus.times do
                @threads << Libuv::Loop.new
            end

            @handlers = Set.new
            @select_handler = @handlers.cycle     # provides a looping enumerator for our round robin
            @accept_handler = method(:accept_handler)

            # Manage the set of Gazelle signal pipes
            @gazella = Set.new
            @accept_gazella = method(:accept_gazella)

            # Create a function for stopping the spider from another thread
            @squash = @web.async &method(:squash)

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
                    gazelle = Gazelle.new(thread)
                    gazelle.run
                end
                @waiting_gazelle += 1
            end

            # Signal gazelle death here
            @web.signal(:INT) do
                squash
            end

            # Update state only once the event loop is ready
            @gazelles_loaded.promise
        end

        # Triggers a shutdown of the gazelles.
        # We ensure the process is running here as signals can be called multiple times
        def squash
            if @status == :running

                # Update the state and close the socket
                @status = :squashing
                @bindings.each_key do |key|
                    unload(key)
                end

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
                @status = :running

                # Start any bindings that are already present
                @bindings.each_key do |key|
                    start(key)
                end

                # Inform any listeners that we have completed loading
                @gazelles_loaded.resolve(@gazelle_count)
            end
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
    end
end
