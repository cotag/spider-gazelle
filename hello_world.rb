$LOAD_PATH << File.expand_path('./lib')
require "spider-gazelle"


app = lambda do |env|
  body = "Hello, World!"
  [200, {"Content-Type" => "text/plain", "Content-Length" => body.length.to_s}, [body]]
end

p 'starting spider'
SpiderGazelle::Spider.run app
