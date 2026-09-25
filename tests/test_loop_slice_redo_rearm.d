// test_loop_slice_redo_rearm.d — the Loop Slice session law (owner decisions
// В23/В26; verdicts `C1-ls-r verdict: LS-R-bare` and `C1-ls-arm verdict:
// RA-act`, toolcards/bugfix_w17_slice_tools; fixture
// tests/fixtures/slice_session_redo_and_rearm.json; gap rows 205 and 213).
//
// Arming with polygons selected is a history row and already cuts the loop;
// the drag of the arming press, and every later press..release (a motionless
// one included), is one Ctrl+Z step; the tool stays armed until the Ctrl+Z
// that pops the activation row; the navigate redo then re-arms at the ARM-TIME
// loop — not where the arming drag released, not the last scrub — and the redo
// after it is empty. Our gesture stack lives in the tool, not in the history:
// the history length is pinned as OUR model (gap 205), not as the law.
//
// Every gesture is real SDL input through /api/play-events; the undo and redo
// are keystrokes (the navigate chokepoint). Rig: tests/slice_leak_helpers.d,
// subpatch OFF, the front and right faces of the open box selected (their
// shared vertical edge seeds the ring). Scrub pixels are FRACTIONS of that
// edge's screen length, so every step lands a distinct loop position.
// Blocks M and M0 pin the Ctrl+Z during a drag: dropped, since no key
// dispatches while a mouse button is held (slice M1a, captured C-O5);
// blocks R2 and S came from the diff sweep (see each).

import slice_leak_helpers;
import http_client : getJson;
import drag_helpers : Vec3, fetchCamera, viewportFromCamera, projectToWindow;
import std.format : format;
import std.json : JSONType;
import std.math : abs, round;
import std.stdio : writeln;

void main() {}

void ctrlZ(string what)      { slKey(SL_SDLK_z, SL_KMOD_LCTRL, what); }
void ctrlShiftZ(string what) { slKey(SL_SDLK_z, SL_KMOD_LCTRL | SL_KMOD_LSHIFT, what); }

string topLabel() {
    auto l = slHistoryLabels();
    return l.length ? l[$ - 1] : "";
}

/// The Loop Slice fields this file reads. Since slice M3 the gesture steps
/// are the SESSION's: `gestureDepth` is `session.steps` and `armStateValid`
/// (the arm-time loop latched) is `session.live` — the window the arm opened
/// (`OpensAt.arm`). An absent `session` reads as depth -1, so a binary without
/// it can never satisfy a depth floor.
struct LsState {
    string tool;
    bool armed, dragging, armStateValid;
    long depth = -1;
    double pos0 = double.nan;
    string toString() const {
        return format("{tool '%s', armed %s, dragging %s, gestureDepth %d, positions[0] %s, "
                      ~ "armStateValid %s}", tool, armed, dragging, depth, pos0, armStateValid);
    }
}

LsState lsState() {
    auto s = getJson("/api/tool/state");
    LsState r;
    if ("tool" in s.object) r.tool = s["tool"].str;
    bool flag(string k) { return (k in s.object) !is null && s[k].type == JSONType.true_; }
    r.armed = flag("armed");
    r.dragging = flag("dragging");
    if ("session" in s.object && s["session"].type == JSONType.object) {
        auto ss = s["session"];
        r.armStateValid = ss["live"].type == JSONType.true_;
        r.depth = ss["steps"].integer;
    }
    if ("positions" in s.object && s["positions"].array.length) {
        auto p = s["positions"].array[0];
        r.pos0 = p.type == JSONType.integer ? cast(double)p.integer : p.floating;
    }
    return r;
}

/// The shared front/right vertical edge (the seed) on screen: pixel at
/// fraction `f` from its bottom end.
struct Rail { float ax, ay, bx, by; }

