require "http-parser"   # C based, fast, http parser
require "libuv"         # Ruby Libuv FFI wrapper
require "rack"          # Ruby webserver abstraction

require "spider-gazelle/version"
require "spider-gazelle/request"
require "spider-gazelle/connection"
require "spider-gazelle/gazelle"
require "spider-gazelle/spider"

module SpiderGazelle
    # Delegate pipe used for passing sockets to the gazelles
    # Signal pipe used to pass control signals
    DELEGATE_PIPE = "/tmp/spider-gazelle.delegate"
    SIGNAL_PIPE = "/tmp/spider-gazelle.signal"
end
