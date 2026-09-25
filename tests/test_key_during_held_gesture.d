// test_key_during_held_gesture.d — slice M1a of the tool session model
// (doc/tool_session_model_plan_2026-09-24.md, R4.4): while ANY mouse button is
// held, no key press is dispatched (dropped, not queued) and no key release is
// delivered, not even at the button's release; keys work again after it.
// Captured law, toolcards/tool_session_model (README M0: C-H9-move, C-H9-bev,
// C-O5-*; M0b: C-H9-X, C-H9-X-up, C-H9-rmb; M0c: C-H9-orbit, Escape included).
//
// ONE rule in the event router, so the cells span tools that share nothing
// (Move, Polygon Bevel, Edge Slice, Slice, no tool at all) and all three
// buttons. Each cell asserts the negative half first, then the SAME key after
// the release as its positive control (so a dead key cannot pass the negative).
// All input is real SDL events through /api/play-events.

import slice_leak_helpers;
import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow, axisGrabPx,
    DHVec3 = Vec3;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : round, sqrt;

void main() {}

// ---- keys (sym, scan) ------------------------------------------------------
enum int K_2 = 50, K_2_SCAN = 31;
enum int K_e = 101, K_e_SCAN = 8;
enum int K_w = 119, K_w_SCAN = 26;
enum int K_x = 120, K_x_SCAN = 27;
enum int K_z = 122, K_z_SCAN = 29;
enum int K_RETURN = 13, K_RETURN_SCAN = 40;
enum int K_ESCAPE = 27, K_ESCAPE_SCAN = 41;
enum int KMOD_LCTRL_ = 64, KMOD_LALT_ = 256;

string keyEv(double t, bool down, int sym, int scan, int mod = 0) {
    return format(`{"t":%.1f,"type":"%s","sym":%d,"scan":%d,"mod":%d,"repeat":0}`,
                  t, down ? "SDL_KEYDOWN" : "SDL_KEYUP", sym, scan, mod);
}
/// A whole key tap (down + up) as one log.
void tap(int sym, int scan, int mod, string what) {
    slPlay(keyEv(20, true, sym, scan, mod) ~ "\n" ~ keyEv(30, false, sym, scan, mod), what);
}
void keyDown(int sym, int scan, string what) { slPlay(keyEv(20, true, sym, scan), what); }
void keyUp(int sym, int scan, string what)   { slPlay(keyEv(20, false, sym, scan), what); }
void ctrlZ(string what) { tap(K_z, K_z_SCAN, KMOD_LCTRL_, what); }

string motionMod(double t, int x, int y, int state, int mod) {
    return format(`{"t":%.1f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":%d,"mod":%d}`,
                  t, x, y, state, mod);
}
string buttonMod(double t, bool down, int btn, int x, int y, int mod) {
    return format(`{"t":%.1f,"type":"%s","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":%d}`,
                  t, down ? "SDL_MOUSEBUTTONDOWN" : "SDL_MOUSEBUTTONUP", btn, x, y, mod);
}

JSONValue toolState() { return getJson("/api/tool/state"); }
bool flag(JSONValue s, string k) {
    return (k in s.object) !is null && s[k].type == JSONType.true_;
}
/// The armed tool's identity: the tool id plus, for the unified transform, its
/// T/R/S bank flags (Move, Rotate and Scale all report tool "xfrm").
string toolSig() {
    auto s = toolState();
    if (("tool" in s.object) is null) return "";
    return s["tool"].str ~ (("enabled" in s.object) ? s["enabled"].toString : "");
}
string selMode() { return getJson("/api/selection")["mode"].str; }

void resetCube() {
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "scene.reset failed: " ~ r.toString);
}

