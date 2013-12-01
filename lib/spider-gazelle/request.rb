require 'stringio'
require 'benchmark'


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

        GATEWAY_INTERFACE = "GATEWAY_INTERFACE".freeze
        CGI_VER = "CGI/1.2".freeze

        RACK = 'rack'.freeze            # used for filtering headers
        EMPTY = ''.freeze

        HTTP_11 = 'HTTP/1.1'.freeze     # used in PROTO_ENV
        HTTP_URL_SCHEME = 'http'.freeze
        HTTPS_URL_SCHEME = 'https'.freeze
        HTTP_HOST = 'HTTP_HOST'.freeze
        COLON_SPACE = ': '.freeze
        CRLF = "\r\n".freeze
        LOCALHOST = 'localhost'.freeze
        
        CONTENT_LENGTH = "Content-Length".freeze
        CONNECTION = "Connection".freeze
        KEEP_ALIVE = "Keep-Alive".freeze
        CLOSE = "close".freeze

        HTTP_CONTENT_LENGTH = 'HTTP_CONTENT_LENGTH'.freeze
        HTTP_CONTENT_TYPE = 'HTTP_CONTENT_TYPE'.freeze
        HTTP_AUTHORIZATION = 'AUTHORIZATION'.freeze
        HTTP_CONNECTION = 'HTTP_CONNECTION'.freeze

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
            'CONTENT_TYPE'.freeze => 'text/plain',      # works with Rack and Rack::Lint (source puma)
            'SERVER_PROTOCOL'.freeze => HTTP_11,

            GATEWAY_INTERFACE => CGI_VER,
            SERVER_SOFTWARE   => SERVER
        }


        attr_accessor :env, :url, :header, :body, :keep_alive, :upgrade, :response


        def initialize(remote, port, tls, app)
            @app = app
            @body = ''
            @header = ''
            @url = ''
            @env = PROTO_ENV.dup
            @env[SERVER_PORT] = port
            @env[REMOTE_ADDR] = remote
            @env[RACK_URLSCHEME] = tls ? HTTPS_URL_SCHEME : HTTP_URL_SCHEME
        end

        def execute!
            @env.delete(HTTP_CONTENT_LENGTH)
            @env.delete(HTTP_CONTENT_TYPE)
            @env.delete(HTTP_AUTHORIZATION)
            @env.delete(HTTP_CONNECTION)

            @env[REQUEST_URI] = @url.freeze
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

            # Process the request
            #p @env
            status, headers, body = nil, nil, nil
            puts Benchmark.measure {
                status, headers, body = @app.call(@env)
            }
            # TODO:: check if upgrades were handled here (hijack_io)
            
            # Collect the body
            resp_body = ''
            body.each do |val|
                resp_body << val
            end

            # Build the response
            resp = "HTTP/1.1 #{status}\r\n"
            headers[CONTENT_LENGTH] = resp_body.size.to_s           # ensure correct size
            headers[CONNECTION] = CLOSE if @keep_alive == false     # ensure appropriate keep alive is set (http 1.1 way)

            headers.each do |key, value|
                next if key.start_with? RACK

                resp << key
                resp << COLON_SPACE
                resp << value
                resp << CRLF
            end
            resp << CRLF
            resp << resp_body

            # TODO:: streaming responses (using async and a queue object?)
            @response = resp
        end


        protected


        def hijack
            @hijacked = true
            @env[RACK_HIJACK_IO] = nil
        end
    end
end
