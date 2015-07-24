require 'singleton'
require 'thread'


module SpiderGazelle
    VERSION = '2.0.0.alpha1'.freeze
    EXEC_NAME = 'sg2'.freeze

    # Signaller is used to communicate:
    # * command line requests
    # * Startup and shutdown requests 
    # * Live updates (bindings passed by this pipe)
    SIGNAL_SERVER = '/tmp/sg-signaller.pipe'.freeze

    # Spider server is used to
    # * Track gazelles
    # * Signal shutdown as required
    # * Pass sockets
    SPIDER_SERVER = '/tmp/sg-spider.pipe'.freeze

    # Encrypted
    USE_TLS = 'E'.freeze
    # Clear
    NO_TLS = 'C'.freeze

    MODES = [:process, :thread, :no_ipc].freeze


    class LaunchControl
        include Singleton


        attr_reader :password, :args


        def exec(args)
            require 'spider-gazelle/options'
            options = SpiderGazelle::Options.sanitize(args)

            require 'spider-gazelle/logger'
            require 'spider-gazelle/reactor'
            require 'spider-gazelle/signaller'

            @args = args

            # Start the Libuv Event Loop
            reactor = ::SpiderGazelle::Reactor.instance
            reactor.run do

                # Check if SG is already running
                signaller = ::SpiderGazelle::Signaller.instance
                signaller.check.then do |running|
                    logger = ::SpiderGazelle::Logger.instance

                    begin
                        # What do we want to do?
                        master = options[0]

                        if running
                            logger.verbose "SG is already running".freeze

                            if master[:spider]
                                logger.verbose "Starting Spider".freeze
                                start_spider(signaller, logger, options)
                            elsif master[:gazelle]
                                logger.verbose "Starting Gazelle".freeze
                                start_gazelle(signaller, logger, options)
                            else
                                logger.verbose "Sending signal to SG Master".freeze
                                signal_master(reactor, signaller, logger, options)
                            end

                        elsif master[:debug]
                            logger.verbose "SG is now running in debug mode".freeze
                        else
                            logger.verbose "SG was not running, launching Spider".freeze
                            launch_spider(args)
                        end
                    rescue => e
                        logger.verbose "Error performing requested operation".freeze
                        logger.print_error(e)
                        shutdown
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
            require 'thread'

            @password ||= SecureRandom.hex
            #cmd = "#{EXEC_NAME} -s #{@password} #{Shellwords.join(args)}"
            cmd = [EXEC_NAME, '-s', @password] + args

            Thread.new do
                result = system(*cmd)

                # TODO:: We need to detect a failed load
                # This is a little more tricky as spiders
                # may come and go without this process exiting
            end
        end

        # This is called when a spider process starts
        def start_spider(signaller, logger, options)
            logger.set_client signaller.pipe

            require 'spider-gazelle/spider'
            Spider.instance.run!(options)
        end



        # ---------------------------------------
        # GAZELLE LAUNCH CONTROL
        # ---------------------------------------
        def start_gazelle(signaller, logger, options)
            logger.set_client signaller.pipe

            require 'spider-gazelle/gazelle'
            ::SpiderGazelle::Gazelle.new(:process).run!(options)
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
    end
end
