# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)

require 'spider-gazelle/version'
version = SpiderGazelle::VERSION

Gem::Specification.new do |s|
    s.name        = "spider-gazelle"
    s.version     = version
    s.authors     = ["Stephen von Takach"]
    s.email       = ["steve@cotag.me"]
    s.license     = 'MIT'
    s.homepage    = "https://github.com/cotag/spider-gazelle"
    s.summary     = "A fast, parallel and concurrent web server for ruby"
    s.description = <<-EOF
      Spidergazelle, spidergazelle, amazingly agile, she leaps through the veldt,
      Spidergazelle, spidergazelle! She don’t care what you think, she says what the hell!
      Look out! Here comes the Spidergazelle!
    EOF

    s.add_dependency 'http-parser', '~> 1.1'    # Ruby FFI bindings for https://github.com/joyent/http-parser
    s.add_dependency 'libuv',  '~> 3.0' # Ruby FFI bindings for https://github.com/libuv/libuv
    s.add_dependency 'uv-rays','~> 2.0' # Provides buffering tools
    s.add_dependency 'rack',   '~> 2.0' # Ruby web server interface
    s.add_dependency 'websocket-driver', '~> 0.6'   # Websocket parser
    s.add_dependency 'http-2', '~> 0.8' # HTTP2 parsing and response management

    s.add_development_dependency 'rspec', '~> 3.5'  # Testing framework
    s.add_development_dependency 'rake', '~> 11.2'  # Task runner
    s.add_development_dependency 'yard', '~> 0.9'   # Comment based documentation generation

    s.files = Dir["{lib,bin}/**/*"] + %w(Rakefile spider-gazelle.gemspec README.md LICENSE)
    s.test_files = Dir["spec/**/*"]
    s.extra_rdoc_files = ["README.md"]

    s.bindir = 'bin'
    s.executables = [SpiderGazelle::EXEC_NAME]

    s.require_paths = ["lib"]
end
