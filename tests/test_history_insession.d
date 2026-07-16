module test_history_insession;

// ---------------------------------------------------------------------------
// Phase 0 — in-session entry tagging + run-consolidation primitives (UNUSED).
//
// These primitives (CommandHistory.recordInSession / consolidate / nextRun /
// runOpen / currentRunId, MeshVertexEdit.mergeRun / getHooks / edit{Indices,
// Before,After}) are not yet wired into any product code path. They are
// exercised here head-lessly by driving a scratch CommandHistory directly —
// the module is plain D, no app / GL context needed, so all assertions run as
// unittest blocks at binary startup.
//
// We never call revert()/apply() on the MeshVertexEdits (those touch the GPU
// upload path, which needs a GL context); instead we assert on the MERGED
// entry's payload (indices / before / after) — the load-bearing merge math —
// plus the stack-rewrite + foreign-record-guard orchestration.
//
// Source-backed: importing `command`, `mesh`, `command_history`, and the
// vertex-edit command makes the runner compile this with `-unittest -i`, which
// pulls in + runs the imported modules' unittest blocks too.
// ---------------------------------------------------------------------------

import command;
import command : CmdFlags;
import command_history;
import commands.mesh.vertex_edit : MeshVertexEdit;
import mesh : Mesh;
import view : View;
import editmode : EditMode;
import math : Vec3;
import std.conv : to;

void main() {}

// ----- shared scratch fixtures ---------------------------------------------
// A scratch mesh + view for constructing MeshVertexEdits. After task 0413 the
// command resolves its display targets (gpu / caches) through the app-installed
// resolver at refresh time, so the fixture no longer carries those pointers.
// The mesh/view are never mutated by the tests (we don't call apply/revert).

private struct Scratch {
    Mesh            mesh;
    View            view;

    MeshVertexEdit makeEdit(uint[] idx, Vec3[] before, Vec3[] after,
                            string label) {
        auto cmd = new MeshVertexEdit(&mesh, view, EditMode.Vertices);
        cmd.setEdit(idx, before, after, label);
        return cmd;
    }
}

// A minimal non-vertex-edit undoable command — the "foreign" record. record()
// only stores it (no apply/revert during record), so a trivial revert() is
// enough to keep it well-formed.
private final class ForeignCmd : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }
    override string name()  const { return "test.foreign"; }
    override string label() const { return "Foreign"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    override bool apply()  { return true; }
    override bool revert() { return true; }
}

// Downcast undoStack[i].cmd back to MeshVertexEdit for payload inspection.
private MeshVertexEdit mveAt(CommandHistory h, size_t i) {
    auto ents = h.undoEntries();
    assert(i < ents.length, "mveAt: index out of range");
    return cast(MeshVertexEdit) ents[i].cmd;
}

private bool veq(Vec3 a, Vec3 b) {
    return a.x == b.x && a.y == b.y && a.z == b.z;
}

