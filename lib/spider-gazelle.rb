require "http-parser"   # C based, fast, http parser
require "libuv"         # Ruby Libuv FFI wrapper
require "rack"          # Ruby webserver abstraction

require "spider-gazelle/version"
require "spider-gazelle/request"
require "spider-gazelle/connection"
require "spider-gazelle/gazelle"
require "spider-gazelle/spider"

module SpiderGazelle
    # Location of the pipe used for socket delegation
    CONTROL_PIPE = "/tmp/spider-gazelle.delegator"
end
