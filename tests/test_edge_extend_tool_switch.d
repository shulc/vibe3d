// Edge Extend — the scale-tool key (R) during and after an arm drag
// (item 15; fixture cells `switch_key_while_button_held`,
// `switch_key_after_release` of tests/fixtures/edge_extend_gesture_laws.json).
//
// The measured law has two halves:
//   * with the button HELD, R is ignored: the drag runs to its end and Edge
//     Extend stays the active tool;
//   * after the RELEASE, R switches to the scale transform and the extension
//     is kept; no message is shown (so none is asserted either way).
//
// Order: (C0) the same X-arm drag with no key, which gives the offset the
// held-key drag must reach; (H) the held-key cell — RED on HEAD at "scale key
// interrupted the extend drag", because HEAD switches tools mid-drag; (S) the
// after-release cell, below the red line (HEAD already switches there).
//
// Below them the undo walk of the switch (fixture cells
// `switch_key_undo_walk_no_read`, `switch_undo_restore_then_haul`; gaps
// 215/218/221): (W) undoing the scale tool's arm row re-arms Edge Extend with
// the committed run's values in the panel, NOT live; the next Ctrl+Z removes
// the run together with the tool; the third reaches the edit before the tool.
// (X) is a BOUNDARY, not a law: an undone Edge Extend run must not end a
// DIFFERENT tool. (Y) a haul after the restore starts a new ring from 0 over
// the committed run and records no activation row. (O) only Edge Extend is a
// restorable predecessor: undoing a switch away from Edge Extrude leaves no
// tool, as today. W/X/Y rigs record the selection AFTER `history.clear`, so
// the third undo is never vacuous. Ctrl+Z is the real keystroke (navHistory),
// never the raw `history.undo` command. On HEAD, W fails at "undo of the tool
// switch did not return Edge Extend" (run in isolation: H is red above it).
//
// Every H assert carries the same message prefix, the population floor
// included: the floor ("all ten increments were accepted by the extend") is
// what keeps the offset comparison from being vacuous, and on HEAD it is the
// first thing the interrupted drag breaks.

import edge_extend_gesture_helpers;
import http_client : getJson;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs;

void main() {}

enum int[2][] kPlusRidge = [[6, 7], [7, 8]];
enum string kHeld = "scale key interrupted the extend drag";

__gshared double ctl10;

unittest { // (C0) the X-arm drag, no key
    armRig(kPlusRidge, 1.0);
    engage();
    Px p = pressArm(kArmPressPx, 0, 0, "tool switch control: x arm press did not grab the arm");
    Px end;
    auto tr = increments(p, kIncrementPx, kIncrementPx, 10, end);
    release(end);
    assert(tr.length == 10 && tr[9].x > 0, "tool switch control: read " ~ tr.to!string);
    ctl10 = offset().x;
    assert(abs(ctl10 - tr[9].x) <= 1e-9, "tool switch control: release moved the offset");
    cmd("tool.set edge.extend off");
}

/// offsetX when Edge Extend is still the active tool, else NaN.
double extendOffsetXOrNaN() {
    auto s = toolState();
    if (s["tool"].str != "edgeExtend") return double.nan;
    return num(s["offsetX"]);
}

unittest { // (H) R with the button held is ignored
    armRig(kPlusRidge, 1.0);
    engage();
    Px p = pressArm(kArmPressPx, 0, 0, kHeld ~ ": x arm press did not grab the arm");
    size_t accepted = 0;
    double prev = offset().x;
    foreach (i; 0 .. 10) {
        if (i == 5) tapKey(kScaleKey);
        p = Px(p.x + kIncrementPx, p.y + kIncrementPx);
        motion(p, kIncrementPx, kIncrementPx);
        immutable double x = extendOffsetXOrNaN();
        if (x == x && x > prev) { ++accepted; prev = x; }
    }
    release(p);
    auto s = toolState();
    assert(accepted == 10, format("%s: the extend accepted %d of 10 increments (tool now %s)",
                                  kHeld, accepted, s["tool"].str));
    assert(s["tool"].str == "edgeExtend", kHeld ~ ": active tool after release is " ~ s.toString);
    assert(abs(num(s["offsetX"]) - ctl10) <= 1e-5,
        format("%s: offsetX %s, the same drag without the key reached %s", kHeld, num(s["offsetX"]), ctl10));
    cmd("tool.set edge.extend off");
}

