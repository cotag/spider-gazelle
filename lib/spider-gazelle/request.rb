require 'stringio'


module SpiderGazelle
    class Request

        SERVER = 'SG'.freeze

        REQUEST_URI = 'REQUEST_URI'.freeze
        REQUEST_METHOD = 'REQUEST_METHOD'.freeze
        REQUEST_PATH = 'REQUEST_PATH'.freeze
        SCRIPT_NAME = 'SCRIPT_NAME'.freeze
        PATH_INFO = 'PATH_INFO'.freeze
        QUERY_STRING = 'QUERY_STRING'.freeze
        SERVER_NAME = 'SERVER_NAME'.freeze
        SERVER_SOFTWARE = 'SERVER_SOFTWARE'.freeze
        SERVER_PORT = 'SERVER_PORT'.freeze

        RACK_INPUT = 'rack.input'.freeze
        RACK_ERRORS = 'rack.errors'.freeze
        RACK_MULTITHREAD = 'rack.multithread'.freeze
        RACK_MULTIPROCESS = 'rack.multiprocess'.freeze
        RACK_RUNONCE = 'rack.run_once'.freeze
        RACK_URLSCHEME = 'rack.url_scheme'.freeze

        HTTP_URL_SCHEME = 'http'.freeze
        HTTPS_URL_SCHEME = 'https'.freeze
        COLON_SPACE = ': '.freeze
        CRLF = "\r\n".freeze
        EMPTY = ''.freeze

        CONTENT_LENGTH = "Content-Length".freeze
        CONNECTION = "Connection".freeze
        KEEP_ALIVE = "Keep-Alive".freeze
        CLOSE = "close".freeze


        attr_accessor :url, :header, :headers, :body, :response


        # TODO:: ensure rack has all the information
        def initialize(app, options)
            @app, @options = app, options
            @body = ''
            @headers = {}
        end

        def prepare(state)
            # TODO:: check for upgrades and mark if we should close connection
            @env = {
                SERVER_SOFTWARE => SERVER,
                SERVER_PORT => 8080,

                RACK_MULTITHREAD => true,
                RACK_MULTIPROCESS => false,
                RACK_RUNONCE => false,
                RACK_URLSCHEME => HTTP_URL_SCHEME,

                SCRIPT_NAME => EMPTY,    # TODO:: needed?
                REQUEST_URI => @url.freeze,

                REQUEST_METHOD => state.http_method,
                CONNECTION => state.keep_alive? ? KEEP_ALIVE : CLOSE
            }
        end

        def execute!
            query_start  = @url.index('?')
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
            @env[RACK_INPUT] = StringIO.new(@body)
            @env[RACK_ERRORS] = $stderr

            # Process the request
            status, headers, body = @app.call(@env)

            # Collect the body
            resp_body = ''
            body.each do |val|
                resp_body << val
            end

            # Build the response
            resp = "HTTP/1.1 #{status}\r\n"
            headers[CONTENT_LENGTH] = body.size     # ensure correct size
            headers.each do |key, value|
                resp << key
                resp << COLON_SPACE
                resp << value
                resp << CRLF
            end
            resp << CRLF
            resp << resp_body
            @response = resp
        end
    end
end
