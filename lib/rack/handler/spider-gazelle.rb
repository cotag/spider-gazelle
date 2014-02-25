require "rack/handler"
require "spider-gazelle"
require "spider-gazelle/const"

module Rack
  module Handler
    module SpiderGazelle
      DEFAULT_OPTIONS = {
        :Host => "0.0.0.0",
        :Port => 8080,
        :Verbose => false
      }

      def self.run(app, options = {})
        options = DEFAULT_OPTIONS.merge(options)

        if options[:Verbose]
          app = Rack::CommonLogger.new(app, STDOUT)
        end

        if options[:environment]
          ENV["RACK_ENV"] = options[:environment].to_s
        end

        ::SpiderGazelle::Spider.run app, options
      end

      def self.valid_options
        { "Host=HOST"       => "Hostname to listen on (default: 0.0.0.0)",
          "Port=PORT"       => "Port to listen on (default: 8080)",
          "Quiet"           => "Don't report each request" }
      end
    end

    register :"spider-gazelle", SpiderGazelle
  end
end
