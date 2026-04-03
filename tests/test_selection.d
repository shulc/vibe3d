import std.net.curl;
import std.json;
import std.file : read;
import std.conv : to;

void main() {}

unittest { // SELECTION VERTICES: Test selected vertices after playing events
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/selection_points.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }

    auto json = parseJSON(get("http://localhost:8080/api/selection"));

    assert(json["mode"].str == "vertices", "mode mismatch");

    auto verts = json["selectedVertices"].array;
    assert(verts.length == 2, "expected 2 selected vertices, got " ~ verts.length.to!string);
    assert(verts[0].integer == 4, "selectedVertices[0] should be 4");
    assert(verts[1].integer == 6, "selectedVertices[1] should be 6");

    assert(json["selectedEdges"].array.length  == 0, "selectedEdges should be empty");
    assert(json["selectedFaces"].array.length == 0, "selectedFaces should be empty");
}

unittest { // ADD SELECTION: Shift+click adds a third vertex to existing selection
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/selection_add.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }

    auto json = parseJSON(get("http://localhost:8080/api/selection"));

    assert(json["mode"].str == "vertices", "mode mismatch");

    auto verts = json["selectedVertices"].array;
    assert(verts.length == 3, "expected 3 selected vertices, got " ~ verts.length.to!string);
    assert(verts[0].integer == 4, "selectedVertices[0] should be 4");
    assert(verts[1].integer == 6, "selectedVertices[1] should be 6");
    assert(verts[2].integer == 7, "selectedVertices[2] should be 7");

    assert(json["selectedEdges"].array.length == 0, "selectedEdges should be empty");
    assert(json["selectedFaces"].array.length == 0, "selectedFaces should be empty");
}

unittest { // REMOVE SELECTION: Ctrl+click removes one vertex from a 3-vertex selection
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/selection_remove.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }

    auto json = parseJSON(get("http://localhost:8080/api/selection"));

    assert(json["mode"].str == "vertices", "mode mismatch");

    auto verts = json["selectedVertices"].array;
    assert(verts.length == 2, "expected 2 selected vertices after removing one, got " ~ verts.length.to!string);
    assert(verts[0].integer == 4, "selectedVertices[0] should be 4");
    assert(verts[1].integer == 7, "selectedVertices[1] should be 7");

    assert(json["selectedEdges"].array.length == 0, "selectedEdges should be empty");
    assert(json["selectedFaces"].array.length == 0, "selectedFaces should be empty");
}

unittest { // DESELECT: clicking empty space after selecting vertices clears selection
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/selection_deselect.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }

    auto json = parseJSON(get("http://localhost:8080/api/selection"));

    assert(json["mode"].str == "vertices", "mode mismatch");
    assert(json["selectedVertices"].array.length == 0, "selectedVertices should be empty after clicking empty space");
    assert(json["selectedEdges"].array.length    == 0, "selectedEdges should be empty");
    assert(json["selectedFaces"].array.length    == 0, "selectedFaces should be empty");
}
