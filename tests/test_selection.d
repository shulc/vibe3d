import std.net.curl;
import std.json;
import std.file : read;
import std.conv : to;

void main() {}

// Wait for any in-flight event-log replay to drain before we reset and play our
// own log. The runner reuses ONE vibe3d per worker across many tests; a
// preceding test's /api/play-events can still be replaying on the background
// event player when this test starts, and its leftover events would clobber the
// selection we play here (the documented "expected 2 selected, got 0" flake).
void waitPlayerIdle() {
    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 200; ++i) {
        auto s = parseJSON(get("http://localhost:8080/api/play-events/status"));
        auto f = "finished" in s;
        if (f is null || f.type != JSONType.FALSE) {
            // The player reports finished once events are DISPATCHED, but
            // /api/play-events pushes them onto the SDL queue — the last few
            // drain over the next 1–2 frames. Settle so a prior test's queued
            // events land before our reset rather than clobbering our own play.
            Thread.sleep(dur!"msecs"(120));
            return;
        }
        Thread.sleep(dur!"msecs"(10));
    }
}

unittest { // SELECTION VERTICES: Test selected vertices after playing events
    waitPlayerIdle();
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
    // The player reports "finished" once its events are DISPATCHED, but the HTTP
    // play-events path pushes them onto the SDL queue (g_directDispatch is null)
    // — the LAST gesture's MOUSEBUTTONUP is still queued, unprocessed, when the
    // player goes idle, and drains over the next 1–2 main-loop frames. Reading
    // the selection before it drains sees only the prior gesture's verts (the
    // "expected 3 selected vertices, got 2" flake on selection_add.log). Settle
    // so the trailing click is processed before we read.
    Thread.sleep(dur!"msecs"(120));

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
    waitPlayerIdle();
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
    // The player reports "finished" once its events are DISPATCHED, but the HTTP
    // play-events path pushes them onto the SDL queue (g_directDispatch is null)
    // — the LAST gesture's MOUSEBUTTONUP is still queued, unprocessed, when the
    // player goes idle, and drains over the next 1–2 main-loop frames. Reading
    // the selection before it drains sees only the prior gesture's verts (the
    // "expected 3 selected vertices, got 2" flake on selection_add.log). Settle
    // so the trailing click is processed before we read.
    Thread.sleep(dur!"msecs"(120));

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
    // The player reports "finished" once its events are DISPATCHED, but the HTTP
    // play-events path pushes them onto the SDL queue (g_directDispatch is null)
    // — the LAST gesture's MOUSEBUTTONUP is still queued, unprocessed, when the
    // player goes idle, and drains over the next 1–2 main-loop frames. Reading
    // the selection before it drains sees only the prior gesture's verts (the
    // "expected 3 selected vertices, got 2" flake on selection_add.log). Settle
    // so the trailing click is processed before we read.
    Thread.sleep(dur!"msecs"(120));

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
    // The player reports "finished" once its events are DISPATCHED, but the HTTP
    // play-events path pushes them onto the SDL queue (g_directDispatch is null)
    // — the LAST gesture's MOUSEBUTTONUP is still queued, unprocessed, when the
    // player goes idle, and drains over the next 1–2 main-loop frames. Reading
    // the selection before it drains sees only the prior gesture's verts (the
    // "expected 3 selected vertices, got 2" flake on selection_add.log). Settle
    // so the trailing click is processed before we read.
    Thread.sleep(dur!"msecs"(120));

    auto json = parseJSON(get("http://localhost:8080/api/selection"));

    assert(json["mode"].str == "vertices", "mode mismatch");
    assert(json["selectedVertices"].array.length == 0, "selectedVertices should be empty after clicking empty space");
    assert(json["selectedEdges"].array.length    == 0, "selectedEdges should be empty");
    assert(json["selectedFaces"].array.length    == 0, "selectedFaces should be empty");
}

unittest { // SELECTION EDGES: Test selected edges after playing events (edges 5 and 6)
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/selection_edges.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }
    // The player reports "finished" once its events are DISPATCHED, but the HTTP
    // play-events path pushes them onto the SDL queue (g_directDispatch is null)
    // — the LAST gesture's MOUSEBUTTONUP is still queued, unprocessed, when the
    // player goes idle, and drains over the next 1–2 main-loop frames. Reading
    // the selection before it drains sees only the prior gesture's verts (the
    // "expected 3 selected vertices, got 2" flake on selection_add.log). Settle
    // so the trailing click is processed before we read.
    Thread.sleep(dur!"msecs"(120));

    auto json = parseJSON(get("http://localhost:8080/api/selection"));

    assert(json["mode"].str == "edges", "mode mismatch");

    auto edges = json["selectedEdges"].array;
    assert(edges.length == 2, "expected 2 selected edges, got " ~ edges.length.to!string);
    assert(edges[0].integer == 5, "selectedEdges[0] should be 5");
    assert(edges[1].integer == 6, "selectedEdges[1] should be 6");

    assert(json["selectedVertices"].array.length == 0, "selectedVertices should be empty");
    assert(json["selectedFaces"].array.length    == 0, "selectedFaces should be empty");
}

