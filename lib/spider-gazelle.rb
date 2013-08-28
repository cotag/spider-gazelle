require "http-parser"   # C based, fast, http parser
require "uvrb"          # Ruby Libuv FFI wrapper
require "rack"          # Ruby webserver abstraction

require "spider-gazelle/version"

module SpiderGazelle
    # Location of the pipe used for socket delegation
    CONTROL_PIPE = "/tmp/spider-gazelle.delegator"
end