// ---------------------------------------------------------------------------
// (a) C-H9-move — Move haul on the X arrow; a tool key (E) mid-haul is dropped
// and the haul runs to its end; the same key after the release switches.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto camR = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":0.6,"distance":6.0,"focus":{"x":0,"y":0,"z":0}}`);
    assert("error" !in camR, "/api/camera failed: " ~ camR.toString);
    slLine("tool.pipe.attr snap enabled false");
    slLine("tool.set move");
    const moveId = toolSig();
    assert(moveId.length, "move floor: tool.set move armed nothing");
    const before = getJson("/api/model")["vertices"].array[6].array[0].floating;

    auto vp = viewportFromCamera(fetchCamera());
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    const pivot = DHVec3(cast(float)c[0].floating, cast(float)c[1].floating,
                         cast(float)c[2].floating);
    int gx, gy;
    double ux, uy;
    axisGrabPx(pivot, vp, gx, gy, ux, uy);
    float ax, ay, bx, by;
    assert(projectToWindow(pivot, vp, ax, ay)
           && projectToWindow(DHVec3(pivot.x + 1.0f, pivot.y, pivot.z), vp, bx, by),
           "move rig: the displacement does not project");
    const pxPerUnit = sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
    int at(int i, bool y) {   // 12 steps to one world unit along +X
        return cast(int)round((y ? gy : gx) + pxPerUnit * (y ? uy : ux) * i / 12.0);
    }
    string half(int from, int to) {
        string log;
        foreach (i; from .. to + 1) log ~= slMotion(20 + 10 * i, at(i, false), at(i, true), 1) ~ "\n";
        return log;
    }
    slPlay(slMotion(10, gx, gy, 0) ~ "\n" ~ slButton(20, true, 1, gx, gy) ~ "\n" ~ half(1, 6),
           "(a) press on the X arrow, first half of the haul");
    const dxMid = getJson("/api/model")["vertices"].array[6].array[0].floating - before;
    tap(K_e, K_e_SCAN, 0, "(a) E during the haul");
    assert(toolSig() == moveId,
           format("(a) C-H9-move: a tool key switched tools during a held haul: '%s' (was '%s')",
                  toolSig(), moveId));
    slPlay(half(7, 12) ~ slButton(200, false, 1, at(12, false), at(12, true)),
           "(a) second half of the haul, release");
    const dx = getJson("/api/model")["vertices"].array[6].array[0].floating - before;
    assert(dxMid > 0.1 && toolSig() == moveId && dx > dxMid + 0.1,
           format("(a) C-H9-move: the haul did not run on past the dropped key: "
                  ~ "tool '%s', dx %.4f at the key, %.4f at the release", toolSig(), dxMid, dx));
    tap(K_e, K_e_SCAN, 0, "(a) E after the release");
    assert(toolSig() != moveId,
           format("(a) positive control: E after the release did not switch tools ('%s')", toolSig()));
    slLine("tool.pipe.attr snap enabled true");
}

// ---------------------------------------------------------------------------
// (b) C-H9-bev — Polygon Bevel shift haul; W (Move) mid-haul is dropped.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    slCmd("mesh.select", `{"mode":"polygons","indices":[0]}`);
    slLine("tool.set poly.bevel on");
    slPlay(slMotion(10, 5, 5, 0), "(b) settle a frame");
    int sx, sy;
    bool found;
    foreach (p; getJson("/api/tool/handles")["handles"]["parts"].array)
        if (p["part"].integer == 0) {
            sx = cast(int)(p["screen"].array[0].floating + 0.5);
            sy = cast(int)(p["screen"].array[1].floating + 0.5);
            found = true;
        }
    assert(found && slTool() == "polyBevel", "(b) bevel floor: no shift handle / tool not armed");
    string drag(int k0, int k1) {
        string log;
        foreach (k; k0 .. k1 + 1) log ~= slMotion(20 + 10 * k, sx - 10 * k, sy - 17 * k, 1) ~ "\n";
        return log;
    }
    slPlay(slButton(10, true, 1, sx, sy) ~ "\n" ~ drag(1, 3), "(b) shift-handle press + drag");
    const midShift = toolState()["shift"].floating;
    tap(K_w, K_w_SCAN, 0, "(b) W during the haul");
    assert(slTool() == "polyBevel" && midShift > 1e-4,
           format("(b) C-H9-bev: a tool key switched tools during a held bevel haul: '%s' "
                  ~ "(shift %s before it)", slTool(), midShift));
    slPlay(drag(4, 6) ~ slButton(200, false, 1, sx - 60, sy - 102), "(b) rest of the haul, release");
    const endShift = toolState()["shift"].floating;
    assert(slTool() == "polyBevel" && endShift > midShift + 1e-5,
           format("(b) C-H9-bev: the haul did not continue past the dropped key: tool '%s', "
                  ~ "shift %s -> %s", slTool(), midShift, endShift));
    tap(K_w, K_w_SCAN, 0, "(b) W after the release");
    assert(slTool() != "polyBevel",
           "(b) positive control: W after the release did not switch tools");
}

