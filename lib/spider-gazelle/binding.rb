require 'thread'
require 'set'


module SpiderGazelle
    class Binding


        attr_reader :app_id


        def initialize(loop, delegate, app_id, options = {})
            @app_id = app_id
            @options = options
            @loop = loop
            @delegate = delegate
            @port = @options[:Port]
            @tls = @options[:tls]
            @optimize = @options[:optimize_for_latency]

            # Connection management functions
            @new_connection = method(:new_connection)
            @accept_connection = method(:accept_connection)
        end

        # Bind the application to the selected port
        def bind
            # Bind the socket
            @tcp = @loop.tcp
            @tcp.bind(@options[:Host], @port, @new_connection)
            @tcp.listen(@options[:backlog])

            # Delegate errors
            @tcp.catch do |e|
                @loop.log :error, 'application bind failed', e
            end
            @tcp
        end

        # Close the bindings
        def unbind
            # close unless we've never been bound
            @tcp.close unless @tcp.nil?
            @tcp
        end


        protected


        # There is a new connection pending
        # We accept it
        def new_connection(server)
            server.accept @accept_connection
        end

        # Once the connection is accepted we disable Nagles Algorithm
        # This improves performance as we are using vectored or scatter/gather IO
        # Then the spider delegates to the gazelle loops
        def accept_connection(client)
            client.enable_nodelay if @optimize == true
            @delegate.call(client, @tls, @port, @app_id)
        end
    end
end
