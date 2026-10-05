// One element-pick law (task 9441): the selection click, its tie group, and
// the action-centre Element pick, against the frozen capture rows.
//
// Every cell copies its geometry, offsets and expected outcome from the
// private fixtures K-P (radius and comparator) and K-OC (click tie group);
// the capture is not read at test time.  Law: a click reaches an element
// within 8 px EUCLIDEAN, inclusive, vertex and edge alike; snapping does not
// widen it; a vertex click also takes every vertex whose squared distance is
// within 36 px² of the nearest's (6 px = the vertex point size); a mixed-type
// pick gathers within 8 px and lets a vertex win unless the winning edge's
// midpoint is nearer than it (and within 8 px).
//
// Rig: front orthographic view at 100 px per unit, every element placed at a
// PIXEL CENTRE so the offsets below are exact integers in both the ID buffer
// and the CPU projection.
//
// Run via: ./run_test.d element_pick_law

module test_element_pick_law;

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.math : PI, abs, tan;
import std.stdio : writeln;

import drag_helpers : playAndWait;

void main() {}

/// Every cell runs; the failures are reported together at the end, so one
/// red names every cell that differs.
string[] g_fail;

void check(bool ok, lazy string msg) {
    if (!ok) { g_fail ~= msg; writeln("CELL_FAIL ", msg); }
}

enum float PPU = 100.0f;

void settle() {
    import core.thread : Thread;
    import core.time : msecs;
    Thread.sleep(150.msecs);
}

void cmdOk(string body) {
    auto r = postJson("/api/command", body);
    assert(r["status"].str == "ok" || r["status"].str == "success",
           "command failed: " ~ body ~ " -> " ~ r.toString);
}

void cmd(string args) { cmdOk(args); }

/// Pixel frame: element (x, y) world sits at the CENTRE of pixel
/// (cx + x*PPU, cy - y*PPU); (cx, cy) is an integer pixel.
struct Frame { int vpX, vpY, w, h, cx, cy; }

Frame frontOrtho() {
    cmd("viewport.view Front");
    auto before = getJson("/api/camera");
    immutable int h = cast(int)before["height"].integer;
    immutable int w = cast(int)before["width"].integer;
    immutable float distance = h / (2.0f * PPU * tan(cast(float)(PI / 8.0)));
    // Focus shifted so world (0,0) lands on a pixel centre: window x of the
    // origin = w/2 - focusX*PPU must be k + 0.5.
    immutable float fx = (w % 2 == 0) ? -0.5f / PPU : 0.0f;
    immutable float fy = (h % 2 == 0) ?  0.5f / PPU : 0.0f;
    auto r = postJson("/api/camera", format(
        `{"distance":%.9g,"focus":{"x":%.9g,"y":%.9g,"z":0}}`, distance, fx, fy));
    assert(r["status"].str == "ok" || r["status"].str == "success",
           "camera setup failed: " ~ r.toString);
    settle();
    auto j = getJson("/api/camera");
    assert(j["projKind"].str == "Ortho" && j["viewPreset"].str == "Front",
           "rig requires the Front orthographic view: " ~ j.toString);
    Frame f;
    f.vpX = cast(int)j["vpX"].integer;
    f.vpY = cast(int)j["vpY"].integer;
    f.w = cast(int)j["width"].integer;
    f.h = cast(int)j["height"].integer;
    f.cx = f.vpX + f.w / 2;
    f.cy = f.vpY + f.h / 2;
    return f;
}

