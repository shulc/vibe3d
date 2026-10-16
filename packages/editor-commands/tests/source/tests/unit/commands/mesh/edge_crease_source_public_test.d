module tests.unit.commands.mesh.edge_crease_source_public_test;

import commands.mesh.edge_crease;
import vibe3d.mesh.edit_replay.mesh_edit_replay : apply, revert;

import command;
import vibe3d.mesh.core.mesh;
import vibe3d.viewport.camera.view;
import vibe3d.editing.contracts.editmode;
import vibe3d.editing.params.params : Param;
import vibe3d.mesh.edit_log.mesh_edit_delta : MeshEditDelta, MeshEditScope;

version (unittest) {
    private View freshView() { return new View(0, 0, 1, 1); }
}
// Empty selection REFUSES (baseRefusal_ + return false) rather than
// silently applying to the whole mesh (§ module doc) — and rather than
// throwing out of the UI dispatch frame, which is what this test pinned
// before the SHOULD-FIX 1 rewrite (task 1062 review). Mutation: drop the
// `sel.length == 0` guard on either command → apply() succeeds against zero
// edges and both assertions below redden (the return value AND the reason).

unittest {
    auto m = new Mesh;
    *m = makeCube();
    View v = freshView();

    auto setCmd = new EdgeCreaseSet(m, v, EditMode.Edges);
    assert(!setCmd.apply(),
        "mesh.edgeCrease.set must refuse (not throw) on an empty edge selection");
    assert(setCmd.refusalReason().length > 0,
        "a refusal without a reason renders as a SILENT no-op "
      ~ "(ui/command_notice.d) — the empty-selection case must say why");

    auto clearCmd = new EdgeCreaseClear(m, v, EditMode.Edges);
    assert(!clearCmd.apply(),
        "mesh.edgeCrease.clear must refuse (not throw) on an empty edge selection");
    assert(clearCmd.refusalReason().length > 0);
}
version (unittest) private Mesh creaseCell_(out uint eA, out uint eB) {
    Mesh m = makeCube();
    m.buildLoops();
    m.syncSelection();
    eA = m.edgeIndex(6, 7);
    eB = m.edgeIndex(2, 3);
    assert(eA != ~0u && eB != ~0u, "the cube stand lost an edge");
    m.selectEdge(cast(int) eA);
    m.selectEdge(cast(int) eB);
    return m;
}
unittest { // clear: [Values] alone, and a NO-OP write bumps NOTHING
    import std.conv : to;

    uint eA, eB;
    auto m = new Mesh;
    *m = creaseCell_(eA, eB);
    // Pre-existing map with a real value on both selected edges, written
    // OUTSIDE the command so this cell measures the clear alone.
    assert(m.setCreaseWeight(eA, 0.75f) && m.setCreaseWeight(eB, 0.75f));

    View v = freshView();
    auto c = new EdgeCreaseClear(m, v, EditMode.Edges);
    assert(c.apply(), "mesh.edgeCrease.clear must apply");
    string ops;
    foreach (i, ref e; c.recordedDelta().log) {
        if (i) ops ~= ", ";
        ops ~= e.mapOp.to!string;
    }
    assert(ops == "Values",
        "mesh.edgeCrease.clear's op-log MapOps are [" ~ ops ~ "], expected "
      ~ "[Values] — the map already existed, so there is no Create to record "
      ~ "and an extra one would unregister a map the user had");
    assert(m.edgeCreaseWeight(eA) == 0.0f && m.edgeCreaseWeight(eB) == 0.0f);

    immutable ulong tv0 = m.topologyVersion;
    assert(c.revert(), "the undo must succeed");
    assert(m.topologyVersion == tv0 + 1,
        "topologyVersion moved by " ~ (m.topologyVersion - tv0).to!string
      ~ " across a crease-clear UNDO, expected exactly 1");
    assert(m.edgeCreaseWeight(eA) == 0.75f && m.edgeCreaseWeight(eB) == 0.75f,
        "the undo did not put the cleared weights back");

    // ---- THE ROW THAT KEEPS THE TWO ABOVE HONEST. A clear over a map that is
    // ALREADY all zeroes moves no value, so `recordMapValueDiff` records
    // NOTHING and the replay has nothing to bump on. Without this row a
    // mutation that made `owesTopologyBump` answer `true` unconditionally
    // would leave both asserts above green.
    auto n = new Mesh;
    uint fA, fB;
    *n = creaseCell_(fA, fB);
    assert(n.addMeshMapOfKind(MapKind.creaseWeight) !is null);
    auto c2 = new EdgeCreaseClear(n, v, EditMode.Edges);
    assert(c2.apply(), "a clear over an all-zero crease map still SUCCEEDS — "
                     ~ "it is a real no-op edit, not a refusal");
    assert(c2.recordedDelta().log.length == 0,
        "clearing an already-zero crease map recorded "
      ~ c2.recordedDelta().log.length.to!string ~ " entr(ies); the post-hoc "
      ~ "door records nothing when no element moved bitwise, and an entry here "
      ~ "would carry before == after");
    immutable ulong tv1 = n.topologyVersion;
    assert(c2.revert(),
        "an empty delta's revert must answer TRUE — a false pops the entry off "
      ~ "BOTH history stacks and truncates the suffix after it");
    assert(n.topologyVersion == tv1,
        "topologyVersion moved by " ~ (n.topologyVersion - tv1).to!string
      ~ " across an EMPTY crease delta, expected 0. This row is what stops the "
      ~ "two +1 asserts above from being satisfied by 'everything bumps'");
}
