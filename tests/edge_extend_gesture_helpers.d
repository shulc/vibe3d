module edge_extend_gesture_helpers;

// Shared rig + real-input drivers for the Edge Extend gesture witnesses
// (tests/test_edge_extend_{z_axis,symmetry,rearm_offset,tool_switch}.d).
//
// The rig is the frozen capture's own (tests/fixtures/edge_extend_gesture_laws.json,
// `rig`): an open 2x2 quad plane in XY, vertices x,y in {-1,0,1}, index
// (x+1)*3+(y+1), seen from an orthographic TOP view (screen right = +X,
// screen up = -Z). Every gesture is played through /api/play-events as real
// SDL events, one 4-px increment per playback, and the tool's own state is
// read after each increment, so a trace is a per-increment record rather
// than a before/after pair.
//
// Arms are located, not assumed: the gizmo sits at the action centre, so a
// press point is the action centre projected through the ortho camera plus
// the arm's screen offset. Every caller then asserts what the press GRABBED
// (`dragAxis` in /api/tool/state) before trusting the trace, because a press
// that misses the arm becomes the screen-plane haul, which moves the same
// offset channel and would read as a plausible drag.

import http_client : getJson, postJson;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs, tan, PI, round;
import core.thread : Thread;
import core.time : dur;

enum int kIncrementPx = 4;       // fixture rig.increment_px
enum int kArmPressPx  = 91;      // 24 px shaft start + 70 % of the 96 px shaft
enum int kScaleKey = 114;     // SDL keycode 'r' — the scale-tool binding

// Empty-space press points, far from the gizmo, the plane (edge-on on the
// z = 0 row) and each other. Relative to the viewport centre.
enum int kHaulDx = -150, kHaulDy = 150;
enum int kClickDx = 175,  kClickDy = -150;

struct Offset { double x, y, z; }

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command `" ~ line ~ "` failed: " ~ r.toString);
}

void cmdId(string id, string params) {
    auto r = postJson("/api/command", `{"id":"` ~ id ~ `","params":` ~ params ~ `}`);
    assert(r["status"].str == "ok", id ~ " failed: " ~ r.toString);
}

JSONValue toolState() { return getJson("/api/tool/state"); }
JSONValue model()     { return getJson("/api/model"); }
long undoLen()        { return cast(long) getJson("/api/history")["undo"].array.length; }

double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double) v.integer : v.floating;
}

double[3] vtx(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return [num(a[0]), num(a[1]), num(a[2])];
}

size_t vertexCount() { return model()["vertices"].array.length; }
size_t faceCount()   { return model()["faces"].array.length; }

Offset offset() {
    auto s = toolState();
    assert(s["tool"].str == "edgeExtend", "edge extend is not the active tool: " ~ s.toString);
    return Offset(num(s["offsetX"]), num(s["offsetY"]), num(s["offsetZ"]));
}

int grabbedAxis() { return cast(int) toolState()["dragAxis"].integer; }

/// The fixture rig: 3x3 grid in XY, four quads, index (x+1)*3+(y+1).
void loadPlaneRig() {
    string verts = "[";
    foreach (x; [-1, 0, 1]) foreach (y; [-1, 0, 1]) {
        if (verts.length > 1) verts ~= ",";
        verts ~= format("[%d,%d,0]", x, y);
    }
    verts ~= "]";
    int idx(int x, int y) { return (x + 1) * 3 + (y + 1); }
    string faces = "[";
    foreach (x; [-1, 0]) foreach (y; [-1, 0]) {
        if (faces.length > 1) faces ~= ",";
        faces ~= format("[%d,%d,%d,%d]", idx(x, y), idx(x + 1, y), idx(x + 1, y + 1), idx(x, y + 1));
    }
    faces ~= "]";
    cmdId("scene.loadMesh", `{"vertices":` ~ verts ~ `,"faces":` ~ faces ~ `}`);
    assert(vertexCount() == 9 && faceCount() == 4, "plane rig did not load as 9 v / 4 f");
}

