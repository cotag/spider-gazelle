require 'stringio'


module SpiderGazelle
    class Request

        # Based on http://rack.rubyforge.org/doc/SPEC.html
        PATH_INFO = 'PATH_INFO'.freeze              # Request path from the script name up
        QUERY_STRING = 'QUERY_STRING'.freeze        # portion of the request following a '?' (empty if none)
        SERVER_NAME = 'SERVER_NAME'.freeze          # required although HTTP_HOST takes priority if set
        SERVER_PORT = 'SERVER_PORT'.freeze          # required (set in spider.rb init)
        REQUEST_URI = 'REQUEST_URI'.freeze
        REQUEST_PATH = 'REQUEST_PATH'.freeze
        RACK_URLSCHEME = 'rack.url_scheme'.freeze   # http or https
        RACK_INPUT = 'rack.input'.freeze            # an IO like object containing all the request body
        RACK_HIJACKABLE = 'rack.hijack?'.freeze     # hijacking IO is supported
        RACK_HIJACK = 'rack.hijack'.freeze          # callback for indicating that this socket will be hijacked
        RACK_HIJACK_IO = 'rack.hijack_io'.freeze    # the object for performing IO on after hijack is called
        RACK_ASYNC = 'async.callback'.freeze

        GATEWAY_INTERFACE = "GATEWAY_INTERFACE".freeze
        CGI_VER = "CGI/1.2".freeze

        EMPTY = ''.freeze

        HTTP_11 = 'HTTP/1.1'.freeze     # used in PROTO_ENV
        HTTP_URL_SCHEME = 'http'.freeze
        HTTPS_URL_SCHEME = 'https'.freeze
        HTTP_HOST = 'HTTP_HOST'.freeze
        LOCALHOST = 'localhost'.freeze
        
        KEEP_ALIVE = "Keep-Alive".freeze

        CONTENT_LENGTH = 'CONTENT_LENGTH'.freeze
        CONTENT_TYPE = 'CONTENT_TYPE'.freeze
        DEFAULT_TYPE = 'text/plain'.freeze
        HTTP_CONTENT_LENGTH = 'HTTP_CONTENT_LENGTH'.freeze
        HTTP_CONTENT_TYPE = 'HTTP_CONTENT_TYPE'.freeze

        SERVER_SOFTWARE   = 'SERVER_SOFTWARE'.freeze
        SERVER   = 'SpiderGazelle'.freeze
        REMOTE_ADDR = 'REMOTE_ADDR'.freeze


        #
        # TODO:: Add HTTP headers to the env and capitalise them and prefix them with HTTP_
        #   convert - signs to underscores
        # => copy puma with a const file
        # 
        PROTO_ENV = {
            'rack.version'.freeze => ::Rack::VERSION,   # Should be an array of integers
            'rack.errors'.freeze => $stderr,            # An error stream that supports: puts, write and flush
            'rack.multithread'.freeze => true,          # can the app be simultaneously invoked by another thread?
            'rack.multiprocess'.freeze => false,        # will the app be simultaneously be invoked in a separate process?
            'rack.run_once'.freeze => false,            # this isn't CGI so will always be false

            'SCRIPT_NAME'.freeze => ENV['SCRIPT_NAME'] || EMPTY,   #  The virtual path of the app base (empty if root)
            'SERVER_PROTOCOL'.freeze => HTTP_11,

            GATEWAY_INTERFACE => CGI_VER,
            SERVER_SOFTWARE   => SERVER
        }


        attr_accessor :env, :url, :header, :body, :keep_alive, :upgrade, :deferred 
        attr_reader :hijacked, :response


        def initialize(connection, app)
            @app = app
            @body = ''
            @header = ''
            @url = ''
            @execute = method(:execute)
            @env = PROTO_ENV.dup
            @loop = connection.loop
            @env[SERVER_PORT] = connection.port
            @env[REMOTE_ADDR] = connection.remote_ip
            @env[RACK_URLSCHEME] = connection.tls ? HTTPS_URL_SCHEME : HTTP_URL_SCHEME
            @env[RACK_ASYNC] = connection.async_callback
        end

        def execute!
            @env[CONTENT_LENGTH] = @env.delete(HTTP_CONTENT_LENGTH) || @body.length
            @env[CONTENT_TYPE] = @env.delete(HTTP_CONTENT_TYPE) || DEFAULT_TYPE
            @env[REQUEST_URI] = @url.freeze
            
            # For Rack::Lint on 1.9, ensure that the encoding is always for spec
            @body.force_encoding('ASCII-8BIT') if @body.respond_to?(:force_encoding)
            @env[RACK_INPUT] = StringIO.new(@body)

            # Break the request into its components
            query_start  = @url.index('?')
            if query_start
                path = @url[0...query_start].freeze
                @env[PATH_INFO] = path
                @env[REQUEST_PATH] = path
                @env[QUERY_STRING] = @url[query_start + 1..-1].freeze
            else
                @env[PATH_INFO] = @url
                @env[REQUEST_PATH] = @url
                @env[QUERY_STRING] = ''
            end

            # Grab the host name from the request
            if host = @env[HTTP_HOST]
                if colon = host.index(':')
                    @env[SERVER_NAME] = host[0, colon]
                    @env[SERVER_PORT] = host[colon+1, host.bytesize]
                else
                    @env[SERVER_NAME] = host
                    @env[SERVER_PORT] = PROTO_ENV[SERVER_PORT]
                end
            else
                @env[SERVER_NAME] = LOCALHOST
                @env[SERVER_PORT] = PROTO_ENV[SERVER_PORT]
            end

            # Provide hijack options if this is an upgrade request
            if @upgrade == true
                @env[RACK_HIJACKABLE] = true
                @env[RACK_HIJACK] = method(:hijack)
            end

            # Execute the request
            @response = catch(:async, &@execute)
            if @response.nil? || @response[0] == -1
                @deferred = @loop.defer
            end
            @response
        end


        protected


        # Execute the request then close the body
        # NOTE:: closing the body here might cause issues (see connection.rb)
        def execute(*args)
            result = @app.call(@env)
            body = result[2]
            body.close if body.respond_to?(:close)
            result
        end

        def hijack
            @hijacked = @loop.defer
            @env[RACK_HIJACK_IO] = @hijacked.promise
        end
    end
end
