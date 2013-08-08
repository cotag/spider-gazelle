module SpiderGazelle
	class Server
		def initialize(app, options)
			@reactor = UV::Loop.new
			@running = false			# is the loop running?
			@app = app

			#
			# thread safe shutdown callback
			@stop = @reactor.async do |e|
				@running = false
				@listeners.each |listener|
					listener.close
				end
				@stop.close				# Close the stop handle and the libuv will return when current request have completed
				@add_listeners.close 	# Close the add_listeners handle
			end

			#
			# thread safe tcp listener notifier
			@pending_listeners = Queue.new		# tcp listeners waiting to be added to the reactor
			@listeners = []						# active tcp listeners
			@add_listeners = @reactor.async do |e|
				until @pending_listeners.empty? do
					settings = @pending_listeners.pop true	# pop non-block
				    tcp = @reactor.tcp
					tcp.bind settings[0], settings[1]
					if settings[2]				 # optimize_for_latency
						tcp.enable_nodelay
					end
					@listeners << tcp
					start_listening tcp, settings[3]
				end
			end
		end

		def run
			@running = true
			@reactor.run 	# run is blocking
		end

		def stop
			@stop.call
		end

		def add_tcp_listener(host, port, optimize_for_latency=true, backlog=1024)
			@listeners << [host, port, optimize_for_latency, backlog]
			@add_listeners.call
		end


		protected


		def start_listening(tcp, backlog)
			tcp.listen backlog do |e|
				# if not an error then we will accept
				if e.nil?
					# NOTE:: memory leak if accept fails, need promises
					Client.new(@app, tcp.accept)
				end
			end
		end


	end
end