// ===========================================================================
// 1. Record 3 tagged entries on one run -> consolidate -> ONE entry whose
//    payload restores the pre-run state (before[] = first-touch positions).
// ===========================================================================
unittest {
    Scratch s;
    auto h = new CommandHistory();
    ulong run = h.nextRun();   // run id 1

    // Gesture 1: verts {0,1} move from A0/A1 -> B0/B1.
    h.recordInSession(s.makeEdit(
        [0u, 1u],
        [Vec3(0,0,0), Vec3(1,0,0)],
        [Vec3(0,1,0), Vec3(1,1,0)], "Move"), run);
    assert(h.runOpen(), "run should be open after first recordInSession");

    // Gesture 2: verts {1,2} — vert 1 moves AGAIN (from B1 -> C1), vert 2 new.
    h.recordInSession(s.makeEdit(
        [1u, 2u],
        [Vec3(1,1,0), Vec3(2,0,0)],
        [Vec3(1,2,0), Vec3(2,2,0)], "Move"), run);

    // Gesture 3: vert {0} moves again (from B0 -> D0).
    h.recordInSession(s.makeEdit(
        [0u],
        [Vec3(0,1,0)],
        [Vec3(0,3,0)], "Move"), run);

    assert(h.undoEntries().length == 3, "3 in-session entries before merge");
    assert(h.runOpen(), "run still open before consolidate");

    h.consolidate(run);

    assert(!h.runOpen(), "consolidate clears runOpen");
    assert(h.undoEntries().length == 1, "run collapses to ONE entry");

    auto merged = mveAt(h, 0);
    assert(merged !is null, "merged entry is a MeshVertexEdit");

    // Union of indices, sorted: {0,1,2}.
    auto idx = merged.editIndices();
    assert(idx.length == 3, "union has 3 verts");
    assert(idx[0] == 0 && idx[1] == 1 && idx[2] == 2, "indices sorted union");

    auto bef = merged.editBefore();
    auto aft = merged.editAfter();

    // before[] = first-touch (run-start) positions:
    //   vert 0 first touched in gesture 1 -> A0 = (0,0,0)
    //   vert 1 first touched in gesture 1 -> A1 = (1,0,0)
    //   vert 2 first touched in gesture 2 -> (2,0,0)  (its run-start, since it
    //          was untouched by gesture 1).
    assert(veq(bef[0], Vec3(0,0,0)), "vert0 before = run-start A0");
    assert(veq(bef[1], Vec3(1,0,0)), "vert1 before = run-start A1 (first touch)");
    assert(veq(bef[2], Vec3(2,0,0)), "vert2 before = its run-start");

    // after[] = latest positions:
    //   vert 0 last touched in gesture 3 -> D0 = (0,3,0)
    //   vert 1 last touched in gesture 2 -> C1 = (1,2,0)
    //   vert 2 last touched in gesture 2 -> (2,2,0)
    assert(veq(aft[0], Vec3(0,3,0)), "vert0 after = latest D0");
    assert(veq(aft[1], Vec3(1,2,0)), "vert1 after = latest C1");
    assert(veq(aft[2], Vec3(2,2,0)), "vert2 after = latest");
}

// ===========================================================================
// 2. Hooks: the merged entry carries the FIRST gesture's revert-hook + the
//    LAST gesture's apply-hook.
// ===========================================================================
unittest {
    Scratch s;
    auto h = new CommandHistory();
    ulong run = h.nextRun();

    int firstRevert, lastApply, otherFlag;
    auto g1 = s.makeEdit([0u], [Vec3(0,0,0)], [Vec3(0,1,0)], "Move");
    g1.setHooks(/*apply*/ () { otherFlag = 1; },
                /*revert*/ () { firstRevert = 11; });
    auto g2 = s.makeEdit([0u], [Vec3(0,1,0)], [Vec3(0,2,0)], "Move");
    g2.setHooks(/*apply*/ () { lastApply = 22; },
                /*revert*/ () { otherFlag = 2; });

    h.recordInSession(g1, run);
    h.recordInSession(g2, run);
    h.consolidate(run);
    assert(h.undoEntries().length == 1);

    auto merged = mveAt(h, 0);
    auto hk = merged.getHooks();
    assert(hk.revert !is null && hk.apply !is null, "both hooks spliced");
    hk.revert(); assert(firstRevert == 11, "merged revert = first.revert");
    hk.apply();  assert(lastApply  == 22, "merged apply  = last.apply");
}

// ===========================================================================
// 3. Foreign record mid-run triggers consolidation FIRST, then appends.
// ===========================================================================
unittest {
    Scratch s;
    auto h = new CommandHistory();
    ulong run = h.nextRun();

    h.recordInSession(s.makeEdit([0u], [Vec3(0,0,0)], [Vec3(0,1,0)], "Move"), run);
    h.recordInSession(s.makeEdit([0u], [Vec3(0,1,0)], [Vec3(0,2,0)], "Move"), run);
    assert(h.undoEntries().length == 2 && h.runOpen());

    // A foreign (non-tagged) undoable record while the run is open.
    auto foreign = new ForeignCmd(&s.mesh, s.view, EditMode.Vertices);
    h.record(foreign);

    assert(!h.runOpen(), "foreign record closed the run");
    // 1 surviving consolidated entry + 1 foreign on top.
    assert(h.undoEntries().length == 2, "consolidated(1) + foreign(1)");
    auto merged = mveAt(h, 0);
    assert(merged !is null, "entry 0 is the consolidated vertex edit");
    // entry 1 is the foreign command (not a MeshVertexEdit).
    assert(cast(MeshVertexEdit) h.undoEntries()[1].cmd is null,
        "entry 1 is the foreign command");
}

