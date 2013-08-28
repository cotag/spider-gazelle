require 'websocket/driver'


module SpiderGazelle
	class Websocket
		attr_reader :env, :url, :driver, :socket


		def initialize(tcp, env)
			@socket, @env = tcp, env

			scheme = Rack::Request.new(env).ssl? ? 'wss://' : 'ws://'
			@url = scheme + env['HTTP_HOST'] + env['REQUEST_URI']
			@driver = ::WebSocket::Driver.rack(self)

			# Pass data from the socket to the driver
			@socket.progress do |data|
				@driver.parse(data)
			end

			# Driver has indicated that it is closing
			# We'll close the socket after writing any remaining data
			@driver.on(:close) {
				@socket.shutdown
			}
		end

		def start
			@driver.start
			@socket.start_read
		end

		def write(string)
			@socket.write(string)
		end
	end
end
