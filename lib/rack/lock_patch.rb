require 'thread'
require 'rack/body_proxy'

require 'rack/lock' # ensure this loads first

module Rack
    # Rack::Lock locks every request inside a mutex, so that every request
    # will effectively be executed synchronously.
    class Lock
        # FLAG = 'rack.multithread'.freeze # defined in rack/lock
        RACK_MULTITHREAD ||= FLAG

        def initialize(app, mutex = Mutex.new)
            @app, @mutex = app, mutex
            @sig = ConditionVariable.new
            @count = 0
        end

        def call(env)
            @mutex.lock
            @count += 1
            @sig.wait(@mutex) if @count > 1
            response = @app.call(env.merge(RACK_MULTITHREAD => false))
            returned = response << BodyProxy.new(response.pop) {
                @mutex.synchronize { unlock }
            }
        ensure
            unlock unless returned
            @mutex.unlock
        end

        private

        def unlock
            @count -= 1
            @sig.signal
        end
    end
end