// ===========================================================================
// 4. recordInSession clears the redo stack (N1).
// ===========================================================================
unittest {
    Scratch s;
    auto h = new CommandHistory();

    // Seed a committed entry then undo it so the redo stack is non-empty.
    auto f = new ForeignCmd(&s.mesh, s.view, EditMode.Vertices);
    h.record(f);
    assert(h.undoEntries().length == 1);
    assert(h.undo());
    assert(h.canRedo(), "redo available after an undo");

    // A fresh in-session gesture must invalidate the redo timeline.
    ulong run = h.nextRun();
    h.recordInSession(s.makeEdit([0u], [Vec3(0,0,0)], [Vec3(0,1,0)], "Move"), run);
    assert(!h.canRedo(), "recordInSession cleared the redo stack");
}

// ===========================================================================
// 5. Empty / zero-entry consolidate is a safe no-op.
// ===========================================================================
unittest {
    Scratch s;
    auto h = new CommandHistory();

    // No entries at all.
    h.consolidate(h.currentRunId);
    assert(h.undoEntries().length == 0, "consolidate on empty stack = no-op");
    assert(!h.runOpen());

    // A non-matching runId finds no tail.
    auto run = h.nextRun();
    h.recordInSession(s.makeEdit([0u], [Vec3(0,0,0)], [Vec3(0,1,0)], "Move"), run);
    h.consolidate(run + 12345);  // wrong id
    assert(h.undoEntries().length == 1, "wrong-runId consolidate left the entry");
    assert(!h.runOpen(), "consolidate always clears runOpen");

    // Single-entry run consolidates to itself (still 1 entry).
    auto run2 = h.nextRun();
    h.recordInSession(s.makeEdit([1u], [Vec3(1,0,0)], [Vec3(1,1,0)], "Move"), run2);
    auto lenBefore = h.undoEntries().length;
    h.consolidate(run2);
    assert(h.undoEntries().length == lenBefore, "single-entry run unchanged in count");
}

// ===========================================================================
// 6. Cap-trim interplay: a run longer than maxDepth=50 must not crash and
//    must merge the SURVIVING tail (before[] anchors to earliest survivor).
// ===========================================================================
unittest {
    Scratch s;
    auto h = new CommandHistory();
    ulong run = h.nextRun();

    // 60 gestures all moving vert 0 by one unit each: y goes 0->1->2->...->60.
    foreach (k; 0 .. 60) {
        h.recordInSession(s.makeEdit(
            [0u],
            [Vec3(0, cast(float)k,     0)],
            [Vec3(0, cast(float)(k+1), 0)], "Move"), run);
    }
    // Stack capped at 50: the surviving tail is gestures k=10..59.
    assert(h.undoEntries().length == 50, "stack capped at maxDepth");

    h.consolidate(run);
    assert(!h.runOpen());
    assert(h.undoEntries().length == 1, "surviving tail collapses to one entry");

    auto merged = mveAt(h, 0);
    auto bef = merged.editBefore();
    auto aft = merged.editAfter();
    // Earliest SURVIVING gesture is k=10 (before y=10); latest is k=59 (after y=60).
    assert(veq(bef[0], Vec3(0, 10, 0)), "before anchors to earliest survivor");
    assert(veq(aft[0], Vec3(0, 60, 0)), "after = latest gesture");
}

