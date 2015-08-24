require 'set'
require 'optparse'
require 'spider-gazelle/logger'


module SpiderGazelle
    module Options
        DEFAULTS = {
            host: "0.0.0.0",
            port: 3000,
            verbose: false,
            tls: false,
            backlog: 5000,
            rackup: "#{Dir.pwd}/config.ru",
            mode: :thread,
            app_mode: :thread_pool,
            isolate: true
        }.freeze


        # Options that can't be used when more than one set of options is being applied
        APP_OPTIONS = [:port, :host, :verbose, :debug, :environment, :rackup, :mode, :backlog, :count, :name, :loglevel].freeze
        MUTUALLY_EXCLUSIVE = {

            # Only :password is valid when this option is present
            update: APP_OPTIONS

        }.freeze


        def self.parse(args)
            options = {}

            parser = OptionParser.new do |opts|
                # ================
                # STANDARD OPTIONS
                # ================
                opts.on "-p", "--port PORT", Integer, "Define what port TCP port to bind to (default: 3000)" do |arg|
                    options[:port] = arg
                end

                opts.on "-h", "--host ADDRESS", "bind to address (default: 0.0.0.0)" do |arg|
                    options[:host] = arg
                end

                opts.on "-v", "--verbose", "loud output" do
                    options[:verbose] = true
                end

                opts.on "-d", "--debug", "debugging mode with lowered security and manual processes" do
                    options[:debug] = true
                end

                opts.on "-e", "--environment ENVIRONMENT", "The environment to run the Rack app on (default: development)" do |arg|
                    options[:environment] = arg
                end

                opts.on "-r", "--rackup FILE", "Load Rack config from this file (default: config.ru)" do |arg|
                    options[:rackup] = arg
                end

                opts.on "-m", "--mode MODE", MODES, "Either process, thread or no_ipc (default: process)" do |arg|
                    options[:mode] = arg
                end

                opts.on "-a", "--app-mode MODE", APP_MODE, "How should requests be processed (default: thread_pool)" do |arg|
                    options[:host] = arg
                end

                opts.on "-b", "--backlog BACKLOG", Integer, "Number of pending connections allowed (default: 5000)" do |arg|
                    options[:backlog] = arg
                end


                # =================
                # TLS Configuration
                # =================
                opts.on "-t", "--use-tls PRIVATE_KEY_FILE", "Enables TLS on the port specified using the provided private key in PEM format" do |arg|
                    options[:tls] = true
                    options[:private_key] = arg
                end

                opts.on "-tc", "--tls-chain-file CERT_CHAIN_FILE", "The certificate chain to provide clients" do |arg|
                    options[:cert_chain] = arg
                end

                opts.on "-ts", "--tls-ciphers CIPHER_LIST", "A list of Ciphers that the server will accept" do |arg|
                    options[:ciphers] = arg
                end

                opts.on "-tv", "--tls-verify-peer", "Do we want to verify the client connections? (default: false)" do
                    options[:verify_peer] = true
                end


                # ========================
                # CHILD PROCESS INDICATORS
                # ========================
                opts.on "-g", "--gazelle PASSWORD", 'For internal use only' do |arg|
                    options[:gazelle] = arg
                end

                opts.on "-f", "--file IPC", 'For internal use only' do |arg|
                    options[:gazelle_ipc] = arg
                end


                opts.on "-s", "--spider PASSWORD", 'For internal use only' do |arg|
                    options[:spider] = arg
                end


                opts.on "-i", "--interactive-mode", 'Loads a multi-process version of spider-gazelle that can live update your app' do
                    options[:isolate] = false
                end

                opts.on "-c", "--count NUMBER", Integer, "Number of gazelle processes to launch (default: number of CPU cores)" do |arg|
                    options[:count] = arg
                end


                # ==================
                # SIGNALLING OPTIONS
                # ==================
                opts.on "-u", "--update", "Live migrates to a new process without dropping existing connections" do |arg|
                    options[:update] = true
                end

                opts.on "-up", "--update-password PASSWORD", "Sets a password for performing updates" do |arg|
                    options[:password] = arg
                end

                opts.on "-l", "--loglevel LEVEL", Logger::LEVELS, "Sets the log level" do |arg|
                    options[:loglevel] = arg
                end
            end

            parser.banner = "sg <options> <rackup file>"
            parser.on_tail "-h", "--help", "Show help" do
                puts parser
                exit 1
            end
            parser.parse!(args)

            # Check for rackup file
            if args.last =~ /\.ru$/
                options[:rackup] = args.last
            end

            # Unless this is a signal then we want to include the default options
            unless options[:update]
                options = DEFAULTS.merge(options)

                unless File.exist? options[:rackup]
                    abort "No rackup found at #{options[:rackup]}"
                end

                options[:environment] ||= ENV['RACK_ENV'] || 'development'
                ENV['RACK_ENV'] = options[:environment]

                # isolation and process mode don't mix
                options[:isolate] = false if options[:mode] == :process

                # Force no_ipc mode on Windows (sockets over pipes are not working in threaded mode)
                options[:mode] = :no_ipc if ::FFI::Platform.windows? && options[:mode] == :thread
            end

            options
        end

        def self.sanitize(args)
            # Use "\0" as this character won't be used in the command
            cmdline = args.join("\0")
            components = cmdline.split("\0--", -1)

            # Ensure there is at least one component
            # (This will occur when no options are provided)
            components << '' if components.empty?

            # Parse the commandline options
            options = []
            components.each do |app_opts|
                options << parse(app_opts.split(/\0+/))
            end

            # Check for any invalid requests
            exclusive = Set.new(MUTUALLY_EXCLUSIVE.keys)

            if options.length > 1

                # Some options can only be used by themselves
                options.each do |opt|
                    keys = Set.new(opt.keys)

                    if exclusive.intersect? keys
                        invalid = exclusive & keys

                        abort "The requested actions can only be used in isolation: #{invalid.to_a}"
                    end
                end

                # Ensure there are no conflicting ports
                ports = [options[0][:port]]
                options[1..-1].each do |opt|
                    # If there is a clash we'll increment the port by 1
                    while ports.include? opt[:port]
                        opt[:port] += 1
                    end
                    ports << opt[:port]
                end
            end

            options
        end
    end
end
