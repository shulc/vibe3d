// Lasso-pick perf test (Stage D3 of doc/test_coverage_plan.md).
//
// Lasso selection projects every visible mesh element to screen pixels
// and runs a point-in-polygon test against the lasso path. On a heavy
// mesh this is the most expensive selection operation we expose; a
// quadratic regression in `pointInPolygon2D` or the projection cache
// would show up here long before users notice 200 ms lag picking on
// dense geometry.
//
// Workload: cube → subdivide×3 (386 verts, 384 faces) → enter polygon
//           mode → play a wide right-mouse-drag lasso that covers ~70 %
//           of the viewport. Measure time-to-playback-finished.
//
// Budget: 1500 ms median. Typical observed timing is 250–500 ms (the
// log runs 4 mouse events @ 50 ms each → 200 ms event time + per-frame
// pick work). ×3 margin catches regressions; doesn't flake on slow CI.

import std.net.curl;
import std.json;
import std.conv : to;
import core.thread : Thread;
import core.time   : msecs;

import perf_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

void runCmdJson(string id) {
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/command",
        `{"id":"` ~ id ~ `"}`));
    assert(r["status"].str == "ok", id ~ " failed: " ~ r.toString);
}

void waitPlaybackDone() {
    foreach (i; 0 .. 300) {
        auto s = parseJSON(cast(string)get(
            baseUrl ~ "/api/play-events/status"));
        if (s["finished"].type == JSONType.TRUE) return;
        Thread.sleep(20.msecs);
    }
    assert(false, "playback did not finish within 6s");
}

// Build a right-mouse-drag lasso that covers most of the viewport.
// First frame: switch to Polygons mode (key '3'). Then RMB-down at
// upper-left, drag across to upper-right, down to lower-right, back
// to lower-left, RMB-up. EventPlayer remaps from the recorded 650×544
// viewport into whatever the current viewport is.
string buildLassoLog() {
    return
        `{"t":0.000,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.0,"type":"SDL_KEYDOWN","sym":51,"scan":31,"mod":0,"repeat":0}` ~ "\n" ~
        `{"t":80.0,"type":"SDL_KEYUP","sym":51,"scan":31,"mod":0,"repeat":0}` ~ "\n" ~
        `{"t":150.0,"type":"SDL_MOUSEMOTION","x":250,"y":150,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
        `{"t":200.0,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":250,"y":150,"clicks":1,"mod":0}` ~ "\n" ~
        `{"t":250.0,"type":"SDL_MOUSEMOTION","x":600,"y":150,"xrel":350,"yrel":0,"state":4,"mod":0}` ~ "\n" ~
        `{"t":300.0,"type":"SDL_MOUSEMOTION","x":600,"y":500,"xrel":0,"yrel":350,"state":4,"mod":0}` ~ "\n" ~
        `{"t":350.0,"type":"SDL_MOUSEMOTION","x":250,"y":500,"xrel":-350,"yrel":0,"state":4,"mod":0}` ~ "\n" ~
        `{"t":400.0,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":250,"y":500,"clicks":1,"mod":0}` ~ "\n";
}

unittest { // lasso pick on a 384-face mesh stays under budget
    enum double BUDGET_MS = 1500.0;

    post(baseUrl ~ "/api/reset", "");
    post(baseUrl ~ "/api/command", "select.typeFrom polygon");
    runCmdJson("mesh.subdivide");
    runCmdJson("mesh.subdivide");
    runCmdJson("mesh.subdivide");
    auto m = parseJSON(cast(string)get(baseUrl ~ "/api/model"));
    assert(m["faceCount"].integer == 384,
        "setup: subdivide×3 should leave 384 faces; got " ~
        m["faceCount"].integer.to!string);

    string log = buildLassoLog();

    double median = timeMedianMs(3, () {
        auto r = parseJSON(cast(string)post(
            baseUrl ~ "/api/play-events", log));
        assert(r["status"].str == "success",
            "/api/play-events failed: " ~ r.toString);
        waitPlaybackDone();
    });

    assert(median < BUDGET_MS,
        "lasso pick on 384-face mesh median=" ~ fmtMs(median) ~
        " exceeds budget " ~ fmtMs(BUDGET_MS) ~
        " — projection cache or pointInPolygon2D may have regressed");

    // Sanity: lasso must have selected at least some faces (~70 % of
    // viewport coverage on the front of a cube should grab most of one
    // face's verts on every camera angle). 0 selected = the lasso path
    // never reached the selection code.
    auto sel = parseJSON(cast(string)get(baseUrl ~ "/api/selection"));
    assert(sel["selectedFaces"].array.length > 0,
        "lasso didn't select any faces — pick code never ran?");
}