Rail seedRail() {
    auto m = getJson("/api/model");
    const lo = slCornerVert(m, 0.5, false, 0.5), hi = slCornerVert(m, 0.5, true, 0.5);
    assert(lo >= 0 && hi >= 0 && slEdgeOf(m, lo, hi) >= 0,
           "slice rig: the front/right vertical edge was not found");
    auto vp = viewportFromCamera(fetchCamera());
    auto a = m["vertices"].array[lo].array, b = m["vertices"].array[hi].array;
    Rail r;
    assert(projectToWindow(Vec3(a[0].floating, a[1].floating, a[2].floating), vp, r.ax, r.ay)
           && projectToWindow(Vec3(b[0].floating, b[1].floating, b[2].floating), vp, r.bx, r.by),
           "slice rig: the seed edge projects off screen");
    assert(abs(r.by - r.ay) > 40, format("slice rig: the seed edge is %.1f px tall on screen",
                                         abs(r.by - r.ay)));
    return r;
}

int[2] at(const Rail r, double f) {
    return [cast(int)round(r.ax + (r.bx - r.ax) * f), cast(int)round(r.ay + (r.by - r.ay) * f)];
}

/// Held motions from fraction f0 to f1 (button down), no press, no release.
void holdTo(const Rail r, double f0, double f1, string what) {
    string log;
    foreach (i; 1 .. 9) {
        const p = at(r, f0 + (f1 - f0) * i / 8.0);
        log ~= slMotion(20 + 20 * i, p[0], p[1], 1) ~ "\n";
    }
    slPlay(log, what);
}

void release(const Rail r, double f, string what) {
    const p = at(r, f);
    slPlay(slButton(20, false, 1, p[0], p[1]), what);
}

/// A whole press..release gesture from fraction f0 to f1 (f0 == f1: a click
/// with no motion at all).
void gesture(const Rail r, double f0, double f1, string what) {
    const p = at(r, f0);
    slClickDown(p[0], p[1], what ~ " (press)");
    if (f0 != f1) holdTo(r, f0, f1, what ~ " (drag)");
    release(r, f1, what ~ " (release)");
}

/// Prologue + the front/right face selection. Returns the history length.
long rig(out SlMesh base, out Rail rail) {
    slPrologue(false, "polygons", &slBackAndLeft, false);
    base = slMesh();
    assert(base.verts == 8 && base.faces == 4,
           "slice floor: the prologue is not the 8v/4f open box: " ~ base.toString);
    auto m = getJson("/api/model");
    const front = slFaceOnSide(m, 2, 1.0), right = slFaceOnSide(m, 0, 1.0);
    assert(front >= 0 && right >= 0, "slice rig: front/right faces not found");
    slCmd("mesh.select", format(`{"mode":"polygons","indices":[%d,%d]}`, front, right));
    rail = seedRail();
    return slHistoryLen();
}

enum double F_ARM = 0.5, F_A30 = 0.25, F_G1 = 0.7, F_G3 = 0.4;

