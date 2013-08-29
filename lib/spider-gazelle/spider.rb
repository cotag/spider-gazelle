require 'set'


module SpiderGazelle
	class Spider


		DEFAULT_OPTIONS = {
			:gazelle_count => ::Libuv.cpu_count || 1,
			:host => '127.0.0.1',
        	:port => 8080
		}

		NEW_SOCKET = 's'.freeze


		def initialize(app, options = {})
			@spider = Libuv::Loop.new
			@app = app
			@options = DEFAULT_OPTIONS.merge(options)

			# Manage the set of Gazelle pipe connections
			@gazella = Set.new
			@select_gazella = @gazella.cycle 	# provides a looping enumerator for our round robin
			@accept_gazella = proc { |gazelle|
				p "gazelle #{@gazella.size} running"

				# start accepting connections
				if @gazella.size == 0
					@tcp.listen(1024)
				end

				@gazella.add gazelle 		# add the new gazelle to the set
				@select_gazella.rewind		# update the enumerator with the new gazelle

				# If a gazelle dies or shuts down we update the set
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
				gazelle.write2(client, NEW_SOCKET)
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
					if @status == :running
						@status = :squashing

						# TODO:: Kill gazella here

						@spider.stop
					end
				end

				# Bind the socket
				@tcp = @spider.tcp
				@tcp.bind(@options[:host], @options[:port], @new_connection)

				# Bind the pipe for communicating with gazelle
				begin
					File.unlink(CONTROL_PIPE)
				rescue
				end
				@delegator = @spider.pipe(true)
				@delegator.bind(CONTROL_PIPE, @new_gazella)
				@delegator.listen(128)

				# Launch the gazelle here
				@options[:gazelle_count].times do
					Thread.new do
						gazelle = Gazelle.new(@app, @options)
						gazelle.run
					end
				end


				@spider.signal(:INT) do 
					@spider.stop
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