// ===========================================================================
// 7. replaceInSessionTail (in-session re-grade primitive) — Refire-keyed
//    REPLACE-vs-APPEND. It is the SINGLE re-fire primitive: it tags every
//    recorded entry with the Refire bit, and DROPS the tail ONLY when the tail
//    is THIS run's prior RE-GRADE (InSession && Refire && runId). The FIRST
//    re-grade (tail = a plain GESTURE, InSession but NOT Refire) APPENDS; a
//    CONSECUTIVE re-grade (tail = the prior Refire entry) REPLACES. N consecutive
//    tweaks stay ONE undo step; the stack always clears redo (N1). The caller
//    owns before[] (anchored to the post-gesture snapshot).
// ===========================================================================
unittest {
    Scratch s;
    auto h = new CommandHistory();
    ulong run = h.nextRun();

    // A landed GESTURE (plain in-session entry, NOT a refire).
    h.recordInSession(s.makeEdit(
        [0u], [Vec3(0,0,0)], [Vec3(0,1,0)], "Move"), run);
    assert(h.undoEntries().length == 1, "gesture recorded");
    assert(h.runOpen());

    // FIRST re-grade: the tail is the GESTURE (no Refire bit), so this APPENDS,
    // giving 2 entries; the new entry IS tagged Refire. before[] anchors to the
    // POST-GESTURE state (0,1,0).
    h.replaceInSessionTail(s.makeEdit(
        [0u], [Vec3(0,1,0)], [Vec3(0,2,0)], "Falloff"), run);
    assert(h.undoEntries().length == 2,
        "first re-grade APPENDS (tail is a plain gesture, not a refire)");
    auto firstRegrade = h.undoEntries()[1];
    assert((firstRegrade.flags & HistoryFlags.InSession)
        && (firstRegrade.flags & HistoryFlags.Refire),
        "the re-grade entry carries both InSession AND Refire");

    // CONSECUTIVE re-grade: the tail IS this run's prior RE-GRADE (Refire set),
    // so this DROPS it and records the new one — the stack length stays 2. The
    // new entry's before[] is again anchored to the post-gesture state (0,1,0),
    // NOT to the dropped entry's before[]; the CALLER owns that anchoring.
    h.replaceInSessionTail(s.makeEdit(
        [0u], [Vec3(0,1,0)], [Vec3(0,3,0)], "Falloff"), run);
    assert(h.undoEntries().length == 2,
        "consecutive re-grade REPLACES in place (length stable)");
    assert(h.runOpen());
    assert(!h.canRedo(), "replaceInSessionTail clears redo (N1)");

    auto tail = mveAt(h, 1);
    assert(tail !is null, "tail is the replacement vertex edit");
    assert((h.undoEntries()[1].flags & HistoryFlags.Refire),
        "the replacement entry is still tagged Refire");
    auto bef = tail.editBefore();
    auto aft = tail.editAfter();
    assert(veq(bef[0], Vec3(0,1,0)), "tail before = post-gesture anchor (0,1,0)");
    assert(veq(aft[0], Vec3(0,3,0)), "tail after = latest re-grade (0,3,0)");

    // Consolidate: the gesture + the single re-grade tail collapse to ONE entry.
    // before[] = run-start (0,0,0); after[] = latest re-grade (0,3,0).
    h.consolidate(run);
    assert(!h.runOpen(), "consolidate clears runOpen");
    assert(h.undoEntries().length == 1, "drop = ONE consolidated entry");
    auto merged = mveAt(h, 0);
    assert(veq(merged.editBefore()[0], Vec3(0,0,0)),
        "consolidated before = gesture run-start");
    assert(veq(merged.editAfter()[0], Vec3(0,3,0)),
        "consolidated after = latest re-grade");
}

// ===========================================================================
// 8. replaceInSessionTail on a NON-matching tail degrades to append.
//    A tail belonging to a different run (or an untagged/foreign entry) must
//    NOT be dropped — the primitive only drops a SAME-run in-session REFIRE
//    tail.
// ===========================================================================
unittest {
    Scratch s;
    auto h = new CommandHistory();

    // Run A: one in-session entry, then CONSOLIDATE so it is no longer tagged.
    ulong runA = h.nextRun();
    h.recordInSession(s.makeEdit([0u], [Vec3(0,0,0)], [Vec3(0,1,0)], "Move"), runA);
    h.consolidate(runA);   // strips the InSession (+ Refire) tag (n==1)
    assert(h.undoEntries().length == 1);

    // Run B opens; a replace for run B must NOT drop run A's (now untagged)
    // surviving entry — the tail is not (InSession && Refire && runId==runB), so
    // it appends.
    ulong runB = h.nextRun();
    h.replaceInSessionTail(s.makeEdit([1u], [Vec3(1,0,0)], [Vec3(1,1,0)], "Falloff"), runB);
    assert(h.undoEntries().length == 2,
        "replace with non-matching tail appends (does not drop run A)");
    // Entry 0 is run A's untagged survivor; entry 1 is run B's new tagged entry.
    auto e0 = h.undoEntries()[0];
    assert(!(e0.flags & HistoryFlags.InSession),
        "run A entry stays untagged + intact");
}

