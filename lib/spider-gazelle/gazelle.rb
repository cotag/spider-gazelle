# frozen_string_literal: true


require 'rack' # Ruby webserver abstraction

# Reactor aware websocket implementation
require "spider-gazelle/upgrades/websocket"


module SpiderGazelle
    class Gazelle
        def initialize(thread, type)
            raise ArgumentError, "type must be one of #{MODES}" unless MODES.include?(type)
            
            @type = type
            @logger = Logger.instance
            @thread = thread
        end

        def run!(options)
            @options = options
            @logger.verbose { "Gazelle: #{@type} started" }

            self
        end

        def shutdown
            # Wait for the requests to finish
            @logger.verbose { "Gazelle: #{@type} shutting down" }
        end




        protected
    end
end
