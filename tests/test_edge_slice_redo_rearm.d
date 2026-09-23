// test_edge_slice_redo_rearm.d — task 7137 (S1b), owner decision В21 for Edge
// Slice: the tool's arm is a history row; the Ctrl+Z that peels the session's
// FIRST point also pops that row (the tool ends); Ctrl+Shift+Z then re-arms the
// tool WITH that first point — same edge, same `t`, RELEASED — and the redo
// after it is empty. Law and provenance: doc/measured_laws.md §22 and the
// fixture toolcards/bugfix_w17_slice_tools (verdicts C1-u, C1-rearm).
//
// Every gesture is real SDL input through /api/play-events; the redo is the
// keystroke (the navigate chokepoint), never the `history.redo` command — the
// raw doors re-arm BARE by design, which block D pins.
//
// Block A (subpatch OFF) runs before block B (ON, the captured cell) so a red
// on A names the capability first. Block C pins rule K (verdict K1) and our
// Z2/Z3 sequence after a re-arm inside one activation (gap row 204). Block D
// pins the raw redo door. Rig: tests/slice_leak_helpers.d.

import slice_leak_helpers;
import http_client : getJson;
import drag_helpers : Vec3, fetchCamera, viewportFromCamera, projectToWindow;
import std.format : format;
import std.math : abs, sqrt, round;
import std.stdio : writeln;

void main() {}

enum int[2][3] HINT_OFF = [[315, 303], [531, 355], [616, 270]];
enum int[2][3] HINT_ON  = [[323, 302], [507, 326], [606, 271]];
enum SL_SDLK_RETURN = 13;

void ctrlZ(string what)      { slKey(SL_SDLK_z, SL_KMOD_LCTRL, what); }
void ctrlShiftZ(string what) { slKey(SL_SDLK_z, SL_KMOD_LCTRL | SL_KMOD_LSHIFT, what); }

string topLabel() {
    auto l = slHistoryLabels();
    return l.length ? l[$ - 1] : "";
}

/// Button-less motion from `px` 30 px along the screen direction of edge
/// (a, b) of the current mesh, in six steps.
void hoverAlongEdge(long a, long b, int[2] px) {
    auto m = getJson("/api/model");
    auto vp = viewportFromCamera(fetchCamera());
    auto va = m["vertices"].array[cast(size_t)a].array, vb = m["vertices"].array[cast(size_t)b].array;
    float ax, ay, bx, by;
    projectToWindow(Vec3(va[0].floating, va[1].floating, va[2].floating), vp, ax, ay);
    projectToWindow(Vec3(vb[0].floating, vb[1].floating, vb[2].floating), vp, bx, by);
    const dx = bx - ax, dy = by - ay, len = sqrt(dx * dx + dy * dy);
    assert(len > 10, format("slice rig: edge (%d,%d) is %.1f px on screen", a, b, len));
    string log;
    foreach (i; 1 .. 7) {
        const x = cast(int)round(px[0] + dx / len * 5.0 * i);
        const y = cast(int)round(px[1] + dy / len * 5.0 * i);
        log ~= slMotion(20 + 20 * i, x, y, 0) ~ "\n";
    }
    slPlay(log, "button-less motion along P1");
}

/// Latch the first `n` points of the front/right chain (click + short drag).
int[2][] latchPoints(const long[2][] P, const int[2][3] hints, size_t n, string tag) {
    int[2][] pxs;
    foreach (k; 0 .. n) {
        const px = slEdgePixel(P[k][0], P[k][1], hints[k], format("point %d (%s)", k + 1, tag));
        slClickDown(px[0], px[1], format("click %d", k + 1));
        slDragUp(px[0], px[1], 0, 4, 3, format("drag %d", k + 1));
        pxs ~= px;
    }
    auto c = slChain();
    assert(slNorm(c.pairs) == slNorm(P[0 .. n]),
           format("slice floor: %d points latched as %s, expected %s (%s)", n,
                  slPairsStr(slNorm(c.pairs)), slPairsStr(slNorm(P[0 .. n])), tag));
    return pxs;
}

