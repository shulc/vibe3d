import std.net.curl;
import std.algorithm;
import std.stdio;

/**
 * Comprehensive test suite for the play-events HTTP endpoint
 */
void main() {}

unittest { // Test 1: Valid mouse motion event
    // JSON Lines / EventLogger format
    string testData = `{"t":0.000,"type":"SDL_MOUSEMOTION","x":100,"y":200,"xrel":0,"yrel":0,"state":0,"mod":0}`;

    assert(curlPost(testData) == 200);
}

unittest { // Test 2: Valid mouse click sequence
    // JSON Lines / EventLogger format
    string testData =
        `{"t":0.000,"type":"SDL_MOUSEMOTION","x":150,"y":250,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
        `{"t":100.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":150,"y":250,"clicks":1,"mod":0}` ~ "\n" ~
        `{"t":200.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":150,"y":250,"clicks":1,"mod":0}`;

    assert(curlPost(testData) == 200);
}

unittest { // Test 3: Invalid JSON format
    string testData = "not valid json at all";
    assert(curlPost(testData) == 400);
}

unittest { // Test 4: Empty string
    assert(curlPost("") == 400);
}

unittest { // Test 5: Wrong HTTP method
    assert(curlGet() == 404);
}

int curlPost(string data) {
    auto http = HTTP();
    http.method = HTTP.Method.post;
    http.url = "http://localhost:8080/api/play-events";
    http.postData = data;
    http.perform();
    return http.statusLine.code;
}

int curlGet() {
    auto http = HTTP();
    http.method = HTTP.Method.get;
    http.url = "http://localhost:8080/api/play-events";
    http.perform();
    return http.statusLine.code;
}
