# frozen_string_literal: true

require 'libuv'

module SpiderGazelle
    class Logger
        include Singleton
        attr_reader :level, :thread
        attr_accessor :formatter


        LEVEL = {
            debug: 0,
            info: 1,
            warn: 2,
            error: 3,
            fatal: 4
        }.freeze
        DEFAULT_LEVEL = 1
        LEVELS = LEVEL.keys.freeze


        def initialize
            @thread = ::Libuv::Reactor.default
            @stdout = @thread.pipe
            @stdout.open(1)
            @level = DEFAULT_LEVEL
        end


        def self.log(data)
            Logger.instance.write(data)
        end

        def level=(level)
            @level = LEVEL[level] || level
        end

        def verbose!(enabled = true)
            @verbose = enabled
        end

        def debug(msg = nil)
            if @level <= 0
                msg = yield if block_given?
                log(:debug, msg)
            end
        end

        def info(msg = nil)
            if @level <= 1
                msg = yield if block_given?
                log(:info, msg)
            end
        end

        def warn(msg = nil)
            if @level <= 2
                msg = yield if block_given?
                log(:warn, msg)
            end
        end

        def error(msg = nil)
            if @level <= 3
                msg = yield if block_given?
                log(:error, msg)
            end
        end

        def fatal(msg = nil)
            if @level <= 4
                msg = yield if block_given?
                log(:fatal, msg)
            end
        end

        def verbose(msg = nil)
            if @verbose
                msg = yield if block_given?
                @thread.schedule { @stdout.write ">> #{msg}\n" }
            end
        end

        def write(msg)
            @thread.schedule { @stdout.write msg }
        end

        def print_error(e, msg = nil, trace = nil)
            message = String.new(msg || e.message)
            message << "\n#{e.message}" if msg
            message << "\n#{e.backtrace.join("\n")}" if e.respond_to?(:backtrace) && e.backtrace
            message << "\nCaller backtrace:\n#{trace.join("\n")}" if trace
            error(message)
        end


        protected


        def log(level, msg)
            output = "[#{level}] #{msg}\n"
            @thread.schedule do
                @stdout.write output
            end
        end
    end
end
