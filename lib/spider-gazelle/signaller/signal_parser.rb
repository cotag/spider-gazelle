require 'uv-rays'


module SpiderGazelle
    class Signaller
        class SignalParser
            def initialize
                @tokenizer = ::UV::BufferedTokenizer.new({
                    indicator: "\x02",
                    delimiter: "\x03"
                })
                @logger = Logger.instance
                @launchctrl = LaunchControl.instance
            end

            def process(msg)
                @tokenizer.extract(msg).each do |cmd|
                    perform cmd
                end
            end

            # These are signals that can be sent
            # While the remote client is untrusted
            def signal(msg)
                result = nil
                @tokenizer.extract(msg).each do |request|
                    result = check request
                end
                result
            end


            protected


            def perform(cmd)
                begin
                    klass, action, data = cmd.split(' ', 3)
                    SpiderGazelle.const_get(klass).__send__(action, data)
                rescue => e
                    @logger.print_error(e, 'Error executing command in SignalParser')
                end
            end

            def check(cmd)
                comp = cmd.split(' ', 2)
                request = comp[0].to_sym
                data = comp[1]

                case request
                when :validate
                    if data == @launchctrl.password
                        return :validated
                    else
                        return :close_connection
                    end
                when :reload
                when :Logger
                    perform cmd
                end

                request
            end
        end
    end
end
