module topology_pen_session_helpers;

// The topology pen session-law rig (task 8650; wave plan 8640 slice S2), shared
// by tests/test_session_laws_topology_pen.d and the cells later slices add to
// it. Rig: tests/fixtures/topology_pen_session_rig.v3d — layer 0 (primary) the
// 4x4 vertex grid on the +Z cap of the unit sphere, vertex index j*4+i, layer 1
// (visible, not selected) the 32x16 UV sphere background; perspective camera,
// eye (0,0,4) on the origin. Expectations: tests/fixtures/
// topology_pen_session_laws.json (structural only: moved-index sets, counts,
// armed flags, row counts). Pixels are projected on OUR side from the live
// mesh and the live camera; a gesture's drag is given in GRID SPACINGS (the
// screen distance v5 -> v6), so the rig means the same at any viewport size.
//
// Every gesture is real SDL input through /api/play-events; Ctrl+Z and
// Ctrl+Shift+Z are keystrokes (the navigate chokepoint); the arm is the UI
// door (`?origin=ui`). Nothing here asserts a law — only floors on the rig
// itself (the load, the camera, the hover that resolves a named element).

import http_client : getJson, postRaw, waitPlaybackProcessed, waitPreviewBuilt;
import drag_helpers : Vec3, Viewport, fetchCamera, viewportFromCamera, projectToWindow;
import std.algorithm : sort;
import std.array : join;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs, round, sqrt;
import std.path : buildPath, dirName;

enum PEN_KMOD_LSHIFT = 1;
enum PEN_KMOD_LCTRL  = 64;
enum PEN_KMOD_LALT   = 256;
enum PEN_SDLK_w = 119;
enum PEN_SDLK_z = 122;

enum string kPenToolId = "mesh.topoPen";

// ---------------------------------------------------------------------------
// transport
// ---------------------------------------------------------------------------

JSONValue penPost(string path, string body_) { return parseJSON(postRaw(path, body_)); }

/// A command by id (+ JSON params) through the script door; must succeed.
void penCmd(string id, string params = null) {
    const body_ = params.length ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
                                : `{"id":"` ~ id ~ `"}`;
    auto r = penPost("/api/command", body_);
    assert(r["status"].str == "ok", "pen rig: command " ~ id ~ " failed: " ~ r.toString);
}

/// An argstring line through the UI door (`?origin=ui`) — the door of the typed
/// command line, which arms a tool as its key/button does (gap 300).
void penLineUi(string line) {
    auto r = penPost("/api/command?origin=ui", line);
    assert(r["status"].str == "ok", "pen rig: ui line `" ~ line ~ "` failed: " ~ r.toString);
}

string penHeader() {
    auto c = fetchCamera();
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
                  ~ `{"t":0.000,"type":"PACE","mode":"frames"}`,
                  c.vpX, c.vpY, c.width, c.height);
}

void penPlay(string events, string what) {
    auto r = penPost("/api/play-events", penHeader() ~ "\n" ~ events);
    assert(r["status"].str == "success", "pen rig: play-events (" ~ what ~ ") refused: " ~ r.toString);
    waitPlaybackProcessed();
    waitPreviewBuilt();
}

string penMotion(double t, int x, int y, int state, int mod) {
    return format(`{"t":%.1f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":%d,"mod":%d}`,
                  t, x, y, state, mod);
}

string penButton(double t, bool down, int btn, int x, int y, int mod) {
    return format(`{"t":%.1f,"type":"%s","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":%d}`,
                  t, down ? "SDL_MOUSEBUTTONDOWN" : "SDL_MOUSEBUTTONUP", btn, x, y, mod);
}

