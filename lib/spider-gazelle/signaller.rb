# frozen_string_literal: true

require 'libuv'


module SpiderGazelle
    class Signaller
        include Singleton


        attr_reader   :thread, :pipe
        attr_accessor :gazelle


        def initialize
            @thread = ::Libuv::Reactor.default
            @logger = Logger.instance

            # This is used to check if an instance of spider-gazelle is already running
            @is_master = false
            @is_client = false
            @is_connected = false
            @client_check = @thread.defer
            @validated = [] # Set requires more processing
            @validating = {}
        end

        def request(options)
            defer = @thread.defer

            defer.resolve(true)

            defer.promise
        end

        def check
            @thread.next_tick do
                connect_to_sg_master
            end
            @client_check.promise
        end

        def shutdown
            defer = @thread.defer

            # Close the SIGNAL_SERVER pipe
            @pipe.close if @is_connected

            # Request spider or gazelle process to shutdown
            if @gazelle
                @gazelle.shutdown(defer)
            end

            if defined?(::SpiderGazelle::Spider)
                Spider.instance.shutdown(defer)
            else
                # This must be the master process
                @thread.next_tick do
                    defer.resolve(true)
                end
            end

            defer.promise
        end

        # ------------------------------
        # Called from the spider process
        # ------------------------------
        def authenticate(password)
            @pipe.write "\x02validate #{password}\x03"
        end

        def general_failure
            @pipe.write "\x02Signaller general_failure\x03"
        rescue
        ensure
            Reactor.instance.shutdown
        end

        def self.general_failure(_)
            Reactor.instance.shutdown
        end


        protected


        def connect_to_sg_master
            @pipe = @thread.pipe :ipc

            process = method(:process_response)
            @pipe.connect(SIGNAL_SERVER) do |client|
                @is_client = true
                @is_connected = true

                @logger.verbose "Client connected to SG Master"
                
                require 'uv-rays/buffered_tokenizer'
                @parser = ::UV::BufferedTokenizer.new({
                    indicator: "\x02",
                    delimiter: "\x03"
                })

                client.progress process
                client.start_read
                @client_check.resolve(true)
            end

            @pipe.catch do |reason|
                if !@is_client
                    @client_check.resolve(false)
                end
            end

            @pipe.finally do
                if @is_client
                    @is_connected = false
                    panic!(nil)
                else
                    # Assume the role of master
                    become_sg_master
                end
            end
        end

        def become_sg_master
            @is_master = true
            @is_client = false
            @is_connected = true

            # Load the server request processor here
            require 'spider-gazelle/signaller/signal_parser'
            @pipe = @thread.pipe :ipc

            begin
                File.unlink SIGNAL_SERVER
            rescue
            end

            process = method(:process_request)
            @pipe.bind(SIGNAL_SERVER) do |client|
                @logger.verbose { "Client <0x#{client.object_id.to_s(16)}> connection made" }
                @validating[client.object_id] = SignalParser.new

                client.catch do |error|
                    @logger.print_error(error, "Client <0x#{client.object_id.to_s(16)}> connection error")
                end

                client.finally do
                    @validated.delete client
                    @validating.delete client.object_id
                    @logger.verbose { "Client <0x#{client.object_id.to_s(16)}> disconnected, #{@validated.length} remaining" }

                    # If all the process connections are gone then we want to shutdown
                    # This should never happen under normal conditions
                    if @validated.length == 0
                        Reactor.instance.shutdown
                    end
                end

                client.progress process
                client.start_read
            end

            # catch server errors
            @pipe.catch method(:panic!)
            @pipe.finally { @is_connected = false }

            # start listening
            @pipe.listen(INTERNAL_PIPE_BACKLOG)
        end

        def panic!(reason)
            #@logger.error "Master pipe went missing: #{reason}"
            # Server most likely exited
            # We'll shutdown here
            STDERR.puts "\n\npanic! #{reason.inspect}\n\n\n"
            STDERR.flush
            Reactor.instance.shutdown
        end

        # The server processes requests here
        def process_request(data, client)
            validated = @validated.include?(client)
            parser = @validating[client.object_id]

            if validated
                parser.process data
            else
                result = parser.signal(data)

                case result
                when :validated
                    @validated.each do |old|
                        old.write "\x02update\x03"
                    end
                    @validated << client
                    if @validated.length > 1
                        client.write "\x02wait\x03"
                    else
                        client.write "\x02ready\x03"
                    end
                    @logger.verbose { "Client <0x#{client.object_id.to_s(16)}> connection was validated" }
                when :close_connection
                    client.close
                    @logger.warn "Client <0x#{client.object_id.to_s(16)}> connection was closed due to bad credentials"
                end
            end
        end

        # The client processes responses here
        def process_response(data, server)
            @parser.extract(data).each do |msg|
                Spider.instance.__send__(msg)
            end
        end
    end
end