// ---------------------------------------------------------------------------
// (d) MIDDLE button — Slice's middle-drag relocate: Ctrl+Z held is dropped.
// (f) C-H9-X — X during a held LMB draw is dropped: the chord never engages.
// (i) C-H9-X-up — an X release during the hold is never delivered: the chord
//     stays engaged after the button's release; a free X tap clears it.
// ---------------------------------------------------------------------------
void sliceLinePixels(out int ax, out int ay, out int bx, out int by) {
    auto vp = viewportFromCamera(fetchCamera());
    float fax, fay, fbx, fby;
    assert(projectToWindow(DHVec3(0, -0.6f, 0), vp, fax, fay)
           && projectToWindow(DHVec3(0, 0.6f, 0), vp, fbx, fby),
           "slice rig: the slice line projects off screen");
    ax = cast(int)fax; ay = cast(int)fay; bx = cast(int)fbx; by = cast(int)fby;
}

unittest { // (d)
    slPrologue(false, "polygons", &slBackAndLeft, false);
    slKey(SL_SDLK_c, SL_KMOD_LSHIFT, "(d) Shift+C (Slice)");
    const Ha = slHistoryLen();
    slSliceDrawLine();
    const M1 = slMesh();
    int ax, ay, bx, by;
    sliceLinePixels(ax, ay, bx, by);
    const mx = (ax + bx) / 2 + 50, my = (ay + by) / 2;
    string log = slMotion(10, mx, my, 0) ~ "\n" ~ slButton(20, true, 2, mx, my) ~ "\n";
    foreach (i; 1 .. 5) log ~= slMotion(20 + 20 * i, mx + 5 * i, my, 2) ~ "\n";
    slPlay(log, "(d) middle press + held relocate");
    const mid = slMesh();
    assert(mid.canon != M1.canon, "(d) slice floor: the middle relocate did not move the cut");
    ctrlZ("(d) Ctrl+Z while the middle button is held");
    assert(slTool() == "slice" && slMesh().canon == mid.canon && slHistoryLen() == Ha,
           format("(d) a key reached Slice while the MIDDLE button was held: tool '%s', "
                  ~ "mesh moved %s, history %d (expected %d)", slTool(),
                  slMesh().canon != mid.canon, slHistoryLen(), Ha));
    slPlay(slButton(20, false, 2, mx + 20, my), "(d) middle release");
    const M2 = slMesh();
    ctrlZ("(d) Ctrl+Z after the release");
    assert(slMesh().canon == M1.canon && slTool() == "slice",
           format("(d) positive control: Ctrl+Z after the release did not pop the relocate "
                  ~ "(mesh is M1: %s, is the relocate: %s)", slMesh().canon == M1.canon,
                  slMesh().canon == M2.canon));
    slKey(SL_SDLK_w, 0, "(d) W (drop Slice)");
}

bool chordOn() {
    auto s = toolState();
    assert(("snapTempInvert" in s.object) !is null && s["tool"].str == "slice",
           "slice floor: /api/tool/state does not publish snapTempInvert: " ~ s.toString);
    return flag(s, "snapTempInvert");
}