unittest { // ADD EDGE SELECTION: Shift+click adds a third edge to existing selection
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/selection_edges_add.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }
    // The player reports "finished" once its events are DISPATCHED, but the HTTP
    // play-events path pushes them onto the SDL queue (g_directDispatch is null)
    // — the LAST gesture's MOUSEBUTTONUP is still queued, unprocessed, when the
    // player goes idle, and drains over the next 1–2 main-loop frames. Reading
    // the selection before it drains sees only the prior gesture's verts (the
    // "expected 3 selected vertices, got 2" flake on selection_add.log). Settle
    // so the trailing click is processed before we read.
    Thread.sleep(dur!"msecs"(120));

    auto json = parseJSON(get("http://localhost:8080/api/selection"));

    assert(json["mode"].str == "edges", "mode mismatch");

    auto edges = json["selectedEdges"].array;
    assert(edges.length == 3, "expected 3 selected edges, got " ~ edges.length.to!string);
    assert(edges[0].integer == 5, "selectedEdges[0] should be 5");
    assert(edges[1].integer == 6, "selectedEdges[1] should be 6");
    assert(edges[2].integer == 7, "selectedEdges[2] should be 7");

    assert(json["selectedVertices"].array.length == 0, "selectedVertices should be empty");
    assert(json["selectedFaces"].array.length    == 0, "selectedFaces should be empty");
}

unittest { // REMOVE EDGE SELECTION: Ctrl+click removes one edge from a 3-edge selection
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/selection_edges_remove.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }
    // The player reports "finished" once its events are DISPATCHED, but the HTTP
    // play-events path pushes them onto the SDL queue (g_directDispatch is null)
    // — the LAST gesture's MOUSEBUTTONUP is still queued, unprocessed, when the
    // player goes idle, and drains over the next 1–2 main-loop frames. Reading
    // the selection before it drains sees only the prior gesture's verts (the
    // "expected 3 selected vertices, got 2" flake on selection_add.log). Settle
    // so the trailing click is processed before we read.
    Thread.sleep(dur!"msecs"(120));

    auto json = parseJSON(get("http://localhost:8080/api/selection"));

    assert(json["mode"].str == "edges", "mode mismatch");

    auto edges = json["selectedEdges"].array;
    assert(edges.length == 2, "expected 2 selected edges after removing one, got " ~ edges.length.to!string);
    assert(edges[0].integer == 5, "selectedEdges[0] should be 5");
    assert(edges[1].integer == 7, "selectedEdges[1] should be 7");

    assert(json["selectedVertices"].array.length == 0, "selectedVertices should be empty");
    assert(json["selectedFaces"].array.length    == 0, "selectedFaces should be empty");
}

unittest { // DESELECT EDGES: clicking empty space after selecting edges clears selection
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/selection_edges_deselect.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }
    // The player reports "finished" once its events are DISPATCHED, but the HTTP
    // play-events path pushes them onto the SDL queue (g_directDispatch is null)
    // — the LAST gesture's MOUSEBUTTONUP is still queued, unprocessed, when the
    // player goes idle, and drains over the next 1–2 main-loop frames. Reading
    // the selection before it drains sees only the prior gesture's verts (the
    // "expected 3 selected vertices, got 2" flake on selection_add.log). Settle
    // so the trailing click is processed before we read.
    Thread.sleep(dur!"msecs"(120));

    auto json = parseJSON(get("http://localhost:8080/api/selection"));

    assert(json["mode"].str == "edges", "mode mismatch");
    assert(json["selectedEdges"].array.length    == 0, "selectedEdges should be empty after clicking empty space");
    assert(json["selectedVertices"].array.length == 0, "selectedVertices should be empty");
    assert(json["selectedFaces"].array.length    == 0, "selectedFaces should be empty");
}

