// Tests for lasso (right-mouse drag) selection.
//
// Lasso flow in app.d:
//   • RIGHT mouse down → rmbPath = [(x,y)], rmbDragging = true
//   • MOUSEMOTION while dragging → rmbPath ~= (x,y)
//   • RIGHT mouse up → if rmbPath.length >= 3, select all visible elements
//     whose screen-projected position lies inside the polygon
//
// Event logs are calibrated to the recorded VIEWPORT (150,28 650x544) and
// auto-rescaled by EventPlayer if the live layout differs (see eventlog.d).

import std.net.curl;
import std.json;
import std.file : read;
import std.conv : to;

void main() {}

void resetCube() {
    post("http://localhost:8080/api/reset", "");
}

void waitForPlaybackFinish() {
    import core.thread : Thread;
    import core.time : msecs;
    for (int i = 0; i < 100; ++i) {
        auto j = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (j["finished"].type == JSONType.TRUE) return;
        Thread.sleep(100.msecs);
    }
}

unittest { // lasso a tight triangle around v6 → only v6 selected
    resetCube();
    auto events = cast(const(void)[])read("tests/events/lasso_vertex_v6.log");
    auto resp = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(resp)["status"].str == "success",
        "play-events failed: " ~ resp);
    waitForPlaybackFinish();

    auto sel = parseJSON(get("http://localhost:8080/api/selection"));
    assert(sel["mode"].str == "vertices",
        "expected vertices mode, got " ~ sel["mode"].str);

    auto verts = sel["selectedVertices"].array;
    assert(verts.length == 1,
        "expected 1 lasso-selected vert, got " ~ verts.length.to!string);
    assert(verts[0].integer == 6,
        "expected v6 inside lasso triangle, got " ~ verts[0].integer.to!string);
}

unittest { // lasso a wide rect over the whole front face in polygon mode
    resetCube();
    // Log starts with key '3' to switch to Polygons mode, then drags a wide
    // right-mouse rectangle around face 1's four verts (v4, v5, v6, v7).
    auto events = cast(const(void)[])read("tests/events/lasso_polygon_front.log");
    auto resp = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(resp)["status"].str == "success",
        "play-events failed: " ~ resp);
    waitForPlaybackFinish();

    auto sel = parseJSON(get("http://localhost:8080/api/selection"));
    assert(sel["mode"].str == "polygons",
        "expected polygons mode, got " ~ sel["mode"].str);

    auto faces = sel["selectedFaces"].array;
    assert(faces.length == 1,
        "expected 1 lasso-selected face, got " ~ faces.length.to!string);
    assert(faces[0].integer == 1,
        "expected face 1 (front) inside lasso, got " ~ faces[0].integer.to!string);
}