unittest { // (f) C-H9-X, the press
    resetCube();
    slLine("tool.set mesh.sliceTool on");
    int ax, ay, bx, by;
    sliceLinePixels(ax, ay, bx, by);
    string log = slMotion(10, ax, ay, 0) ~ "\n" ~ slButton(20, true, 1, ax, ay) ~ "\n";
    foreach (i; 1 .. 5) log ~= slMotion(20 + 20 * i, ax + (bx - ax) * i / 8, ay + (by - ay) * i / 8, 1) ~ "\n";
    slPlay(log, "(f) LMB press + held draw");
    assert(!chordOn(), "(f) slice floor: the chord is engaged before X");
    keyDown(K_x, K_x_SCAN, "(f) X down while held");
    assert(!chordOn(), "(f) C-H9-X: X pressed during a held LMB reached the Slice tool "
                       ~ "(the snap chord engaged)");
    keyUp(K_x, K_x_SCAN, "(f) X up while held");
    slPlay(slButton(20, false, 1, bx, by), "(f) LMB release");
    keyDown(K_x, K_x_SCAN, "(f) X down after the release");
    assert(chordOn(), "(f) positive control: X after the release did not engage the chord");
    keyUp(K_x, K_x_SCAN, "(f) X up after the release");
    assert(!chordOn(), "(f) positive control: X up after the release did not clear the chord");
    slLine("tool.set mesh.sliceTool off");
}

unittest { // (i) C-H9-X-up, the release
    resetCube();
    slLine("tool.set mesh.sliceTool on");
    int ax, ay, bx, by;
    sliceLinePixels(ax, ay, bx, by);
    keyDown(K_x, K_x_SCAN, "(i) X down, no button");
    assert(chordOn(), "(i) slice floor: a free X did not engage the chord");
    string log = slMotion(10, ax, ay, 0) ~ "\n" ~ slButton(20, true, 1, ax, ay) ~ "\n";
    foreach (i; 1 .. 5) log ~= slMotion(20 + 20 * i, ax + (bx - ax) * i / 8, ay + (by - ay) * i / 8, 1) ~ "\n";
    slPlay(log, "(i) LMB press + held draw");
    keyUp(K_x, K_x_SCAN, "(i) X up while held");
    slPlay(slButton(20, false, 1, bx, by), "(i) LMB release");
    assert(chordOn(), "(i) C-H9-X-up: an X release during a held button was delivered "
                      ~ "(the chord cleared; the reference loses that release for good)");
    keyDown(K_x, K_x_SCAN, "(i) free X down");
    keyUp(K_x, K_x_SCAN, "(i) free X up");
    assert(!chordOn(), "(i) positive control: a free X tap did not clear the chord");
    slLine("tool.set mesh.sliceTool off");
}

// ---------------------------------------------------------------------------
// (c)+(g) C-O5-es — Edge Slice, a third point held down: Ctrl+Z and Return are
// dropped (the chain stays live, the history does not move); after the release
// Ctrl+Z pops the third point and Return commits (positive controls).
// ---------------------------------------------------------------------------
enum int[2][3] HINT_OFF = [[315, 303], [531, 355], [616, 270]];