unittest { // SELECTION POLYGONS: Test selected faces after playing events (faces 1 and 3)
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/selection_polygons.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }
    // The player reports "finished" once its events are DISPATCHED, but the HTTP
    // play-events path pushes them onto the SDL queue (g_directDispatch is null)
    // — the LAST gesture's MOUSEBUTTONUP is still queued, unprocessed, when the
    // player goes idle, and drains over the next 1–2 main-loop frames. Reading
    // the selection before it drains sees only the prior gesture's verts (the
    // "expected 3 selected vertices, got 2" flake on selection_add.log). Settle
    // so the trailing click is processed before we read.
    Thread.sleep(dur!"msecs"(120));

    auto json = parseJSON(get("http://localhost:8080/api/selection"));

    assert(json["mode"].str == "polygons", "mode mismatch");

    auto faces = json["selectedFaces"].array;
    assert(faces.length == 2, "expected 2 selected faces, got " ~ faces.length.to!string);
    assert(faces[0].integer == 1, "selectedFaces[0] should be 1");
    assert(faces[1].integer == 3, "selectedFaces[1] should be 3");

    assert(json["selectedVertices"].array.length == 0, "selectedVertices should be empty");
    assert(json["selectedEdges"].array.length    == 0, "selectedEdges should be empty");
}

unittest { // ADD POLYGON SELECTION: Shift+click adds a third face to existing selection
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/selection_polygons_add.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }
    // The player reports "finished" once its events are DISPATCHED, but the HTTP
    // play-events path pushes them onto the SDL queue (g_directDispatch is null)
    // — the LAST gesture's MOUSEBUTTONUP is still queued, unprocessed, when the
    // player goes idle, and drains over the next 1–2 main-loop frames. Reading
    // the selection before it drains sees only the prior gesture's verts (the
    // "expected 3 selected vertices, got 2" flake on selection_add.log). Settle
    // so the trailing click is processed before we read.
    Thread.sleep(dur!"msecs"(120));

    auto json = parseJSON(get("http://localhost:8080/api/selection"));

    assert(json["mode"].str == "polygons", "mode mismatch");

    auto faces = json["selectedFaces"].array;
    assert(faces.length == 3, "expected 3 selected faces, got " ~ faces.length.to!string);
    assert(faces[0].integer == 1, "selectedFaces[0] should be 1");
    assert(faces[1].integer == 3, "selectedFaces[1] should be 3");
    assert(faces[2].integer == 4, "selectedFaces[2] should be 4");

    assert(json["selectedVertices"].array.length == 0, "selectedVertices should be empty");
    assert(json["selectedEdges"].array.length    == 0, "selectedEdges should be empty");
}

unittest { // REMOVE POLYGON SELECTION: Ctrl+click removes one face from a 3-face selection
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/selection_polygons_remove.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }
    // The player reports "finished" once its events are DISPATCHED, but the HTTP
    // play-events path pushes them onto the SDL queue (g_directDispatch is null)
    // — the LAST gesture's MOUSEBUTTONUP is still queued, unprocessed, when the
    // player goes idle, and drains over the next 1–2 main-loop frames. Reading
    // the selection before it drains sees only the prior gesture's verts (the
    // "expected 3 selected vertices, got 2" flake on selection_add.log). Settle
    // so the trailing click is processed before we read.
    Thread.sleep(dur!"msecs"(120));

    auto json = parseJSON(get("http://localhost:8080/api/selection"));

    assert(json["mode"].str == "polygons", "mode mismatch");

    auto faces = json["selectedFaces"].array;
    assert(faces.length == 2, "expected 2 selected faces after removing one, got " ~ faces.length.to!string);
    assert(faces[0].integer == 1, "selectedFaces[0] should be 1");
    assert(faces[1].integer == 4, "selectedFaces[1] should be 4");

    assert(json["selectedVertices"].array.length == 0, "selectedVertices should be empty");
    assert(json["selectedEdges"].array.length    == 0, "selectedEdges should be empty");
}

unittest { // DESELECT POLYGONS: clicking empty space after selecting faces clears selection
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/selection_polygons_deselect.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }
    // The player reports "finished" once its events are DISPATCHED, but the HTTP
    // play-events path pushes them onto the SDL queue (g_directDispatch is null)
    // — the LAST gesture's MOUSEBUTTONUP is still queued, unprocessed, when the
    // player goes idle, and drains over the next 1–2 main-loop frames. Reading
    // the selection before it drains sees only the prior gesture's verts (the
    // "expected 3 selected vertices, got 2" flake on selection_add.log). Settle
    // so the trailing click is processed before we read.
    Thread.sleep(dur!"msecs"(120));

    auto json = parseJSON(get("http://localhost:8080/api/selection"));

    assert(json["mode"].str == "polygons", "mode mismatch");
    assert(json["selectedFaces"].array.length    == 0, "selectedFaces should be empty after clicking empty space");
    assert(json["selectedVertices"].array.length == 0, "selectedVertices should be empty");
    assert(json["selectedEdges"].array.length    == 0, "selectedEdges should be empty");
}