void redoBlock(bool subpatchOn) {
    const tag = subpatchOn ? "subpatch ON" : "subpatch OFF";
    auto pro = slPrologue(subpatchOn, "polygons", &slBackAndLeft, true);
    const Hp = pro.historyLen;
    const base = slMesh();
    assert(base.verts == 8 && base.faces == 4,
           "slice floor: the prologue is not the 8v/4f open box: " ~ base.toString);

    slLine("tool.set mesh.edgeSliceTool on");
    assert(slTool() == "edgeSlice", "slice floor: Edge Slice did not activate");
    // The named red on HEAD (plan §S1b design item 1).
    assert(slHistoryLen() == Hp + 1 && topLabel() == "Activate Tool",
           format("edge slice arm wrote no activation row (%s): history %s, prologue %d",
                  tag, slHistoryLabels(), Hp));

    const P = slFrontRightChain();
    const pxs = latchPoints(P, subpatchOn ? HINT_ON : HINT_OFF, 3, tag);
    const t0 = slLatchedT();
    assert(t0.length == 3, format("slice floor: latchedT %s after 3 points (%s)", t0, tag));
    const t1 = t0[0];

    ctrlZ("Ctrl+Z 1");
    ctrlZ("Ctrl+Z 2");
    // Positive control for the tool-off negation below.
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 1,
           format("slice floor: after two Ctrl+Z the tool is '%s' with %d point(s) (%s)",
                  slTool(), slChain().pairs.length, tag));
    ctrlZ("Ctrl+Z 3");
    assert(slTool() != "edgeSlice",
           format("third ctrl+z did not end the tool (%s): tool '%s'", tag, slTool()));
    assert(slHistoryLen() == Hp,
           format("third ctrl+z did not pop the activation row (%s): history %s, prologue %d",
                  tag, slHistoryLabels(), Hp));
    assert(slCanRedo(), format("no redo after the session ended (%s)", tag));

    ctrlShiftZ("Ctrl+Shift+Z (re-arm)");
    const c = slChain();
    const tr = slLatchedT();
    const mr = slMesh();
    assert(slTool() == "edgeSlice" && slNorm(c.pairs) == slNorm(P[0 .. 1])
           && tr.length == 1 && abs(tr[0] - t1) <= 1e-6
           && mr.canon == base.canon && slHistoryLen() == Hp + 1,
           format("redo did not re-arm the session with its first point (%s): tool '%s', "
                  ~ "points %s (expected %s), latchedT %s (expected [%s]), mesh %s (base %s, "
                  ~ "equal %s), history %d (expected %d)",
                  tag, slTool(), slPairsStr(slNorm(c.pairs)), slPairsStr(slNorm(P[0 .. 1])),
                  tr, t1, mr.toString, base.toString, mr.canon == base.canon,
                  slHistoryLen(), Hp + 1));

    // Released, not mid-drag (plan R8): the state flag, then the behaviour.
    const scrubbingAfterRedo = slScrubbing();
    hoverAlongEdge(P[0][0], P[0][1], pxs[0]);
    const th = slLatchedT();
    assert(!scrubbingAfterRedo && th.length == 1 && abs(th[0] - t1) <= 1e-6 && !slScrubbing(),
           format("redo left the re-armed tool mid-drag (%s): scrubbing after redo %s, "
                  ~ "latchedT after a button-less motion %s (expected [%s])",
                  tag, scrubbingAfterRedo, th, t1));

    const redoBefore = slCanRedo();
    ctrlShiftZ("Ctrl+Shift+Z (second)");
    assert(!redoBefore && slTool() == "edgeSlice" && slChain().pairs.length == 1
           && slHistoryLen() == Hp + 1,
           format("redo after the re-arm is not empty (%s): canRedo before %s, tool '%s', "
                  ~ "points %d, history %d (expected %d)",
                  tag, redoBefore, slTool(), slChain().pairs.length, slHistoryLen(), Hp + 1));
    writeln("edge slice redo re-arm (", tag, "): t1 ", t1, " re-armed ", th);
    slLine("tool.set mesh.edgeSliceTool off");
}

