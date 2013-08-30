require 'set'


module SpiderGazelle
	class Spider


		DEFAULT_OPTIONS = {
			:gazelle_count => ::Libuv.cpu_count || 1,
			:host => '127.0.0.1',
        	:port => 8080
		}

		NEW_SOCKET = 's'.freeze
		KILL_GAZELLE = 'k'.freeze


		def initialize(app, options = {})
			@spider = Libuv::Loop.new
			@app = app
			@options = DEFAULT_OPTIONS.merge(options)

			# Manage the set of Gazelle socket listeners
			@loops = Set.new
			@select_loop = @loops.cycle 	# provides a looping enumerator for our round robin
			@accept_loop = proc { |loop|
				p "gazelle #{@loops.size} loop running"

				# start accepting connections
				if @loops.size == 0
					# Bind the socket
					@tcp = @spider.tcp
					@tcp.bind(@options[:host], @options[:port], @new_connection)
					@tcp.listen(1024)
					@tcp.catch do
						@spider.log :error, :tcp_binding, e
					end
				end

				@loops.add loop 		# add the new gazelle to the set
				@select_loop.rewind		# update the enumerator with the new gazelle

				# If a gazelle dies or shuts down we update the set
				loop.finally do
					@loops.delete loop
					@select_loop.rewind

					if @loops.size == 0
						@tcp.close
					end
				end
			}

			# Manage the set of Gazelle signal pipes
			@gazella = Set.new
			@accept_gazella = proc { |gazelle|
				p "gazelle #{@gazella.size} signal port ready"
				# add the signal port to the set
				@gazella.add gazelle
				gazelle.finally do
					@gazella.delete gazelle
				end
			}

			# Connection management
			@accept_connection = proc { |client|
				client.enable_nodelay
				loop = @select_loop.next
				loop.write2(client, NEW_SOCKET)
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
				logger.progress do |level, errorid, error|
					begin
						p "Log called: #{level}: #{errorid}\n#{error.message}\n#{error.backtrace.join("\n")}\n"
					rescue Exception
						p 'error in gazelle logger'
					end
				end

				# Create a function for stopping the spider from another thread
				@squash = @spider.async do
					squash
				end

				# Bind the pipe for sending sockets to gazelle
				begin
					File.unlink(DELEGATE_PIPE)
				rescue
				end
				@delegator = @spider.pipe(true)
				@delegator.bind(DELEGATE_PIPE) do 
					@delegator.accept @accept_loop
				end
				@delegator.listen(128)

				# Bind the pipe for communicating with gazelle
				begin
					File.unlink(SIGNAL_PIPE)
				rescue
				end
				@signaller = @spider.pipe(true)
				@signaller.bind(SIGNAL_PIPE) do
					@signaller.accept @accept_gazella
				end
				@signaller.listen(128)


				# Launch the gazelle here
				@options[:gazelle_count].times do
					Thread.new do
						gazelle = Gazelle.new(@app, @options)
						gazelle.run
					end
				end

				# Signal gazelle death here
				@spider.signal(:INT) do
					squash
				end

				# Update state only once the event loop is ready
				@status = :running
			end
		end

		# If the spider is running we will request to squash it (thread safe)
		def stop
			@squash.call
		end


		protected


		# Triggers a shutdown of the gazelles.
		# We ensure the process is running here as signals can be called multiple times
		def squash
			if @status == :running

				# Update the state and close the socket
				@status = :squashing
				@tcp.close

				# Signal all the gazelle to shutdown
				promises = []
				@gazella.each do |gazelle|
					promises << gazelle.write(KILL_GAZELLE)
				end

				# Once the signal has been sent we can stop the spider loop
				@spider.all(*promises).finally do
					begin
						@delegator.close
						File.unlink(DELEGATE_PIPE)
					rescue
					end
					begin
						@signaller.close
						File.unlink(SIGNAL_PIPE)
					rescue
					end
					@spider.stop
					@status = :dead
				end
			end
		end


	end
end