/// Edge indices for vertex pairs, looked up (edge order is a build detail).
int[] edgesOf(int[2][] pairs) {
    auto m = model();
    int[] out_;
    foreach (p; pairs) {
        int found = -1;
        foreach (i, e; m["edges"].array) {
            long a = e.array[0].integer, b = e.array[1].integer;
            if ((a == p[0] && b == p[1]) || (a == p[1] && b == p[0])) { found = cast(int) i; break; }
        }
        assert(found >= 0, format("rig edge (%d,%d) missing", p[0], p[1]));
        out_ ~= found;
    }
    return out_;
}

void selectEdges(int[] idx) {
    string s = "[";
    foreach (i, v; idx) { if (i) s ~= ","; s ~= v.to!string; }
    cmdId("mesh.select", `{"mode":"edges","indices":` ~ s ~ `]}`);
    auto got = getJson("/api/selection")["selectedEdges"].array;
    assert(got.length == idx.length,
        format("selection floor: %d edges requested, %d selected", idx.length, got.length));
}

/// Symmetry is written AND read back. Enable it only AFTER the selection:
/// a selection made while symmetry is on is itself mirrored (measured on
/// this rig: +X ridge alone -> both ridges selected, 15 vertices after a
/// haul), which would make every one-sided cell a two-sided one.
void setSymmetryX(bool on) {
    cmd("tool.pipe.attr symmetry enabled " ~ (on ? "true" : "false"));
    cmd("tool.pipe.attr symmetry axis x");
    cmd("tool.pipe.attr symmetry offset 0");
    foreach (st; getJson("/api/toolpipe")["stages"].array) {
        if (st["id"].str != "symmetry") continue;
        assert(st["attrs"]["enabled"].str == (on ? "true" : "false")
            && st["attrs"]["axis"].str == "x" && st["attrs"]["offset"].str == "0",
            "symmetry state did not read back: " ~ st.toString);
        return;
    }
    assert(false, "no symmetry stage in /api/toolpipe");
}

/// Reset, rig, select, optional symmetry, ortho top centred on `focusX`,
/// arm the tool, clear history (headroom under the history cap).
void armRig(int[2][] pairs, double focusX, bool symmetry = false, string axisMode = null) {
    auto r = postJson("/api/command", `{"id":"scene.reset"}`);
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    loadPlaneRig();
    setSymmetryX(false);
    selectEdges(edgesOf(pairs));
    if (symmetry) setSymmetryX(true);
    cmd("viewport.view Top");
    r = postJson("/api/camera", format(`{"focus":{"x":%s,"y":0,"z":0}}`, focusX));
    assert(r["status"].str == "ok", "camera focus failed: " ~ r.toString);
    auto cam = getJson("/api/camera");
    assert(cam["projKind"].str == "Ortho", "rig premise: top view must be orthographic");
    cmd("tool.set edge.extend on");
    if (axisMode !is null) cmd("tool.pipe.attr axis mode " ~ axisMode);
    cmd("history.clear");
    settle(250);
    assert(undoLen() == 0, "history.clear left entries");
    assert(offset() == Offset(0, 0, 0), "armed extend does not start at offset 0");
}

void settle(int ms = 120) { Thread.sleep(dur!"msecs"(ms)); }

// --- screen geometry ------------------------------------------------------

struct Px { int x, y; }

Px viewCentre() {
    auto c = getJson("/api/camera");
    return Px(cast(int)(c["vpX"].integer + c["width"].integer / 2),
              cast(int)(c["vpY"].integer + c["height"].integer / 2));
}

/// World point -> window pixel under the ortho TOP camera (screen right = +X,
/// screen down = +Z). World-per-pixel is the camera's own ortho extent.
Px topScreen(double wx, double wz) {
    auto c = getJson("/api/camera");
    immutable double wpp = 2.0 * num(c["distance"]) * tan(PI / 8) / cast(double) c["height"].integer;
    immutable double cx = c["vpX"].integer + c["width"].integer / 2.0;
    immutable double cy = c["vpY"].integer + c["height"].integer / 2.0;
    return Px(cast(int) round(cx + (wx - num(c["focus"]["x"])) / wpp),
              cast(int) round(cy + (wz - num(c["focus"]["z"])) / wpp));
}

