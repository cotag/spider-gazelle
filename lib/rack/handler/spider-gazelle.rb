require 'rack/handler'
require 'spider-gazelle'


module Rack
	module Handler
	    module SpiderGazelle
			DEFAULT_OPTIONS = {
				:Host => '0.0.0.0',
				:Port => 8080,
				:Verbose => false
			}

	    	def self.run(app, options = {})
	    		options = DEFAULT_OPTIONS.merge(options)

	    		if options[:Verbose]
	    			app = Rack::CommonLogger.new(app, STDOUT)
	    		end

	    		if options[:environment]
	    			ENV['RACK_ENV'] = options[:environment].to_s
	    		end

	    		server = ::SpiderGazelle::Spider.new(app, options)

	    		puts "Spider-Gazelle #{::SpiderGazelle::VERSION} starting..."
	    		puts "* Environment: #{ENV['RACK_ENV']}"
	    		puts "* Listening on tcp://#{options[:Host]}:#{options[:Port]}"

	    		yield server if block_given?

	    		server.run
	    	end

			def self.valid_options
				{
					"Host=HOST"       => "Hostname to listen on (default: 0.0.0.0)",
					"Port=PORT"       => "Port to listen on (default: 8080)",
					"Quiet"           => "Don't report each request"
				}
			end
	    end

	    register :sg, SpiderGazelle
	end
end
