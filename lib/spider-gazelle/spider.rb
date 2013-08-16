require 'set'

module SpiderGazelle
	class Spider


		# From Celluloid by Tarcieri and Contributors (16/08/2013)
		# https://github.com/celluloid/celluloid/blob/master/lib/celluloid/cpu_counter.rb
		DEFAULT_LEG_COUNT = begin
			case RbConfig::CONFIG['host_os'][/^[A-Za-z]+/]
			when 'darwin'
				Integer(`/usr/sbin/sysctl hw.ncpu`[/\d+/])
			when 'linux'
				if File.exists?("/sys/devices/system/cpu/present")
					File.read("/sys/devices/system/cpu/present").split('-').last.to_i+1
				else
					Dir["/sys/devices/system/cpu/cpu*"].select { |n| n=~/cpu\d+/ }.count
				end
			when 'mingw', 'mswin'
				Integer(ENV["NUMBER_OF_PROCESSORS"][/\d+/])
			else
				1 	# we'll go with a safe default if introspection fails
			end
		end

		DEFAULT_OPTIONS = {
			:leg_count => DEFAULT_LEG_COUNT,
			:host => '0.0.0.0',
        	:port => 8080
		}


		def initialize(app, options = {})
			@spider = Libuv::Loop.new

			@app = app
			@options = DEFAULT_OPTIONS.merge(options)

			@status = :dead		# Either dead, squashing, reanimating or running
			@mode = :thread		# Either thread or process

			@gazella = Set.new
		end

		# Start the server (this method blocks until completion)
		def run
			return unless @status == :dead
			@status = :reanimating

			@spider.run do |spider|
				# Create a function for stopping the spider from another thread
				@squash = spider.async do
					if @status == :running
						@status = :squashing

						# TODO:: Kill gazella here

						spider.stop
					end
				end

				# Bind the socket
				@tcp = spider.tcp
				@tcp.bind(@options[:host], @options[:port])

				# Update state only once the event loop is ready
				@status = :running
			end
		end

		# If the spider is running we will request to squash it (thread safe)
		def stop
			return false unless @status == :running
			@squash.call
			return true
		end


		protected


	end
end
