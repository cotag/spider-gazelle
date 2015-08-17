
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

                # Connection management functions
                @new_connection = method :new_connection
            end

            # Bind the application to the selected port
            def bind
                # Bind the socket
                @tcp = @thread.tcp
                @tcp.bind @options[:host], @port, @new_connection
                @tcp.listen @options[:backlog]
                @tcp.enable_simultaneous_accepts

                @logger.info "Listening on tcp://#{@options[:host]}:#{@port}"

                @tcp.catch do |error|
                    @logger.print_error(error)
                    @signaller.general_failure
                end
                @tcp
            end

            # Close the bindings
            def unbind
                @tcp.close unless @tcp.nil?
                @tcp
            end


            protected


            # Once the connection is accepted we disable Nagles Algorithm
            # This improves performance as we are using vectored or scatter/gather IO
            # Then the spider delegates to the gazelle loops
            def new_connection(client)
                client.enable_nodelay
                @delegate.call client
            end

            def delegate(client)
                @select_gazelle.next.write2(client, @indicator).finally do
                    client.close
                end
            end

            def direct_delegate(client)
                gazelle = @gazelle
                indicator = @indicator

                # Keep the stack level low
                # Might be over thinking this?
                @thread.next_tick do
                    gazelle.__send__(:process_connection, client, indicator)
                end
            end
        end
    end
end
