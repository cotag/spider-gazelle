$LOAD_PATH << File.expand_path('./lib')
require "spider-gazelle"


app = lambda do |env|
  body = "Hello, World!"
  [200, {"Content-Type" => "text/plain", "Content-Length" => body.length.to_s}, [body]]
end

server = SpiderGazelle::Spider.new (app)
p 'starting server'
server.run
