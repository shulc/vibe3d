import std.stdio;
import std.socket;
import std.string;
import std.conv;
import std.algorithm;

/**
 * Comprehensive test suite for the play-events HTTP endpoint
 */
void main() {
    writeln("=== Play-Events Endpoint Test Suite ===\n");

    // Test 1: Valid mouse motion event
    testValidMouseMotion();

    // Test 2: Valid mouse click sequence
    testValidMouseClickSequence();

    // Test 3: Invalid JSON format
    testInvalidJsonFormat();

    // Test 4: Empty array
    testEmptyArray();

    // Test 5: Wrong HTTP method
    testWrongHttpMethod();

    // Test 6: Non-existent endpoint
    testNonExistentEndpoint();

    writeln("=== Test Suite Completed ===");
}

/**
 * Test 1: Valid mouse motion event
 */
void testValidMouseMotion() {
    writeln("Test 1: Valid mouse motion event");

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

    auto response = sendPostRequest("localhost", 8080, "/api/play-events", testData);
    if (response.startsWith("HTTP/1.1 200 OK")) {
        writeln("  ✓ PASS: Valid mouse motion event processed successfully");
    } else {
        writeln("  ✗ FAIL: Expected 200 OK, got: ", response);
    }
    writeln();
}

/**
 * Test 2: Valid mouse click sequence
 */
void testValidMouseClickSequence() {
    writeln("Test 2: Valid mouse click sequence");

    string testData = `[
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

    auto response = sendPostRequest("localhost", 8080, "/api/play-events", testData);
    if (response.startsWith("HTTP/1.1 200 OK")) {
        writeln("  ✓ PASS: Valid mouse click sequence processed successfully");
    } else {
        writeln("  ✗ FAIL: Expected 200 OK, got: ", response);
    }
    writeln();
}

/**
 * Test 3: Invalid JSON format
 */
void testInvalidJsonFormat() {
    writeln("Test 3: Invalid JSON format");

    string testData = `[
        {
            "time": 0.0,
            "type": "SDL_MOUSEMOTION",
            "x": 100,
            "y": 200,
            // Missing closing brace
        }
    `;

    auto response = sendPostRequest("localhost", 8080, "/api/play-events", testData);
    if (response.startsWith("HTTP/1.1 400 Bad Request") ||
        response.canFind("\"status\": \"error\"") ||
        response.canFind("Failed to parse events")) {
        writeln("  ✓ PASS: Invalid JSON properly rejected");
    } else {
        writeln("  ✗ FAIL: Expected error response, got: ", response);
    }
    writeln();
}

/**
 * Test 4: Empty array
 */
void testEmptyArray() {
    writeln("Test 4: Empty array");

    string testData = `[]`;

    auto response = sendPostRequest("localhost", 8080, "/api/play-events", testData);
    // Empty array should be accepted but may not trigger any events
    if (response.startsWith("HTTP/1.1 200 OK")) {
        writeln("  ✓ PASS: Empty array accepted");
    } else {
        writeln("  ? INFO: Response for empty array: ", response);
    }
    writeln();
}

/**
 * Test 5: Wrong HTTP method
 */
void testWrongHttpMethod() {
    writeln("Test 5: Wrong HTTP method (GET instead of POST)");

    auto response = sendGetRequest("localhost", 8080, "/api/play-events");
    if (response.startsWith("HTTP/1.1 404 Not Found") ||
        response.canFind("The requested resource was not found")) {
        writeln("  ✓ PASS: Wrong method properly rejected");
    } else {
        writeln("  ✗ FAIL: Expected 404 Not Found, got: ", response);
    }
    writeln();
}

/**
 * Test 6: Non-existent endpoint
 */
void testNonExistentEndpoint() {
    writeln("Test 6: Non-existent endpoint");

    string testData = `[]`;
    auto response = sendPostRequest("localhost", 8080, "/api/non-existent", testData);
    if (response.startsWith("HTTP/1.1 404 Not Found") ||
        response.canFind("The requested resource was not found")) {
        writeln("  ✓ PASS: Non-existent endpoint properly rejected");
    } else {
        writeln("  ✗ FAIL: Expected 404 Not Found, got: ", response);
    }
    writeln();
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

/**
 * Send an HTTP GET request
 */
string sendGetRequest(string host, ushort port, string path) {
    try {
        auto socket = new TcpSocket();
        scope(exit) socket.close();

        socket.connect(new InternetAddress(host, port));

        // Create HTTP GET request
        string request = "GET " ~ path ~ " HTTP/1.1\r\n";
        request ~= "Host: " ~ host ~ ":" ~ to!string(port) ~ "\r\n";
        request ~= "Connection: close\r\n";
        request ~= "\r\n";

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