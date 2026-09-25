module edge_extend_gesture_helpers;

// Shared rig + real-input drivers for the Edge Extend gesture witnesses
// (tests/test_edge_extend_{z_axis,symmetry,rearm_offset,tool_switch,live_undo,
// first_press,shift_middle}.d).
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
//
// Two cameras. The TOP rig above serves the capture's top-view cells; the
// FRONT rig (`frontRig`) serves the cells captured in a front orthographic
// view, where the plane faces the camera and world (x, y) points are pressed
// directly. Its distance is chosen so ONE pixel is 0.003125 m: ten 4-px
// increments are then exactly 0.125, the capture's own value, because our
// haul maps pixels linearly and does not round (the capture's 0.005 offset
// quantum is not reproduced — recorded as a divergence, not a law).
//
// HTTP reads between gestures do not end the run (gap 211: the law "a new
// press starts a fresh extend", gap 174, is refuted), so every witness reads
// state freely between presses.

import http_client : frameFence, getJson, postJson, waitPlaybackProcessed;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs, tan, PI, round;
import core.thread : Thread;
import core.time : dur;

enum int kIncrementPx = 4;       // fixture rig.increment_px
enum int kArmPressPx  = 91;      // 24 px shaft start + 70 % of the 96 px shaft
enum int kScaleKey = 114;     // SDL keycode 'r' — the scale-tool binding
enum int kExtendKey = 122;    // SDL keycode 'z' — config/shortcuts.yaml edge.extend: Z
enum int SDLK_z = 122;
enum int KMOD_LSHIFT = 0x0001, KMOD_LCTRL = 0x0040, KMOD_LALT = 0x0100;
enum double kFrontWpp = 0.003125;   // front rig: metres per pixel

// Empty-space press points, far from the gizmo, the plane (edge-on on the
// z = 0 row) and each other. Relative to the viewport centre.
enum int kHaulDx = -150, kHaulDy = 150;
enum int kClickDx = 175,  kClickDy = -150;
enum int kThirdDx = -150, kThirdDy = -150;

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

/// The Move bank's handler centre as the last press left it (world).
double[3] pressAnchor() {
    auto a = toolState()["pressAnchor"].array;
    return [num(a[0]), num(a[1]), num(a[2])];
}

bool moveOffGizmo() { return toolState()["moveOffGizmo"].type == JSONType.true_; }
bool built()        { return toolState()["built"].type == JSONType.true_; }
bool runStarted()   { return toolState()["runStarted"].type == JSONType.true_; }

/// The active tool id, or "" when no tool is armed. /api/tool/state names an
/// Edge Extend `edgeExtend` and a transform `xfrm`.
string toolId() {
    auto s = toolState();
    return ("tool" in s.object) ? s["tool"].str : "";
}

size_t[] selectedEdgeList() {
    size_t[] out_;
    foreach (e; getJson("/api/selection")["selectedEdges"].array) out_ ~= cast(size_t) e.integer;
    return out_;
}

string topHistoryLabel() {
    auto u = getJson("/api/history")["undo"].array;
    return u.length ? u[$ - 1]["label"].str : "";
}

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

// One completed frame (card test-sleep-removal); `ms` is the retired sleep.
void settle(int ms = 120) { frameFence(); }

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

/// World point -> window pixel under the FRONT ortho camera (screen right =
/// +X, screen up = +Y).
Px frontScreen(double wx, double wy) {
    auto c = getJson("/api/camera");
    immutable double wpp = 2.0 * num(c["distance"]) * tan(PI / 8) / cast(double) c["height"].integer;
    immutable double cx = c["vpX"].integer + c["width"].integer / 2.0;
    immutable double cy = c["vpY"].integer + c["height"].integer / 2.0;
    return Px(cast(int) round(cx + (wx - num(c["focus"]["x"])) / wpp),
              cast(int) round(cy - (wy - num(c["focus"]["y"])) / wpp));
}

/// Where the Edge Extend handle is drawn: the tool's `gizmoCentre` readout
/// (the Move bank's handler centre), not the action centre — the two part
/// once a press stops placing the action centre.
double[3] gizmoCentre() {
    auto g = toolState()["gizmoCentre"];
    assert(g.type == JSONType.array, "gizmoCentre is not posed: " ~ g.toString);
    return [num(g[0]), num(g[1]), num(g[2])];
}

/// The gizmo centre on screen, projected (top view).
Px gizmoPx() { auto g = gizmoCentre(); return topScreen(g[0], g[2]); }

/// The Z arm's press pixel in the top view: the gizmo centre plus the same
/// screen offset file 1's block A presses (the arm points screen-down).
Px zArmPx() { auto g = gizmoPx(); return Px(g.x, g.y + kArmPressPx); }

