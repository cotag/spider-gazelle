require 'spider-gazelle/const'
require 'set'
require 'thread'
require 'logger'
require 'singleton'
require 'fileutils' # mkdir_p
require 'forwardable' # run method

module SpiderGazelle
  class Spider
    include Const
    include Singleton

    STATES = [:reanimating, :running, :squashing, :dead]
    # TODO:: implement clustering using processes
    MODES = [:thread, :process, :no_ipc]
    DEFAULT_OPTIONS = {
      Host: "0.0.0.0",
      Port: 8080,
      Verbose: false,
      tls: false,
      optimize_for_latency: true,
      backlog: 1024
    }

    attr_reader :state, :mode, :threads, :logger

    extend Forwardable
    def_delegators :@web, :run

    def self.run(app, options = {})
      options = DEFAULT_OPTIONS.merge options

      ENV['RACK_ENV'] = options[:environment].to_s if options[:environment]

      puts "Look out! Here comes Spider-Gazelle #{SPIDER_GAZELLE_VERSION}!"
      puts "* Environment: #{ENV['RACK_ENV']} on #{RUBY_ENGINE || 'ruby'} #{RUBY_VERSION}"

      server = instance
      server.run do |logger|
        logger.progress server.method(:log)
        server.loaded.then do
          puts "* Loading: #{app}"

          caught = proc { |e| puts("#{e.message}\n#{e.backtrace.join("\n")}") unless e.backtrace.nil? }
          server.load(app, options).catch(caught)
            .finally { Process.kill('INT', 0) } # Terminate the application if the TCP binding is lost

          puts "* Listening on tcp://#{options[:Host]}:#{options[:Port]}"
        end
      end
    end

    def initialize
      # Threaded mode by default
      reanimating!
      @bindings = {}
      # @bindings = {
      #   id => [bind1, bind2]
      # }

      # Single reactor in development
      if ENV['RACK_ENV'].to_sym == :development
        @mode = :no_ipc
      else
        mode = ENV['SG_MODE'] || :thread
        @mode = mode.to_sym
      end

      @delegate = method(no_ipc? ? :direct_delegate : :delegate)
      @squash = method(:squash)

      log_path = ENV['SG_LOG'] || File.expand_path('log/sg.log', Dir.pwd)
      dirname = File.dirname(log_path)
      FileUtils.mkdir_p(dirname) unless File.directory?(dirname)
      @logger = ::Logger.new(log_path.to_s, 10, 4194304)

      unless ::FFI::Platform.windows?
        # Create the PID file
        pid_path = ENV['SG_PID'] || File.expand_path('tmp/pids/sg.pid', Dir.pwd)
        dirname = File.dirname(pid_path)
        FileUtils.mkdir_p(dirname) unless File.directory?(dirname)
        @pid = Management::Pid.new(pid_path)
      end


      # Keep track of the loading process
      @waiting_gazelle = 0
      @gazelle_count = 0

      # Spider always runs on the default loop
      @web = ::Libuv::Loop.default
      @gazelles_loaded = @web.defer

      # Start the server
      reanimate
    end

    # Modes
    def thread?
      @mode == :thread
    end
    def process?
      @mode == :process
    end
    def no_ipc?
      @mode == :no_ipc
    end

    # Statuses
    def reanimating?
      @status == :reanimating
    end
    def reanimating!
      @status = :reanimating
    end
    def running?
      @status == :running
    end
    def running!
      @status = :running
    end
    def squashing?
      @status == :squashing
    end
    def squashing!
      @status = :squashing
    end
    def dead?
      @status == :dead
    end
    def dead!
      @status = :dead
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

      ports = [ports] if ports.is_a?(Hash)
      ports << {} if ports.empty?

      @web.schedule do
        begin
          app_id = AppStore.load app
          bindings = @bindings[app_id] ||= []

          ports.each { |options| bindings << Binding.new(@web, @delegate, app_id, options) }

          defer.resolve(running? ? start(app, app_id) : true)
        rescue Exception => e
          defer.reject e
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
      app_id ||= AppStore.lookup app

      if !app_id.nil? && running?
        @web.schedule do
          bindings = @bindings[app_id] ||= []
          starting = []

          bindings.each { |binding| starting << binding.bind }
          defer.resolve ::Libuv::Q.all(@web, *starting)
        end
      elsif app_id.nil?
        defer.reject 'application not loaded'
      else
        defer.reject 'server not running'
      end

      defer.promise
    end

    # Stops the app specified. If loaded
    #
    # @param app [String, Object] rackup filename or the rack app instance
    # @return [::Libuv::Q::Promise] resolves once the app is no longer bound to the port
    def stop(app, app_id = nil)
      defer = @web.defer
      app_id ||= AppStore.lookup app

      if !app_id.nil?
        @web.schedule do
          bindings = @bindings[app_id]
          closing = []

          bindings.each do |binding|
            result = binding.unbind
            closing << result unless result.nil?
          end unless bindings.nil?

          defer.resolve ::Libuv::Q.all(@web, *closing)
        end
      else
        defer.reject 'application not loaded'
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
      @select_handler.next.write2(client, "#{indicator} #{port} #{app_id}").finally do
        client.close
      end
    end

    def direct_delegate(client, tls, port, app_id)
      indicator = tls ? USE_TLS : NO_TLS
      @gazelle.__send__(:new_connection, "#{indicator} #{port} #{app_id}", client)
    end

    # Triggers the creation of gazelles
    def reanimate

      # Manage the set of Gazelle socket listeners
      @threads = Set.new

      if thread?
        cpus = ::Libuv.cpu_count || 1
        cpus.times { @threads << Libuv::Loop.new }
      elsif no_ipc?
        # TODO:: need to perform process mode as well
        @threads << @web
      end

      @handlers = Set.new
      @select_handler = @handlers.cycle # provides a looping enumerator for our round robin
      @accept_handler = method :accept_handler

      # Manage the set of Gazelle signal pipes
      @gazella = Set.new
      @accept_gazella = method :accept_gazella

      # Create a function for stopping the spider from another thread
      @signal_squash = @web.async @squash

      if no_ipc?
        @gazelle = Gazelle.new @web, @logger, @mode
        @gazelle_count = 1
        start_bindings
      else
        # Bind the pipe for sending sockets to gazelle
        begin
          File.unlink DELEGATE_PIPE
        rescue
        end
        @delegator = @web.pipe :with_socket_support
        @delegator.bind(DELEGATE_PIPE) { @delegator.accept @accept_handler }
        @delegator.listen INTERNAL_PIPE_BACKLOG

        # Bind the pipe for communicating with gazelle
        begin
          File.unlink SIGNAL_PIPE
        rescue
        end
        @signaller = @web.pipe
        @signaller.bind(SIGNAL_PIPE) { @signaller.accept @accept_gazella }
        @signaller.listen INTERNAL_PIPE_BACKLOG

        # Launch the gazelle here
        @threads.each do |thread|
          Thread.new { Gazelle.new(thread, @logger, @mode).run }
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
      if running?
        # Update the state and close the socket
        squashing!
        @bindings.each { |key, val| stop(key) }

        if no_ipc?
          @web.stop
          dead!
        else
          # Signal all the gazelle to shutdown
          promises = @gazella.map { |gazelle| gazelle.write(KILL_GAZELLE) }

          # Once the signal has been sent we can stop the spider loop
          @web.finally(*promises).finally do
            # TODO:: need a better system for ensuring these are cleaned up
            #  Especially when we implement live migrations and process clusters
            begin
              @delegator.close
              File.unlink DELEGATE_PIPE
            rescue
            end
            begin
              @signaller.close
              File.unlink SIGNAL_PIPE
            rescue
            end

            @web.stop
            dead!
          end
        end
      end
    end

    # A new gazelle is ready to accept commands
    def accept_gazella(gazelle)
      # add the signal port to the set
      @gazella.add gazelle
      gazelle.finally do
        @gazella.delete gazelle
        @waiting_gazelle -= 1
        @gazelle_count -= 1
      end

      @gazelle_count += 1
      start_bindings if @waiting_gazelle == @gazelle_count
    end

    def start_bindings
      running!

      # Start any bindings that are already present
      @bindings.each { |key, val| start(key) }

      # Inform any listeners that we have completed loading
      @gazelles_loaded.resolve @gazelle_count
    end

    # A new gazelle loop is ready to accept sockets.
    # We start the server as soon as the first gazelle is ready
    def accept_handler(handler)
      # Add the new gazelle to the set
      @handlers.add handler
      # Update the enumerator with the new gazelle
      @select_handler.rewind

      # If a gazelle dies or shuts down we update the set
      handler.finally do
        @handlers.delete handler
        @select_handler.rewind

        # I assume if we made it here something went quite wrong
        squash if running? && @handlers.empty?
      end
    end

    # TODO FIXME Review this method.
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
      ::Libuv::Q.reject @web, msg
    end
  end
end
