require "rack/handler"
require "spider-gazelle"

module Rack
    module Handler
        module SpiderGazelle
            def self.run(app, options = {})
                
                # Replace the rackup with app
                options = ::SpiderGazelle::Options::DEFAULTS.merge(options)
                options.delete(:rackup)
                options[:app] = app

                # Can't pass an object over a pipe
                options[:isolate] = true
                options[:mode] = :thread if options[:mode] == :process

                # Ensure the environment is set
                options[:environment] ||= ENV['RACK_ENV'] || 'development'
                ENV['RACK_ENV'] = options[:environment]

                ::SpiderGazelle::LaunchControl.instance.launch([options])
            end
        end

        register :"spider-gazelle", SpiderGazelle
    end
end