// Block A — subpatch OFF.
unittest {
    redoBlock(false);
}

// Block B — subpatch ON (the captured cell, C1-u).
unittest {
    redoBlock(true);
}

// Block C — rule K after a re-arm inside one activation (verdict
// `C1-rearm verdict: K1`), then OUR Z2/Z3 (plan R9): Z2 pops chain 1 while
// the reference pops its re-arm rows (divergence, gap row 204); Z3 reaches the
// reference's end state. Asserts in order Z1, Z2, Z3.
unittest {
    auto pro = slPrologue(false, "polygons", &slBackAndLeft, true);
    const Hp = pro.historyLen;
    const base = slMesh();
    assert(base.verts == 8 && base.faces == 4,
           "slice floor: the prologue is not the 8v/4f open box: " ~ base.toString);
    slLine("tool.set mesh.edgeSliceTool on");
    const P = slFrontRightChain();
    latchPoints(P, HINT_OFF, 2, "block C chain 1");
    const Hc = slHistoryLen();
    assert(Hc == Hp + 1 && topLabel() == "Activate Tool",
           format("slice floor (block C): history before Enter %s, prologue %d",
                  slHistoryLabels(), Hp));
    slKey(SL_SDLK_RETURN, 0, "Enter (commit chain 1)");
    const C1 = slMesh();
    assert(C1.faces > base.faces && slHistoryLen() == Hc + 1 && slTool() == "edgeSlice"
           && slChain().pairs.length == 0,
           format("slice floor (block C): Enter did not commit chain 1 as one row with the "
                  ~ "tool still armed: mesh %s, history %s, tool '%s'",
                  C1.toString, slHistoryLabels(), slTool()));
    // The first point of a new chain, on the uncut right-back vertical.
    const px = slEdgePixel(P[2][0], P[2][1], HINT_OFF[2], "block C chain 2 point 1");
    slClickDown(px[0], px[1], "chain 2 click");
    slDragUp(px[0], px[1], 0, 4, 3, "chain 2 drag");
    assert(slChain().pairs.length == 1,
           format("slice floor (block C): chain 2 has %d point(s)", slChain().pairs.length));

    ctrlZ("Z1");
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 0
           && slHistoryLen() == Hc + 1 && slMesh().canon == C1.canon,
           format("ctrl+z after a re-arm ended the tool (K1): tool '%s', points %d, "
                  ~ "history %s (expected %d rows), mesh %s (chain 1 %s)",
                  slTool(), slChain().pairs.length, slHistoryLabels(), Hc + 1,
                  slMesh().toString, C1.toString));
    ctrlZ("Z2");
    assert(slTool() == "edgeSlice" && slMesh().canon == base.canon
           && slHistoryLen() == Hp + 1 && topLabel() == "Activate Tool",
           format("ctrl+z 2 after a re-arm: ours pops chain 1 here (divergence-registered, "
                  ~ "gap 204): tool '%s', mesh %s (base %s), history %s",
                  slTool(), slMesh().toString, base.toString, slHistoryLabels()));
    ctrlZ("Z3");
    assert(slTool() != "edgeSlice" && slMesh().canon == base.canon && slHistoryLen() == Hp,
           format("ctrl+z 3 after a re-arm did not reach the reference end state (tool off, "
                  ~ "chain 1 and activation gone): tool '%s', mesh %s, history %s",
                  slTool(), slMesh().toString, slHistoryLabels()));
}

