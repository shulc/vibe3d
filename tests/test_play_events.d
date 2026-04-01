import std.net.curl;
import std.string;
import std.conv;

/**
 * Test program for the play-events HTTP endpoint
 */
void main() {}

unittest {
    // Test data - simple mouse motion event (JSON Lines / EventLogger format)
    string testData = `{"t":0.000,"type":"SDL_MOUSEMOTION","x":100,"y":200,"xrel":0,"yrel":0,"state":0,"mod":0}`;

    // Send HTTP POST request
    auto response = post("http://localhost:8080/api/play-events", testData);

    // Test data - mouse click sequence (JSON Lines / EventLogger format)
    string testData2 =
        `{"t":0.000,"type":"SDL_MOUSEMOTION","x":150,"y":250,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
        `{"t":100.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":150,"y":250,"clicks":1,"mod":0}` ~ "\n" ~
        `{"t":200.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":150,"y":250,"clicks":1,"mod":0}`;

    auto response2 = post("http://localhost:8080/api/play-events", testData2);
}