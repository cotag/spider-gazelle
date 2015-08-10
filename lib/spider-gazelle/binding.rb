require 'spider-gazelle/const'
require 'set'
require 'thread'

module SpiderGazelle
  class Binding
    include Const

    attr_reader :app_id

    def initialize(loop, delegate, app_id, options = {})
      @app_id = app_id
      @options = options
      @loop = loop
      @delegate = delegate
      @tls = @options[:tls] || false
      @port = @options[:Port] || (@tls ? PORT_443 : PORT_80)
      @optimize = @options[:optimize_for_latency] || true

      # Connection management functions
      @accept_connection = method :accept_connection
    end

    # Bind the application to the selected port
    def bind
      # Bind the socket
      @tcp = @loop.tcp
      @tcp.bind @options[:Host], @port, @accept_connection
      @tcp.listen @options[:backlog]

      # Delegate errors
      @tcp.catch { |e| @loop.log(:error, 'application bind failed', e) }
      @tcp
    end

    # Close the bindings
    def unbind
      # close unless we've never been bound
      @tcp.close unless @tcp.nil?
      @tcp
    end

    protected

    # Once the connection is accepted we disable Nagles Algorithm
    # This improves performance as we are using vectored or scatter/gather IO
    # Then the spider delegates to the gazelle loops
    def accept_connection(client)
      client.enable_nodelay if @optimize == true
      @delegate.call client, @tls, @port, @app_id
    end
  end
end