unittest { // (S) R after the release switches to scale, extension kept
    armRig(kPlusRidge, 1.0);
    engage();
    Px p = pressArm(kArmPressPx, 0, 0, "scale did not arm after extend move: x arm press did not grab the arm");
    Px end;
    increments(p, kIncrementPx, kIncrementPx, 10, end);
    release(end);
    immutable long h0 = undoLen();
    assert(h0 < 40, "tool switch: no history headroom");
    tapKey(kScaleKey);
    settle(250);
    auto s = toolState();
    assert(s["tool"].str == "xfrm" && s["enabled"]["s"].type == JSONType.true_
        && s["enabled"]["t"].type == JSONType.false_ && s["enabled"]["r"].type == JSONType.false_,
        "scale did not arm after extend move: " ~ s.toString);
    assert(vertexCount() == 12, "scale did not arm after extend move: extension lost, "
        ~ vertexCount().to!string ~ " vertices");
    // Measured on HEAD: TWO records — the extend's commit and the tool
    // activation, in that order. (The reference also undoes in two steps:
    // the first brings the extend tool back, the second removes the ring.)
    auto undo = getJson("/api/history")["undo"].array;
    assert(undo.length == h0 + 2
        && undo[h0]["label"].str == "Edge Extend" && undo[h0 + 1]["label"].str == "Activate Tool",
        "scale did not arm after extend move: history " ~ undo.to!string);
}

// --- the undo walk of the switch --------------------------------------------

/// W/X/Y rig: symmetry off, the selection a RECORDED edit, the tool armed.
size_t[] recordedRig() {
    auto sel0 = rigNoArm(kPlusRidge, false, 1.0, 0, true);
    // The UI door, as the key: the walk below is the KEY-armed law (gap 218);
    // a script arm keeps its row as its own step (gap 215, C-H1-door).
    cmdUi("tool.set edge.extend on");
    settle(250);
    return sel0;
}

struct Switched { long h0; Offset oR; size_t v1; }

/// W up to (and including) the first Ctrl+Z.
Switched switchAndUndoOnce() {
    engage();
    Px p = pressArm(kArmPressPx, 0, 0, "switch undo: x arm press did not grab the arm");
    Px end;
    increments(p, kIncrementPx, kIncrementPx, 10, end);
    release(end);
    Switched w;
    w.h0 = undoLen();
    w.oR = offset();
    import std.math : sqrt;
    assert(sqrt(w.oR.x ^^ 2 + w.oR.y ^^ 2 + w.oR.z ^^ 2) > 0.05,
        "rig: committed offset too small to tell carried from zero: " ~ w.oR.to!string);
    w.v1 = vertexCount();
    tapKey(kScaleKey);
    settle(250);
    assert(toolId() == "xfrm" && undoLen() == w.h0 + 2,
        format("rig: R did not switch to scale behind two rows: tool %s, %d new records", toolId(), undoLen() - w.h0));
    ctrlZ();
    assert(toolId() == "edgeExtend",
        "undo of the tool switch did not return Edge Extend (reference: re-armed, gap 221): tool " ~ toolId());
    assert(vertexCount() == w.v1, "undo of the tool switch changed the committed run: " ~ vertexCount().to!string ~ " v");
    assert(undoLen() == w.h0 + 1, "undo of the tool switch recorded or removed a second row: "
        ~ (undoLen() - w.h0).to!string ~ " records over H0");
    immutable Offset o = offset();
    assert(abs(o.x - w.oR.x) <= 1e-6 && abs(o.y - w.oR.y) <= 1e-6 && abs(o.z - w.oR.z) <= 1e-6,
        format("restored Edge Extend does not show the committed offset (reference: the panel shows the run's "
             ~ "offset, gap 221): %s, run %s", o, w.oR));
    assert(!built() && !runStarted(), "restored Edge Extend resumed the committed run as live (reference: not live, "
        ~ "gap 221): " ~ toolState().toString);
    return w;
}

