require 'thread'
require 'radix/base'


module SpiderGazelle
    module AppStore
        # Basic compression using UTF (more efficient for ID's stored as strings)
        B65 = ::Radix::Base.new(::Radix::BASE::B62 + ['-', '_', '~'])
        B10 = ::Radix::Base.new(10)

        @mutex = Mutex.new
        @count = 0
        @apps = ThreadSafe::Cache.new
        @loaded = ThreadSafe::Cache.new

        # Load an app and assign it an ID
        def self.load(app, options={})
            is_rack_app = !app.is_a?(String)
            app_key = is_rack_app ? app.class.name.to_sym : app.to_sym
            id = @loaded[app_key]

            if id.nil?
                app, options = ::Rack::Builder.parse_file(app) unless is_rack_app

                count = 0
                @mutex.synchronize {
                    count = @count += 1
                }
                id = Radix.convert(count, B10, B65).to_sym
                @apps[id] = app
                @loaded[app_key] = id
            end

            id
        end

        # Manually load an app
        def self.add(app)
            id = @loaded[app.__id__]

            if id.nil?
                count = 0
                @mutex.synchronize {
                    count = @count += 1
                }
                id = Radix.convert(count, B10, B65).to_sym
                @apps[id] = app
                @loaded[app.__id__] = id
            end

            id
        end

        # Lookup an application
        def self.lookup(app)
            if app.is_a?(String) || app.is_a?(Symbol)
                @apps[@loaded[app.to_sym]]
            else
                @apps[@loaded[app.__id__]]
            end
        end

        # Get an app using the id directly
        def self.get(id)
            id = id.to_sym if id.is_a?(String)
            @apps[id]
        end
    end
end
