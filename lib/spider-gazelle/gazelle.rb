require 'spider-gazelle/const'
require 'set'

module SpiderGazelle
  class Gazelle
    include Const

    attr_reader :parser_cache, :connections, :logger

    def set_instance_type(inst)
      inst.type = :request
    end

    def initialize(loop, logger, mode)
      @gazelle = loop
      # Set of active connections on this thread
      @connections = Set.new
      # Stale parser objects cached for reuse
      @parser_cache = []

      @mode = mode
      @logger = logger
      @app_cache = {}
      @connection_queue = ::Libuv::Q::ResolvedPromise.new @gazelle, true

      # A single parser instance for processing requests for each gazelle
      @parser = ::HttpParser::Parser.new self
      @set_instance_type = method :set_instance_type

      # Single progress callback for each gazelle
      @on_progress = method :on_progress
    end

    # TODO Review.
    def run
      @gazelle.run do |logger|
        logger.progress do |level, errorid, error|
          begin
            msg = "Gazelle log: #{level}: #{errorid}\n#{error.message}\n#{error.backtrace.join("\n") if error.backtrace}\n"
            @logger.error msg
            puts msg
          rescue Exception
            p 'error in gazelle logger'
          end
        end

        unless @mode == :no_ipc
          # A pipe used to forward connections to different threads
          @socket_server = @gazelle.pipe true
          @socket_server.connect(DELEGATE_PIPE) do
            @socket_server.progress &method(:new_connection)
            @socket_server.start_read2
          end

          # A pipe used to signal various control commands (shutdown, etc)
          @signal_server = @gazelle.pipe
          @signal_server.connect(SIGNAL_PIPE) do
            @signal_server.progress &method(:process_signal)
            @signal_server.start_read
          end
        end
      end
    end

    # HTTP Parser callbacks:
    def on_message_begin(parser)
      @connection.start_parsing
    end

    def on_url(parser, url)
      @connection.parsing.url << url
    end

    def on_header_field(parser, header)
      req = @connection.parsing
      req.header.frozen? ? req.header = header : req.header << header
    end

    def on_header_value(parser, value)
      req = @connection.parsing
      if req.header.frozen?
        req.env[req.header] << value
      else
        header = req.header
        header.upcase!
        header.gsub!('-', '_')
        header.prepend(HTTP_META)
        header.freeze
        if req.env[header]
          req.env[header] << COMMA
          req.env[header] << value
        else
          req.env[header] = value
        end
      end
    end

    def on_headers_complete(parser)
      @connection.parsing.env[REQUEST_METHOD] = @connection.state.http_method.to_s
    end

    def on_body(parser, data)
      @connection.parsing.body << data
    end

    def on_message_complete(parser)
      @connection.finished_parsing
    end

    def discard(connection)
      @connections.delete(connection)
      @parser_cache << connection.state
    end

    protected

    def on_progress(data, socket)
      # Keep track of which connection we are processing for the callbacks
      @connection = socket.storage

      # Check for errors during the parsing of the request
      @connection.parsing_error if @parser.parse(@connection.state, data)
    end

    def new_connection(data, socket)
      # Data == "TLS_indicator Port APP_ID"
      tls, port, app_id = data.split(' ', 3)
      app = @app_cache[app_id.to_sym] ||= AppStore.get(app_id)
      inst = @parser_cache.pop || ::HttpParser::Parser.new_instance(&@set_instance_type)

      # process any data coming from the socket
      socket.progress @on_progress
      # TODO:: Allow some globals for supplying the certs
      socket.start_tls(:server => true) if tls == 'T'

      # Keep track of the connection
      connection = Connection.new self, @gazelle, socket, port, inst, app, @connection_queue
      @connections.add connection
      # This allows us to re-use the one proc for parsing
      socket.storage = connection

      socket.start_read
    end

    def process_signal(data, pipe)
      shutdown if data == KILL_GAZELLE
    end

    def shutdown
      # TODO:: do this nicely. Need to signal the connections to close
      @gazelle.stop
    end
  end
end
