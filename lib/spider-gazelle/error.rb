
module SpiderGazelle
    module Error

        # Indicate that we couldn't parse the request
        ERROR_400_RESPONSE = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".freeze

        # The standard empty 404 response for bad requests.
        ERROR_404_RESPONSE = "HTTP/1.1 404 Not Found\r\n\r\nNOT FOUND".freeze

        # Indicate that there was an internal error, obviously.
        ERROR_500_RESPONSE = "HTTP/1.1 500 Internal Server Error\r\n\r\n".freeze


    end
end
