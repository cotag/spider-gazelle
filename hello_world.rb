$LOAD_PATH << File.expand_path('./lib')
require 'rack/handler/spider-gazelle'

app = lambda do |env|
  body = 'Hello, World!'
  [200, {'Content-Type' => 'text/plain', 'Content-Length' => body.length.to_s}, [body]]
end

Rack::Handler::SpiderGazelle.run app, verbose: true
