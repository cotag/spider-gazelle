# frozen_string_literal: true

require 'thread'

module SpiderGazelle
    class Spider
        class Binding
            attr_reader :tcp, :app, :app_port, :tls


            def initialize(iterator, options)
                @options = options

                @logger = Logger.instance
                @signaller = Signaller.instance
                @thread = @signaller.thread

                @port = @options[:port]
                @app, @app_port, @tls = AppStore.lookup(options[:rackup])

                @on_progress   = method(:on_progress)
                @set_protocol  = method(:set_protocol)

                @http1_cache = []
                @http2_cache = []
                @return_http1 = method(:return_http1)
                @return_http2 = method(:return_http2)
                @parser_count = 0
            end

            # Bind the application to the selected port
            def bind
                # Bind the socket
                @tcp = @thread.tcp
                if @tls
                    @tcp.bind @options[:host], @port, method(:prepare_client_tls)
                else
                    @tcp.bind @options[:host], @port, method(:prepare_client)
                end
                @tcp.listen 10000
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


            def prepare_client(client)
                set_protocol(client, :http1)
                client.start_read
                client.enable_nodelay
            end

            def prepare_client_tls(client)
                client.on_handshake @set_protocol
                client.start_tls(@tls)

                client.start_read
                client.enable_nodelay
            end

            def set_protocol(client, version)
                parser = if version == :h2
                    @http2_cache.pop || new_http2_parser
                else
                    @http1_cache.pop || new_http1_parser
                end

                parser.load(client, @app_port, @app, @tls)
                client.storage = parser
                client.progress @on_progress
            end

            def on_progress(data, client)
                # Storage contains the parser for this connection
                parser = client.storage
                parser.parse(data)
            end

            def new_http1_parser
                @h1_parser_obj ||= Http1::Callbacks.new

                @parser_count += 1
                Http1.new(@return_http1, @h1_parser_obj, @thread, @logger)
            end

            def return_http1(parser)
                @http1_cache.push parser
            end

            def new_http2_parser
                raise NotImplementedError.new 'TODO:: Create HTTP2 parser class'
                @parser_count += 1
                Http2.new(@return_http2)
            end

            def return_http2(parser)
                @http2_cache << parser
            end
        end
    end
end
