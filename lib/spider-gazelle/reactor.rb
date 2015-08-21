require 'libuv'
require 'spider-gazelle/logger'


module SpiderGazelle
    class Reactor
        include Singleton
        attr_reader :thread


        def initialize
            @thread = ::Libuv::Loop.default
            @logger = Logger.instance
            @running = false
            @shutdown = method(:shutdown)
            @shutdown_called = false
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
            if @shutdown_called
                @logger.warn "Shutdown called twice! Callstack:\n#{caller.join("\n")}"
                return
            end

            @thread.schedule do
                return if @shutdown_called
                @shutdown_called = true

                # Signaller will manage the shutdown of the gazelles
                signaller = Signaller.instance.shutdown
                signaller.finally do
                    @thread.stop
                    # New line on exit to avoid any ctrl-c characters
                    # We check for pipe as we only want the master process to print this
                    puts "\nSpider-Gazelle leaps through the veldt\n" unless @logger.pipe
                end
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
