require 'rack/lint'
require 'rack/lock'
require 'rack/mock'

require 'rack/lock_patch'


module Rack
  class Lock
    def would_block
      @count > 0
    end
  end
end


  def lock_app(app)
    app = Rack::Lock.new(app)
    return app, Rack::Lint.new(app)
  end


describe Rack::Lock do

  describe 'Proxy' do

    it 'delegate each' do
      env      = Rack::MockRequest.env_for("/")
      response = Class.new {
        attr_accessor :close_called
        def initialize; @close_called = false; end
        def each; %w{ hi mom }.each { |x| yield x }; end
      }.new

      app = lock_app(lambda { |inner_env| [200, {"Content-Type" => "text/plain"}, response] })[1]
      response = app.call(env)[2]
      list = []
      response.each { |x| list << x }
      expect(list).to eq(%w{ hi mom })
    end

    it 'delegate to_path' do
      env  = Rack::MockRequest.env_for("/")

      res = ['Hello World']
      def res.to_path ; "/tmp/hello.txt" ; end

      app = Rack::Lock.new(lambda { |inner_env| [200, {"Content-Type" => "text/plain"}, res] })
      body = app.call(env)[2]

      expect(body.respond_to? :to_path).to eq(true)
      expect(body.to_path).to eq("/tmp/hello.txt")
    end

    it 'not delegate to_path if body does not implement it' do
      env  = Rack::MockRequest.env_for("/")

      res = ['Hello World']

      app = lock_app(lambda { |inner_env| [200, {"Content-Type" => "text/plain"}, res] })[1]
      body = app.call(env)[2]

      expect(body.respond_to? :to_path).to eq(false)
    end
  end

  it 'call super on close' do
    env      = Rack::MockRequest.env_for("/")
    response = Class.new {
      attr_accessor :close_called
      def initialize; @close_called = false; end
      def close; @close_called = true; end
    }.new

    app = lock_app(lambda { |inner_env| [200, {"Content-Type" => "text/plain"}, response] })[1]
    app.call(env)
    expect(response.close_called).to eq(false)
    response.close
    expect(response.close_called).to eq(true)
  end

  it "not unlock until body is closed" do
    env      = Rack::MockRequest.env_for("/")
    response = Object.new
    lock, app      = lock_app(lambda { |inner_env| [200, {"Content-Type" => "text/plain"}, response] })

    expect(lock.would_block).to eq(false)
    response = app.call(env)[2]
    expect(lock.would_block).to eq(true)
    response.close
    expect(lock.would_block).to eq(false)
  end

  it "return value from app" do
    env  = Rack::MockRequest.env_for("/")
    body = [200, {"Content-Type" => "text/plain"}, %w{ hi mom }]
    app  = lock_app(lambda { |inner_env| body })[1]

    res = app.call(env)
    expect(res[0]).to eq(body[0])
    expect(res[1]).to eq(body[1])
    expect(res[2].to_enum.to_a).to eq(["hi", "mom"])
  end

  it "call synchronize on lock" do
    env = Rack::MockRequest.env_for("/")
    lock, app = lock_app(lambda { |inner_env| [200, {"Content-Type" => "text/plain"}, %w{ a b c }] })
    expect(lock.would_block).to eq(false)
    app.call(env)
    expect(lock.would_block).to eq(true)
  end

  it "unlock if the app raises" do
    env = Rack::MockRequest.env_for("/")
    lock, app = lock_app(lambda { raise Exception })
    expect { app.call(env) }.to raise_error(Exception)
    expect(lock.would_block).to eq(false)
  end

  it "unlock if the app throws" do
    env = Rack::MockRequest.env_for("/")
    lock, app = lock_app(lambda {|_| throw :bacon })
    expect { app.call(env) }.to raise_error(ArgumentError)
    expect(lock.would_block).to eq(false)
  end

  it "set multithread flag to false" do
    outer = nil
    app = lock_app(lambda { |env|
      outer = env
      expect(env['rack.multithread']).to eq(false)
      [200, {"Content-Type" => "text/plain"}, %w{ a b c }]
    })[1]
    resp = app.call(Rack::MockRequest.env_for("/"))[2]
    resp.close
    expect(outer['rack.multithread']).to eq(true)
  end
end
