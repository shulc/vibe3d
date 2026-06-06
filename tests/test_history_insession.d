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
import mesh : Mesh, GpuMesh;
import view : View;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import editmode : EditMode;
import math : Vec3;

void main() {}

// ----- shared scratch fixtures ---------------------------------------------
// A scratch mesh + caches + GpuMesh whose pointers the MeshVertexEdits carry.
// They are never mutated by the tests (we don't call apply/revert), so a
// default-constructed set is enough.

private struct Scratch {
    Mesh            mesh;
    View            view;
    GpuMesh         gpu;
    VertexCache     vc;
    EdgeCache       ec;
    FaceBoundsCache fc;

    MeshVertexEdit makeEdit(uint[] idx, Vec3[] before, Vec3[] after,
                            string label) {
        auto cmd = new MeshVertexEdit(&mesh, view, EditMode.Vertices,
                                      &gpu, &vc, &ec, &fc);
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
