# frozen_string_literal: true

require 'thread'
require 'singleton'


require 'spider-gazelle/version'
require 'spider-gazelle/options'
require 'spider-gazelle/logger'
require 'spider-gazelle/reactor'
require 'spider-gazelle/signaller'


module SpiderGazelle
    INTERNAL_PIPE_BACKLOG = 4096

    # Signaller is used to communicate:
    # * command line requests
    # * Startup and shutdown requests 
    # * Live updates (bindings passed by this pipe)
    SIGNAL_SERVER = '/tmp/sg-signaller.pipe'


    MODES = [:thread, :inline].freeze


    class LaunchControl
        include Singleton


        attr_reader :password, :args


        def exec(args)
            options = SpiderGazelle::Options.sanitize(args)
            @args = args
            launch(options)
        end

        def launch(options)
            # Enable verbose messages if requested
            Logger.instance.verbose! if options[0][:verbose]

            # Start the Libuv Event Loop
            reactor = ::SpiderGazelle::Reactor.instance
            reactor.run do

                # Check if SG is already running
                signaller = ::SpiderGazelle::Signaller.instance

                if options[0][:isolate]
                    # This ensures this process will load the spider code
                    options[0][:spider] = true
                    boot(true, signaller, options)
                else
                    signaller.check.then do |running|
                        boot(running, signaller, options)
                    end
                end
            end
        end

        def shutdown
            reactor = Reactor.instance
            reactor.thread.schedule do
                reactor.shutdown
            end
        end


        # ---------------------------------------
        # SPIDER LAUNCH CONTROL
        # ---------------------------------------
        def launch_spider(args)
            require 'securerandom'

            @password ||= SecureRandom.hex

            #cmd = "#{EXEC_NAME} -s #{@password} #{Shellwords.join(args)}"

            thread = Reactor.instance.thread
            spider = thread.spawn(EXEC_NAME, args: (['-s', @password] + args), mode: :inherit)
            spider.finally do
                signaller = ::SpiderGazelle::Signaller.instance
                signaller.panic!('Unexpected spider exit') unless signaller.shutting_down
            end
        end

        # This is called when a spider process starts
        def start_spider(signaller, logger, options)
            require 'spider-gazelle/spider'
            Spider.instance.run!(options)
        end


        # ---------------------------------------
        # TTY SIGNALLING CONTROL
        # ---------------------------------------
        def signal_master(reactor, signaller, logger, options)
            # This is a signal request
            promise = signaller.request(options)

            promise.then do |result|
                logger.info "signal recieved #{result}"
            end
            promise.catch do |error|
                logger.info "there was an error #{error}"
            end
            promise.finally do
                reactor.shutdown
            end
        end


        protected


        def boot(running, signaller, options)
            logger = ::SpiderGazelle::Logger.instance

            begin
                # What do we want to do?
                master = options[0]

                if running
                    if master[:spider]
                        logger.verbose "Starting Spider"
                        start_spider(signaller, logger, options)
                    else
                        logger.verbose "Sending signal to SG Master"
                        signal_master(reactor, signaller, logger, options)
                    end

                elsif master[:debug]
                    logger.verbose "SG is now running in debug mode"
                else
                    logger.verbose "SG was not running, launching Spider"
                    launch_spider(@args)
                end
            rescue => e
                logger.verbose "Error performing requested operation"
                logger.print_error(e)
                shutdown
            end
        end
    end
end