/// The Z arm's pixel BEFORE any tool is armed, for a background sample:
/// there is no handle and no `gizmoCentre` yet, so the pixel comes from the
/// action centre the armed handle will first be posed at. A witness compares
/// it with zArmPx() after arming, so a parting of the two channels shows.
Px unarmedZArmPx() {
    foreach (st; getJson("/api/toolpipe")["stages"].array) {
        if (st["id"].str != "actionCenter") continue;
        auto g = topScreen(st["attrs"]["cenX"].str.to!double, st["attrs"]["cenZ"].str.to!double);
        return Px(g.x, g.y + kArmPressPx);
    }
    assert(false, "no actionCenter stage in /api/toolpipe");
}

Px haulPx()  { auto c = viewCentre(); return Px(c.x + kHaulDx,  c.y + kHaulDy); }
Px clickPx() { auto c = viewCentre(); return Px(c.x + kClickDx, c.y + kClickDy); }
Px thirdPx() { auto c = viewCentre(); return Px(c.x + kThirdDx, c.y + kThirdDy); }

// --- real input -----------------------------------------------------------

private string header() {
    auto c = getJson("/api/camera");
    // PACE: one frame per distinct `t`, no wall-clock wait (card test-sleep-removal).
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
        ~ `{"t":0.000,"type":"PACE","mode":"frames"}` ~ "\n",
        c["vpX"].integer, c["vpY"].integer, c["width"].integer, c["height"].integer);
}

void play(string body_) {
    auto r = postJson("/api/play-events", header() ~ body_);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    waitPlaybackProcessed();
}

/// Hover (button up) then press — the hover lets the arbiter see the arm.
/// The hover carries no button mask (nothing is held yet) but does carry the
/// modifiers, so a Shift or Alt chord is already down when the press lands.
void press(Px p, int btn = 1, int mod = 0) {
    play(format(`{"t":20.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":%d}` ~ "\n"
              ~ `{"t":200.000,"type":"SDL_MOUSEBUTTONDOWN","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":%d}` ~ "\n",
                p.x, p.y, mod, btn, p.x, p.y, mod));
}

/// One motion with button `btn` held (SDL mask 1 << (btn - 1)).
void motion(Px to_, int dx, int dy, int btn = 1, int mod = 0) {
    play(format(`{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":%d,"mod":%d}` ~ "\n",
                to_.x, to_.y, dx, dy, 1 << (btn - 1), mod));
}

/// One motion with NO button held.
void hover(Px to_, int dx, int dy) {
    play(format(`{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":0,"mod":0}` ~ "\n",
                to_.x, to_.y, dx, dy));
}

/// Release; while Edge Extend is the tool, the drag must be over afterwards
/// (the other half of the press floor: `dragBank` is read both ways).
void release(Px p, int btn = 1, int mod = 0) {
    play(format(`{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":%d}` ~ "\n",
                btn, p.x, p.y, mod));
    auto s = toolState();
    if ("tool" in s.object && s["tool"].str == "edgeExtend")
        assert(s["dragBank"].str == "none", "release did not end the extend drag: " ~ s.toString);
}

/// A motionless click: press and release at one pixel.
void click(Px p, int btn = 1, int mod = 0) { press(p, btn, mod); release(p, btn, mod); }

