// Edge Extend — Shift and middle presses, and the undo / redo walk of an
// Edge Extend session (fixture cells `shift_press_after_haul_*`,
// `middle_press_after_haul_*`, `undo_after_*_after_haul`,
// `continuation_op_then_tool_switch_undo_walk`, `two_continuation_ops_undo_walk`,
// `plain_haul_after_undoing_continuation_op`, `redo_continuation_op_then_plain_haul`,
// `operation_after_restored_switch_undo_walk`,
// `motionless_first_click_then_haul_undo_walk` of
// tests/fixtures/edge_extend_gesture_laws.json; gaps 222/223/225/229-232/240/241).
//
// The measured law: a Shift press after a finished haul commits the run and
// starts a new operation from offset 0 (zero-length ring); a middle press does
// the same but re-applies the previous offset at the press; under symmetry both
// re-latch the side at their press. Ctrl+Z after a Shift or middle press pops
// the new operation whole and keeps the tool; the next Ctrl+Z removes the first
// run together with the tool (gap 225); only the newest operation is walked
// gesture by gesture, every earlier one - and one closed by a tool switch - goes
// in one step, the tool stays until the first run is popped (gap 229/230); after
// that undo a plain press opens a new operation from 0 (gap 231); Ctrl+Shift+Z
// brings the undone operation back live and a haul continues it (gap 232); a
// motionless first click is its own undo step (gap 240); an operation opened
// after an undone tool switch is popped alone and keeps the tool (gap 241).
//
// Real input only (play-events): Shift is `"mod":1` on down, motion and up;
// the middle button is `"btn":2` with motion mask 2; Alt+middle is the camera
// roll chord (`"mod":256`). Ctrl+Z / Ctrl+Shift+Z are keystrokes through the
// input router (the navHistory path) — never the raw `history.undo` command,
// except where the raw door IS the rig ((un3)).
//
// Rig: the file-6 rig (edge (7,8), 9 v / 4 f) in the FRONT ortho camera at
// 0.003125 m/px, so ten (+4,+4) increments are the capture's (0.125, -0.125, 0).
// Presses at world (0.5, 1.35) / (-0.5, 1.35), as captured. Prologue h1 of each
// block: the key arms the tool; the first press IS the haul (no click first).
//
// Block order is the evidence order: the controls and the boundaries HEAD
// keeps come first, then the laws; on HEAD the file's first red is (sc).

import edge_extend_gesture_helpers;
import http_client : getJson, postJson;
import std.algorithm : sort;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs, sqrt;

void main() {}

enum int[2][] kRidge = [[7, 8]];
enum double PX = 0.5, PY = 1.35;       // the capture's press point
enum double MX = -0.5;                 // the other side (symmetry cells)
enum double QX = -0.4, QY = 1.35;      // "another point" of empty space
enum Offset kO1 = Offset(0.125, -0.125, 0);

__gshared Offset ctl;       // (k): the ten-increment haul
__gshared Offset ctl5;      // (k): after its first five increments

// --- block-local helpers ----------------------------------------------------