string penKeyEvents(double t, int sym, int mod) {
    return format(`{"t":%.1f,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n" ~
                  `{"t":%.1f,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
                  t, sym, mod, t + 10, sym, mod);
}

void penKey(int sym, int mod, string what) { penPlay(penKeyEvents(20, sym, mod), what); }
void penCtrlZ(string what)      { penKey(PEN_SDLK_z, PEN_KMOD_LCTRL, what); }
void penCtrlShiftZ(string what) { penKey(PEN_SDLK_z, PEN_KMOD_LCTRL | PEN_KMOD_LSHIFT, what); }

/// SDL button mask bit of `btn` (1 left, 2 middle, 3 right) for motion `state`.
int penButtonMask(int btn) { return 1 << (btn - 1); }

/// One whole gesture: hover (x0,y0), press `btn` under `mod`, `n` held motions
/// to (x1,y1), release. `n == 0` is a motionless click. The modifier rides on
/// every event (playback drives SDL's modifier state from each one).
string penGestureEvents(int x0, int y0, int x1, int y1, int btn, int mod, int n) {
    string log = penMotion(20, x0, y0, 0, mod) ~ "\n" ~ penMotion(40, x0, y0, 0, mod) ~ "\n"
               ~ penButton(60, true, btn, x0, y0, mod) ~ "\n";
    foreach (i; 1 .. n + 1)
        log ~= penMotion(60 + 40 * i, x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n,
                         penButtonMask(btn), mod) ~ "\n";
    log ~= penButton(100 + 40 * n, false, btn, x1, y1, mod);
    return log;
}

void penGesture(int[2] from, double dxSp, double dySp, int btn, int mod, string what, int n = 8) {
    const sp = penSpacingPx();
    const x1 = cast(int)round(from[0] + dxSp * sp), y1 = cast(int)round(from[1] + dySp * sp);
    penPlay(penGestureEvents(from[0], from[1], x1, y1, btn, mod, (x1 == from[0] && y1 == from[1]) ? 0 : n),
            what);
}

void penTap(int[2] at, int btn, int mod, string what) {
    penPlay(penGestureEvents(at[0], at[1], at[0], at[1], btn, mod, 0), what);
}

// ---------------------------------------------------------------------------
// state reads
// ---------------------------------------------------------------------------

double penNum(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger : v.floating;
}

/// The primary mesh as values: positions (index-aligned), faces as given, and
/// the edge count. `==` on two of these is the bit-exact comparison the laws
/// ask for (the doubles the API serialised, compared exactly).
struct PenMesh {
    double[3][] pos;
    long[][] faces;
    long edges;
    long nv() const { return cast(long)pos.length; }
    long nf() const { return cast(long)faces.length; }
    string toString() const { return format("(nv %d, nf %d, ne %d)", nv, nf, edges); }
    bool opEquals(const PenMesh o) const { return pos == o.pos && faces == o.faces && edges == o.edges; }
}

PenMesh penMesh() {
    auto m = getJson("/api/model");
    PenMesh r;
    foreach (v; m["vertices"].array)
        r.pos ~= [penNum(v.array[0]), penNum(v.array[1]), penNum(v.array[2])];
    foreach (f; m["faces"].array) {
        long[] idx;
        foreach (c; f.array) idx ~= c.integer;
        r.faces ~= idx;
    }
    r.edges = cast(long)m["edges"].array.length;
    return r;
}

/// Indices whose position differs (exactly) between two meshes of equal size;
/// null when the vertex counts differ.
long[] penMoved(const PenMesh a, const PenMesh b) {
    if (a.pos.length != b.pos.length) return null;
    long[] r;
    foreach (i; 0 .. a.pos.length) if (a.pos[i] != b.pos[i]) r ~= cast(long)i;
    return r;
}

string penTool() {
    auto s = getJson("/api/tool/state");
    return ("tool" in s.object) ? s["tool"].str : "";
}

bool penArmed() { return penTool() == kPenToolId; }

long penHistoryLen() { return cast(long)getJson("/api/history")["undo"].array.length; }

string[] penHistoryLabels() {
    string[] r;
    foreach (e; getJson("/api/history")["undo"].array) r ~= e["label"].str;
    return r;
}

bool penCanRedo() { return getJson("/api/undo/status")["canRedo"].type == JSONType.true_; }

// ---------------------------------------------------------------------------
// pixels (projected from the LIVE mesh and camera)
// ---------------------------------------------------------------------------

float[2] penProject(double[3] p) {
    auto vp = viewportFromCamera(fetchCamera());
    float x, y;
    assert(projectToWindow(Vec3(cast(float)p[0], cast(float)p[1], cast(float)p[2]), vp, x, y),
           format("pen rig: %s projects off screen", p));
    return [x, y];
}

int[2] penRound(float[2] p) { return [cast(int)round(p[0]), cast(int)round(p[1])]; }

/// Screen distance v5 -> v6 on the rig at load (the unit a gesture's drag is
/// given in; the capture rig's was 66.8 px).
double penSpacingPx() {
    auto m = penMesh();
    const a = penProject(m.pos[5]), b = penProject(m.pos[6]);
    return sqrt((a[0] - b[0]) ^^ 2 + (a[1] - b[1]) ^^ 2);
}

JSONValue penHoverIndicator() { return getJson("/api/tool/state")["hoverIndicator"]; }

void penHover(int[2] at) {
    penPlay(penMotion(20, at[0], at[1], 0, 0) ~ "\n" ~ penMotion(40, at[0], at[1], 0, 0), "hover");
}

/// The pixel of vertex `v` of the current mesh; floor: the pen's hover resolves
/// that vertex there (a gesture is never sent at an unverified pixel).
int[2] penVertexPx(long v, string what) {
    const px = penRound(penProject(penMesh().pos[cast(size_t)v]));
    penHover(px);
    auto hi = penHoverIndicator();
    assert(hi["nearestVert"].integer == v,
           format("pen pick floor (%s): vertex %d at %s hovers vertex %d", what, v, px,
                  hi["nearestVert"].integer));
    return px;
}

/// The id of edge (a, b) in /api/model's edge list, or -1.
long penEdgeId(long a, long b) {
    foreach (i, e; getJson("/api/model")["edges"].array) {
        const x = e.array[0].integer, y = e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(long)i;
    }
    return -1;
}

/// The screen midpoint of edge (a, b); floor: the pen's hover resolves that
/// edge there.
int[2] penEdgePx(long a, long b, string what) {
    auto m = penMesh();
    const pa = penProject(m.pos[cast(size_t)a]), pb = penProject(m.pos[cast(size_t)b]);
    const px = penRound([(pa[0] + pb[0]) / 2, (pa[1] + pb[1]) / 2]);
    const e = penEdgeId(a, b);
    assert(e >= 0, format("pen rig (%s): edge (%d,%d) does not exist", what, a, b));
    penHover(px);
    auto hi = penHoverIndicator();
    assert(hi["nearestEdge"].integer == e,
           format("pen pick floor (%s): edge (%d,%d) = id %d at %s hovers edge %d", what, a, b, e,
                  px, hi["nearestEdge"].integer));
    return px;
}

/// The screen centroid of face `f`'s corners (a face-interior pixel on the grid).
int[2] penFacePx(long f) {
    auto m = penMesh();
    float[2] s = [0, 0];
    foreach (v; m.faces[cast(size_t)f]) {
        const p = penProject(m.pos[cast(size_t)v]);
        s[0] += p[0]; s[1] += p[1];
    }
    const n = cast(float)m.faces[cast(size_t)f].length;
    return penRound([s[0] / n, s[1] / n]);
}

/// A pixel on the background below the grid, off every FG element: the sphere
/// point (0, -0.6, 0.8), the capture rig's own empty-background point.
int[2] penEmptyBackgroundPx() { return penRound(penProject([0.0, -0.6, 0.8])); }

// ---------------------------------------------------------------------------
// the rig
// ---------------------------------------------------------------------------

struct PenRig {
    PenMesh a0;       // the FG grid as loaded
    long hp;          // history length after the load (0: cleared)
}

/// scene.reset, load the two-layer rig, set the camera, clear history. `rigPath`
/// is the absolute path of topology_pen_session_rig.v3d (the test computes it
/// from its own `__FILE_FULL_PATH__`).
/// Put the camera back to the rig's: perspective, eye (0,0,4), on the origin.
void penResetCamera() {
    auto cam = penPost("/api/camera",
        `{"azimuth":0.0,"elevation":0.0,"distance":4.0,"focus":{"x":0.0,"y":0.0,"z":0.0}}`);
    const c = fetchCamera();
    assert(abs(c.eye.x) < 1e-4 && abs(c.eye.y) < 1e-4 && abs(c.eye.z - 4) < 1e-4
           && abs(c.focus.x) + abs(c.focus.y) + abs(c.focus.z) < 1e-4,
           format("pen rig: the camera is not eye (0,0,4) on the origin: eye %s focus %s (%s)",
                  c.eye, c.focus, cam.toString));
}

PenRig penRigLoad(string rigPath) {
    penCmd("scene.reset");
    penCmd("file.load", format(`{"path":%s}`, JSONValue(rigPath).toString));
    penResetCamera();
    penCmd("history.clear");
    PenRig r;
    r.a0 = penMesh();
    r.hp = penHistoryLen();
    assert(r.a0.nv == 16 && r.a0.nf == 9 && r.a0.edges == 24 && r.hp == 0,
           format("pen rig: the primary is not the 16v/9f/24e grid with an empty history: %s, "
                  ~ "history %d", r.a0.toString, r.hp));
    assert(!penArmed(), "pen rig: a tool is armed before the arm");
    penBackgroundLayerFloor();
    return r;
}

/// Floor on the loaded document: exactly the two rig layers, layer 0 the
/// primary grid and layer 1 the capture's background sphere — 482 vertices,
/// 512 polygons (448 quads + 64 pole triangles), visible and not selected, so
/// it is a background. Without it the pen snaps to nothing and the cells still
/// run (the counts below are the generator's, appendix A of card 8650).
void penBackgroundLayerFloor() {
    auto ls = getJson("/api/layers")["layers"].array;
    assert(ls.length == 2, format("pen rig: %d layers loaded, expected 2 (grid + background)", ls.length));
    auto fg = ls[0], bg = ls[1];
    assert(fg["primary"].type == JSONType.true_ && fg["vertexCount"].integer == 16,
           "pen rig: layer 0 is not the primary 16-vertex grid: " ~ fg.toString);
    assert(bg["vertexCount"].integer == 482 && bg["faceCount"].integer == 512
           && bg["visible"].type == JSONType.true_ && bg["selected"].type == JSONType.false_
           && bg["background"].type == JSONType.true_,
           "pen rig: layer 1 is not the visible, unselected 482v/512f background sphere: " ~ bg.toString);
}

/// Floor on the background HIT and its WINDING, readable only with the pen
/// armed (its hover is what reaches the background): hovering
/// penEmptyBackgroundPx hits layer 1 at the near-side sphere point
/// (0, -0.6, 0.8) the pixel was projected from, and the hit face's normal
/// points OUTWARD (n . p > 0). The seed ray reaches the near side whatever the
/// winding, so the normal term is the one an inward-wound sphere reddens.
/// Restores no state: a hover writes no history.
void penBackgroundHitFloor() {
    penHover(penEmptyBackgroundPx());
    auto s = getJson("/api/tool/state");
    double[3] v3(JSONValue a) { return [penNum(a.array[0]), penNum(a.array[1]), penNum(a.array[2])]; }
    const p = v3(s["point"]), n = v3(s["normal"]);
    const outward = n[0] * p[0] + n[1] * p[1] + n[2] * p[2];
    assert(s["hit"].type == JSONType.true_ && s["layer"].integer == 1
           && abs(p[0]) < 0.05 && abs(p[1] + 0.6) < 0.05 && abs(p[2] - 0.8) < 0.05 && outward > 0.5,
           format("pen rig: hovering the empty background does not hit the outward-facing near side "
                  ~ "of layer 1 at (0,-0.6,0.8): hit %s layer %d point %s normal %s",
                  s["hit"].toString, s["layer"].integer, p, n));
}

/// Arm the pen through the UI door; floors: armed, and the background hit
/// (penBackgroundHitFloor). The activation ROW is a law (L1), asserted by the
/// cells, not here.
void penArmUi(const PenRig rig) {
    penLineUi("tool.set " ~ kPenToolId ~ " on");
    assert(penArmed(), format("pen rig: the UI arm did not arm the pen: tool '%s', history %s",
                              penTool(), penHistoryLabels()));
    penBackgroundHitFloor();
}

string penIdx(const long[] xs) { return "[" ~ xs.to!(string[]).join(",") ~ "]"; }
