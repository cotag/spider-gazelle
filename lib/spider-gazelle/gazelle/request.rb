# frozen_string_literal: true

require 'stringio'
require 'rack'            # Ruby webserver abstraction

module SpiderGazelle
    class Request < ::Libuv::Q::DeferredPromise
        RACK_VERSION = 'rack.version'
        RACK_ERRORS = 'rack.errors'
        RACK_MULTITHREAD = "rack.multithread"
        RACK_MULTIPROCESS = "rack.multiprocess"
        RACK_RUN_ONCE = "rack.run_once"
        SCRIPT_NAME = "SCRIPT_NAME"
        EMPTY = ''
        SERVER_PROTOCOL = "SERVER_PROTOCOL"
        HTTP_11 = "HTTP/1.1"
        SERVER_SOFTWARE = "SERVER_SOFTWARE"
        GATEWAY_INTERFACE = "GATEWAY_INTERFACE"
        CGI_VER = "CGI/1.2"
        SERVER = "SpiderGazelle"
        LOCALHOST = 'localhost'


        # TODO:: Add HTTP headers to the env and capitalise them and prefix them with HTTP_
        #   convert - signs to underscores
        PROTO_ENV = {
            RACK_VERSION => ::Rack::VERSION,   # Should be an array of integers
            RACK_ERRORS => $stderr,            # An error stream that supports: puts, write and flush
            RACK_MULTITHREAD => true,          # can the app be simultaneously invoked by another thread?
            RACK_MULTIPROCESS => true,        # will the app be simultaneously be invoked in a separate process?
            RACK_RUN_ONCE => false,            # this isn't CGI so will always be false

            SCRIPT_NAME => ENV['SCRIPT_NAME'] || EMPTY,   #  The virtual path of the app base (empty if root)
            SERVER_PROTOCOL => HTTP_11,

            GATEWAY_INTERFACE => CGI_VER,
            SERVER_SOFTWARE   => SERVER
        }

        attr_accessor :env, :url, :header, :body, :keep_alive, :upgrade
        attr_reader :hijacked, :defer, :is_async


        SERVER_PORT = "SERVER_PORT"
        REMOTE_ADDR = "REMOTE_ADDR"
        RACK_URL_SCHEME = "rack.url_scheme"

        def initialize(thread, app, port, remote_ip, scheme, socket)
            super(thread, thread.defer)

            @socket = socket
            @app = app
            @body = String.new
            @header = String.new
            @url = String.new
            @env = PROTO_ENV.dup
            @env[SERVER_PORT] = port
            @env[REMOTE_ADDR] = remote_ip
            @env[RACK_URL_SCHEME] = scheme
        end


        CONTENT_LENGTH = "CONTENT_LENGTH"
        HTTP_CONTENT_LENGTH = "HTTP_CONTENT_LENGTH"
        CONTENT_TYPE = "CONTENT_TYPE"
        HTTP_CONTENT_TYPE = "HTTP_CONTENT_TYPE"
        DEFAULT_TYPE = "text/plain"
        REQUEST_URI= "REQUEST_URI"
        ASCII_8BIT = "ASCII-8BIT"
        RACK_INPUT = "rack.input"
        PATH_INFO = "PATH_INFO"
        REQUEST_PATH = "REQUEST_PATH"
        QUERY_STRING = "QUERY_STRING"
        HTTP_HOST = "HTTP_HOST"
        COLON = ":"
        SERVER_NAME = "SERVER_NAME"
        # Hijacking IO is supported
        HIJACK_P = "rack.hijack?"
        # Callback for indicating that this socket will be hijacked
        HIJACK = "rack.hijack"
        # The object for performing IO on after hijack is called
        HIJACK_IO = "rack.hijack_io"
        QUESTION_MARK = "?"
        
        HTTP_UPGRADE = 'HTTP_UPGRADE'
        USE_HTTP2 = 'h2c'




        def execute!
            @env[CONTENT_LENGTH] = @env.delete(HTTP_CONTENT_LENGTH) || @body.bytesize.to_s
            @env[CONTENT_TYPE] = @env.delete(HTTP_CONTENT_TYPE) || DEFAULT_TYPE
            @env[REQUEST_URI] = @url.freeze

            # For Rack::Lint on 1.9, ensure that the encoding is always for spec
            @body.force_encoding(ASCII_8BIT)
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
                    @env[SERVER_PORT] = host[colon + 1, host.bytesize]
                else
                    @env[SERVER_NAME] = host
                end
            else
                @env[SERVER_NAME] = LOCALHOST
            end

            if @upgrade == true && @env[HTTP_UPGRADE] == USE_HTTP2
                # TODO:: implement the upgrade process here
            end

            # Provide hijack options
            @env[HIJACK_P] = true
            @env[HIJACK] = proc { @env[HIJACK_IO] = @socket }

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