// ===========================================================================
// 9. The C1 multi-gesture-run hazard, at the primitive level: a SECOND gesture
//    in the same run must NOT be dropped by a following re-grade. The key is
//    keyed on the Refire bit ("is the TAIL a re-grade"), NOT on "did any
//    re-grade happen this run". Sequence: g1 -> tweak1 (appends, Refire) -> g2
//    (plain gesture, NO Refire) -> tweak2. tweak2's tail is g2 (no Refire), so
//    tweak2 must APPEND — never drop g2. Stack: [g1, tweak1, g2, tweak2] = 4.
//    Then tweak3 (tail = tweak2, Refire) REPLACES -> still 4. g2's after[] must
//    survive into the consolidated drop entry.
// ===========================================================================
unittest {
    Scratch s;
    auto h = new CommandHistory();
    ulong run = h.nextRun();

    // g1: vert 0 (0,0,0) -> (0,1,0).
    h.recordInSession(s.makeEdit([0u], [Vec3(0,0,0)], [Vec3(0,1,0)], "Move"), run);
    // tweak1: re-grade after g1, anchored to post-g1 (0,1,0) -> (0,1,5).
    h.replaceInSessionTail(s.makeEdit([0u], [Vec3(0,1,0)], [Vec3(0,1,5)], "Falloff"), run);
    assert(h.undoEntries().length == 2, "g1 + tweak1 = 2");
    assert((h.undoEntries()[1].flags & HistoryFlags.Refire), "tweak1 is a refire");

    // g2: a SECOND gesture in the SAME run — vert 1 NEW (1,0,0) -> (1,9,0). It is
    // a plain in-session entry (NO Refire). This is the entry the C1 bug erased.
    h.recordInSession(s.makeEdit([1u], [Vec3(1,0,0)], [Vec3(1,9,0)], "Move"), run);
    assert(h.undoEntries().length == 3, "g1 + tweak1 + g2 = 3");
    assert(!(h.undoEntries()[2].flags & HistoryFlags.Refire),
        "g2 is a plain gesture, NOT a refire");

    // tweak2: re-grade after g2. The tail is g2 (NO Refire), so it must APPEND —
    // NEVER drop g2. before[] anchored to post-g2 for vert 1: (1,9,0) -> (1,9,7).
    h.replaceInSessionTail(s.makeEdit([1u], [Vec3(1,9,0)], [Vec3(1,9,7)], "Falloff"), run);
    assert(h.undoEntries().length == 4,
        "tweak2 APPENDS (its tail g2 is not a refire) -> g2 NOT erased; expected 4 "
        ~ "got " ~ h.undoEntries().length.to!string);

    // tweak3: a CONSECUTIVE re-grade. The tail is tweak2 (Refire), so it REPLACES
    // -> stack stays 4.
    h.replaceInSessionTail(s.makeEdit([1u], [Vec3(1,9,0)], [Vec3(1,9,8)], "Falloff"), run);
    assert(h.undoEntries().length == 4,
        "tweak3 REPLACES tweak2 (tail is a refire) -> stack stays 4; got "
        ~ h.undoEntries().length.to!string);

    // Drop: consolidate to ONE entry. g2's contribution (vert 1) MUST be present:
    // before[1] = g2 run-start (1,0,0) (first-touch), after[1] = latest (1,9,8).
    h.consolidate(run);
    assert(h.undoEntries().length == 1, "drop = ONE consolidated entry");
    auto merged = mveAt(h, 0);
    auto idx = merged.editIndices();
    // Union of {0} and {1}.
    assert(idx.length == 2 && idx[0] == 0 && idx[1] == 1,
        "consolidated union covers BOTH g1's vert 0 and g2's vert 1");
    auto bef = merged.editBefore();
    auto aft = merged.editAfter();
    // vert 0: g1 run-start (0,0,0) -> latest tweak1 (0,1,5).
    assert(veq(bef[0], Vec3(0,0,0)) && veq(aft[0], Vec3(0,1,5)),
        "vert 0 spans g1 run-start -> tweak1");
    // vert 1: g2 run-start (1,0,0) -> latest tweak3 (1,9,8). This is the C1
    // witness — g2's geometry contribution survived into the drop entry.
    assert(veq(bef[1], Vec3(1,0,0)),
        "vert 1 before = g2 run-start (1,0,0) — g2 was NOT erased (C1)");
    assert(veq(aft[1], Vec3(1,9,8)),
        "vert 1 after = latest re-grade (1,9,8)");
}

