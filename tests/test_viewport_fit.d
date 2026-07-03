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
import std.format : format;

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

// ----------------------------------------------------------------------
// task 0220 — viewport.fit / viewport.fit_selected must target the
// HOVERED cell, not the last-CLICKED one (focus-follows-mouse, no click
// required). Repro: activity (selection / last click) happened in one
// Quad cell, the mouse then moves — WITHOUT a click — into a different
// cell; A/Shift+A must reframe the cell under the mouse.
// ----------------------------------------------------------------------

void postCommand(string id, string param) {
    auto resp = post("http://localhost:8080/api/command",
        `{"id":"` ~ id ~ `","params":"` ~ param ~ `"}`);
    assert(parseJSON(resp)["status"].str != "error",
        id ~ " " ~ param ~ " failed: " ~ resp);
}

double numField(JSONValue j, string key) {
    auto v = j[key];
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double)v.integer;
        case JSONType.uinteger: return cast(double)v.uinteger;
        default: assert(false, "field '" ~ key ~ "' is not numeric: " ~ v.toString);
    }
}

JSONValue camAt(int vp) {
    return parseJSON(get("http://localhost:8080/api/camera?viewport=" ~ vp.to!string));
}

struct CellRect { int x, y, w, h; }

CellRect cellRect(int vp) {
    auto c = camAt(vp);
    return CellRect(cast(int)numField(c, "vpX"), cast(int)numField(c, "vpY"),
                     cast(int)numField(c, "width"), cast(int)numField(c, "height"));
}

// Set a cell's OWN camera directly (bypasses activeId entirely) — used to
// give two cells distinct, non-origin foci so a successful fit is
// unambiguous.
void setCam(int vp, double fx, double fy, double fz, double distance) {
    auto body_ = format(
        `{"focus":{"x":%g,"y":%g,"z":%g},"distance":%g,"azimuth":0,"elevation":0}`,
        fx, fy, fz, distance);
    auto resp = post("http://localhost:8080/api/camera?viewport=" ~ vp.to!string, body_);
    assert(parseJSON(resp)["status"].str == "ok",
        "set camera viewport=" ~ vp.to!string ~ " failed: " ~ resp);
}

