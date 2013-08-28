module SpiderGazelle
    class Request < DeferredPromise


        SET_INSTANCE_TYPE = proc {|inst| inst.type = :request}


        attr_reader :url, :header, :headers, :body, :env


        def initialize(gazelle, socket)
            @defer = gazelle.loop.defer
            super(gazelle.loop, @defer)

            @gazelle, @socket = gazelle, socket
            @request = ::HttpParser::Parser.new_instance &SET_INSTANCE_TYPE

            @url = ''
            @header = ''
            @body = ''
            @headers = {}
            @env = {}

            @socket.progress do |data|
                @gazelle.context = @client
                @gazelle.parse @request, data
            end

            @socket.start_read
        end

        def response(data)

        end

        def complete!
            # TODO:: work
        end
    end
end