void tapKey(int sym, int mod = 0) {
    play(format(`{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n"
              ~ `{"t":80.000,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n",
                sym, mod, sym, mod));
}

/// The real interactive undo / redo keystrokes (the navHistory path through
/// the input router), never the raw `history.undo` command.
void ctrlZ()      { tapKey(SDLK_z, KMOD_LCTRL); settle(); }
void ctrlShiftZ() { tapKey(SDLK_z, KMOD_LCTRL | KMOD_LSHIFT); settle(); }

/// `n` increments of (dx,dy) from an already-pressed `start`, the offset read
/// after each. Returns the trace; `end` receives the final pointer pixel.
Offset[] increments(Px start, int dx, int dy, int n, out Px end, int btn = 1, int mod = 0) {
    Offset[] tr;
    Px p = start;
    foreach (i; 0 .. n) {
        p = Px(p.x + dx, p.y + dy);
        motion(p, dx, dy, btn, mod);
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
    assert(moveOffGizmo(), "haul press was not an off-gizmo press (moveOffGizmo false)");
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

// --- key arm, panel, probe ---------------------------------------------------

/// The tool's own key, as a user presses it.
void keyArm() {
    tapKey(kExtendKey);
    settle(250);
    assert(toolId() == "edgeExtend", "the tool's key did not arm Edge Extend: " ~ toolState().toString);
}

/// A value typed into the tool panel: the interactive script door
/// (ParameterChangeSource.InteractiveValue), as tests/test_mixed_bank_history_probe.d.
void typePanel(string line) {
    auto r = postJson("/api/script?interactive=true", line);
    assert(r["status"].str == "ok", "panel edit `" ~ line ~ "` failed: " ~ r.toString);
    settle();
}

/// One framebuffer pixel of the active cell, as [r, g, b].
int[3] probe(Px p) {
    auto c = getJson("/api/camera");
    auto j = getJson(format("/api/viewport/probe?points=%d,%d",
                            p.x - cast(int) c["vpX"].integer, p.y - cast(int) c["vpY"].integer));
    assert("error" !in j, "probe failed: " ~ j.toString);
    assert(j["renders"].type == JSONType.true_, "probe cell did not render");
    auto e = j["points"].array[0];
    assert("error" !in e, "probe point failed: " ~ e.toString);
    return [cast(int) num(e["r"]), cast(int) num(e["g"]), cast(int) num(e["b"])];
}

// --- the rig without an armed tool ------------------------------------------

/// Reset, rig, optional recorded selection edit, camera — no tool armed.
/// `front` picks the front ortho camera at 0.003125 m/px focused on
/// (focusX, focusY); otherwise the top camera focused on x = focusX.
/// With `recordedEdit`, history is cleared BEFORE the selection, so the
/// selection is the one recorded edit a third undo must reach; returns sel0,
/// the selected edges before it.
size_t[] rigNoArm(int[2][] pairs, bool front, double focusX, double focusY = 0,
                  bool recordedEdit = false) {
    auto r = postJson("/api/command", `{"id":"scene.reset"}`);
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    loadPlaneRig();
    setSymmetryX(false);
    if (front) {
        cmd("viewport.view Front");
        auto c0 = getJson("/api/camera");
        immutable double dist = kFrontWpp * cast(double) c0["height"].integer / (2.0 * tan(PI / 8));
        r = postJson("/api/camera", format(`{"focus":{"x":%s,"y":%s,"z":0},"distance":%s,"roll":0}`,
                                           focusX, focusY, dist));
    } else {
        cmd("viewport.view Top");
        r = postJson("/api/camera", format(`{"focus":{"x":%s,"y":0,"z":0}}`, focusX));
    }
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    assert(getJson("/api/camera")["projKind"].str == "Ortho", "rig premise: the view must be orthographic");
    size_t[] sel0;
    if (recordedEdit) {
        cmd("history.clear");
        sel0 = selectedEdgeList();
        selectEdges(edgesOf(pairs));
        assert(topHistoryLabel() == "Select" && selectedEdgeList().length == pairs.length,
            "rig: no recorded edit before the tool (the third undo would be vacuous): "
            ~ getJson("/api/history")["undo"].toString);
    } else {
        selectEdges(edgesOf(pairs));
        cmd("history.clear");
    }
    settle(250);
    return sel0;
}

/// The capture's symmetric-click rig (C2-sym-sel): front camera, symmetry X
/// on, edge mode, and ONE real click on the midpoint of the +X ridge edge
/// (7,8) at world (1.0, 0.5) — or wherever (clickX, clickY) says — under
/// symmetry the click selects the mirror edge too (S-both). No tool is armed.
void symSelRig(double focusX = 0.0, double focusY = 0.55, double clickX = 1.0, double clickY = 0.5) {
    auto r = postJson("/api/command", `{"id":"scene.reset"}`);
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    loadPlaneRig();
    setSymmetryX(false);
    cmd("viewport.view Front");
    auto c0 = getJson("/api/camera");
    immutable double dist = kFrontWpp * cast(double) c0["height"].integer / (2.0 * tan(PI / 8));
    r = postJson("/api/camera", format(`{"focus":{"x":%s,"y":%s,"z":0},"distance":%s,"roll":0}`,
                                       focusX, focusY, dist));
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    setSymmetryX(true);
    tapKey(50);   // '2' — edge mode
    assert(getJson("/api/selection")["mode"].str == "edges", "rig: edge mode did not take");
    click(frontScreen(clickX, clickY));
    assert(selectedEdgeList().length == 2, "symmetric click did not select the mirror edge: "
        ~ getJson("/api/selection")["selectedEdges"].toString);
    cmd("history.clear");
    settle(250);
}

/// |pressAnchor - (wx, wy)| <= 0.02 in the front plane.
void assertAnchorAt(double wx, double wy, string msg) {
    auto a = pressAnchor();
    assert(abs(a[0] - wx) <= 0.02 && abs(a[1] - wy) <= 0.02,
        format("%s: press anchor %s, press point (%s, %s)", msg, a, wx, wy));
}

/// Front-rig haul on empty space at world (wx, wy): press, the floor that it
/// is an off-handle press at that point (moveOffGizmo + anchor), `n`
/// increments of (dx, dy) read after each, release.
Offset[] frontHaul(double wx, double wy, int dx, int dy, int n, string rigMsg = "rig: the haul press grabbed a handle (not an off-handle haul)") {
    Px p = frontScreen(wx, wy);
    press(p);
    assert(moveOffGizmo(), rigMsg ~ ": moveOffGizmo false");
    assertAnchorAt(wx, wy, rigMsg);
    Px end;
    auto tr = increments(p, dx, dy, n, end);
    release(end);
    return tr;
}

// --- the handle pose (Q-pose, gap 245) -------------------------------------

/// The frozen handle origin (world x, y) of a `handle_pose_*` fixture cell
/// at `frame` (e.g. "h1_released").
double[2] fixturePose(string cell, string frame) {
    import std.file : readText;
    import std.json : parseJSON;
    auto j = parseJSON(readText("tests/fixtures/edge_extend_gesture_laws.json"));
    auto p = j["cells"][cell]["handle_origin_world_xy"][frame];
    assert(p.type == JSONType.array, format("fixture: %s.%s is not a pose: %s", cell, frame, p));
    return [num(p[0]), num(p[1])];
}

/// |gizmoCentre - (wx, wy, 0)| <= tol, else `msg` with both points.
void assertHandleAt(double wx, double wy, double tol, string msg) {
    auto g = gizmoCentre();
    assert(abs(g[0] - wx) <= tol && abs(g[1] - wy) <= tol && abs(g[2]) <= tol,
        format("%s: gizmoCentre %s, expected (%s, %s, 0)", msg, g, wx, wy));
}

/// The front-view pixel of the handle's X arm (screen right of the centre,
/// on the shaft) and its two row neighbours, for a probe that must see the
/// handle rather than a ridge that may run through the centre.
Px[3] xArmPx(double wx, double wy) {
    Px c = frontScreen(wx, wy);
    return [Px(c.x + 40, c.y - 1), Px(c.x + 40, c.y), Px(c.x + 40, c.y + 1)];
}

/// Edge mode by the key, then real clicks at the given world points (front
/// view): the first plain, the rest with Shift (selection add).
void clickSelectFront(double[2][] pts) {
    tapKey(50);   // '2' — edge mode
    assert(getJson("/api/selection")["mode"].str == "edges", "rig: edge mode did not take");
    foreach (i, q; pts) click(frontScreen(q[0], q[1]), 1, i ? KMOD_LSHIFT : 0);
}

/// Reset, rig, symmetry off, the front camera at `kFrontWpp` focused on
/// (focusX, focusY); no selection, no tool.
void frontRigNoSel(double focusX, double focusY) {
    auto r = postJson("/api/command", `{"id":"scene.reset"}`);
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    loadPlaneRig();
    setSymmetryX(false);
    cmd("viewport.view Front");
    frontFocus(focusX, focusY);
}

/// Re-aim the front camera (same `kFrontWpp` scale) at (focusX, focusY) — the
/// cell is too small to hold a far selection click and the haul at once.
void frontFocus(double focusX, double focusY) {
    auto c0 = getJson("/api/camera");
    immutable double dist = kFrontWpp * cast(double) c0["height"].integer / (2.0 * tan(PI / 8));
    auto r = postJson("/api/camera", format(`{"focus":{"x":%s,"y":%s,"z":0},"distance":%s,"roll":0}`,
                                            focusX, focusY, dist));
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    settle();
}

/// Floor: every world point lands inside the active cell (front view).
void assertOnScreen(double[2][] pts) {
    auto c = getJson("/api/camera");
    immutable long x0 = c["vpX"].integer, y0 = c["vpY"].integer;
    immutable long w = c["width"].integer, h = c["height"].integer;
    foreach (q; pts) {
        Px p = frontScreen(q[0], q[1]);
        assert(p.x > x0 + 4 && p.x < x0 + w - 4 && p.y > y0 + 4 && p.y < y0 + h - 4,
            format("rig: world point %s projects off the cell (%s in %sx%s at %s,%s)", q, p, w, h, x0, y0));
    }
}

/// The action-centre stage's `userPlaced` pin, as the stage reports it.
bool acenUserPlaced() {
    foreach (st; getJson("/api/toolpipe")["stages"].array)
        if (st["id"].str == "actionCenter") return st["attrs"]["userPlaced"].str == "true";
    assert(false, "no actionCenter stage in /api/toolpipe");
}