string viewportLine(ref const Frame f) {
    return format(`{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
                  ~ "\n", f.vpX, f.vpY, f.w, f.h);
}

string clickLog(ref const Frame f, int x, int y) {
    return viewportLine(f) ~ format(
        `{"t":50,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
      ~ `{"t":100,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
      ~ `{"t":150,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y, x, y, x, y);
}

void load(string geo) {
    cmdOk(commandBody("scene.reset"));
    cmdOk(commandBody("scene.loadMesh", geo));
}

void setMode(string mode) {
    cmdOk(commandBody("mesh.select", format(`{"mode":"%s","indices":[]}`, mode)));
    settle();
}

long[] selected(string key) {
    long[] r;
    foreach (v; getJson("/api/selection")[key].array) r ~= v.integer;
    return r;
}

// ---- selection click radius (K-P P1..P4b, P7) ------------------------------

/// A lone vertex at the origin; click at (dx, dy) px.
void vertexClickCell(string id, int dx, int dy, bool expectHit) {
    load(`{"vertices":[[0,0,0]],"faces":[]}`);
    auto f = frontOrtho();
    setMode("vertices");
    playAndWait(clickLog(f, f.cx + dx, f.cy + dy));
    settle();
    auto s = selected("selectedVertices");
    writeln("PICK_RESULT ", id, " d=(", dx, ",", dy, ") selected=", s);
    check((s.length == 1) == expectHit,
        format("%s: vertex click at (%d,%d) px: expected %s, selected=%s",
               id, dx, dy, expectHit ? "HIT (Euclidean <= 8)" : "MISS", s.to!string));
}

/// The bottom edge of a quad well above the cursor; click `d` px below it
/// (outside the face, 100 px from either end).
void edgeClickCell(string id, int d, bool expectHit) {
    load(`{"vertices":[[-1,0,0],[1,0,0],[1,1,0],[-1,1,0]],"faces":[[0,1,2,3]]}`);
    auto f = frontOrtho();
    setMode("edges");
    playAndWait(clickLog(f, f.cx, f.cy + d));
    settle();
    auto s = selected("selectedEdges");
    writeln("PICK_RESULT ", id, " d=", d, " selected=", s);
    check((s.length == 1) == expectHit,
        format("%s: edge click %d px off the edge: expected %s, selected=%s",
               id, d, expectHit ? "HIT (<= 8)" : "MISS", s.to!string));
}

// ---- click tie group (K-OC) -------------------------------------------------

void tieGroupCell(string id, string geo, long[] expected) {
    load(geo);
    auto f = frontOrtho();
    setMode("vertices");
    playAndWait(clickLog(f, f.cx, f.cy));
    settle();
    auto s = selected("selectedVertices");
    import std.algorithm : sort;
    sort(s);
    writeln("TIE_RESULT ", id, " selected=", s, " expected=", expected);
    check(s == expected,
        format("%s: a vertex click takes the nearest PLUS every vertex within "
             ~ "d²_best + 36 px²; expected %s, selected %s",
               id, expected.to!string, s.to!string));
}

// ---- action-centre Element pick (K-P P5*A) -----------------------------------

double[3] pivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return [c[0].floating, c[1].floating, c[2].floating];
}

/// Element Move (element mode automatic). A parking vertex at (-3, 2) takes
/// the first click so the gizmo sits 300 px away from the cell's press.
void acenCell(string id, string verts, string faces, int pressDy, double[3] want) {
    load(format(`{"vertices":[[-3,2,0],%s],"faces":%s}`, verts, faces));
    auto f = frontOrtho();
    setMode("vertices");
    cmd("tool.set xfrm.elementMove on");
    settle();
    playAndWait(clickLog(f, f.cx - 300, f.cy - 200));
    settle();
    auto park = pivot();
    assert(abs(park[0] + 3) < 1e-3 && abs(park[1] - 2) < 1e-3,
        format("%s: the parking click must pin the pivot at (-3,2,0), got %s",
               id, park.to!string));
    playAndWait(clickLog(f, f.cx, f.cy + pressDy));
    settle();
    auto p = pivot();
    cmd("tool.set xfrm.elementMove off");
    settle();
    writeln("ACEN_RESULT ", id, " pivot=", p, " want=", want);
    check(abs(p[0] - want[0]) < 1e-3 && abs(p[1] - want[1]) < 1e-3 && abs(p[2] - want[2]) < 1e-3,
        format("%s: the Element pick must land the pivot on %s, got %s",
               id, want.to!string, p.to!string));
}

void radiusCells() {
    // Controls first: they hold under every candidate law, so a red below
    // them is a law difference, not a dead channel.
    vertexClickCell("KP_P0", 0, 0, true);
    vertexClickCell("KP_P3", 12, 0, false);
    vertexClickCell("KP_P2b", 7, 7, false);    // Euclid 9.9: a square window would hit
    edgeClickCell("KP_P4b", 10, false);
    {
        cmd("tool.pipe.attr snap enabled true");
        cmd("tool.pipe.attr snap types vertex");
        scope (exit) cmd("tool.pipe.attr snap enabled false");
        vertexClickCell("KP_P7", 12, 0, false); // snapping does not widen a click
    }
    vertexClickCell("KP_P1", 5, 0, true);       // Manhattan-4 misses
    vertexClickCell("KP_P2", 4, 4, true);       // Euclid 5.66
    edgeClickCell("KP_P4", 7, true);            // edge-6 misses
}

void tieCells() {
    // OC_FSTK: four vertices stacked on the view axis, a control 1.5 px off,
    // a sentinel 20 px off.  OC_FOFF: 0 / 2 / 4 / 7.5 / 12 px (the 6 px
    // float-boundary row is deliberately absent).
    tieGroupCell("OC_FSTK",
        `{"vertices":[[0,0,0],[0,0,-0.5],[0,0,-1],[0,0,-1.5],[0.015,0,0],[0.2,0,0]],"faces":[]}`,
        [0, 1, 2, 3, 4]);
    tieGroupCell("OC_FOFF",
        `{"vertices":[[0,0,0],[0.02,0,0],[0.04,0,0],[0.075,0,0],[0.12,0,0]],"faces":[]}`,
        [0, 1, 2]);
}

void acenCells() {
    // Vertex V at the origin, press 7 px below it; an edge (a quad's top
    // side) 3 px below the press.  P5bA: vertex 10 px (outside the gather).
    // P5cA: the edge's midpoint 3 px from the press removes the vertex.
    acenCell("KP_P5bA", `[0,0,0],[-1,-0.13,0],[1.5,-0.13,0],[1.5,-1.13,0],[-1,-1.13,0]`,
             `[[2,3,4,5]]`, 10, [0.25, -0.13, 0.0]);
    acenCell("KP_P5A", `[0,0,0],[-1,-0.1,0],[1.5,-0.1,0],[1.5,-1.1,0],[-1,-1.1,0]`,
             `[[2,3,4,5]]`, 7, [0.0, 0.0, 0.0]);
    acenCell("KP_P5cA", `[0,0,0],[-0.6,-0.1,0],[0.6,-0.1,0],[0.6,-1.1,0],[-0.6,-1.1,0]`,
             `[[2,3,4,5]]`, 7, [0.0, -0.1, 0.0]);
}

// ---- topology-pen press visibility (K-P P9 / P9c, P10 / P10c) ---------------

enum string QUAD = `[-1,-0.5,0],[1,-0.5,0],[1,0.5,0],[-1,0.5,0]`;

/// A closed box x 0.1..0.5, y -0.7..-0.3, z z0..z1 after the quad; its +Z
/// side is face 1.
string boxRig(double z0, double z1) {
    string p = QUAD;
    foreach (i; 0 .. 8)
        p ~= format(`,[%g,%g,%g]`, (i & 4) ? 0.5 : 0.1, (i & 2) ? -0.3 : -0.7, (i & 1) ? z1 : z0);
    return format(`{"vertices":[%s],"faces":[[0,1,2,3],[5,9,11,7],[4,6,10,8],[8,10,11,9],`
                ~ `[4,5,7,6],[6,7,11,10],[4,8,9,5]]}`, p);
}

int edgeIndex(long a, long b) {
    foreach (i, e; getJson("/api/model")["edges"].array) {
        auto x = e.array[0].integer, y = e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    assert(false, format("edge %d-%d not found", a, b));
}

void setStyle(string style) {
    cmdOk(format(`{"id":"viewport.displayStyle","params":"%s"}`, style));
    settle();
}

/// Hover the topology pen (Move) at (dx, dy) px and compare what a press
/// would grab (`hoverIndicator`, the press's own resolver).
void penCell(string id, string geo, string style, int dx, int dy,
             string wantElem, int wantIndex) {
    load(geo);
    auto f = frontOrtho();
    setStyle(style);
    scope (exit) setStyle("shaded");
    cmd("tool.set mesh.topoPen on");
    cmd("tool.attr mesh.topoPen mode move");
    scope (exit) cmd("tool.set mesh.topoPen off");
    settle();
    playAndWait(viewportLine(f) ~ format(
        `{"t":50,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
        f.cx + dx, f.cy + dy));
    settle();
    auto hi = getJson("/api/tool/state")["hoverIndicator"];
    immutable string elem = hi["grabElem"].str;
    immutable int idx = cast(int)hi["grabIndex"].integer;
    writeln("PEN_RESULT ", id, " grab=", elem, "#", idx, " want=", wantElem, "#", wantIndex);
    check(elem == wantElem && (wantIndex < 0 || idx == wantIndex),
        format("%s: the press must take %s #%d, the hover promises %s #%d",
               id, wantElem, wantIndex, elem, idx));
}

void penCells() {
    // Controls first: the box BEHIND the quad leaves the edge pickable; a
    // filled style keeps the polygon.
    load(boxRig(-0.6, -0.2));
    penCell("KP_P9c", boxRig(-0.6, -0.2), "shaded", 30, 50, "edge", edgeIndex(0, 1));
    penCell("KP_P10c", `{"vertices":[` ~ QUAD ~ `],"faces":[[0,1,2,3]]}`, "shaded", 0, 0, "face", 0);
    // The box IN FRONT hides the edge: the press takes the box's front face.
    penCell("KP_P9", boxRig(0.2, 0.6), "shaded", 30, 50, "face", 1);
    // Wireframe draws no polygon: a press in the quad's interior takes nothing.
    penCell("KP_P10", `{"vertices":[` ~ QUAD ~ `],"faces":[[0,1,2,3]]}`, "wireframe", 0, 0, "none", -1);
}

/// K-P P8c: the pen's Point click over a BACKGROUND quad F, 7 px from F's
/// corner A and 3 px from a T-vertex M of the adjacent faces, snapping off:
/// the point lands on the surface under the press (no hit-face gather).
void penPlaceCell(string id, bool snapOn, double[2] want, double tol) {
    enum double PX = 0.07, PY = 0.03;
    immutable double ax = PX - 0.065, ay = PY - 0.026, mx = ax + 0.08;
    cmdOk(commandBody("scene.reset"));
    cmdOk(commandBody("scene.loadMesh", format(
        `{"vertices":[[%g,%g,0],[%g,%g,0],[%g,%g,0],[%g,%g,0],[%g,%g,0],[%g,%g,0],[%g,%g,0],[%g,%g,0]],`
      ~ `"faces":[[0,1,2,3],[0,6,5,4],[4,5,7,1]]}`,
        ax, ay, ax + 2, ay, ax + 2, ay + 1, ax, ay + 1,
        mx, ay, mx, ay - 0.5, ax, ay - 0.5, ax + 2, ay - 0.5)));
    cmd("layer.add name:Edit");
    auto f = frontOrtho();
    cmd("tool.set mesh.topoPen on");
    cmd("tool.attr mesh.topoPen mode point");
    scope (exit) cmd("tool.set mesh.topoPen off");
    cmd(snapOn ? "tool.pipe.attr snap enabled true" : "tool.pipe.attr snap enabled false");
    if (snapOn) cmd("tool.pipe.attr snap types vertex");
    scope (exit) cmd("tool.pipe.attr snap enabled false");
    settle();
    playAndWait(clickLog(f, f.cx + 7, f.cy - 3));
    settle();
    auto vs = getJson("/api/model?layer=1")["vertices"].array;
    double[2] got = [double.nan, double.nan];
    if (vs.length == 1) got = [vs[0].array[0].floating, vs[0].array[1].floating];
    writeln("PLACE_RESULT ", id, " n=", vs.length, " point=", got, " want=", want);
    check(vs.length == 1 && abs(got[0] - want[0]) < tol && abs(got[1] - want[1]) < tol,
        format("%s: the placed point must be %s (+-%g), got %d point(s) %s",
               id, want.to!string, tol, vs.length, got.to!string));
}

unittest {
    penPlaceCell("KP_P8c", false, [0.07, 0.03], 0.006);
    penCells();
    radiusCells();
    tieCells();
    acenCells();
    import std.array : join;
    assert(g_fail.length == 0, format("%d cell(s) differ from the captured law:\n  %s",
                                      g_fail.length, g_fail.join("\n  ")));
}
