require 'set'


module SpiderGazelle
	class Spider


		DEFAULT_OPTIONS = {
			:leg_count => ::Libuv.cpu_count || 1,
			:host => '0.0.0.0',
        	:port => 8080
		}


		def initialize(app, options = {})
			@spider = Libuv::Loop.new

			# Create a function for stopping the spider from another thread
			@squash = spider.async do
				if @status == :running
					@status = :squashing

					# TODO:: Kill gazella here

					spider.stop
				end
			end

			@app = app
			@options = DEFAULT_OPTIONS.merge(options)



			# Manage the set of Gazelle pipe connections
			@gazella = Set.new
			@select_gazella = @gazella.cycle 	# provides a looping enumerator
			@accept_gazella = proc { |gazelle|
				if @gazella.size == 0
					# start accepting connections
					@tcp.listen(1024)
				end

				@gazella.add gazelle 			# add the new gazelle to the set
				@select_gazella.rewind			# update the enumerator

				gazelle.finally do
					@gazella.delete gazelle
					@select_gazella.rewind
				end
			}
			@new_gazella = proc { |server|
				server.accept @accept_gazella
			}


			# Connection management
			@accept_connection = proc { |client|
				gazelle = @select_gazella.next
				gazelle.write2(connection, 'client')
			}
			@new_connection = proc { |server|
				server.accept @accept_connection
			}


			@status = :dead		# Either dead, squashing, reanimating or running
			@mode = :thread		# Either thread or process
		end

		# Start the server (this method blocks until completion)
		def run
			return unless @status == :dead
			@status = :reanimating

			@spider.run do |logger|
				# Bind the socket
				@tcp = spider.tcp
				@tcp.bind(@options[:host], @options[:port]) @new_connection

				# Bind the pipe for communicating with gazelle
				@delegator = @loop.pipe(true)
				@delegator.bind(CONTROL_PIPE, @new_gazella)
				@delegator.listen(128)

				# Launch the gazelle here
				::Libuv.cpu_count.times do
					Gazelle.new(app, options)
				end

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
