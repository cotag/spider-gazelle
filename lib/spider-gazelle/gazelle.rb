require "http-parser"     # C based, fast, http parser
require "rack"            # Ruby webserver abstraction

#require "spider-gazelle/gazelle/request"        # Holds request information and handles request processing
#require "spider-gazelle/gazelle/connection"     # Holds connection information and handles request pipelining

# Reactor aware websocket implementation
#require "spider-gazelle/upgrades/websocket"


module SpiderGazelle
    class Gazelle
        SPACE = ' '.freeze

        def initialize(type)
            raise ArgumentError, "type must be one of #{MODES}" unless MODES.include?(type)
            
            @type = type
            @logger = Logger.instance
            @thread = @logger.thread
        end

        def run!(options)
            @options = options
            @logger.verbose "Gazelle Started!".freeze

            connect_to_spider unless @type == :no_ipc

            load_required_applications
        end

        def new_app(options)
            # TODO:: load this app into all of the gazelles dynamically
        end

        def new_connection(data, socket)
            # If pipe does not exist then we are in no_ipc mode
            if @pipe
                socket = @pipe.check_pending
                return if socket.nil?
            end

            tls, port, app_id = data.split(SPACE, 3)
        end


        protected


        def connect_to_spider
            @pipe = @thread.pipe :ipc
            @pipe.connect(SPIDER_SERVER) do |client|
                client.progress method(:new_connection)
                client.start_read

                authenticate
            end

            @pipe.catch do |reason|
                @logger.print_error(error)
            end

            @pipe.finally do
                Reactor.instance.shutdown
            end
        end

        def authenticate
            @pipe.write "#{@options[0][:gazelle]} #{@type}"
        end

        def load_required_applications
            # TODO:: Loop through the options and load all the applications
            # That require gazelles of the same type
        end
    end
end
