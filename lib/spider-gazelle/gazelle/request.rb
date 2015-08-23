require 'stringio'
require 'rack'            # Ruby webserver abstraction

module SpiderGazelle
    class Request < ::Libuv::Q::DeferredPromise
        RACK_VERSION = 'rack.version'.freeze
        RACK_ERRORS = 'rack.errors'.freeze
        RACK_MULTITHREAD = "rack.multithread".freeze
        RACK_MULTIPROCESS = "rack.multiprocess".freeze
        RACK_RUN_ONCE = "rack.run_once".freeze
        SCRIPT_NAME = "SCRIPT_NAME".freeze
        EMPTY = ''.freeze
        SERVER_PROTOCOL = "SERVER_PROTOCOL".freeze
        HTTP_11 = "HTTP/1.1".freeze
        SERVER_SOFTWARE = "SERVER_SOFTWARE".freeze
        GATEWAY_INTERFACE = "GATEWAY_INTERFACE".freeze
        CGI_VER = "CGI/1.2".freeze
        SERVER = "SpiderGazelle".freeze
        LOCALHOST = 'localhost'.freeze


        # TODO:: Add HTTP headers to the env and capitalise them and prefix them with HTTP_
        #   convert - signs to underscores
        PROTO_ENV = {
            RACK_VERSION => ::Rack::VERSION,   # Should be an array of integers
            RACK_ERRORS => $stderr,            # An error stream that supports: puts, write and flush
            RACK_MULTITHREAD => true,          # can the app be simultaneously invoked by another thread?
            RACK_MULTIPROCESS => true,        # will the app be simultaneously be invoked in a separate process?
            RACK_RUN_ONCE => false,            # this isn't CGI so will always be false

            SCRIPT_NAME => ENV['SCRIPT_NAME'.freeze] || EMPTY,   #  The virtual path of the app base (empty if root)
            SERVER_PROTOCOL => HTTP_11,

            GATEWAY_INTERFACE => CGI_VER,
            SERVER_SOFTWARE   => SERVER
        }

        attr_accessor :env, :url, :header, :body, :keep_alive, :upgrade
        attr_reader :hijacked, :defer, :is_async


        SERVER_PORT = "SERVER_PORT".freeze
        REMOTE_ADDR = "REMOTE_ADDR".freeze
        RACK_URL_SCHEME = "rack.url_scheme".freeze
        ASYNC = "async.callback".freeze

        def initialize(thread, app, port, remote_ip, scheme, async_callback)
            super(thread, thread.defer)

            @app = app
            @body = ''
            @header = ''
            @url = ''
            @env = PROTO_ENV.dup
            @env[SERVER_PORT] = port
            @env[REMOTE_ADDR] = remote_ip
            @env[RACK_URL_SCHEME] = scheme
            @env[ASYNC] = async_callback
        end


        CONTENT_LENGTH = "CONTENT_LENGTH".freeze
        HTTP_CONTENT_LENGTH = "HTTP_CONTENT_LENGTH".freeze
        CONTENT_TYPE = "CONTENT_TYPE".freeze
        HTTP_CONTENT_TYPE = "HTTP_CONTENT_TYPE".freeze
        DEFAULT_TYPE = "text/plain".freeze
        REQUEST_URI= "REQUEST_URI".freeze
        ASCII_8BIT = "ASCII-8BIT".freeze
        RACK_INPUT = "rack.input".freeze
        PATH_INFO = "PATH_INFO".freeze
        REQUEST_PATH = "REQUEST_PATH".freeze
        QUERY_STRING = "QUERY_STRING".freeze
        HTTP_HOST = "HTTP_HOST".freeze
        COLON = ":".freeze
        SERVER_NAME = "SERVER_NAME".freeze
        # Hijacking IO is supported
        HIJACK_P = "rack.hijack?".freeze
        # Callback for indicating that this socket will be hijacked
        HIJACK = "rack.hijack".freeze
        # The object for performing IO on after hijack is called
        HIJACK_IO = "rack.hijack_io".freeze
        QUESTION_MARK = "?".freeze
        
        HTTP_UPGRADE = 'HTTP_UPGRADE'.freeze
        USE_HTTP2 = 'h2c'.freeze


        def execute!
            @env[CONTENT_LENGTH] = @env.delete(HTTP_CONTENT_LENGTH) || @body.length
            @env[CONTENT_TYPE] = @env.delete(HTTP_CONTENT_TYPE) || DEFAULT_TYPE
            @env[REQUEST_URI] = @url.freeze

            # For Rack::Lint on 1.9, ensure that the encoding is always for spec
            @body.force_encoding(ASCII_8BIT) if @body.respond_to?(:force_encoding)
            @env[RACK_INPUT] = StringIO.new @body

            # Break the request into its components
            query_start  = @url.index QUESTION_MARK
            if query_start
                path = @url[0...query_start].freeze
                @env[PATH_INFO] = path
                @env[REQUEST_PATH] = path
                @env[QUERY_STRING] = @url[query_start + 1..-1].freeze
            else
                @env[PATH_INFO] = @url
                @env[REQUEST_PATH] = @url
                @env[QUERY_STRING] = EMPTY
            end

            # Grab the host name from the request
            if host = @env[HTTP_HOST]
                if colon = host.index(COLON)
                    @env[SERVER_NAME] = host[0, colon]
                    @env[SERVER_PORT] = host[colon + 1, host.bytesize].to_i
                else
                    @env[SERVER_NAME] = host
                end
            else
                @env[SERVER_NAME] = LOCALHOST
            end

            # Provide hijack options if this is an upgrade request
            if @upgrade == true
                if @env[HTTP_UPGRADE] == USE_HTTP2
                    # TODO:: implement the upgrade process here
                else
                    @env[HIJACK_P] = true
                    @env[HIJACK] = method :hijack
                end
            end

            # Execute the request
            # NOTE:: Catch was overloaded by Promise so this does the 
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

        protected

        def hijack
            @hijacked = @loop.defer
            @env.delete HIJACK # don't want to hold a reference to this request object
            @env[HIJACK_IO] = @hijacked.promise
        end
    end
end