// The main walk: arm, arming drag, g1, motionless g2, g3; Z1..Z5; redo; redo.
unittest {
    SlMesh base;
    Rail rail;
    const Hp = rig(base, rail);

    slLineUi("tool.set mesh.loopSliceTool on");
    assert(slTool() == "loopSlice", "slice floor: Loop Slice did not activate: " ~ slTool());
    assert(slHistoryLen() == Hp + 1 && topLabel() == "Activate Tool",
           format("loop slice arm wrote no activation row: history %s, prologue %d",
                  slHistoryLabels(), Hp));

    // The arming press, no motion: the arm-time loop.
    const pa = at(rail, F_ARM);
    slClickDown(pa[0], pa[1], "the arming press");
    const A0 = slMesh();
    const s0 = lsState();
    assert(s0.armed && A0.faces > 4 && s0.armStateValid,
           format("slice floor: the arming press did not arm a cut with its arm state: mesh %s, %s",
                  A0.toString, s0.toString));
    const pA0 = s0.pos0;
    holdTo(rail, F_ARM, F_A30, "the arming drag");
    release(rail, F_A30, "the arming release");
    const A30 = slMesh();
    assert(A30.canon != A0.canon, "slice floor: the arming drag did not move the loop");
    assert(lsState().depth == 1,
           format("the arming drag was not a gesture (gestureDepth after the arming drag): %s",
                  lsState().toString));

    gesture(rail, F_A30, F_G1, "g1");
    const G1 = slMesh();
    assert(G1.canon != A30.canon && lsState().depth == 2,
           format("slice floor: g1 did not move the loop into a second step: %s", lsState().toString));
    gesture(rail, F_G1, F_G1, "g2 (motionless click)");
    const G2 = slMesh();
    assert(G2.canon == G1.canon, "slice floor: the motionless click g2 moved the loop");
    assert(lsState().depth == 3,
           format("a motionless loop slice gesture was not pushed (gestureDepth after g2): %s",
                  lsState().toString));
    gesture(rail, F_G1, F_G3, "g3");
    const G3 = slMesh();
    assert(G3.canon != G2.canon && lsState().depth == 4,
           format("slice floor: g3 did not move the loop into a fourth step: %s", lsState().toString));
    assert(slHistoryLen() == Hp + 1,
           format("divergence (gap 205): our loop slice gestures live in the tool stack; the "
                  ~ "reference writes one row per gesture: history %s, prologue %d",
                  slHistoryLabels(), Hp));

    string which(const SlMesh m) {
        return m.canon == G3.canon ? "G3" : m.canon == G2.canon ? "G2/G1"
             : m.canon == A30.canon ? "A30" : m.canon == A0.canon ? "A0"
             : m.canon == base.canon ? "base" : "other " ~ m.toString;
    }

    ctrlZ("Z1");
    assert(slTool() == "loopSlice" && slMesh().canon == G2.canon,
           format("ctrl+z did not pop the newest loop slice gesture: tool '%s', mesh %s, %s",
                  slTool(), which(slMesh()), lsState().toString));
    ctrlZ("Z2");
    assert(slMesh().canon == G1.canon && lsState().depth == 2,
           format("a motionless loop slice gesture was not a separate undo step: mesh %s, %s",
                  which(slMesh()), lsState().toString));
    ctrlZ("Z3");
    assert(slMesh().canon == A30.canon && lsState().depth == 1,
           format("loop slice ctrl+z 3 did not return to the arming drag's loop: mesh %s, %s",
                  which(slMesh()), lsState().toString));
    ctrlZ("Z4");
    const z4 = lsState();
    assert(slMesh().canon == A0.canon && z4.armed && z4.depth == 0 && abs(z4.pos0 - pA0) <= 1e-6,
           format("loop slice ctrl+z did not return to the arm-time loop (reference: 0.4 armed): "
                  ~ "mesh %s, %s, arm-time position %s", which(slMesh()), z4.toString, pA0));
    ctrlZ("Z5");
    assert(slTool() != "loopSlice" && slMesh().canon == base.canon && slHistoryLen() == Hp,
           format("loop slice ctrl+z of its arm did not end the tool and pop its row: tool '%s', "
                  ~ "mesh %s, history %s, prologue %d", slTool(), which(slMesh()),
                  slHistoryLabels(), Hp));
    assert(slCanRedo(), "no redo after the loop slice session ended");

    ctrlShiftZ("Ctrl+Shift+Z (re-arm)");
    const r = lsState();
    const mr = slMesh();
    assert(slTool() == "loopSlice" && mr.canon == A0.canon && abs(r.pos0 - pA0) <= 1e-6
           && slHistoryLen() == Hp + 1,
           format("loop slice redo did not re-arm at the arm-time loop: tool '%s', mesh %s, %s, "
                  ~ "arm-time position %s, history %d (expected %d)", slTool(), which(mr),
                  r.toString, pA0, slHistoryLen(), Hp + 1));
    // Discrimination floors: the rivals RA-release (A30) and RA-last (G3).
    assert(A0.canon != A30.canon && A0.canon != G3.canon,
           "slice floor: the arm-time loop does not discriminate the redo rivals");
    // Released, not mid-drag: button-less motion along the rail.
    string log;
    foreach (i; 1 .. 7) {
        const p = at(rail, F_ARM - 0.05 * i);
        log ~= slMotion(20 + 20 * i, p[0], p[1], 0) ~ "\n";
    }
    slPlay(log, "button-less motion after the redo");
    assert(!lsState().dragging && slMesh().canon == A0.canon,
           format("loop slice redo left the tool mid-drag: mesh %s, %s",
                  which(slMesh()), lsState().toString));

    const redoBefore = slCanRedo();
    ctrlShiftZ("Ctrl+Shift+Z (second)");
    assert(!redoBefore && slMesh().canon == A0.canon && slTool() == "loopSlice"
           && slHistoryLen() == Hp + 1,
           format("redo after the loop slice re-arm is not empty: canRedo before %s, mesh %s, "
                  ~ "tool '%s', history %d", redoBefore, which(slMesh()), slTool(), slHistoryLen()));
    // The re-armed session is a session like the first: its Ctrl+Z ends it
    // again with its row, and the redo re-arms at the same loop.
    ctrlZ("Z6 (the re-armed session)");
    assert(slTool() != "loopSlice" && slMesh().canon == base.canon && slHistoryLen() == Hp,
           format("slice floor: Ctrl+Z on the re-armed session did not end it: tool '%s', "
                  ~ "mesh %s, history %s", slTool(), which(slMesh()), slHistoryLabels()));
    ctrlShiftZ("Ctrl+Shift+Z (second re-arm)");
    assert(slTool() == "loopSlice" && slMesh().canon == A0.canon
           && abs(lsState().pos0 - pA0) <= 1e-6,
           format("a re-armed loop slice session did not re-arm again at its arm-time loop: "
                  ~ "tool '%s', mesh %s, %s", slTool(), which(slMesh()), lsState().toString));
    writeln("loop slice redo re-arm: arm-time position ", pA0, " -> re-armed ", r.pos0);
    slLine("tool.set mesh.loopSliceTool off");
}