/// The gizmo centre on screen: the action centre, projected.
Px gizmoPx() {
    foreach (st; getJson("/api/toolpipe")["stages"].array) {
        if (st["id"].str != "actionCenter") continue;
        return topScreen(st["attrs"]["cenX"].str.to!double, st["attrs"]["cenZ"].str.to!double);
    }
    assert(false, "no actionCenter stage in /api/toolpipe");
}

Px haulPx()  { auto c = viewCentre(); return Px(c.x + kHaulDx,  c.y + kHaulDy); }
Px clickPx() { auto c = viewCentre(); return Px(c.x + kClickDx, c.y + kClickDy); }

// --- real input -----------------------------------------------------------

private string header() {
    auto c = getJson("/api/camera");
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        c["vpX"].integer, c["vpY"].integer, c["width"].integer, c["height"].integer);
}

void play(string body_) {
    auto r = postJson("/api/play-events", header() ~ body_);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    foreach (i; 0 .. 200) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.true_) {
            settle();
            return;
        }
        settle(50);
    }
    assert(false, "play-events did not finish within 10 s");
}

/// Hover (button up) then press — the hover lets the arbiter see the arm.
void press(Px p) {
    play(format(`{"t":20.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
              ~ `{"t":200.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
                p.x, p.y, p.x, p.y));
}

void motion(Px to_, int dx, int dy) {
    play(format(`{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
                to_.x, to_.y, dx, dy));
}

/// Release; while Edge Extend is the tool, the drag must be over afterwards
/// (the other half of the press floor: `dragBank` is read both ways).
void release(Px p) {
    play(format(`{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
                p.x, p.y));
    auto s = toolState();
    if (s["tool"].str == "edgeExtend")
        assert(s["dragBank"].str == "none", "release did not end the extend drag: " ~ s.toString);
}

void tapKey(int sym) {
    play(format(`{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":0,"repeat":0}` ~ "\n"
              ~ `{"t":80.000,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":0,"repeat":0}` ~ "\n", sym, sym));
}

/// `n` increments of (dx,dy) from an already-pressed `start`, the offset read
/// after each. Returns the trace; `end` receives the final pointer pixel.
Offset[] increments(Px start, int dx, int dy, int n, out Px end) {
    Offset[] tr;
    Px p = start;
    foreach (i; 0 .. n) {
        p = Px(p.x + dx, p.y + dy);
        motion(p, dx, dy);
        tr ~= offset();
    }
    end = p;
    return tr;
}

/// A complete haul on empty space: press, `n` increments, release.
Offset[] haul(Px start, int dx, int dy, int n) {
    press(start);
    assert(grabbedAxis() == 3,
        "haul press did not begin the screen-plane haul (dragAxis " ~ grabbedAxis().to!string
        ~ ", expected 3) — it landed on a gizmo arm, or the readout is dead");
    Px end;
    auto tr = increments(start, dx, dy, n, end);
    release(end);
    return tr;
}

/// The fixture's engage: a 3-increment screen-up haul on empty space.
void engage() {
    auto tr = haul(haulPx(), 0, -kIncrementPx, 3);
    assert(tr.length == 3 && tr[2].z < 0 && tr[2].x == 0 && tr[2].y == 0,
        "engage haul did not write a pure -Z offset: " ~ tr.to!string);
}

/// Press the arm `armOffset` pixels from the gizmo centre and assert the
/// press grabbed Move-bank axis `expectAxis`; returns the press pixel.
Px pressArm(int ox, int oy, int expectAxis, string what) {
    Px g = gizmoPx();
    Px p = Px(g.x + ox, g.y + oy);
    press(p);
    immutable int got = grabbedAxis();
    assert(toolState()["dragBank"].str == "move" && got == expectAxis,
        what ~ ": press at " ~ p.to!string ~ " grabbed dragAxis " ~ got.to!string
        ~ ", expected " ~ expectAxis.to!string ~ " (3 = the haul, which moves the same channel)");
    return p;
}

/// New vertices = the tail past the 9 rig vertices.
double[3][] newVertices() {
    auto m = model();
    double[3][] out_;
    foreach (i; 9 .. m["vertices"].array.length) out_ ~= vtx(m, i);
    return out_;
}
