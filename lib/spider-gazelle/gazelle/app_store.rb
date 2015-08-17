require 'thread'

module SpiderGazelle
    class Gazelle
        module AppStore
            @apps = []
            @loaded = {}
            @critical = Mutex.new
            @logger = Logger.instance

            # Load an app and assign it an ID
            def self.load(rackup, options)
                begin
                    @critical.synchronize {
                        return if @loaded[rackup]

                        app, opts = ::Rack::Builder.parse_file(rackup)
                        tls = configure_tls(options)

                        val = [app, @options[:app_mode], options[:port], tls]
                        @apps << val
                        @loaded[rackup] = val
                    }
                rescue Exception => e
                    # Prevent other threads from trying to load this too (might be in threaded mode)
                    @loaded[rackup] = true
                    @logger.print_error(e, "loading rackup #{rackup}")
                    Reactor.instance.shutdown
                end
            end

            # Add an already loaded application
            def self.add(app, options)
                @critical.synchronize {
                    obj_id = app.object_id
                    return if @loaded[obj_id]
                    
                    id = @apps.length

                    app, opts = ::Rack::Builder.parse_file(rackup)
                    tls = configure_tls(options)

                    val = [app, APP_MODE[@options[:app_mode]], options[:port], tls]
                    @apps << val
                    @loaded[obj_id] = val

                    id
                }
            end

            # Lookup an application
            def self.lookup(app)
                @loaded[app.to_s]
            end

            # Get an app using the id directly
            def self.get(id)
                @apps[id.to_i]
            end

            PROTOCOLS = ['h2'.freeze, 'http/1.1'.freeze].freeze
            FALLBACK = 'http/1.1'.freeze
            def self.configure_tls(opts)
                return false unless opts[:tls]

                tls = {
                    protocols: PROTOCOLS,
                    fallback: FALLBACK
                }
                tls[:verify_peer] = true if opts[:verify_peer]
                tls[:ciphers] = opts[:ciphers] if opts[:ciphers]

                # NOTE:: Blocking reads however only during load so it's OK
                private_key = opts[:private_key]
                if private_key
                    tls[:private_key] = ::FFI::MemoryPointer.from_string(File.read(private_key))
                end

                cert_chain = opts[:cert_chain]
                if cert_chain
                    tls[:cert_chain] = ::FFI::MemoryPointer.from_string(File.read(cert_chain))
                end

                tls
            end
        end
    end
end
