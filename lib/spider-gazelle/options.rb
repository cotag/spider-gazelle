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
            mode: :process
        }.freeze


        # Options that can't be used when more than one set of options is being appli
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

                opts.on "-a", "--address HOST", "bind to HOST address (default: 0.0.0.0)" do |arg|
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

                opts.on "-b", "--backlog BACKLOG", Integer, "Number of pending connections allowed (default: 5000)" do |arg|
                    options[:backlog] = arg
                end

                opts.on "-c", "--count NUMBER", Integer, "Number of gazelle processes to launch (default: number of CPU cores)" do |arg|
                    options[:count] = arg
                end


                # ========================
                # CHILD PROCESS INDICATORS
                # ========================
                opts.on "-g", "--gazelle PASSWORD", 'For internal use only' do |arg|
                    options[:gazelle] = arg
                end

                opts.on "-s", "--spider PASSWORD", 'For internal use only' do |arg|
                    options[:spider] = arg
                end


                # ==================
                # SIGNALLING OPTIONS
                # ==================
                opts.on "-u", "--update", "Live migrates to a new process without dropping existing connections" do |arg|
                    options[:update] = true
                end

                opts.on "-p", "--password PASSWORD", "Sets a password for performing updates" do |arg|
                    options[:password] = arg
                end

                opts.on "-n", "--name NAME", "Sets a name for referencing an application (default: rackup file path)" do |arg|
                    options[:name] = arg
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

            # If this is not a signal or a gazelle process
            # Then we want to include the default options
            unless options[:gazelle] || options[:update]
                options = DEFAULTS.merge(options)

                unless File.exist? options[:rackup]
                    abort "No rackup found at #{options[:rackup]}"
                end

                options[:environment] ||= ENV['RAILS_ENV'] || 'development'
                ENV['RAILS_ENV'] = options[:environment]


            end

            # Enable verbose messages if requested
            Logger.instance.verbose! if options[:verbose]

            options
        end

        def self.sanitize(args)
            # Use "\0" as this character won't be used in the command
            cmdline = args.join("\0")
            components = cmdline.split("\0--\0")

            # Ensure there is at least one component
            # (This will occur when no options are provided)
            components << '' if components.empty?

            # Parse the commandline options
            options = []
            components.each do |app_opts|
                options << parse(app_opts.split("\0"))
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