unittest { // (W) the undo walk after R (switch_key_undo_walk_no_read)
    auto sel0 = recordedRig();
    auto w = switchAndUndoOnce();
    ctrlZ();
    assert(vertexCount() == 9 && undoLen() == w.h0 - kActivationRow,
        format("the committed run and its activation row are not one undo step (gap 215/218): %d v, %d records",
               vertexCount(), undoLen() - w.h0));
    assert(toolId() != "edgeExtend",
        "undo of the committed run did not end the tool (reference: the activation is undone with the run, gap 218)");
    ctrlZ();
    assert(selectedEdgeList() == sel0 && toolId() != "edgeExtend",
        "third undo after the switch did not undo the edit before the tool (gap 218): " ~ selectedEdgeList().to!string);
}

unittest { // (X) boundary (not a law): an undone Extend run ends no other tool
    recordedRig();
    engage();
    cmd("tool.set edge.extrude on");
    settle(250);
    assert(topHistoryLabel() == "Edge Extend", "rig: the switch did not record the Extend run: " ~ topHistoryLabel());
    ctrlZ();
    assert(vertexCount() == 9 && toolId() == "edgeExtrude",
        format("divergence scope (not captured, gap 218): an undone Edge Extend run ended a different tool: "
             ~ "%d v, tool %s", vertexCount(), toolId()));
    cmd("tool.set edge.extrude off");
}

unittest { // (Y) R-fresh-noact (switch_undo_restore_then_haul)
    recordedRig();
    auto w = switchAndUndoOnce();
    auto tr = haul(haulPx(), kIncrementPx, kIncrementPx, 10);
    assert(tr.length == 10, "haul after the restore: read " ~ tr.length.to!string ~ " states");
    assert(vertexCount() == w.v1 + (w.v1 - 9), format("haul after a switch-undo restore did not start a new ring "
        ~ "over the committed run (reference: 11 -> 13 v, gap 221): %d v, run %d v", vertexCount(), w.v1));
    import std.math : sqrt;
    immutable double m1 = sqrt(tr[0].x ^^ 2 + tr[0].y ^^ 2 + tr[0].z ^^ 2);
    immutable double mR = sqrt(w.oR.x ^^ 2 + w.oR.y ^^ 2 + w.oR.z ^^ 2);
    assert(m1 <= 0.5 * mR, format("haul after a switch-undo restore continued from the committed offset (reference "
        ~ "restarts at 0: 0.0 -> 0.125, gap 221): o_1 %s, run %s", tr[0], w.oR));
    cmd("tool.set edge.extend off");
    assert(undoLen() == w.h0 + 2, "the restored tool's run recorded an activation row (reference: none, gap 221): "
        ~ (undoLen() - w.h0).to!string ~ " records over the run's H0");
}

unittest { // (O) every tool is a restorable predecessor (slice M4, C-M4-token-switch)
    // Flipped by slice M4: undoing an activation row restores the tool it
    // replaced, whichever it was — the captured C-M4-token switch twin brings
    // Edge Extrude back armed when the row that replaced it is undone. The
    // cell used to pin "only Edge Extend is restorable" (our gap-221 scope).
    armRig(kPlusRidge, 1.0);
    cmd("tool.set edge.extend off");
    cmd("tool.set edge.extrude on");
    settle(250);
    tapKey(kScaleKey);
    settle(250);
    assert(toolId() == "xfrm", "rig: R did not switch Edge Extrude to scale: tool " ~ toolId());
    ctrlZ();
    assert(toolId() == "edgeExtrude", "undoing a switch away from Edge Extrude did not restore it (C-M4-token "
        ~ "switch twin: the predecessor comes back armed): tool " ~ toolId());
}