// A real click (down+up, no motion in between) — legitimate SETUP-only use
// of activeId-via-click, independent of the focus-follows-mouse behavior
// under test.
string clickLog(int x, int y) {
    return format(`{"t":0.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", x, y)
         ~ format(`{"t":10.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", x, y);
}

// A lone motion event — mouse moves WITHOUT any button held (state=0), i.e.
// hover-only, no click.
string hoverLog(int x, int y) {
    return format(
        `{"t":0.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
        x, y);
}

void playEvents(string log) {
    post("http://localhost:8080/api/play-events", log);
    import core.thread : Thread;
    import core.time : msecs;
    for (int i = 0; i < 100; ++i) {
        if (parseJSON(get("http://localhost:8080/api/play-events/status"))
                ["finished"].type == JSONType.TRUE) return;
        Thread.sleep(50.msecs);
    }
    assert(false, "playback didn't finish within 5s");
}

// Quad layout with cell 0 and cell 1 detached + displaced to distinct,
// non-origin foci; last CLICK lands on cell 0. Returns nothing — leaves
// the app in that state for the caller to move the mouse and fire a fit.
void setupQuadLastClickCell0() {
    resetCube();
    postCommand("viewport.layout", "Quad");

    auto r0 = cellRect(0);
    auto r1 = cellRect(1);
    int cx0 = r0.x + r0.w / 2, cy0 = r0.y + r0.h / 2;
    int cx1 = r1.x + r1.w / 2, cy1 = r1.y + r1.h / 2;

    // Fully detach cells 0 and 1 from the Quad linked-group defaults
    // (indCenter/indScale=false out of the box — see test_viewport_independence.d
    // Flow A) so each cell's OWN camera is what `viewport.fit` mutates AND
    // what `/api/camera?viewport=N` (which reports the follow-RESOLVED
    // snapshot, not raw own fields) reports back.
    playEvents(clickLog(cx0, cy0));   // cell 0 active (setup)
    postCommand("viewport.master",   "-1");
    postCommand("viewport.indCenter", "yes");
    postCommand("viewport.indScale",  "yes");
    postCommand("viewport.indRotate", "yes");
    setCam(0, 5, 5, 5, 10);

    playEvents(clickLog(cx1, cy1));   // cell 1 active (setup)
    postCommand("viewport.master",   "-1");
    postCommand("viewport.indCenter", "yes");
    postCommand("viewport.indScale",  "yes");
    postCommand("viewport.indRotate", "yes");
    setCam(1, -5, -5, -5, 10);

    // Last click lands back on cell 0 — the bug scenario: activity in one
    // cell, mouse then wanders elsewhere.
    playEvents(clickLog(cx0, cy0));
}

unittest { // viewport.fit targets the HOVERED cell (1), not last-clicked (0)
    setupQuadLastClickCell0();

    auto r1 = cellRect(1);
    playEvents(hoverLog(r1.x + r1.w / 2, r1.y + r1.h / 2));  // hover cell 1, NO click

    runCmd("viewport.fit");

    auto c1 = camAt(1);
    assert(approxEqual(c1["focus"]["x"].floating, 0.0) &&
           approxEqual(c1["focus"]["y"].floating, 0.0) &&
           approxEqual(c1["focus"]["z"].floating, 0.0),
        "viewport.fit must reframe the HOVERED cell (1): focus=" ~ c1["focus"].toString);

    auto c0 = camAt(0);
    assert(approxEqual(c0["focus"]["x"].floating, 5.0) &&
           approxEqual(c0["focus"]["y"].floating, 5.0) &&
           approxEqual(c0["focus"]["z"].floating, 5.0),
        "viewport.fit must NOT touch the last-clicked-but-not-hovered cell (0): focus=" ~ c0["focus"].toString);
}

unittest { // viewport.fit_selected targets the HOVERED cell (1), not last-clicked (0)
    setupQuadLastClickCell0();
    // Face 0 = back face [0,3,2,1] at z=-0.5; centroid = (0, 0, -0.5).
    setSelection("polygons", [0]);

    auto r1 = cellRect(1);
    playEvents(hoverLog(r1.x + r1.w / 2, r1.y + r1.h / 2));  // hover cell 1, NO click

    runCmd("viewport.fit_selected");

    auto c1 = camAt(1);
    assert(approxEqual(c1["focus"]["x"].floating, 0.0) &&
           approxEqual(c1["focus"]["y"].floating, 0.0) &&
           approxEqual(c1["focus"]["z"].floating, -0.5),
        "viewport.fit_selected must reframe the HOVERED cell (1): focus=" ~ c1["focus"].toString);

    auto c0 = camAt(0);
    assert(approxEqual(c0["focus"]["x"].floating, 5.0) &&
           approxEqual(c0["focus"]["y"].floating, 5.0) &&
           approxEqual(c0["focus"]["z"].floating, 5.0),
        "viewport.fit_selected must NOT touch the last-clicked-but-not-hovered cell (0): focus=" ~ c0["focus"].toString);
}

unittest { // mid-drag: activeId must stay pinned to the drag-origin cell
    // even though the cursor wanders into a different cell before release
    // (the per-cell picking caches indexed by activeId must not switch
    // mid-gesture). Exercised at the ViewportManager.followHover() level in
    // source/viewport.d (GL-free unit test); here we lock the OBSERVABLE
    // HTTP contract: a button-down in cell 0 followed by motion into cell 1
    // WITHOUT a button-up must NOT make fit target cell 1.
    setupQuadLastClickCell0();

    auto r0 = cellRect(0);
    auto r1 = cellRect(1);
    int cx0 = r0.x + r0.w / 2, cy0 = r0.y + r0.h / 2;
    int cx1 = r1.x + r1.w / 2, cy1 = r1.y + r1.h / 2;

    // Button DOWN in cell 0, then motion into cell 1 — NO button-up, so the
    // gesture is still open (dragOriginId pinned to cell 0).
    string log = format(`{"t":0.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", cx0, cy0)
               ~ format(`{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
                         cx1, cy1, cx1 - cx0, cy1 - cy0);
    playEvents(log);

    runCmd("viewport.fit");

    auto c0 = camAt(0);
    assert(approxEqual(c0["focus"]["x"].floating, 0.0) &&
           approxEqual(c0["focus"]["y"].floating, 0.0) &&
           approxEqual(c0["focus"]["z"].floating, 0.0),
        "mid-drag: fit must still target the DRAG-ORIGIN cell (0), not the cell "
        ~ "the cursor wandered into before release: focus=" ~ c0["focus"].toString);

    auto c1 = camAt(1);
    assert(approxEqual(c1["focus"]["x"].floating, -5.0) &&
           approxEqual(c1["focus"]["y"].floating, -5.0) &&
           approxEqual(c1["focus"]["z"].floating, -5.0),
        "mid-drag: fit must NOT touch cell 1 while its gesture is still open: focus="
        ~ c1["focus"].toString);

    // Release the button so we don't leave a stray gesture open for any
    // later unittest block in this binary.
    playEvents(format(`{"t":0.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", cx1, cy1));
}