unittest {
    auto pro = slPrologue(false, "polygons", &slBackAndLeft, true);
    slLine("tool.set mesh.edgeSliceTool on");
    assert(slTool() == "edgeSlice", "(c) edge slice floor: the tool did not arm");
    const P = slFrontRightChain();
    int[2][3] px;
    foreach (k; 0 .. 3)
        px[k] = slEdgePixel(P[k][0], P[k][1], HINT_OFF[k], format("(c) point %d", k + 1));
    foreach (k; 0 .. 2) {
        slClickDown(px[k][0], px[k][1], format("(c) click %d", k + 1));
        slDragUp(px[k][0], px[k][1], 0, 4, 3, format("(c) drag %d", k + 1));
    }
    assert(slChain().pairs.length == 2, "(c) edge slice floor: two points did not latch");
    const H2 = slHistoryLen();
    slClickDown(px[2][0], px[2][1], "(c) point 3 press, held");
    ctrlZ("(c) Ctrl+Z while held");
    tap(K_RETURN, K_RETURN_SCAN, 0, "(g) Return while held");
    slDragUp(px[2][0], px[2][1], 0, 4, 3, "(c) point 3 drag + release");
    const c3 = slChain();
    assert(slTool() == "edgeSlice" && c3.pairs.length == 3 && slHistoryLen() == H2,
           format("(c)/(g) C-O5-es: a key reached Edge Slice while its button was held: tool '%s', "
                  ~ "%d point(s) after the release (expected 3), history %d (expected %d)",
                  slTool(), c3.pairs.length, slHistoryLen(), H2));
    ctrlZ("(c) Ctrl+Z after the release");
    assert(slChain().pairs.length == 2 && slTool() == "edgeSlice",
           format("(c) positive control: Ctrl+Z after the release did not pop point 3: %d point(s)",
                  slChain().pairs.length));
    tap(K_RETURN, K_RETURN_SCAN, 0, "(g) Return after the release");
    assert(slHistoryLen() == H2 + 1 && slChain().pairs.length == 0,
           format("(g) positive control: Return after the release did not commit: history %d "
                  ~ "(expected %d), %d point(s)", slHistoryLen(), H2 + 1, slChain().pairs.length));
    slLine("tool.set mesh.edgeSliceTool off");
    cast(void) pro;
}

// ---------------------------------------------------------------------------
// (j) C-H9-rmb — no tool, a held RIGHT-button lasso: W is dropped, not queued.
// (l) focus loss (SDL_WINDOWEVENT_FOCUS_LOST) clears the held set.
// (k) C-H9-orbit — Move armed, a held Alt+LMB orbit: Escape and E are dropped
//     (the orbit runs on); after the release both act.
// ---------------------------------------------------------------------------
unittest { // (j)
    resetCube();
    assert(slTool() == "", "(j) floor: a tool is armed after the reset: " ~ slTool());
    auto cam = fetchCamera();
    const x0 = cam.vpX + 20, y0 = cam.vpY + 20;
    string log = slMotion(10, x0, y0, 0) ~ "\n" ~ slButton(20, true, 3, x0, y0) ~ "\n";
    foreach (i; 1 .. 5) log ~= slMotion(20 + 20 * i, x0 + 15 * i, y0 + 5 * i, 4) ~ "\n";
    slPlay(log, "(j) RMB press + held lasso");
    tap(K_w, K_w_SCAN, 0, "(j) W while the lasso is held");
    assert(slTool() == "", "(j) C-H9-rmb: W reached the editor during a held RMB lasso: " ~ slTool());
    slPlay(slButton(20, false, 3, x0 + 60, y0 + 20), "(j) RMB release");
    assert(slTool() == "", "(j) C-H9-rmb: the dropped W was queued and ran at the release: " ~ slTool());
    tap(K_w, K_w_SCAN, 0, "(j) W after the release");
    assert(slTool() != "", "(j) positive control: W after the release armed nothing");
    slLine("tool.set move off");
}

unittest { // (l) focus loss clears the held set: a release the window never sees
    resetCube();
    assert(slTool() == "", "(l) floor: a tool is armed after the reset: " ~ slTool());
    auto cam = fetchCamera();
    const x0 = cam.vpX + 20, y0 = cam.vpY + 20;
    slPlay(slMotion(10, x0, y0, 0) ~ "\n" ~ slButton(20, true, 3, x0, y0) ~ "\n"
           ~ slMotion(40, x0 + 30, y0 + 10, 4), "(l) RMB press + held lasso");
    tap(K_w, K_w_SCAN, 0, "(l) W while held");
    assert(slTool() == "", "(l) floor: the held RMB did not lock the keys: " ~ slTool());
    slPlay(`{"t":20.0,"type":"SDL_WINDOWEVENT","sub":13}`, "(l) window focus lost");
    tap(K_w, K_w_SCAN, 0, "(l) W after the focus loss, button never released");
    assert(slTool() != "",
           "(l) focus loss did not clear the held buttons: W after it armed nothing");
    slPlay(slButton(20, false, 3, x0 + 30, y0 + 10), "(l) stray RMB release");
    slLine("tool.set move off");
}

