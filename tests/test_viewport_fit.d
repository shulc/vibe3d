// Tests for viewport.fit and viewport.fit_selected.
//
// fit:           reframes camera to bound the entire mesh — focus → mesh centroid.
// fit_selected:  reframes to the selected sub-set in the current edit mode;
//                falls back to the whole mesh when nothing is selected.

import std.net.curl;
import std.json;
import std.file : read;
import std.math : fabs;
import std.conv : to;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

void resetCube() {
    post("http://localhost:8080/api/reset", "");
}

void runCmd(string id) {
    auto resp = post("http://localhost:8080/api/command",
        `{"id":"` ~ id ~ `"}`);
    assert(parseJSON(resp)["status"].str == "ok",
        id ~ " failed: " ~ resp);
}

void setSelection(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) {
        if (i > 0) idxJson ~= ",";
        idxJson ~= v.to!string;
    }
    idxJson ~= "]";
    post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
}

JSONValue cam() {
    return parseJSON(get("http://localhost:8080/api/camera"));
}

unittest { // viewport.fit recenters the camera on a panned scene
    resetCube();
    // Pan the camera away from origin via a recorded log.
    auto events = cast(const(void)[])read("tests/events/camera_pan_events.log");
    post("http://localhost:8080/api/play-events", events);
    import core.thread : Thread;
    import core.time : msecs;
    for (int i = 0; i < 100; ++i) {
        if (parseJSON(get("http://localhost:8080/api/play-events/status"))
                ["finished"].type == JSONType.TRUE) break;
        Thread.sleep(100.msecs);
    }
    // Sanity: focus is no longer at origin after panning.
    auto c = cam();
    bool focusMoved =
        !approxEqual(c["focus"]["x"].floating, 0.0) ||
        !approxEqual(c["focus"]["y"].floating, 0.0) ||
        !approxEqual(c["focus"]["z"].floating, 0.0);
    assert(focusMoved, "expected pan to move focus off origin");

    // viewport.fit should re-frame the cube → focus back at origin.
    runCmd("viewport.fit");
    c = cam();
    assert(approxEqual(c["focus"]["x"].floating, 0.0),
        "fit: focus.x should be 0, got " ~ c["focus"]["x"].floating.to!string);
    assert(approxEqual(c["focus"]["y"].floating, 0.0),
        "fit: focus.y should be 0");
    assert(approxEqual(c["focus"]["z"].floating, 0.0),
        "fit: focus.z should be 0");
    assert(c["distance"].floating > 0.0, "fit: distance must be positive");
}

unittest { // fit_selected on one face → focus at that face's centroid
    resetCube();
    // Face 0 = back face [0,3,2,1] at z=-0.5; centroid = (0, 0, -0.5).
    setSelection("polygons", [0]);
    runCmd("viewport.fit_selected");
    auto c = cam();
    assert(approxEqual(c["focus"]["x"].floating, 0.0),
        "fit_selected face 0: focus.x should be 0, got "
        ~ c["focus"]["x"].floating.to!string);
    assert(approxEqual(c["focus"]["y"].floating, 0.0),
        "fit_selected face 0: focus.y should be 0");
    assert(approxEqual(c["focus"]["z"].floating, -0.5),
        "fit_selected face 0: focus.z should be -0.5, got "
        ~ c["focus"]["z"].floating.to!string);
}

unittest { // fit_selected with empty selection falls back to the whole mesh
    resetCube();
    // No selection → fit_selected should behave like fit (focus at origin).
    runCmd("viewport.fit_selected");
    auto c = cam();
    assert(approxEqual(c["focus"]["x"].floating, 0.0),
        "fit_selected (empty): focus.x should be 0");
    assert(approxEqual(c["focus"]["y"].floating, 0.0),
        "fit_selected (empty): focus.y should be 0");
    assert(approxEqual(c["focus"]["z"].floating, 0.0),
        "fit_selected (empty): focus.z should be 0");
}

unittest { // fit_selected on a single vertex puts focus on that vertex
    resetCube();
    // Vertex 6 = (0.5, 0.5, 0.5).
    setSelection("vertices", [6]);
    runCmd("viewport.fit_selected");
    auto c = cam();
    assert(approxEqual(c["focus"]["x"].floating, 0.5),
        "fit_selected vert 6: focus.x should be 0.5, got "
        ~ c["focus"]["x"].floating.to!string);
    assert(approxEqual(c["focus"]["y"].floating, 0.5),
        "fit_selected vert 6: focus.y should be 0.5");
    assert(approxEqual(c["focus"]["z"].floating, 0.5),
        "fit_selected vert 6: focus.z should be 0.5");
}
