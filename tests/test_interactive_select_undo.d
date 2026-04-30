// Integration tests for interactive selection undo (Phase C selection
// edit). Each test plays back a recorded SDL event log that produces
// a selection via clicks/lasso, then verifies that /api/undo restores
// the prior selection — the same behavior /api/select already has.
//
// The play-events path goes through handleMouseButtonDown/Up which
// open/close an interactive selection edit session and record one
// MeshSelectionEdit per drag.

import std.net.curl;
import std.json;
import std.file : read;
import std.conv : to;
import core.thread : Thread;
import core.time   : dur;

void main() {}

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
}

void playEvents(string logPath) {
    auto events = cast(const(void)[])read(logPath);
    auto resp = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(resp)["status"].str == "success",
        "play-events failed: " ~ resp);
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }
}

JSONValue postUndo() {
    return parseJSON(post("http://localhost:8080/api/undo", ""));
}

JSONValue postRedo() {
    return parseJSON(post("http://localhost:8080/api/redo", ""));
}

JSONValue getSelection() {
    return parseJSON(get("http://localhost:8080/api/selection"));
}

// ---------------------------------------------------------------------------

unittest { // click-to-select verts → undo restores empty selection
    resetCube();
    playEvents("tests/events/selection_points.log");

    // Sanity: events did produce the expected selection (2 verts).
    auto sel = getSelection();
    assert(sel["mode"].str == "vertices", "mode after events");
    assert(sel["selectedVertices"].array.length == 2,
        "expected 2 verts after click-events, got "
        ~ sel["selectedVertices"].array.length.to!string);

    // Each click produces one undo entry. Undo all of them and the
    // selection is back to empty.
    int safety = 0;
    while (getSelection()["selectedVertices"].array.length > 0) {
        auto u = postUndo();
        assert(u["status"].str == "ok",
            "undo failed mid-stack: " ~ u.toString);
        if (++safety > 20) break;
    }
    sel = getSelection();
    assert(sel["selectedVertices"].array.length == 0,
        "expected empty selection after unwinding, got "
        ~ sel["selectedVertices"].array.length.to!string);
}

unittest { // click-to-select edges → undo restores empty selection
    resetCube();
    playEvents("tests/events/selection_edges.log");

    auto sel = getSelection();
    assert(sel["mode"].str == "edges", "mode after edge-click events");
    assert(sel["selectedEdges"].array.length == 2,
        "expected 2 edges after click-events, got "
        ~ sel["selectedEdges"].array.length.to!string);

    int safety = 0;
    while (getSelection()["selectedEdges"].array.length > 0) {
        auto u = postUndo();
        assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
        if (++safety > 20) break;
    }
    sel = getSelection();
    assert(sel["selectedEdges"].array.length == 0,
        "expected empty edge selection after undo, got "
        ~ sel["selectedEdges"].array.length.to!string);
}

unittest { // RMB lasso polygons → undo restores empty selection
    resetCube();
    playEvents("tests/events/lasso_polygon_front.log");

    auto sel = getSelection();
    assert(sel["mode"].str == "polygons", "mode after lasso events");
    assert(sel["selectedFaces"].array.length > 0,
        "expected at least one face from lasso");

    auto u = postUndo();
    assert(u["status"].str == "ok",
        "undo of lasso selection failed: " ~ u.toString);
    sel = getSelection();
    assert(sel["selectedFaces"].array.length == 0,
        "expected empty face selection after undo of lasso, got "
        ~ sel["selectedFaces"].array.length.to!string);

    // Redo brings the lasso selection back.
    auto r = postRedo();
    assert(r["status"].str == "ok",
        "redo of lasso selection failed: " ~ r.toString);
    sel = getSelection();
    assert(sel["selectedFaces"].array.length > 0,
        "expected face selection back after redo");
}