unittest { // (k)
    resetCube();
    slLine("tool.set move");
    const moveId = toolSig();
    assert(moveId.length, "(k) floor: Move did not arm");
    auto cam = fetchCamera();
    const eye0 = cam.eye;
    const x0 = cam.vpX + cam.width / 2 + 120, y0 = cam.vpY + cam.height / 2 + 100;
    string log = motionMod(10, x0, y0, 0, KMOD_LALT_) ~ "\n"
               ~ buttonMod(20, true, 1, x0, y0, KMOD_LALT_) ~ "\n";
    foreach (i; 1 .. 5) log ~= motionMod(20 + 20 * i, x0 + 8 * i, y0, 1, KMOD_LALT_) ~ "\n";
    slPlay(log, "(k) Alt+LMB press + held orbit");
    const eye1 = fetchCamera().eye;
    assert(eye1.x != eye0.x || eye1.z != eye0.z, "(k) orbit floor: the held Alt+LMB did not orbit");
    tap(K_ESCAPE, K_ESCAPE_SCAN, 0, "(k) Escape during the orbit");
    tap(K_e, K_e_SCAN, 0, "(k) E during the orbit");
    assert(toolSig() == moveId,
           format("(k) C-H9-orbit: a key reached the editor during a held orbit: tool '%s' (was '%s')",
                  toolSig(), moveId));
    slPlay(motionMod(20, x0 + 40, y0, 1, KMOD_LALT_) ~ "\n"
           ~ buttonMod(40, false, 1, x0 + 40, y0, KMOD_LALT_) ~ "\n"
           ~ motionMod(60, x0 + 40, y0, 0, 0), "(k) orbit release");
    assert(toolSig() == moveId, "(k) C-H9-orbit: a dropped key was queued to the release: " ~ toolSig());
    tap(K_ESCAPE, K_ESCAPE_SCAN, 0, "(k) Escape after the release");
    assert(toolSig() != moveId,
           "(k) positive control: Escape after the release did not drop Move: " ~ toolSig());
}

// ---------------------------------------------------------------------------
// (h) THE BLEED — a press left without its release must not poison the NEXT
// test. Block h1 leaves LMB down (Move armed) and proves the lock is on; block
// h2 starts as every test does, with scene.reset, and needs the key.
// ---------------------------------------------------------------------------
unittest { // (h1)
    resetCube();
    slLine("tool.set move");
    auto cam = fetchCamera();
    const x0 = cam.vpX + 30, y0 = cam.vpY + cam.height - 30;
    slPlay(slMotion(10, x0, y0, 0) ~ "\n" ~ slButton(20, true, 1, x0, y0),
           "(h1) press-only log");
    assert(selMode() == "vertices", "(h1) floor: the reset left mode " ~ selMode());
    tap(K_2, K_2_SCAN, 0, "(h1) key 2 with the press left held");
    assert(selMode() == "vertices",
           "(h1) the press-only log did not lock the keys: key 2 switched to " ~ selMode());
}

unittest { // (h2)
    resetCube();
    tap(K_2, K_2_SCAN, 0, "(h2) key 2 after scene.reset");
    assert(selMode() == "edges",
           "(h2) a press left held by the previous block still locks the keys after "
           ~ "scene.reset (bleed channel 9): mode " ~ selMode());
    tap(49, 30, 0, "(h2) key 1 back to vertices");
}
