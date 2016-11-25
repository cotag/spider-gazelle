# frozen_string_literal: true

require 'stringio'
require 'rack'            # Ruby webserver abstraction

module SpiderGazelle
    class Request < ::Libuv::Q::DeferredPromise

        # TODO:: Add HTTP headers to the env and capitalise them and prefix them with HTTP_
        #   convert - signs to underscores
        PROTO_ENV = {
            'rack.version' => ::Rack::VERSION,   # Should be an array of integers
            'rack.errors' => $stderr,            # An error stream that supports: puts, write and flush
            'rack.multithread' => true,          # can the app be simultaneously invoked by another thread?
            'rack.multiprocess' => false,        # will the app be simultaneously be invoked in a separate process?
            'rack.run_once' => false,            # this isn't CGI so will always be false
            'SCRIPT_NAME' => ENV['SCRIPT_NAME'] || '',   #  The virtual path of the app base (empty if root)
            'SERVER_PROTOCOL' => 'HTTP/1.1',

            'GATEWAY_INTERFACE' => 'CGI/1.2',
            'SERVER_SOFTWARE'   => 'SpiderGazelle'
        }

        attr_accessor :env, :url, :header, :body, :keep_alive, :upgrade
        attr_reader :hijacked, :defer, :is_async


        def initialize(thread, app, port, remote_ip, scheme, socket)
            super(thread, thread.defer)

            @socket = socket
            @app = app
            @body = String.new
            @header = String.new
            @url = String.new
            @env = PROTO_ENV.dup
            @env['SERVER_PORT'] = port
            @env['REMOTE_ADDR'] = remote_ip
            @env['rack.url_scheme'] = scheme
        end
        

        def execute!
            @env['CONTENT_LENGTH'] = @env.delete('HTTP_CONTENT_LENGTH') || @body.bytesize.to_s
            @env['CONTENT_TYPE'] = @env.delete('HTTP_CONTENT_TYPE') || 'text/plain'
            @env['REQUEST_URI'] = @url.freeze

            # For Rack::Lint on 1.9, ensure that the encoding is always for spec
            @body.force_encoding(Encoding::ASCII_8BIT)
            @env['rack.input'] = StringIO.new @body

            # Break the request into its components
            query_start  = @url.index '?'
            if query_start
                path = @url[0...query_start].freeze
                @env['PATH_INFO'] = path
                @env['REQUEST_PATH'] = path
                @env['QUERY_STRING'] = @url[query_start + 1..-1].freeze
            else
                @env['PATH_INFO'] = @url
                @env['REQUEST_PATH'] = @url
                @env['QUERY_STRING'] = ''
            end

            # Grab the host name from the request
            if host = @env['HTTP_HOST']
                if colon = host.index(':')
                    @env['SERVER_NAME'] = host[0, colon]
                    @env['SERVER_PORT'] = host[colon + 1, host.bytesize]
                else
                    @env['SERVER_NAME'] = host
                end
            else
                @env['SERVER_NAME'] = 'localhost'
            end

            if @upgrade == true && @env['HTTP_UPGRADE'] == 'h2c'
                # TODO:: implement the upgrade process here
            end

            # Provide hijack options
            @env['rack.hijack?'] = true
            @env['rack.hijack'] = proc { @env['rack.hijack_io'] = @socket }

            # Execute the request
            # NOTE:: Catch was overloaded by Promise so this does the trick now
            resp = ruby_catch(:async) { @app.call @env }
            if resp.nil? || resp[0] == -1
                @is_async = true

                # close the body for deferred responses
                unless resp.nil?
                    body = resp[2]
                    body.close if body.respond_to?(:close)
                end
            end
            resp
        end
    end
end
