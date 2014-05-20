require 'spider-gazelle/const'
require 'stringio'

module SpiderGazelle
  class Request
    include Const

    # TODO:: Add HTTP headers to the env and capitalise them and prefix them with HTTP_
    #   convert - signs to underscores
    PROTO_ENV = {
      RACK_VERSION => ::Rack::VERSION,   # Should be an array of integers
      RACK_ERRORS => $stderr,            # An error stream that supports: puts, write and flush
      RACK_MULTITHREAD => true,          # can the app be simultaneously invoked by another thread?
      RACK_MULTIPROCESS => false,        # will the app be simultaneously be invoked in a separate process?
      RACK_RUN_ONCE => false,            # this isn't CGI so will always be false

      SCRIPT_NAME => ENV['SCRIPT_NAME'] || EMPTY,   #  The virtual path of the app base (empty if root)
      SERVER_PROTOCOL => HTTP_11,

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
      @env = PROTO_ENV.dup
      @loop = connection.loop
      @env[SERVER_PORT] = connection.port
      @env[REMOTE_ADDR] = connection.remote_ip
      @env[RACK_URL_SCHEME] = connection.tls ? HTTPS : HTTP
      @env[ASYNC] = connection.async_callback
    end

    def execute!
      @env[CONTENT_LENGTH] = @env.delete(HTTP_CONTENT_LENGTH) || @body.length
      @env[CONTENT_TYPE] = @env.delete(HTTP_CONTENT_TYPE) || DEFAULT_TYPE
      @env[REQUEST_URI] = @url.freeze

      # For Rack::Lint on 1.9, ensure that the encoding is always for spec
      @body.force_encoding('ASCII-8BIT') if @body.respond_to?(:force_encoding)
      @env[RACK_INPUT] = StringIO.new @body

      # Break the request into its components
      query_start  = @url.index '?'
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
        @env[HIJACK_P] = true
        @env[HIJACK] = method :hijack
      end

      # Execute the request
      @response = catch(:async) { @app.call @env }
      if @response.nil? || @response[0] == -1
        @deferred = @loop.defer

        # close the body for deferred responses
        unless @response.nil?
          body = @response[2]
          body.close if body.respond_to?(:close)
        end
      end
      @response
    end

    protected

    def hijack
      @hijacked = @loop.defer
      @env[HIJACK_IO] = @hijacked.promise
    end
  end
end
