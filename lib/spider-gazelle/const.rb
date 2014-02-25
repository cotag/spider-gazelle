# Thanks to Puma https://github.com/puma/puma/blob/master/lib/puma/const.rb
require "rack"

module SpiderGazelle
  # class UnsupportedOption < RuntimeError
  # end


  # Every standard HTTP code mapped to the appropriate message.  These are
  # used so frequently that they are placed directly in SpiderGazelle for easy
  # access rather than SpiderGazelle::Const itself.
  HTTP_STATUS_CODES = Rack::Utils::HTTP_STATUS_CODES

  # # For some HTTP status codes the client only expects headers.
  # STATUS_WITH_NO_ENTITY_BODY = Hash[Rack::Utils::STATUS_WITH_NO_ENTITY_BODY.map { |s|
  #   [s, true]
  # }]

  # Based on http://rack.rubyforge.org/doc/SPEC.html
  # Frequently used constants when constructing requests or responses.  Many times
  # the constant just refers to a string with the same contents.  Using these constants
  # gave about a 3% to 10% performance improvement over using the strings directly.
  #
  # The constants are frozen because Hash#[]= when called with a String key dups
  # the String UNLESS the String is frozen. This saves us therefore 2 object
  # allocations when creating the env hash later.
  #
  # While SpiderGazelle does try to emulate the CGI/1.2 protocol, it does not use the REMOTE_IDENT,
  # REMOTE_USER, or REMOTE_HOST parameters since those are either a security problem or
  # too taxing on performance.
  module Const

    SPIDER_GAZELLE_VERSION = VERSION = "0.1.6".freeze
    # CODE_NAME = "Earl of Sandwich Partition"
    SERVER = "SpiderGazelle".freeze

    # FAST_TRACK_KA_TIMEOUT = 0.2

    # # The default number of seconds for another request within a persistent
    # # session.
    # PERSISTENT_TIMEOUT = 20

    # # The default number of seconds to wait until we get the first data
    # # for the request
    # FIRST_DATA_TIMEOUT = 30

    # # How long to wait when getting some write blocking on the socket when
    # # sending data back
    # WRITE_TIMEOUT = 10

    # DATE = "Date".freeze

    SCRIPT_NAME = "SCRIPT_NAME".freeze

    # The original URI requested by the client.
    REQUEST_URI= "REQUEST_URI".freeze
    REQUEST_PATH = "REQUEST_PATH".freeze

    PATH_INFO = "PATH_INFO".freeze

    # SPIDER_GAZELLE_TMP_BASE = "spider-gazelle".freeze

    # # Indicate that we couldn"t parse the request
    ERROR_400_RESPONSE = "HTTP/1.1 400 Bad Request\r\n\r\n"

    # The standard empty 404 response for bad requests.  Use Error4040Handler for custom stuff.
    ERROR_404_RESPONSE = "HTTP/1.1 404 Not Found\r\nConnection: close\r\nServer: #{SERVER} #{SPIDER_GAZELLE_VERSION}\r\n\r\nNOT FOUND".freeze

    # The standard empty 408 response for requests that timed out.
    ERROR_408_RESPONSE = "HTTP/1.1 408 Request Timeout\r\nConnection: close\r\nServer:  #{SERVER} #{SPIDER_GAZELLE_VERSION}\r\n\r\n".freeze

    # Indicate that there was an internal error, obviously.
    ERROR_500_RESPONSE = "HTTP/1.1 500 Internal Server Error\r\n\r\n"

    # A common header for indicating the server is too busy.  Not used yet.
    ERROR_503_RESPONSE = "HTTP/1.1 503 Service Unavailable\r\n\r\nBUSY".freeze

    # # The basic max request size we"ll try to read.
    # CHUNK_SIZE = 16 * 1024

    # # This is the maximum header that is allowed before a client is booted.  The parser detects
    # # this, but we"d also like to do this as well.
    # MAX_HEADER = 1024 * (80 + 32)

    # # Maximum request body size before it is moved out of memory and into a tempfile for reading.
    # MAX_BODY = MAX_HEADER

    # # A frozen format for this is about 15% faster
    # STATUS_FORMAT = "HTTP/1.1 %d %s\r\nConnection: close\r\n".freeze

    CONTENT_TYPE = "CONTENT_TYPE".freeze
    HTTP_CONTENT_TYPE = "HTTP_CONTENT_TYPE".freeze
    DEFAULT_TYPE = "text/plain".freeze

    # LAST_MODIFIED = "Last-Modified".freeze
    # ETAG = "ETag".freeze
    # SLASH = "/".freeze
    REQUEST_METHOD = "REQUEST_METHOD".freeze
    # GET = "GET".freeze
    HEAD = "HEAD".freeze
    # # ETag is based on the apache standard of hex mtime-size-inode (inode is 0 on win32)
    # ETAG_FORMAT = "\"%x-%x-%x\"".freeze
    LINE_END = "\r\n".freeze
    REMOTE_ADDR = "REMOTE_ADDR".freeze
    # HTTP_X_FORWARDED_FOR = "HTTP_X_FORWARDED_FOR".freeze
    # HTTP_IF_MODIFIED_SINCE = "HTTP_IF_MODIFIED_SINCE".freeze
    # HTTP_IF_NONE_MATCH = "HTTP_IF_NONE_MATCH".freeze
    # REDIRECT = "HTTP/1.1 302 Found\r\nLocation: %s\r\nConnection: close\r\n\r\n".freeze
    # HOST = "HOST".freeze

    HTTP_META = "HTTP_".freeze
    # Portion of the request following a "?" (empty if none)
    QUERY_STRING = "QUERY_STRING".freeze
    # Required although HTTP_HOST takes priority if set
    SERVER_NAME = "SERVER_NAME".freeze
    # Required (set in spider.rb init)
    SERVER_PORT = "SERVER_PORT".freeze
    HTTP_HOST = "HTTP_HOST".freeze
    HOST_0_0_0_0 = "0.0.0.0".freeze
    # PORT_80 = "80".freeze
    # PORT_443 = "443".freeze
    PORT_8080 = "8080".freeze
    LOCALHOST = "localhost".freeze

    HTTP_STATUS_DEFAULT = proc { "CUSTOM" }
    SERVER_PROTOCOL = "SERVER_PROTOCOL".freeze
    HTTP_11 = "HTTP/1.1".freeze
    # HTTP_10 = "HTTP/1.0".freeze

    SERVER_SOFTWARE = "SERVER_SOFTWARE".freeze
    GATEWAY_INTERFACE = "GATEWAY_INTERFACE".freeze
    CGI_VER = "CGI/1.2".freeze

    # STOP_COMMAND = "?".freeze
    # HALT_COMMAND = "!".freeze
    # RESTART_COMMAND = "R".freeze

    RACK = "rack".freeze
    RACK_VERSION = "rack.version".freeze
    RACK_ERRORS = "rack.errors".freeze
    RACK_MULTITHREAD = "rack.multithread".freeze
    RACK_MULTIPROCESS = "rack.multiprocess".freeze
    RACK_RUN_ONCE = "rack.run_once".freeze

    # An IO like object containing all the request body
    RACK_INPUT = "rack.input".freeze
    # http or https
    RACK_URL_SCHEME = "rack.url_scheme".freeze
    # RACK_AFTER_REPLY = "rack.after_reply".freeze
    # SPIDER_GAZELLE_SOCKET = "spider-gazelle.socket".freeze
    # SPIDER_GAZELLE_CONFIG = "spider-gazelle.config".freeze

    HTTP = "http".freeze
    HTTPS = "https".freeze

    # HTTPS_KEY = "HTTPS".freeze

    # HTTP_VERSION = "HTTP_VERSION".freeze
    # HTTP_CONNECTION = "HTTP_CONNECTION".freeze

    # HTTP_11_200 = "HTTP/1.1 200 OK\r\n".freeze
    # HTTP_10_200 = "HTTP/1.0 200 OK\r\n".freeze

    CLOSE = "close".freeze
    KEEP_ALIVE = "Keep-Alive".freeze

    CONTENT_LENGTH = "CONTENT_LENGTH".freeze
    HTTP_CONTENT_LENGTH = "HTTP_CONTENT_LENGTH".freeze
    CONTENT_LENGTH2 = "Content-Length".freeze
    # CONTENT_LENGTH_S = "Content-Length: ".freeze
    TRANSFER_ENCODING = "Transfer-Encoding".freeze

    CONNECTION = "Connection".freeze
    # CONNECTION_CLOSE = "Connection: close\r\n".freeze
    # CONNECTION_KEEP_ALIVE = "Connection: Keep-Alive\r\n".freeze

    CHUNKED = "chunked".freeze
    # TRANSFER_ENCODING_CHUNKED = "Transfer-Encoding: chunked\r\n".freeze
    CLOSE_CHUNKED = "0\r\n\r\n".freeze

    COMMA = ", ".freeze
    COLON = ": ".freeze
    NEWLINE = "\n".freeze
    EMPTY = "".freeze

    ZERO = "0".freeze

    # Hijacking IO is supported
    HIJACK_P = "rack.hijack?".freeze
    # Callback for indicating that this socket will be hijacked
    HIJACK = "rack.hijack".freeze
    # The object for performing IO on after hijack is called
    HIJACK_IO = "rack.hijack_io".freeze

    ASYNC = "async.callback".freeze

    USE_TLS = 'T'.freeze
    NO_TLS = 'F'.freeze
    KILL_GAZELLE = 'k'.freeze
  end
end
