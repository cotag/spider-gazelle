require 'thread'

module SpiderGazelle
    class Spider
        class Binding
            attr_reader :app_id
            attr_accessor :tcp


            def initialize(iterator, app_id, options)
                if options[:mode] == :no_ipc
                    @delegate = method(:direct_delegate)
                    @gazelle = iterator
                else
                    @delegate = method(:delegate)
                    @select_gazelle = iterator
                end

                @options = options

                @logger = Logger.instance
                @signaller = Signaller.instance
                @thread = @signaller.thread

                @port = @options[:port]
                @indicator = app_id.to_s.freeze
            end

            # Bind the application to the selected port
            def bind
                # Bind the socket
                @tcp = @thread.tcp
                @tcp.bind @options[:host], @port, @delegate
                @tcp.listen @options[:backlog]
                @tcp.enable_simultaneous_accepts

                @logger.info "Listening on tcp://#{@options[:host]}:#{@port}"

                @tcp.catch do |error|
                    begin
                        @logger.print_error(error)
                    rescue
                    ensure
                        @signaller.general_failure
                    end
                end
                @tcp
            end

            # Close the bindings
            def unbind
                @tcp.close unless @tcp.nil?
                @tcp
            end


            protected


            DELEGATE_ERR = proc { |error|
                client.close
                begin
                    Logger.instance.print_error(error, "delegating socket to gazelle")
                rescue
                end
            }
            def delegate(client, retries = 0)
                promise = @select_gazelle.next.write2(client, @indicator)
                promise.then do
                    client.close
                end
                promise.catch DELEGATE_ERR
            end

            def direct_delegate(client)
                @gazelle.__send__(:process_connection, client, @indicator)
            end
        end
    end
end