// Block D — the raw redo door re-arms BARE (plan R8, design item 3 (ii)). A
// construction pin, green before and after the fix; its mutation half is the
// source census of `replayFirstGesture(` calls (acceptance (5)).
unittest {
    auto pro = slPrologue(false, "polygons", &slBackAndLeft, true);
    slLine("tool.set mesh.edgeSliceTool on");
    const P = slFrontRightChain();
    latchPoints(P, HINT_OFF, 3, "block D");
    foreach (k; 1 .. 4) ctrlZ(format("block D Ctrl+Z %d", k));
    assert(slTool() != "edgeSlice" && slHistoryLen() == pro.historyLen,
           format("slice floor (block D): the session did not close: tool '%s', history %s",
                  slTool(), slHistoryLabels()));
    slCmd("history.redo");   // the script door (`/api/redo` was retired, task 4063)
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 0,
           format("raw redo replayed the first gesture (replay belongs to navigate only): "
                  ~ "tool '%s', points %d", slTool(), slChain().pairs.length));
    slLine("tool.set mesh.edgeSliceTool off");
}

// Block E — the held gesture replays only on the redo of the row it came
// with (identity, design item 5). The session ends (gesture held), the raw
// door re-arms bare, a selection row is recorded on top and undone by
// Ctrl+Z; the Ctrl+Shift+Z that redoes THAT row must not seat the stale
// point on the live tool. Added by the diff sweep: without it, dropping the
// identity term stayed green.
unittest {
    auto pro = slPrologue(false, "polygons", &slBackAndLeft, true);
    slLine("tool.set mesh.edgeSliceTool on");
    const P = slFrontRightChain();
    latchPoints(P, HINT_OFF, 3, "block E");
    foreach (k; 1 .. 4) ctrlZ(format("block E Ctrl+Z %d", k));
    slCmd("history.redo");
    const H = slHistoryLen();
    slCmd("mesh.select", `{"mode":"edges","indices":[]}`);
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 0
           && slHistoryLen() == H + 1 && !slCanRedo(),
           format("slice floor (block E): bare re-arm plus a selection row: tool '%s', "
                  ~ "points %d, history %s", slTool(), slChain().pairs.length, slHistoryLabels()));
    ctrlZ("block E Ctrl+Z (the selection row)");
    assert(slTool() == "edgeSlice" && slHistoryLen() == H && slCanRedo(),
           format("slice floor (block E): Ctrl+Z did not undo the selection row alone: "
                  ~ "tool '%s', history %s", slTool(), slHistoryLabels()));
    ctrlShiftZ("block E Ctrl+Shift+Z (the selection row)");
    assert(slHistoryLen() == H + 1 && slChain().pairs.length == 0,
           format("a stale first gesture replayed on a foreign redo: points %d, history %s",
                  slChain().pairs.length, slHistoryLabels()));
    slLine("tool.set mesh.edgeSliceTool off");
}

// Block F — the held gesture is CONSUMED by the redo that replays it. After
// the replay, the raw `history.undo` pops the activation row again (the tool
// ends, the row returns to the redo head); the next Ctrl+Shift+Z re-arms bare.
// Two guards hold this, and each hides the other: dropping the clear after
// the redo ALONE stays green, because the raw undo's cancel restores the
// chain baseline and the sealed key then refuses the stale replay; with the
// key check also neutralised this cell reddens (measured in the 7137 sweep).
unittest {
    auto pro = slPrologue(false, "polygons", &slBackAndLeft, true);
    slLine("tool.set mesh.edgeSliceTool on");
    const P = slFrontRightChain();
    latchPoints(P, HINT_OFF, 1, "block F");
    ctrlZ("block F Ctrl+Z (ends the session)");
    ctrlShiftZ("block F Ctrl+Shift+Z (replays)");
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 1,
           format("slice floor (block F): the redo did not replay: tool '%s', points %d",
                  slTool(), slChain().pairs.length));
    slCmd("history.undo");
    assert(slTool() != "edgeSlice" && slHistoryLen() == pro.historyLen && slCanRedo(),
           format("slice floor (block F): the raw undo did not pop the activation row: "
                  ~ "tool '%s', history %s", slTool(), slHistoryLabels()));
    ctrlShiftZ("block F Ctrl+Shift+Z (after the raw undo)");
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 0,
           format("a consumed first gesture replayed again: tool '%s', points %d",
                  slTool(), slChain().pairs.length));
    slLine("tool.set mesh.edgeSliceTool off");
}
