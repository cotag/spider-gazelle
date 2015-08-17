
module SpiderGazelle
    class Gazelle
        class Parser

            # Prevents any callbacks occuring once we are no longer interested
            def self.on_progress(data, socket); end
            DUMMY_PROGRESS = self.method :on_progress


            def initialize(return_method)
                @return_method = return_method
            end

            def load(socket, port, app, app_mode)
                @socket = socket
                @port = port
                @app = app
                @mode = app_mode

                socket.finally &method(:on_close)
            end

            def set_protocol(protocol)
                @protocol = protocol
                
                if protocol == :http2
                    @parser = HTTP2::Client.new
                    @parser.on(:frame) {|bytes| @socket.write bytes }
                    
                else
                    
                end
            end

            def on_close
                @socket.progress &DUMMY_PROGRESS
                reset
                @return_method.call(self)
            end

            def reset
                @socket = nil
                @port = nil
                @app = nil
                @mode = nil
                @parser = nil
                @protocol = nil
            end


            # -----------------
            # Core Parsing Code
            # -----------------
            def parse(data)
                @parser << data
            end
        end
    end
end
