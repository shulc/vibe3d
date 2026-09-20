module http_inprocess_transport;

import http_server : HttpRequest, HttpResponse, HttpServer;

/// Task 6720: socket/thread-free request delivery for callers that share the
/// server process. The routing witnesses live in tests/unit/http_server_test.d
/// and the shared-client witness in tests/test_http_inprocess_transport.d.
final class InProcessHttpTransport
{
    private HttpServer server_;

    this(HttpServer server)
    {
        if (server is null)
            throw new Exception("an in-process HTTP transport needs a server");
        server_ = server;
    }

    HttpResponse request(string method, string path, string body_ = null)
    {
        auto request = new HttpRequest(method, path, "HTTP/1.1");
        request.body = body_;
        return server_.handleRequest(request);
    }
}
