// Edge Extend — Ctrl+Z while the run is live walks it gesture by gesture
// (fixture cell `live_undo_walk_two_presses` of
// tests/fixtures/edge_extend_gesture_laws.json; gaps 215/218).
//
// The measured law: inside one run the first Ctrl+Z pops only the NEWEST
// gesture (the ring is rebuilt at the previous gesture's offset, the tool
// stays, the document history is not touched); the next Ctrl+Z removes the
// rest of the run TOGETHER with the tool's activation (the activation row is
// not a step of its own), and the third reaches the edit made before the
// tool. A motionless click is not a gesture. Under symmetry the popped
// press's side is NOT restored: the latch stays where the newest press put it.
//
// Every Ctrl+Z here is the real keystroke through the input router (the
// navHistory path), never the raw `history.undo` command. The selection is a
// RECORDED edit made after `history.clear`, so the third undo has something
// to reach and cannot pass vacuously.
//
// On HEAD the first red is (u0) "live undo removed the whole run": HEAD
// cancels the whole live edit on the first Ctrl+Z and drops the tool.

import edge_extend_gesture_helpers;
import std.conv : to;
import std.format : format;
import std.math : abs;

void main() {}

enum int[2][] kPlusRidge = [[6, 7], [7, 8]];

__gshared Offset symO1, symO12;   // (u) control: after the first / the second haul, no symmetry

/// The top rig with the selection recorded, then the tool armed.
size_t[] recordedRig() {
    auto sel0 = rigNoArm(kPlusRidge, false, 1.0, 0, true);
    // The UI door, as the key: the law below is the KEY-armed walk (gap 218);
    // a script arm keeps its row as its own step (gap 215, C-H1-door).
    cmdUi("tool.set edge.extend on");
    settle(250);
    return sel0;
}

void allNewX(double want, string msg) {
    auto nv = newVertices();
    assert(nv.length == 3, format("%s: %d new vertices", msg, nv.length));
    foreach (v; nv)
        assert(abs(v[0] - want) <= 1e-4, format("%s: new vertex %s, expected x = %s", msg, v, want));
}

unittest { // (u0) no symmetry: two hauls, Ctrl+Z x3 — the red line on HEAD
    auto sel0 = recordedRig();
    haul(haulPx(), kIncrementPx, 0, 10);
    immutable Offset o1 = offset();
    haul(clickPx(), kIncrementPx, 0, 5);
    immutable Offset o2 = offset();
    assert(vertexCount() == 12 && o2.x > o1.x,
        format("rig: the second haul did not continue the run: %d v, o1 %s, o2 %s", vertexCount(), o1, o2));
    immutable long h0 = undoLen();
    ctrlZ();
    assert(undoLen() == h0, "live undo walked the document history: " ~ (undoLen() - h0).to!string);
    assert(vertexCount() == 12, "live undo removed the whole run: " ~ vertexCount().to!string ~ " v");
    assert(toolId() == "edgeExtend", "live undo ended the tool: " ~ toolId());
    assert(abs(offset().x - o1.x) <= 1e-5, format("live undo did not restore the newest gesture's offset: %s, o1 %s",
                                                  offset(), o1));
    allNewX(1 + o1.x, "live undo did not rebuild the ring");
    ctrlZ();
    assert(vertexCount() == 9 && undoLen() == h0 - kActivationRow,
        format("second live undo did not remove the rest of the run with its activation row: %d v, %d records",
               vertexCount(), undoLen() - h0));
    assert(toolId() != "edgeExtend",
        "second live undo did not end the tool (reference: the activation is undone with the run, gap 218)");
    ctrlZ();
    assert(selectedEdgeList() == sel0, "third live undo did not undo the edit before the tool (reference: the "
        ~ "activation row is not its own step, gap 218): " ~ selectedEdgeList().to!string);
}

unittest { // (u) symmetry: the popped press's side is not restored
    // Control without symmetry: the same two hauls on the front rig.
    rigNoArm([[7, 8]], true, 0.25, 0.55);
    keyArm();
    frontHaul(0.5, 1.35, kIncrementPx, kIncrementPx, 10);
    symO1 = offset();
    frontHaul(-0.5, 1.35, kIncrementPx, kIncrementPx, 10);
    symO12 = offset();
    assert(symO1.x > 0.05 && symO12.x > symO1.x, format("symmetry control: %s, %s", symO1, symO12));
    cmd("tool.set edge.extend off");

    symSelRig();
    keyArm();
    frontHaul(0.5, 1.35, kIncrementPx, kIncrementPx, 10);
    assert(pressAnchor()[0] > 0.05, "rig: the first press was not on the +X side");
    assertRidges(1 + symO1.x, "first off-handle press did not latch +X");
    frontHaul(-0.5, 1.35, kIncrementPx, kIncrementPx, 10);
    assert(pressAnchor()[0] < -0.05, "rig: the second press was not on the -X side");
    assertRidges(1 - symO12.x, "rig: the second press did not latch -X (live ridges)");
    ctrlZ();
    assert(vertexCount() == 13, "live undo removed the whole run (symmetry): " ~ vertexCount().to!string ~ " v");
    assert(abs(offset().x - symO1.x) <= 1e-5, format("live undo did not restore the newest gesture's offset "
        ~ "(symmetry): %s, o1 %s", offset(), symO1));
    foreach (v; newVertices())
        assert(abs(abs(v[0]) - (1 + symO1.x)) <= 1e-4 || abs(abs(v[0]) - (1 - symO1.x)) <= 1e-4,
            "live undo did not rebuild the ring (symmetry): " ~ newVertices().to!string);
    assertRidges(1 - symO1.x, "live undo restored the popped press's symmetry side (reference keeps the "
        ~ "latch: +-0.875 not +-1.125, gap 215)");
    cmd("tool.set edge.extend off");
}

/// Under symmetry: the four new vertices sit at x = +-want.
void assertRidges(double want, string msg) {
    auto nv = newVertices();
    size_t plus = 0, minus = 0;
    foreach (v; nv) {
        if (abs(v[0] - want) <= 1e-4) ++plus;
        else if (abs(v[0] + want) <= 1e-4) ++minus;
    }
    assert(nv.length == 4 && plus == 2 && minus == 2, format("%s: new vertices %s, expected x = +-%s", msg, nv, want));
}

unittest { // (u2) a motionless click between the hauls is not a gesture
    recordedRig();
    haul(haulPx(), kIncrementPx, 0, 10);
    immutable Offset o1 = offset();
    click(thirdPx());
    haul(clickPx(), kIncrementPx, 0, 5);
    immutable Offset o2 = offset();
    assert(vertexCount() == 12 && o2.x > o1.x,
        format("rig: the second haul did not continue the run: %d v, o1 %s, o2 %s", vertexCount(), o1, o2));
    ctrlZ();
    assert(toolId() == "edgeExtend" && abs(offset().x - o1.x) <= 1e-5,
        format("live undo popped a motionless click (reference: no row): tool %s, offset %s, o1 %s",
               toolId(), toolId() == "edgeExtend" ? offset().to!string : "-", o1));
    // The click carries the SAME offset as the haul before it, so #1 alone
    // cannot tell a click step from none; #2 can: with no click step the
    // first haul is the last step and the whole run goes (9 v).
    ctrlZ();
    assert(vertexCount() == 9,
        format("live undo popped a motionless click (reference: no row): the second undo left %d v "
             ~ "(a click step would still hold the ring)", vertexCount()));
    if (toolId() == "edgeExtend") cmd("tool.set edge.extend off");
}
