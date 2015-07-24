require 'libuv'
require 'spider-gazelle/logger'


module SpiderGazelle
    class Reactor
        include Singleton
        attr_reader :thread


        def initialize
            @thread = ::Libuv::Loop.default
            @logger = ::SpiderGazelle::Logger.instance
            @running = false
            @shutdown = method(:shutdown)
        end        

        def run(&block)
            if @running
                @thread.schedule block
            else
                @running = true
                @thread.run { |logger|
                    logger.progress method(:log)
                    
                    # Listen for the signal to shutdown
                    @thread.signal :INT, @shutdown

                    block.call
                }
            end
        end

        def shutdown(_ = nil)
            # Signaller will manage the shutdown of the gazelles
            signaller = Signaller.instance.shutdown
            signaller.finally do
                @thread.stop
                # New line on exit
                puts "\nSpider-Gazelle leaps through the veldt\n" unless @logger.pipe
            end
        end

        # This is an unhandled error on the Libuv Event loop
        def log(level, errorid, error)
            msg = ''
            if error.respond_to?(:backtrace)
                msg << "unhandled exception: #{error.message} (#{level} - #{errorid})"
                backtrace = error.backtrace
                msg << "\n#{backtrace.join("\n")}" if backtrace
            else
                msg << "unhandled exception: #{args}"
            end
            @logger.error msg
        end
    end
end