// Block R2 — the arm-time loop is the SESSION's, not a fresh tool's default:
// a Position typed before the arm is where the redo re-arms. Added by the
// diff sweep: without it, a replay that ignored the carried loop stayed green
// (the main walk's arm-time loop IS the default position).
unittest {
    SlMesh base;
    Rail rail;
    const Hp = rig(base, rail);
    slLineUi("tool.set mesh.loopSliceTool on");
    slLine("tool.attr mesh.loopSliceTool position 0.3");
    assert(slHistoryLen() == Hp + 1 && topLabel() == "Activate Tool",
           format("slice floor (block R2): the Position write moved the history: %s",
                  slHistoryLabels()));
    const pa = at(rail, F_ARM);
    slClickDown(pa[0], pa[1], "block R2 arming press");
    const A0 = slMesh();
    const pA0 = lsState().pos0;
    assert(abs(pA0 - 0.3) <= 1e-6 && A0.faces > 4,
           format("slice floor (block R2): the arm did not cut at the typed Position: %s",
                  lsState().toString));
    holdTo(rail, F_ARM, F_A30, "block R2 arming drag");
    release(rail, F_A30, "block R2 arming release");
    ctrlZ("block R2 Z1 (the arming drag)");
    ctrlZ("block R2 Z2 (the arm)");
    assert(slTool() != "loopSlice" && slHistoryLen() == Hp,
           format("slice floor (block R2): the session did not end: tool '%s', history %s",
                  slTool(), slHistoryLabels()));
    ctrlShiftZ("block R2 Ctrl+Shift+Z");
    assert(slTool() == "loopSlice" && slMesh().canon == A0.canon
           && abs(lsState().pos0 - pA0) <= 1e-6,
           format("loop slice redo did not keep the session's arm-time loop (typed Position %s): "
                  ~ "tool '%s', mesh equal %s, %s", pA0, slTool(), slMesh().canon == A0.canon,
                  lsState().toString));
    slLine("tool.set mesh.loopSliceTool off");
}

// Block S — an RMB cancel ends the arm with its steps: a later motionless
// re-arm has none, so its Ctrl+Z ends the session with the row. Added by the
// diff sweep: without it, keeping the stack across the cancel stayed green.
unittest {
    SlMesh base;
    Rail rail;
    const Hp = rig(base, rail);
    slLineUi("tool.set mesh.loopSliceTool on");
    gesture(rail, F_ARM, F_A30, "block S arming drag");
    gesture(rail, F_A30, F_G1, "block S g1");
    assert(lsState().depth == 2, "slice floor (block S): two steps before RMB: " ~ lsState().toString);
    const pr = at(rail, F_G1);
    slRmb(pr[0], pr[1]);
    assert(slTool() == "loopSlice" && !lsState().armed && slMesh().canon == base.canon,
           "slice floor (block S): RMB did not cancel the arm: " ~ lsState().toString);
    gesture(rail, F_ARM, F_ARM, "block S motionless re-arm");
    assert(lsState().armed, "slice floor (block S): the re-arm did not arm: " ~ lsState().toString);
    ctrlZ("block S Ctrl+Z");
    assert(slTool() != "loopSlice" && slMesh().canon == base.canon && slHistoryLen() == Hp,
           format("an RMB cancel left stale loop slice steps on the stack: tool '%s', %s, "
                  ~ "history %s", slTool(), lsState().toString, slHistoryLabels()));
}

