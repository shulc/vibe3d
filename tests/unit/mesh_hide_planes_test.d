// mesh_hide_planes_test -- `Select` and `Hide` are disjoint -- and the DERIVATION owes that too.
//
// Stage T-S0e. The first cell is the vertex/edge half of the plane
// invariant; the second asserts the derivation itself cannot leave a face
// both selected and hidden. A derivation that writes `Hide` without clearing
// `Select` passes the first cell alone.
//
// These blocks stood in the body of `struct Mesh` until task 3160 -- step 1
// of `doc/tasks/work/2910-mesh-struct-seams.md`, which took fifty `unittest`
// blocks out of a 16 782-line struct body. They are HERE rather than at
// module scope in `mesh.d` because they compile against `Mesh`'s PUBLIC API
// alone: the criterion `tests/unit/README.md` states and task 0706 set. The
// eighteen blocks that read a `private` name stayed behind under the same
// rule, at module scope in `mesh.d`. Bodies are byte-identical to what stood
// in the struct, dedented by four columns; the only edit is the member enum
// `Marks`, which is spelled `Mesh.Marks` outside the body.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT, so a mutation that
// should redden two blocks here only ever proves the first. Run them in
// isolation.
module tests.unit.mesh_hide_planes_test;

import mesh;
import math : Vec3;
import tests.unit.mesh_by_value_gate;

// The seam's compile-time gate: nothing in this module may take a `Mesh` by
// VALUE. `tests/unit/mesh_by_value_gate.d` says why nothing behavioural
// catches that, and carries the gate's own positive control.
private void byValueGateAnchor() {}
mixin MeshByValueGate!(__traits(parent, byValueGateAnchor));

unittest { // vertex and edge planes — same invariant, the other two
    // scalar writers.
    auto m = makeCube();
    m.syncSelection();   // makeCube() does not size the marks arrays itself
    // Direct poke, not setVertexHidden: vertex 0 has incident faces, so
    // the production writer would refuse it (§1.2 — derived, not
    // settable). This test is only about the SELECT-side guard, so it
    // stamps the bit the way refreshHiddenDerived() itself would.
    m.vertexMarks[0] |= Mesh.Marks.Hide;
    const uint e01 = m.edgeIndex(0, 1);
    m.edgeMarks[e01] |= Mesh.Marks.Hide;

    m.selectVertex(0);
    m.selectVertex(1);
    assert(!m.isVertexSelected(0), "selectVertex must refuse a hidden vertex");
    assert(m.isVertexSelected(1));

    const uint e12 = m.edgeIndex(1, 2);
    m.selectEdge(e01);
    m.selectEdge(e12);
    assert(!m.isEdgeSelected(e01), "selectEdge must refuse a hidden edge");
    assert(m.isEdgeSelected(e12));
}

unittest { // T-S0e — the DERIVATION ITSELF owes Select ∧ Hide = ∅
    // (BLOCKER, code review task 0613). T-S0d already proves
    // refreshHiddenDerived() sets the Hide bit on vertices/edges with NO
    // hide command anywhere in the call stack (it rides every geometry
    // commit). If it does not ALSO clear a pre-existing Select bit in
    // that same word write, §3.1 is breakable with Stage 0 code alone:
    // select an element while it is visible, hide it by a route that
    // never calls a hide command (any geometry-mutating commit that
    // happens to remove its last visible incident face), and it ends up
    // both selected and hidden — exactly what the review flagged.
    //
    // Direct marks pokes (not setFaceHidden) so this isolates
    // refreshHiddenDerived()'s OWN obligation from setFaceHidden's
    // (already covered by its own unittest above).
    auto m = makeCube();
    m.syncSelection();

    // Select vertex 0 and the edge (0,1) it anchors WHILE both are still
    // visible — a legal selection at this point.
    m.selectVertex(0);
    const uint e01 = m.edgeIndex(0, 1);
    m.selectEdge(e01);
    assert(m.isVertexSelected(0) && m.isEdgeSelected(e01));

    // Hide vertex 0's three incident faces (f0, f2, f5 — see the comment
    // at the top of the T-S0 block above) directly on faceMarks, then run
    // ONLY the derivation — no hide command, matching T-S0d's own shape.
    m.faceMarks[0] |= Mesh.Marks.Hide;
    m.faceMarks[2] |= Mesh.Marks.Hide;
    m.faceMarks[5] |= Mesh.Marks.Hide;
    m.refreshHiddenDerived();

    assert(m.isVertexHidden(0), "vertex 0's incident faces (f0, f2, f5) are all hidden");
    assert(!m.isVertexSelected(0),
        "a vertex the derivation just hid must not stay selected — no hide command ran");
    assert(m.vertexSelectionOrder[0] == 0, "its order stamp must be cleared too");

    assert(m.isEdgeHidden(e01), "edge (0,1) derives hidden through its now-hidden endpoint");
    assert(!m.isEdgeSelected(e01),
        "an edge the derivation just hid must not stay selected — no hide command ran");
    assert(m.edgeSelectionOrder[e01] == 0, "its order stamp must be cleared too");
}
