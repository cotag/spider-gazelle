# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "spider-gazelle/version"

Gem::Specification.new do |s|
    s.name        = "spider-gazelle"
    s.version     = SpiderGazelle::VERSION
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

    s.add_dependency 'rake'
    s.add_dependency 'http-parser'
    s.add_dependency 'libuv'
    s.add_dependency 'rack'

    s.add_development_dependency 'rspec'
    s.add_development_dependency 'yard'
    

    s.files = Dir["{lib}/**/*"] + %w(Rakefile spider-gazelle.gemspec README.md LICENSE)
    s.test_files = Dir["spec/**/*"]
    s.extra_rdoc_files = ["README.md"]

    s.require_paths = ["lib"]
end
