require 'set'


module SpiderGazelle
	class Gazelle
		def initialize(app, options)
			@app, @options = app, options

			@gazelle = Libuv::Loop.new
			@clients = Set.new 		# Set of active connections on this thread
			@active_requests = [] 	# Requests currently being processed
			@request_cache = []		# Stale request objects cached for reuse

			# The pipe to the connection delegation server
			@spider_comms = @loop.pipe(true)
			@spider_comms.connect(CONTROL_PIPE) do
				@spider_comms.progress do |data, connection|
					new_client(connection)
				end
			end

			# A single parser instance for processing requests
			@parser = ::HttpParser::Parser.new
			@parser.on_url do |instance, url|
				@request.url = url
			end
			@parser.on_header_field do |instance, header|
				@request.header = header
			end
			@parser.on_header_value do |instance, value|
				@request.headers[@request.header] = value
			end
			#@parser.on_headers_complete do
			#	@request.commit_headers
			#end
			@parser.on_body do |instance, data|
				@request.body << data
			end
			@parser.on_message_complete do
				@request.complete!
			end
		end

		def context=(request)
			@request = request
		end

		def parse(request, data)
			@parser.parse request, data
		end


		protected


		def new_client(connection)
			client = Client.new self, connection
			@clients.add client
			client.finally do
				@clients.delete(client)
			end
		end
	end
end