double dist(Offset a, Offset b) {
    return sqrt((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2);
}

double mag(Offset a) { return dist(a, Offset(0, 0, 0)); }

bool zero(Offset a, double tol = 1e-9) {
    return abs(a.x) <= tol && abs(a.y) <= tol && abs(a.z) <= tol;
}

bool extendActive() { return toolId() == "edgeExtend"; }

/// The two NEWEST ring vertices, low y first.
double[3][] lastRing() {
    auto nv = newVertices();
    assert(nv.length >= 2, "no ring vertices: " ~ nv.to!string);
    auto r = nv[$ - 2 .. $].dup;
    r.sort!((a, b) => a[1] < b[1]);
    return r;
}

/// The ring at x = `x` from the rig's (y = 0, y = 1) ridge moved by (x - 1, dy).
bool ringAt(double[3][] r, double x, double dy, double tol) {
    return r.length == 2
        && abs(r[0][0] - x) <= tol && abs(r[0][1] - dy) <= tol && abs(r[0][2]) <= tol
        && abs(r[1][0] - x) <= tol && abs(r[1][1] - (1 + dy)) <= tol && abs(r[1][2]) <= tol;
}

/// Under symmetry: the newest ring on BOTH sides (four vertices), |x| of each.
double[] lastSymRingAbsX() {
    auto nv = newVertices();
    assert(nv.length >= 4, "no symmetric ring: " ~ nv.to!string);
    double[] xs;
    foreach (v; nv[$ - 4 .. $]) xs ~= v[0];
    return xs;
}

void assertSymRidges(double want, string msg) {
    auto xs = lastSymRingAbsX();
    size_t plus = 0, minus = 0;
    foreach (x; xs) {
        if (abs(x - want) <= 1e-4) ++plus;
        else if (abs(x + want) <= 1e-4) ++minus;
    }
    assert(plus == 2 && minus == 2, format("%s: ridges x %s, expected +-%s", msg, xs, want));
}

/// The rig with no tool: `recorded` = the selection is the one recorded edit.
size_t[] rig(bool recorded) { return rigNoArm(kRidge, true, 0.3, 0.55, recorded); }

/// Prologue h1: the key arms Edge Extend; the first press is the haul at P,
/// 10 x (+4,+4), released. Returns o1.
Offset prologue() {
    keyArm();
    auto tr = frontHaul(PX, PY, kIncrementPx, kIncrementPx, 10);
    immutable Offset o1 = offset();
    assert(tr.length == 10 && vertexCount() == 11 && abs(o1.x) > 0.05 && o1.x > 0,
        format("rig: the prologue haul did not build a ring (%d v, o1 %s)", vertexCount(), o1));
    return o1;
}

Px pP() { return frontScreen(PX, PY); }

/// Shift press at P held, `n` Shift increments, release; offsets per increment.
Offset[] shiftDrag(int n) {
    Px p = pP();
    press(p, 1, KMOD_LSHIFT);
    Px end;
    auto tr = increments(p, kIncrementPx, kIncrementPx, n, end, 1, KMOD_LSHIFT);
    release(end, 1, KMOD_LSHIFT);
    return tr;
}

// --- (k) control ------------------------------------------------------------

unittest { // (k) control: the prologue haul on a fresh rig
    rig(false);
    keyArm();
    auto tr = frontHaul(PX, PY, kIncrementPx, kIncrementPx, 10);
    assert(tr.length == 10, "control: read " ~ tr.length.to!string ~ " states");
    ctl = tr[9];
    ctl5 = tr[4];
    assert(abs(ctl.x) > 0.05, "control: the haul did not move: " ~ ctl.to!string);
    cmd("tool.set edge.extend off");
}

// --- boundaries HEAD keeps ----------------------------------------------------

unittest { // (N1) boundary, not a law: Shift press with no open run
    rig(false);
    keyArm();
    click(pP(), 1, KMOD_LSHIFT);
    assert(vertexCount() == 9 && !built() && extendActive(),
        "Shift press with no open run started an operation (not captured; HEAD kept): "
        ~ toolState().toString);
    cmd("tool.set edge.extend off");
}

unittest { // (N2) boundary: middle press with no open run
    rig(false);
    keyArm();
    immutable long h = undoLen();
    click(pP(), 2);
    assert(vertexCount() == 9 && !built() && undoLen() == h,
        "middle press with no open run started an operation (not captured; HEAD kept): "
        ~ toolState().toString);
    cmd("tool.set edge.extend off");
}

unittest { // (N3) positive control of middle-button delivery: Alt+middle rolls
    rig(false);
    immutable Offset o1 = prologue();
    immutable long h0 = undoLen();
    immutable double roll0 = num(getJson("/api/camera")["roll"]);
    Px p = pP();
    press(p, 2, KMOD_LALT);
    Px end;
    foreach (i; 0 .. 10) { p = Px(p.x + kIncrementPx, p.y); motion(p, kIncrementPx, 0, 2, KMOD_LALT); }
    release(p, 2, KMOD_LALT);
    assert(undoLen() == h0 && dist(offset(), o1) <= 1e-6,
        format("Alt+middle with Edge Extend active touched the run (it is the camera roll chord): "
             ~ "undo %d -> %d, offset %s -> %s", h0, undoLen(), o1, offset()));
    immutable double roll1 = num(getJson("/api/camera")["roll"]);
    assert(abs(roll1 - roll0) > 1e-3,
        format("instrument: middle-button events did not reach the router (Alt+middle did not roll): %s -> %s",
               roll0, roll1));
    cmd("tool.set edge.extend off");
}

// --- the Shift / middle laws (R13) ------------------------------------------

unittest { // (sc) Shift, motionless (shift_press_after_haul_motionless)
    rig(false);
    immutable Offset o1 = prologue();
    immutable long h0 = undoLen();
    Px p = pP();
    press(p, 1, KMOD_LSHIFT);
    assert(moveOffGizmo(), "rig: the Shift press did not reach Edge Extend as a press (moveOffGizmo false)");
    assertAnchorAt(PX, PY, "rig: the Shift press did not reach Edge Extend as a press");
    release(p, 1, KMOD_LSHIFT);
    assert(undoLen() == h0 + 1, "Shift press did not commit the finished run as its own step: "
        ~ (undoLen() - h0).to!string ~ " new records");
    assert(zero(offset()), "Shift press kept the previous offset (reference resets to 0, gap 222): "
        ~ offset().to!string);
    assert(vertexCount() == 13 && faceCount() == 6 && ringAt(lastRing(), 1 + o1.x, o1.y, 1e-6),
        format("motionless Shift click did not start a zero-length ring on the committed ridge (gap 222): "
             ~ "%d v / %d f, ring %s", vertexCount(), faceCount(), newVertices()));
    assert(built() && runStarted(), "Shift press: the new operation is not live: " ~ toolState().toString);
    cmd("tool.set edge.extend off");
    assert(vertexCount() == 13, "the zero-length ring of a Shift press was not committed: "
        ~ vertexCount().to!string ~ " v");
}

unittest { // (sd) Shift, drag (shift_press_after_haul_drag)
    rig(false);
    immutable Offset o1 = prologue();
    auto tr = shiftDrag(10);
    assert(tr.length == 10, "Shift drag: read " ~ tr.length.to!string ~ " states");
    assert(tr[0].x < 0.5 * o1.x, format("Shift drag continued from the previous offset (reference grows "
        ~ "from 0: k1 0.01, gap 222): o_1 %s, o1 %s", tr[0], o1));
    assert(dist(tr[9], ctl) <= 1e-4, format("Shift drag is not a fresh haul: o_10 %s, control %s", tr[9], ctl));
    assert(vertexCount() == 13, "Shift drag: " ~ vertexCount().to!string ~ " v, expected 13");
    auto r = lastRing();
    assert(abs(r[0][0] - (1 + o1.x + tr[9].x)) <= 1e-4 && abs(r[1][0] - (1 + o1.x + tr[9].x)) <= 1e-4,
        format("Shift drag did not grow a new ring from the committed ridge: ring %s, o1 %s, o_10 %s", r, o1, tr[9]));
    cmd("tool.set edge.extend off");
}

unittest { // (mc) middle, motionless (middle_press_after_haul_motionless)
    rig(false);
    immutable Offset o1 = prologue();
    immutable long h0 = undoLen();
    click(pP(), 2);
    assert(undoLen() == h0 + 1, "middle press did not commit the finished run as its own step "
        ~ "(reference: a new operation, gap 223): " ~ (undoLen() - h0).to!string ~ " new records");
    assert(dist(offset(), o1) <= 1e-6, format("middle press did not keep the previous offset: %s, o1 %s", offset(), o1));
    auto r = lastRing();
    assert(vertexCount() == 13 && faceCount() == 6
        && abs(r[0][0] - (1 + 2 * o1.x)) <= 1e-4 && abs(r[1][0] - (1 + 2 * o1.x)) <= 1e-4,
        format("motionless middle click did not re-apply the previous offset at the press (reference: "
             ~ "second ring displaced by o1, gap 223): %d v / %d f, ring %s", vertexCount(), faceCount(), r));
    assert(built(), "middle press: the new operation is not live");
    cmd("tool.set edge.extend off");
}

unittest { // (md) middle, drag (middle_press_after_haul_drag)
    rig(false);
    immutable Offset o1 = prologue();
    Px p = pP();
    press(p, 2);
    Px end;
    auto tr = increments(p, kIncrementPx, kIncrementPx, 10, end, 2);
    assert(tr.length == 10, "middle drag: read " ~ tr.length.to!string ~ " states");
    assert(tr[0].x > o1.x, format("middle drag did not continue from the previous offset (reference: "
        ~ "k1 0.135, gap 223): o_1 %s, o1 %s", tr[0], o1));
    immutable Offset want = Offset(o1.x + ctl.x, o1.y + ctl.y, o1.z + ctl.z);
    assert(dist(tr[9], want) <= 1e-4, format("middle drag offset is not o1 plus a haul: %s, expected %s", tr[9], want));
    assert(vertexCount() == 13, "middle drag: " ~ vertexCount().to!string ~ " v, expected 13");
    release(end, 2);
    immutable Offset atRelease = offset();
    hover(Px(end.x + 40, end.y), 40, 0);
    assert(dist(offset(), atRelease) <= 1e-9, format("middle release did not end the extend drag: %s -> %s",
                                                     atRelease, offset()));
    // The closing LEFT haul at another point: must be an off-handle press.
    Px q = frontScreen(QX, QY);
    press(q);
    assert(moveOffGizmo(), "rig: the closing left press grabbed a handle (not an off-handle haul): moveOffGizmo false");
    assertAnchorAt(QX, QY, "rig: the closing left press grabbed a handle (not an off-handle haul)");
    Px qEnd;
    auto tq = increments(q, kIncrementPx, kIncrementPx, 5, qEnd);
    release(qEnd);
    immutable Offset gain = Offset(tq[4].x - atRelease.x, tq[4].y - atRelease.y, tq[4].z - atRelease.z);
    assert(vertexCount() == 13 && dist(gain, ctl5) <= 1e-4,
        format("a left haul after a middle drag did not continue the new operation (a bank was left "
             ~ "mid-drag): %d v, gain %s, control %s", vertexCount(), gain, ctl5));
    cmd("tool.set edge.extend off");
}

unittest { // (ss) Shift under symmetry X (shift_press_after_haul_symmetry_other_side)
    symSelRig();
    keyArm();
    auto tr1 = frontHaul(PX, PY, kIncrementPx, kIncrementPx, 10);
    assert(pressAnchor()[0] > 0.05, "rig: the first press was not on the +X side");
    immutable Offset o1 = offset();
    assertSymRidges(1 + o1.x, "first off-handle press did not latch +X");
    Px m = frontScreen(MX, PY);
    press(m, 1, KMOD_LSHIFT);
    assert(pressAnchor()[0] < -0.05, "rig: the Shift press was not on the -X side: " ~ pressAnchor().to!string);
    Px end;
    auto tr = increments(m, kIncrementPx, kIncrementPx, 10, end, 1, KMOD_LSHIFT);
    release(end, 1, KMOD_LSHIFT);
    assert(tr.length == 10, "Shift drag under symmetry: read " ~ tr.length.to!string ~ " states");
    assert(vertexCount() == 17, "Shift press under symmetry did not start a new ring on both sides: "
        ~ vertexCount().to!string ~ " v");
    assertSymRidges(1 + o1.x - tr[9].x, "Shift press under symmetry did not re-latch the side at the press "
        ~ "(reference: -X press -> inward, +-1.125 -> +-1.0, gap 222)");
    cmd("tool.set edge.extend off");
}

unittest { // (ms) middle under symmetry X (middle_press_after_haul_symmetry_other_side)
    symSelRig();
    keyArm();
    frontHaul(PX, PY, kIncrementPx, kIncrementPx, 10);
    assert(pressAnchor()[0] > 0.05, "rig: the first press was not on the +X side");
    immutable Offset o1 = offset();
    assertSymRidges(1 + o1.x, "first off-handle press did not latch +X");
    Px m = frontScreen(MX, PY);
    press(m, 2);
    assert(pressAnchor()[0] < -0.05, "rig: the middle press was not on the -X side: " ~ pressAnchor().to!string);
    assert(vertexCount() == 17, "middle press under symmetry did not re-apply the previous offset on the new "
        ~ "press side at the press (reference +-1.125 -> +-1.0 before motion, gap 223): "
        ~ vertexCount().to!string ~ " v");
    assertSymRidges(1 + o1.x - o1.x, "middle press under symmetry did not re-apply the previous offset on the "
        ~ "new press side at the press (reference +-1.125 -> +-1.0 before motion, gap 223)");
    Px end;
    auto tr = increments(m, kIncrementPx, kIncrementPx, 10, end, 2);
    assert(tr.length == 10, "middle drag under symmetry: read " ~ tr.length.to!string ~ " states");
    assertSymRidges(1 + o1.x - tr[9].x, "middle drag under symmetry did not continue on the new side");
    release(end, 2);
    cmd("tool.set edge.extend off");
}

// --- the undo walk after a Shift / middle press (R14) -------------------------

/// (ua)/(ub) body: the second gesture was a motionless click with `btn`/`mod`.
void undoAfterClick(int btn, int mod, string sfx, bool middle) {
    auto sel0 = rig(true);
    immutable Offset o1 = prologue();
    immutable long h0 = undoLen();
    click(pP(), btn, mod);
    if (middle)
        assert(vertexCount() == 13 && dist(offset(), o1) <= 1e-6 && undoLen() == h0 + 1,
            format("rig: the middle press did not open a new operation (gap 223 path): %d v, offset %s, %d new records",
                   vertexCount(), offset(), undoLen() - h0));
    else
        assert(vertexCount() == 13 && zero(offset()) && undoLen() == h0 + 1,
            format("rig: the Shift press did not open a new operation (gap 222 path): %d v, offset %s, %d new records",
                   vertexCount(), offset(), undoLen() - h0));
    ctrlZ();
    assert(undoLen() == h0 + 1, "Ctrl+Z after a Shift press walked the document history instead of popping "
        ~ "the new operation (gap 225)" ~ sfx);
    assert(vertexCount() == 11, "Ctrl+Z after a Shift press did not remove the new operation's ring (gap 225)"
        ~ sfx ~ ": " ~ vertexCount().to!string ~ " v");
    assert(ringAt(lastRing(), 1 + o1.x, o1.y, 1e-6), "Ctrl+Z after a Shift press removed the committed first "
        ~ "ring (reference keeps it, gap 225)" ~ sfx ~ ": " ~ newVertices().to!string);
    assert(extendActive(), "Ctrl+Z after a Shift press ended the tool (reference: the tool stays, gap 225)" ~ sfx);
    if (middle)
        assert(dist(offset(), o1) <= 1e-6, "panel after the undo does not show the new operation's start value "
            ~ "(reference: the previous offset after a middle press, gap 225): " ~ offset().to!string);
    else
        assert(zero(offset()), "panel after the undo does not show the new operation's start value "
            ~ "(reference: 0 after Shift, gap 225): " ~ offset().to!string);
    assert(!built(), "Ctrl+Z after a Shift press left the operation live" ~ sfx);
    ctrlZ();
    assert(undoLen() == h0 && vertexCount() == 9,
        format("second Ctrl+Z after a Shift press did not remove the first run (gap 225)%s: %d records, %d v",
               sfx, undoLen() - h0, vertexCount()));
    assert(!extendActive(), "second Ctrl+Z after a Shift press did not end the tool (reference: the first run "
        ~ "carries the activation, gap 225/218)" ~ sfx);
    ctrlZ();
    assert(selectedEdgeList() == sel0, "third Ctrl+Z after a Shift press did not undo the edit before the tool "
        ~ "(gap 225)" ~ sfx ~ ": " ~ selectedEdgeList().to!string);
}

unittest { // (ua) Shift click, then Ctrl+Z x3 (undo_after_shift_click_after_haul)
    undoAfterClick(1, KMOD_LSHIFT, "", false);
}

unittest { // (ub) middle click, then Ctrl+Z x3 (undo_after_middle_click_after_haul)
    undoAfterClick(2, 0, " (middle)", true);
}

unittest { // (uc) Shift drag, then Ctrl+Z x3 (undo_after_shift_drag_after_haul)
    enum sfx = " (drag)";
    auto sel0 = rig(true);
    immutable Offset o1 = prologue();
    immutable long h0 = undoLen();
    auto tr = shiftDrag(10);
    assert(tr.length == 10 && vertexCount() == 13 && mag(tr[9]) > 0.05,
        format("rig: the Shift drag did not move the new operation: %d v, trace %s", vertexCount(), tr));
    ctrlZ();
    assert(undoLen() == h0 + 1, "Ctrl+Z after a Shift press walked the document history instead of popping "
        ~ "the new operation (gap 225)" ~ sfx);
    assert(vertexCount() == 11, "Ctrl+Z after a Shift press did not remove the new operation's ring (gap 225)"
        ~ sfx ~ ": " ~ vertexCount().to!string ~ " v");
    assert(ringAt(lastRing(), 1 + o1.x, o1.y, 1e-6), "Ctrl+Z after a Shift press removed the committed first "
        ~ "ring (reference keeps it, gap 225)" ~ sfx ~ ": " ~ newVertices().to!string);
    assert(extendActive(), "Ctrl+Z after a Shift press ended the tool (reference: the tool stays, gap 225)" ~ sfx);
    assert(zero(offset()), "Ctrl+Z after a Shift drag left the dragged offset in the panel (reference: the "
        ~ "new operation's start value 0, gap 225): " ~ offset().to!string);
    ctrlZ();
    assert(undoLen() == h0 && vertexCount() == 9,
        format("second Ctrl+Z after a Shift press did not remove the first run (gap 225)%s: %d records, %d v",
               sfx, undoLen() - h0, vertexCount()));
    assert(!extendActive(), "second Ctrl+Z after a Shift press did not end the tool (reference: the first run "
        ~ "carries the activation, gap 225/218)" ~ sfx);
    ctrlZ();
    assert(selectedEdgeList() == sel0, "third Ctrl+Z after a Shift press did not undo the edit before the tool "
        ~ "(gap 225)" ~ sfx);
}

unittest { // (uf) instance of the T-live law (gap 230); this rig was not driven
    auto sel0 = rig(true);
    prologue();
    immutable long h0 = undoLen();
    auto tr = shiftDrag(10);
    assert(tr.length == 10 && vertexCount() == 13 && mag(tr[9]) > 0.05,
        format("rig: the Shift drag did not move the new operation: %d v, trace %s", vertexCount(), tr));
    immutable Offset og1 = offset();
    frontHaul(QX, QY, kIncrementPx, kIncrementPx, 5);
    assert(vertexCount() == 13 && dist(offset(), og1) > 0.02,
        format("rig: the second gesture did not move the continued operation: %d v, %s -> %s",
               vertexCount(), og1, offset()));
    ctrlZ();
    assert(undoLen() == h0 + 1, "Ctrl+Z #1 in a multi-gesture continued operation walked the document history (gap 230)");
    assert(vertexCount() == 13, "Ctrl+Z #1 in a multi-gesture continued operation removed more than its last "
        ~ "gesture (reference: gesture by gesture in the open operation, gap 230): " ~ vertexCount().to!string ~ " v");
    assert(extendActive(), "Ctrl+Z #1 in a multi-gesture continued operation ended the tool (gap 230)");
    assert(dist(offset(), og1) <= 1e-5, format("Ctrl+Z #1 did not restore the end of the first gesture (gap 230): "
        ~ "%s, expected %s", offset(), og1));
    ctrlZ();
    assert(vertexCount() == 11 && extendActive(),
        format("Ctrl+Z #2 in a multi-gesture continued operation did not pop the operation whole (gap 230): %d v",
               vertexCount()));
    assert(zero(offset()), "undoing a multi-gesture continued operation did not restore the operation's start "
        ~ "value (gap 225/230): " ~ offset().to!string);
    cmd("tool.set edge.extend off");
}

void stepFloor(string name, size_t v, Offset o, double ringX) {
    assert(vertexCount() == v && dist(offset(), o) <= 1e-4
        && (ringX != ringX || abs(lastRing()[0][0] - ringX) <= 1e-4),
        format("rig: step %s did not match the capture (fixture after_steps): %d v, offset %s, ring %s",
               name, vertexCount(), offset(), newVertices()));
}

unittest { // (ut) T-live (two_continuation_ops_undo_walk)
    rig(true);
    prologue();
    immutable long h0 = undoLen();
    click(pP(), 1, KMOD_LSHIFT);
    stepFloor("s1", 13, Offset(0, 0, 0), double.nan);
    frontHaul(PX, PY, kIncrementPx, kIncrementPx, 10);
    stepFloor("h2", 13, kO1, 1.25);
    click(pP(), 1, KMOD_LSHIFT);
    stepFloor("s2", 15, Offset(0, 0, 0), double.nan);
    assert(undoLen() == h0 + 2, "rig: step s2 did not match the capture (fixture after_steps): "
        ~ (undoLen() - h0).to!string ~ " new records");
    frontHaul(PX, PY, kIncrementPx, kIncrementPx, 10);
    stepFloor("h3", 15, kO1, 1.375);
    ctrlZ();
    assert(undoLen() == h0 + 2, "Ctrl+Z #1 in the newest continued operation walked the document history (gap 230)");
    assert(vertexCount() == 15, "Ctrl+Z #1 popped the whole newest operation instead of its last gesture "
        ~ "(reference: 15 v, zero-length ring kept, gap 230): " ~ vertexCount().to!string ~ " v");
    assert(ringAt(lastRing(), 1.25, -0.25, 1e-6), "Ctrl+Z #1 in the newest continued operation did not leave "
        ~ "the zero-length ring: " ~ newVertices().to!string);
    assert(zero(offset()), "Ctrl+Z #1 in the newest continued operation: panel " ~ offset().to!string ~ ", expected 0");
    assert(extendActive(), "Ctrl+Z #1 in the newest continued operation ended the tool (gap 230)");
    ctrlZ();
    assert(undoLen() == h0 + 2 && vertexCount() == 13 && extendActive(),
        format("undoing the opening Shift click of the newest operation ended the tool (gap 230): %d records, %d v, tool %s",
               undoLen() - h0, vertexCount(), toolId()));
    ctrlZ();
    assert(undoLen() == h0 + 1 && vertexCount() == 11,
        format("Ctrl+Z #3 did not pop the earlier continued operation whole (gap 230): %d records, %d v",
               undoLen() - h0, vertexCount()));
    assert(extendActive(), "an earlier continued operation undone whole ended the tool (reference: the tool "
        ~ "stays until the first run is popped, gap 230)");
    assert(zero(offset()), "the panel changed when history popped a closed operation (reference: unchanged, "
        ~ "gap 229/230): " ~ offset().to!string);
    ctrlZ();
    assert(undoLen() == h0 && vertexCount() == 9 && !extendActive(),
        format("Ctrl+Z #4 did not pop the first run with the tool: %d records, %d v, tool %s",
               undoLen() - h0, vertexCount(), toolId()));
}

unittest { // (ue) instance of the T-live law (gap 230); this rig was not driven
    rig(true);
    prologue();
    immutable long h0 = undoLen();
    click(pP(), 1, KMOD_LSHIFT);
    click(pP(), 1, KMOD_LSHIFT);
    assert(vertexCount() == 15 && undoLen() == h0 + 2,
        format("rig: two Shift clicks did not open two operations: %d v, %d new records",
               vertexCount(), undoLen() - h0));
    ctrlZ();
    assert(vertexCount() == 13 && extendActive(),
        format("Ctrl+Z #1 after two Shift clicks did not pop the newest operation alone: %d v, tool %s",
               vertexCount(), toolId()));
    ctrlZ();
    assert(vertexCount() == 11 && extendActive(),
        format("undoing an earlier continued operation ended the tool (reference: the tool stays until the "
             ~ "first run is popped, gap 230): %d v, tool %s", vertexCount(), toolId()));
    ctrlZ();
    assert(vertexCount() == 9 && !extendActive(),
        format("Ctrl+Z #3 after two Shift clicks did not pop the first run with the tool: %d v, tool %s",
               vertexCount(), toolId()));
}

unittest { // (uk) K-op (continuation_op_then_tool_switch_undo_walk)
    auto sel0 = rig(true);
    prologue();
    immutable long h0 = undoLen();
    click(pP(), 1, KMOD_LSHIFT);
    stepFloor("s1", 13, Offset(0, 0, 0), double.nan);
    frontHaul(PX, PY, kIncrementPx, kIncrementPx, 10);
    stepFloor("h2", 13, kO1, 1.25);
    tapKey(kScaleKey);
    settle(250);
    assert(toolId() == "xfrm" && undoLen() == h0 + 3,
        format("rig: the switch did not commit the continued operation behind the scale row: tool %s, %d new records",
               toolId(), undoLen() - h0));
    ctrlZ();
    assert(extendActive(), "undo of the switch did not return Edge Extend (gap 229/221): tool " ~ toolId());
    assert(vertexCount() == 13, "undo of the switch changed the geometry: " ~ vertexCount().to!string ~ " v");
    assert(undoLen() == h0 + 2, "undo of the switch: " ~ (undoLen() - h0).to!string ~ " new records, expected 2");
    assert(dist(offset(), kO1) <= 1e-4, "undo of the switch: panel " ~ offset().to!string ~ ", expected 0.125");
    ctrlZ();
    assert(undoLen() == h0 + 1 && vertexCount() == 11 && ringAt(lastRing(), 1.125, -0.125, 1e-6),
        format("Ctrl+Z #2 after a switch did not pop the continued operation whole (gap 229): %d records, %d v, %s",
               undoLen() - h0, vertexCount(), newVertices()));
    assert(extendActive(), "Ctrl+Z #2 after a switch from a continued operation ended the tool with the first "
        ~ "run still present (reference: the tool stays, gap 229)");
    assert(dist(offset(), kO1) <= 1e-4, "the panel changed when history popped a closed operation (reference: "
        ~ "unchanged, gap 229/230): " ~ offset().to!string);
    ctrlZ();
    assert(undoLen() == h0 && vertexCount() == 9 && !extendActive(),
        format("third Ctrl+Z after a switch from a continued operation did not end the tool (reference: the "
             ~ "first run carries the activation, gap 229): %d records, %d v, tool %s",
               undoLen() - h0, vertexCount(), toolId()));
    ctrlZ();
    assert(selectedEdgeList() == sel0, "fourth Ctrl+Z after a switch did not undo the edit before the tool");
}

// --- law SR-op (gap 241) ------------------------------------------------------

unittest { // (sr) law SR-op (gap 241) (operation_after_restored_switch_undo_walk)
    auto sel0 = rig(true);
    prologue();
    assert(dist(offset(), kO1) <= 1e-4, "rig: the prologue haul is not the capture's o1: " ~ offset().to!string);
    immutable long h0 = undoLen();
    tapKey(kScaleKey);
    settle(250);
    assert(toolId() == "xfrm" && undoLen() == h0 + 2,
        format("rig: the switch did not commit the run behind the scale row: tool %s, %d new records",
               toolId(), undoLen() - h0));
    ctrlZ();
    assert(extendActive() && vertexCount() == 11 && undoLen() == h0 + 1 && dist(offset(), kO1) <= 1e-4,
        format("rig: the undo of the switch did not restore Edge Extend with the run's value (F10, gap 221): "
             ~ "tool %s, %d v, %d records", toolId(), vertexCount(), undoLen() - h0));
    frontHaul(PX, PY, kIncrementPx, kIncrementPx, 10);
    assert(vertexCount() == 13 && dist(offset(), kO1) <= 1e-4 && ringAt(lastRing(), 1.25, -0.25, 1e-4),
        format("rig: the haul after the restore did not open a new ring from 0 (fixture after_second_haul): "
             ~ "%d v, offset %s, %s", vertexCount(), offset(), newVertices()));
    ctrlZ();
    assert(undoLen() == h0 + 1, "Ctrl+Z after a haul in a restored Edge Extend walked the document history (gap 241)");
    assert(vertexCount() == 11, "Ctrl+Z after a haul in a restored Edge Extend removed more than the new "
        ~ "operation (reference: 11 v, gap 241): " ~ vertexCount().to!string ~ " v");
    assert(extendActive(), "Ctrl+Z after a haul in a restored Edge Extend ended the tool (reference: the new "
        ~ "operation pops alone and the tool stays, gap 241)");
    assert(zero(offset()), "the panel did not return to the new operation's start (reference: 0, gap 241): "
        ~ offset().to!string);
    assert(ringAt(lastRing(), 1.125, -0.125, 1e-4), "Ctrl+Z after a haul in a restored Edge Extend did not "
        ~ "leave the first ring: " ~ newVertices().to!string);
    ctrlZ();
    assert(vertexCount() == 9 && undoLen() == h0 && !extendActive(),
        format("second Ctrl+Z after a restored operation did not pop the first run with the activation (gap 241): "
             ~ "%d v, %d records, tool %s", vertexCount(), undoLen() - h0, toolId()));
    ctrlZ();
    assert(selectedEdgeList() == sel0, "third Ctrl+Z did not undo the edit before the tool");
}

// --- N-new-noact, D-live and their boundaries (R15) ---------------------------

/// The shared lead of (un)...(un3): prologue, Shift drag, Ctrl+Z; returns H0.
long undoneContinuation() {
    rig(true);
    prologue();
    immutable long h0 = undoLen();
    shiftDrag(10);
    assert(vertexCount() == 13 && dist(offset(), kO1) <= 1e-4 && undoLen() == h0 + 1,
        format("rig: the Shift drag did not open a new operation from 0 (gap 222): %d v, offset %s, %d records",
               vertexCount(), offset(), undoLen() - h0));
    ctrlZ();
    assert(vertexCount() == 11 && zero(offset()) && extendActive(),
        format("rig: the undo did not pop the continued operation (gap 225): %d v, offset %s, tool %s",
               vertexCount(), offset(), toolId()));
    return h0;
}

unittest { // (un) N-new-noact (plain_haul_after_undoing_continuation_op)
    immutable long h0 = undoneContinuation();
    auto tr = frontHaul(QX, QY, kIncrementPx, kIncrementPx, 10);
    assert(tr.length == 10, "haul after the undo: read " ~ tr.length.to!string ~ " states");
    assert(vertexCount() == 13, "a haul after undoing a continued operation did not open a new operation over "
        ~ "the committed run (reference: 11 -> 13 v, gap 231): " ~ vertexCount().to!string ~ " v");
    assert(tr[0].x < 0.05 && dist(tr[9], kO1) <= 1e-4, format("a haul after undoing a continued operation did "
        ~ "not start from 0 (reference 0.01 -> 0.125, gap 231): o_1 %s, o_10 %s", tr[0], tr[9]));
    auto nv = newVertices();
    assert(nv.length == 4 && ringAt(nv[0 .. 2].dup, 1.125, -0.125, 1e-4) && ringAt(lastRing(), 1.25, -0.25, 1e-4),
        "a haul after undoing a continued operation: rings are not 1.125 and 1.25: " ~ nv.to!string);
    cmd("tool.set edge.extend off");
    assert(undoLen() == h0 + 2, "the new operation recorded an activation row (reference: none, gap 231): "
        ~ (undoLen() - h0).to!string ~ " new records");
}

unittest { // (un2) the redo is dropped by a new press
    undoneContinuation();
    auto tr = frontHaul(QX, QY, kIncrementPx, kIncrementPx, 5);
    immutable Offset o5 = tr[4];
    assert(dist(o5, kO1) > 0.03, "rig: the new operation ended where the undone one did (redo cannot be told apart): "
        ~ o5.to!string);
    ctrlShiftZ();
    assert(dist(offset(), o5) <= 1e-6 && vertexCount() == 13,
        format("redo after a new operation re-opened the undone one (reference: the new operation drops the redo "
             ~ "rows, gap 231): offset %s, o_5 %s, %d v", offset(), o5, vertexCount()));
    cmd("tool.set edge.extend off");
}

unittest { // (up) boundary, not captured
    undoneContinuation();
    typePanel("tool.attr edge.extend offsetX 0.3");
    assert(built() && vertexCount() == 13, format("rig: the panel edit after the undo did not open an operation "
        ~ "(F8t): built %s, %d v", built(), vertexCount()));
    ctrlShiftZ();
    assert(abs(offset().x - 0.3) <= 1e-6, "boundary (not captured): a redo replaced the operation a panel edit "
        ~ "opened after the undo: offsetX " ~ offset().x.to!string);
    cmd("tool.set edge.extend off");
}

/// (ud)'s whole body, shared with (ud2).
long redoneAndHauled() {
    immutable long h0 = undoneContinuation();
    ctrlShiftZ();
    assert(extendActive(), "Ctrl+Shift+Z after undoing a continued operation ended the tool (gap 232)");
    assert(vertexCount() == 13, "Ctrl+Shift+Z after undoing a continued operation did not bring it back "
        ~ "(reference: 13 v, gap 232): " ~ vertexCount().to!string ~ " v");
    assert(dist(offset(), kO1) <= 1e-4, "the redone operation does not show its own value (reference: 0.125, "
        ~ "gap 232): " ~ offset().to!string);
    auto nv = newVertices();
    assert(nv.length == 4 && ringAt(nv[0 .. 2].dup, 1.125, -0.125, 1e-4) && ringAt(lastRing(), 1.25, -0.25, 1e-4),
        "the redone operation: rings are not 1.125 and 1.25: " ~ nv.to!string);
    assert(built(), "the redone operation is not live (gap 232)");
    assert(undoLen() == h0 + 1, "the live redo wrote a history record: " ~ (undoLen() - h0).to!string);
    auto tr = frontHaul(QX, QY, kIncrementPx, kIncrementPx, 10);
    assert(tr.length == 10, "haul after the redo: read " ~ tr.length.to!string ~ " states");
    assert(vertexCount() == 13, "a haul after the redo started a new ring (reference continues the redone "
        ~ "operation, gap 232): " ~ vertexCount().to!string ~ " v");
    assert(tr[0].x > 0.125 && dist(tr[9], Offset(0.25, -0.25, 0)) <= 1e-4, format("a haul after the redo did not "
        ~ "continue from the redone operation's value (reference 0.135 -> 0.25, gap 232): o_1 %s, o_10 %s", tr[0], tr[9]));
    assert(ringAt(lastRing(), 1.375, -0.375, 1e-4), "a haul after the redo: ring is not at 1.375: " ~ newVertices().to!string);
    return h0;
}

unittest { // (ud) D-live (redo_continuation_op_then_plain_haul)
    redoneAndHauled();
    cmd("tool.set edge.extend off");
}

unittest { // (ud2) boundary, not captured
    redoneAndHauled();
    ctrlZ();
    assert(vertexCount() == 13 && dist(offset(), kO1) <= 1e-5, format("boundary (not captured): undo after a haul "
        ~ "in a redone operation removed more than that haul: %d v, offset %s", vertexCount(), offset()));
    ctrlZ();
    assert(vertexCount() == 11 && extendActive() && zero(offset()),
        format("boundary (not captured): the second undo did not pop the redone operation whole: %d v, tool %s, offset %s",
               vertexCount(), toolId(), extendActive() ? offset().to!string : "-"));
    cmd("tool.set edge.extend off");
}

unittest { // (un3) invariant of our code, not a reference law; the second redo is a boundary, not captured
    undoneContinuation();
    cmd("history.undo");
    settle();
    assert(extendActive() && vertexCount() == 9, format("rig: the raw undo dropped the tool or did not pop the "
        ~ "first run (the stash key cannot be exercised): tool %s, %d v", toolId(), vertexCount()));
    ctrlShiftZ();
    assert(vertexCount() == 11 && !built(), format("a live redo re-opened an operation after the history moved "
        ~ "under it (the stash is keyed on the undo top): %d v, built %s", vertexCount(), built()));
    ctrlShiftZ();
    assert(vertexCount() == 11 && !built(), format("boundary (not captured): a second redo re-opened the undone "
        ~ "operation after the history had moved under it (the live stash is one-shot): %d v, built %s",
        vertexCount(), built()));
    cmd("tool.set edge.extend off");
}

// --- law F-step (gap 240) -----------------------------------------------------

unittest { // (uz) law F-step (gap 240) (motionless_first_click_then_haul_undo_walk)
    auto sel0 = rig(true);
    keyArm();
    immutable long h0 = undoLen();
    click(pP());
    auto nv = newVertices();
    assert(vertexCount() == 11 && zero(offset()) && built()
        && nv.length == 2 && ringAt(lastRing(), 1.0, 0.0, 1e-6),
        format("rig: the first click did not start a zero-length ring (F8): %d v, offset %s, built %s, %s",
               vertexCount(), offset(), built(), nv));
    auto tr = frontHaul(PX, PY, kIncrementPx, kIncrementPx, 10);
    assert(tr.length == 10 && vertexCount() == 11 && dist(offset(), kO1) <= 1e-4
        && ringAt(lastRing(), 1.125, -0.125, 1e-4),
        format("rig: the haul did not match the capture (fixture after_haul): %d v, offset %s, %s",
               vertexCount(), offset(), newVertices()));
    ctrlZ();
    assert(undoLen() == h0, "Ctrl+Z #1 after a motionless first click and a haul walked the document history (gap 240)");
    assert(vertexCount() == 11, "Ctrl+Z #1 after a motionless first click and a haul removed the click too "
        ~ "(reference: only the haul, the zero-length ring stays, gap 240): " ~ vertexCount().to!string ~ " v");
    assert(ringAt(lastRing(), 1.0, 0.0, 1e-6), "Ctrl+Z #1 after a motionless first click: the zero-length ring "
        ~ "moved: " ~ newVertices().to!string);
    assert(zero(offset()), "Ctrl+Z #1 after a motionless first click: panel " ~ offset().to!string ~ ", expected 0");
    assert(extendActive(), "Ctrl+Z #1 after a motionless first click ended the tool (gap 240)");
    ctrlZ();
    assert(vertexCount() == 9 && undoLen() == h0, format("Ctrl+Z #2 did not pop the motionless first click (gap 240): "
        ~ "%d v, %d records", vertexCount(), undoLen() - h0));
    assert(!extendActive(), "Ctrl+Z #2 popped the first click but kept the tool (reference: the click goes with "
        ~ "the activation, gap 240/218)");
    ctrlZ();
    assert(selectedEdgeList() == sel0, "Ctrl+Z #3 after a motionless first click did not undo the edit before the tool");
}

// --- stationary pin (A-row-joined) --------------------------------------------

unittest { // (ug) law A-row-joined after a session with a continuation
    rig(true);
    prologue();
    click(pP(), 1, KMOD_LSHIFT);
    cmd("tool.set edge.extend off");
    assert(vertexCount() == 13, "rig: the Shift click's session did not commit 13 v: " ~ vertexCount().to!string);
    keyArm();
    frontHaul(QX, QY, kIncrementPx, kIncrementPx, 10);
    assert(vertexCount() == 15, "rig: the re-armed haul did not build a ring: " ~ vertexCount().to!string ~ " v");
    ctrlZ();
    assert(vertexCount() == 13 && !extendActive(),
        format("a re-armed Edge Extend kept the continued-operation state of its previous session (the first "
             ~ "run's undo must end the tool, gap 218): %d v, tool %s", vertexCount(), toolId()));
}