// ===========================================================================
// 10. P-E continuous-vs-discrete tweak GENERATION gate. replaceInSessionTail
//     REPLACES a Refire tail ONLY when the tail's tweak generation matches the
//     live generation (same CONTINUOUS interaction — a held slider scrub /
//     falloff-handle drag whose setAttr stream shares one generation). When the
//     generations DIFFER (two DISCRETE tweaks, each its own bumped generation)
//     it APPENDS — each discrete tweak is its OWN in-session undo step (G2).
//
// This is the unit-level witness for the continuous-REPLACE path that is NOT
// headlessly drivable through /api/command (every /api command is its own
// discrete generation by design): here we drive the generation directly.
// ===========================================================================
unittest {
    Scratch s;
    auto h = new CommandHistory();
    ulong run = h.nextRun();

    // A landed GESTURE at generation 0 (default).
    assert(h.currentTweakGeneration() == 0, "generation starts at 0");
    h.recordInSession(s.makeEdit(
        [0u], [Vec3(0,0,0)], [Vec3(0,1,0)], "Move"), run);
    assert(h.undoEntries().length == 1, "gesture recorded");

    // FIRST re-grade: the tail is the GESTURE (no Refire), so this APPENDS
    // regardless of generation. Records at generation 0.
    h.replaceInSessionTail(s.makeEdit(
        [0u], [Vec3(0,1,0)], [Vec3(0,2,0)], "Falloff"), run);
    assert(h.undoEntries().length == 2,
        "first re-grade APPENDS (tail is a plain gesture)");
    assert(h.undoEntries()[1].tweakGeneration == 0,
        "first re-grade stamped at generation 0");

    // CONTINUOUS scrub: a SECOND re-grade at the SAME generation (the held slider
    // never bumped between frames). Its tail is the prior Refire AND the
    // generation matches → REPLACE. Stack stays 2.
    h.replaceInSessionTail(s.makeEdit(
        [0u], [Vec3(0,1,0)], [Vec3(0,3,0)], "Falloff"), run);
    assert(h.undoEntries().length == 2,
        "a same-generation (CONTINUOUS) re-grade REPLACES the prior refire "
        ~ "(length stable); got " ~ h.undoEntries().length.to!string);
    auto tail = mveAt(h, 1);
    assert(veq(tail.editAfter()[0], Vec3(0,3,0)),
        "the REPLACED tail carries the latest continuous value (0,3,0)");

    // DISCRETE tweak: BUMP the generation (a separate tweak interaction), then
    // re-grade. The tail IS a Refire but its generation (0) no longer matches the
    // live generation (1) → P-E gate fails → APPEND. Stack grows to 3 — the
    // discrete tweak is its OWN step (G2).
    ulong g1 = h.bumpTweakGeneration();
    assert(g1 == 1, "bump advances the generation to 1");
    h.replaceInSessionTail(s.makeEdit(
        [0u], [Vec3(0,1,0)], [Vec3(0,4,0)], "Falloff"), run);
    assert(h.undoEntries().length == 3,
        "a DISCRETE (new-generation) tweak APPENDS even though its tail is a "
        ~ "refire (P-E G2) — stack grows to 3; got "
        ~ h.undoEntries().length.to!string);
    assert(h.undoEntries()[2].tweakGeneration == 1,
        "the discrete tweak's entry is stamped at the new generation 1");

    // A FOLLOWING same-(new-)generation re-grade REPLACES the discrete tweak
    // (it is now the latest continuous window). Stack stays 3.
    h.replaceInSessionTail(s.makeEdit(
        [0u], [Vec3(0,1,0)], [Vec3(0,5,0)], "Falloff"), run);
    assert(h.undoEntries().length == 3,
        "a same-(new-)generation re-grade REPLACES the discrete tweak's refire "
        ~ "(length stable at 3); got " ~ h.undoEntries().length.to!string);

    // Consolidate: all three (gesture + the two surviving refires) collapse to
    // ONE entry. before[] = run-start (0,0,0); after[] = latest (0,5,0).
    h.consolidate(run);
    assert(h.undoEntries().length == 1, "drop = ONE consolidated entry");
    auto merged = mveAt(h, 0);
    assert(veq(merged.editBefore()[0], Vec3(0,0,0)),
        "consolidated before = gesture run-start");
    assert(veq(merged.editAfter()[0], Vec3(0,5,0)),
        "consolidated after = latest re-grade");
}
