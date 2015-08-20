require 'libuv'

module SpiderGazelle
    class Logger
        include Singleton
        attr_reader :level, :thread, :pipe


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
            @thread = ::Libuv::Loop.default
            @level = DEFAULT_LEVEL
            @write = method(:server_write)
        end


        def self.log(data)
            Logger.instance.server_write(data)
        end


        def set_client(uv_io)
            @pipe = uv_io
            @write = method(:client_write)
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
                @write.call ">> #{msg}\n"
            end
        end

        def print_error(e, msg = '', trace = nil)
            msg << ":\n" unless msg.empty?
            msg << "#{e.message}\n"
            backtrace = e.backtrace if e.respond_to?(:backtrace)
            if backtrace
                msg << "#{backtrace.join("\n")}\n"
            elsif trace.nil?
                trace = caller
            end
            msg << "Caller backtrace:\n#{trace.join("\n")}\n" if trace
            error(msg)
        end

        # NOTE:: should only be called on reactor thread
        def server_write(msg)
            STDOUT.write msg
        end


        protected


        def log(level, msg)
            output = "[#{level}] #{msg}\n"
            @thread.schedule do
                @write.call output
            end
        end

        # NOTE:: should only be called on reactor thread
        def client_write(msg)
            @pipe.write "\x02Logger log #{msg}\x03"
        end
    end
end
