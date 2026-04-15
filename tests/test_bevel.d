import std.net.curl;
import std.json;
import std.file : read;
import std.conv : to;

void main() {}

unittest { // EDGE BEVEL: beveling one edge on a cube adds 2 vertices, 3 edges, 1 face
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/edge_bevel.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }

    // Check selection: mode is edges, new bevel edges are selected
    auto sel = parseJSON(get("http://localhost:8080/api/selection"));
    assert(sel["mode"].str == "edges", "mode should be edges after bevel");

    auto selectedEdges = sel["selectedEdges"].array;
    assert(selectedEdges.length == 4, "expected 4 selected edges after bevel, got " ~ selectedEdges.length.to!string);
    assert(selectedEdges[0].integer == 5,  "selectedEdges[0] should be 5");
    assert(selectedEdges[1].integer == 11, "selectedEdges[1] should be 11");
    assert(selectedEdges[2].integer == 13, "selectedEdges[2] should be 13");
    assert(selectedEdges[3].integer == 14, "selectedEdges[3] should be 14");

    assert(sel["selectedVertices"].array.length == 0, "selectedVertices should be empty");
    assert(sel["selectedFaces"].array.length    == 0, "selectedFaces should be empty");

    // Check mesh topology: cube (8v/12e/6f) + 1 bevel = 10v/15e/7f
    auto model = parseJSON(get("http://localhost:8080/api/model"));
    assert(model["vertexCount"].integer == 10, "expected 10 vertices after bevel, got " ~ model["vertexCount"].integer.to!string);
    assert(model["edgeCount"].integer   == 15, "expected 15 edges after bevel, got "    ~ model["edgeCount"].integer.to!string);
    assert(model["faceCount"].integer   == 7,  "expected 7 faces after bevel, got "     ~ model["faceCount"].integer.to!string);
}