// Block M — Ctrl+Z during a scrub is DROPPED (slice M1a): the scrub completes
// at its release as one step and the next Ctrl+Z pops it, tool still armed.
unittest {
    SlMesh base;
    Rail rail;
    rig(base, rail);
    slLineUi("tool.set mesh.loopSliceTool on");
    gesture(rail, F_ARM, F_A30, "block M arming drag");
    const A30 = slMesh();
    const pm = at(rail, F_A30);
    slClickDown(pm[0], pm[1], "block M g1 press");
    holdTo(rail, F_A30, F_G1, "block M g1 held drag");
    const mid = slMesh();
    assert(mid.canon != A30.canon && lsState().dragging,
           "slice floor (block M): the in-flight g1 did not move the loop");
    ctrlZ("block M Ctrl+Z mid-drag");
    const s = lsState();
    assert(slTool() == "loopSlice" && slMesh().canon == mid.canon && s.armed && s.dragging
           && s.depth == 1,
           format("a ctrl+z during a loop slice scrub reached the session (it must be dropped): "
                  ~ "tool '%s', mesh (in flight %s), %s", slTool(), slMesh().canon == mid.canon,
                  s.toString));
    release(rail, F_G1, "block M release");
    assert(slMesh().canon == mid.canon && lsState().depth == 2,
           "the release after a dropped mid-scrub ctrl+z did not keep g1 as a step: "
           ~ lsState().toString);
    ctrlZ("block M Ctrl+Z (g1)");
    const z = lsState();
    assert(slTool() == "loopSlice" && slMesh().canon == A30.canon && z.armed && z.depth == 1,
           format("ctrl+z after the release did not pop g1: tool '%s', mesh (A30 %s), %s",
                  slTool(), slMesh().canon == A30.canon, z.toString));
    slLine("tool.set mesh.loopSliceTool off");
}

// Block M0 — the same during the ARMING drag: dropped; the release makes the
// arming drag a step; the next Ctrl+Z returns to the arm-time loop.
unittest {
    SlMesh base;
    Rail rail;
    rig(base, rail);
    slLineUi("tool.set mesh.loopSliceTool on");
    const pa = at(rail, F_ARM);
    slClickDown(pa[0], pa[1], "block M0 arming press");
    const A0 = slMesh();
    holdTo(rail, F_ARM, F_A30, "block M0 held arming drag");
    const mid = slMesh();
    assert(mid.canon != A0.canon,
           "slice floor (block M0): the held arming drag did not move the loop");
    ctrlZ("block M0 Ctrl+Z mid-drag");
    const s = lsState();
    assert(slTool() == "loopSlice" && slMesh().canon == mid.canon && s.armed && s.dragging
           && s.depth == 0,
           format("a ctrl+z during the arming drag reached the session (it must be dropped): "
                  ~ "tool '%s', mesh (in flight %s), %s", slTool(), slMesh().canon == mid.canon,
                  s.toString));
    release(rail, F_A30, "block M0 release");
    assert(slMesh().canon == mid.canon && lsState().depth == 1,
           "the release after a dropped mid-arming-drag ctrl+z did not keep the drag as a step: "
           ~ lsState().toString);
    ctrlZ("block M0 Ctrl+Z (the arming drag)");
    const z = lsState();
    assert(slTool() == "loopSlice" && slMesh().canon == A0.canon && z.armed && z.depth == 0,
           format("ctrl+z after the release did not return to the arm-time loop: tool '%s', "
                  ~ "mesh (A0 %s), %s", slTool(), slMesh().canon == A0.canon, z.toString));
    slLine("tool.set mesh.loopSliceTool off");
}
