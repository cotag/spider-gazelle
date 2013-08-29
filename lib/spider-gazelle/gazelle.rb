require 'set'


module SpiderGazelle
	class Gazelle
		def initialize(app, options)
			@gazelle = Libuv::Loop.new
			@connections = Set.new 		# Set of active connections on this thread
			@parser_cache = []			# Stale parser objects cached for reuse
			@connection_queue = ::Libuv::Q::ResolvedPromise.new(@gazelle, true)

			# A single parser instance for processing requests for each gazelle
			@parser = ::HttpParser::Parser.new
			@parser.on_message_begin do
				@connection.start_request(Request.new(app, options))
			end
			@parser.on_url do |instance, url|
				@connection.parsing.url = url
			end
			@parser.on_header_field do |instance, header|
				@connection.parsing.header = header
			end
			@parser.on_header_value do |instance, value|
				req = @connection.parsing
				req.headers[req.header] = value
			end
			@parser.on_body do |instance, data|
				@connection.parsing.body << data
			end
			@parser.on_message_complete do
				@connection.finished_request
			end
		end

		def run
			@gazelle.run do |logger|
				logger.progress do |level, errorid, error|
					begin
						p "Log called: #{level}: #{errorid}\n#{error.message}\n#{error.backtrace.join("\n")}\n"
					rescue Exception
						p 'error in gazelle logger'
					end
				end

				# The pipe to the connection delegation server
				@spider_comms = @gazelle.pipe(true)
				@spider_comms.connect(CONTROL_PIPE) do
					@spider_comms.progress do |data, socket|
						if data == Spider::NEW_SOCKET
							new_connection(socket)
						else
							stop
						end
					end
					@spider_comms.start_read2
				end

				# TODO:: replace this with a message from the spider
				@gazelle.signal(:INT) do 
					@gazelle.stop
				end
			end
		end


		protected


		def new_connection(socket)
			# Keep track of the connection
			connection = Connection.new @gazelle, socket, @connection_queue
			@connections.add connection

			# process any data coming from the socket
			socket.progress do |data|
				# Keep track of which connection we are processing for the callbacks
                @connection = connection

                # Check for errors during the parsing of the request
                if !@parser.parse(connection.state, data)
					connection.parsing_error
				end
            end
            socket.start_read

            # Remove connection once closed (will auto-close if the socket closes)
			connection.finally do
				@connections.delete(connection)
			end
		end
	end
end
