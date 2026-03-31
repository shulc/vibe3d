import std.stdio;
import std.socket;
import std.string;
import std.conv;

/**
 * Test program for the play-events HTTP endpoint
 */
void main() {
    writeln("Testing play-events endpoint...");

    // Test data - simple mouse motion event
    string testData = `[
        {
            "time": 0.0,
            "type": "SDL_MOUSEMOTION",
            "x": 100,
            "y": 200,
            "xrel": 0,
            "yrel": 0,
            "state": 0,
            "mod": 0
        }
    ]`;

    // Send HTTP POST request
    auto response = sendPostRequest("localhost", 8080, "/api/play-events", testData);
    writeln("Response: ", response);

    // Test data - mouse click sequence
    string testData2 = `[
        {
            "time": 0.0,
            "type": "SDL_MOUSEMOTION",
            "x": 150,
            "y": 250,
            "xrel": 0,
            "yrel": 0,
            "state": 0,
            "mod": 0
        },
        {
            "time": 100.0,
            "type": "SDL_MOUSEBUTTONDOWN",
            "button": 1,
            "x": 150,
            "y": 250,
            "clicks": 1,
            "mod": 0
        },
        {
            "time": 200.0,
            "type": "SDL_MOUSEBUTTONUP",
            "button": 1,
            "x": 150,
            "y": 250,
            "clicks": 1,
            "mod": 0
        }
    ]`;

    writeln("\nTesting mouse click sequence...");
    auto response2 = sendPostRequest("localhost", 8080, "/api/play-events", testData2);
    writeln("Response: ", response2);

    writeln("\nTest completed.");
}

/**
 * Send an HTTP POST request
 */
string sendPostRequest(string host, ushort port, string path, string data) {
    try {
        auto socket = new TcpSocket();
        scope(exit) socket.close();

        socket.connect(new InternetAddress(host, port));

        // Create HTTP POST request
        string request = "POST " ~ path ~ " HTTP/1.1\r\n";
        request ~= "Host: " ~ host ~ ":" ~ to!string(port) ~ "\r\n";
        request ~= "Content-Type: application/json\r\n";
        request ~= "Content-Length: " ~ to!string(data.length) ~ "\r\n";
        request ~= "Connection: close\r\n";
        request ~= "\r\n";
        request ~= data;

        // Send request
        socket.send(request);

        // Read response
        char[4096] buffer;
        size_t received = socket.receive(buffer[]);
        string response = buffer[0 .. received].idup;

        return response;
    } catch (Exception e) {
        return "Error: " ~ e.msg;
    }
}