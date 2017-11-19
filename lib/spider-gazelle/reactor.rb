# frozen_string_literal: true

require 'libuv'
require 'spider-gazelle/logger'


module SpiderGazelle
    class Reactor
        include Singleton
        attr_reader :thread


        def initialize
            @thread = ::Libuv::Reactor.default
            @logger = Logger.instance
            @running = false
            @shutdown_called = false
        end        

        def run
            if @running
                @thread.schedule { yield }
            else
                @running = true
                @thread.notifier { |*args| log(*args) }
                @thread.on_program_interrupt { shutdown }
                @thread.run { yield }
            end
        end

        def shutdown
            if @shutdown_called
                @logger.warn "Shutdown called twice! Callstack:\n#{caller.join("\n")}"
                return
            end

            @thread.schedule do
                if not @shutdown_called
                    @shutdown_called = true

                    # Signaller will manage the shutdown of the gazelles
                    signaller = Signaller.instance.shutdown
                    signaller.finally do
                        @thread.stop
                        # New line on exit to avoid any ctrl-c characters
                        # We check for pipe as we only want the master process to print this
                        puts "\nSpider-Gazelle leaps through the veldt\n"
                    end
                end
            end
        end

        # This is an unhandled error on the Libuv Event loop
        def log(error, context, trace = nil)
            msg = String.new
            if error.respond_to?(:backtrace)
                msg << "unhandled exception: #{error.message} (#{context})"
                backtrace = error.backtrace
                msg << "\n#{backtrace.join("\n")}" if backtrace
                msg << "\n#{trace.join("\n")}" if trace
            else
                msg << "unhandled exception: #{args}"
            end
            @logger.error msg
        end
    end
end
