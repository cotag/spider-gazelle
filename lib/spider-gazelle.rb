require "http-parser"   # C based, fast, http parser
require "libuv"         # Ruby Libuv FFI wrapper
require "rack"          # Ruby webserver abstraction

require "spider-gazelle/version"
require "spider-gazelle/request"        # Holds request information and handles request processing
require "spider-gazelle/connection"     # Holds connection information and handles request pipelining
require "spider-gazelle/gazelle"        # Processes data received from connections

require "spider-gazelle/app_store"      # Holds references to the loaded rack applications
require "spider-gazelle/binding"        # Holds a reference to a bound port and associated rack application
require "spider-gazelle/spider"         # Accepts connections and offloads them to gazelles


module SpiderGazelle
    # Delegate pipe used for passing sockets to the gazelles
    # Signal pipe used to pass control signals
    DELEGATE_PIPE = "/tmp/spider-gazelle.delegate"
    SIGNAL_PIPE = "/tmp/spider-gazelle.signal"
end
