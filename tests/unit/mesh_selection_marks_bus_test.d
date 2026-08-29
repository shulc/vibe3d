// mesh_selection_marks_bus_test -- the change-bus accumulator every selection and marks setter feeds.
//
// One cell, and a wide one: each single setter must note its `Marks` class
// AND the matching selection domain, a bulk setter must do it once, a
// restore that changes nothing must note NOTHING, and the batched form must
// fold to one delivery. The no-op half is the one only this block sees -- a
// setter that notes unconditionally is green on every other row here.
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
module tests.unit.mesh_selection_marks_bus_test;

import mesh;
import math : Vec3;
import mesh_edit_delta : MeshEditScope;
import change_bus : changeBus;
import tests.unit.mesh_by_value_gate;

// The seam's compile-time gate: nothing in this module may take a `Mesh` by
// VALUE. `tests/unit/mesh_by_value_gate.d` says why nothing behavioural
// catches that, and carries the gate's own positive control.
private void byValueGateAnchor() {}
mixin MeshByValueGate!(__traits(parent, byValueGateAnchor));

unittest { // noteSelectionChange / marks-setter accumulation (change-bus Stage 5)
    import change_bus : SelDomain;
    import mesh_edit_delta : MeshEditScope;

    // Single setters accumulate Marks + the matching domain bit, and stay
    // version-stable (selection is not a version-bumping geometry change).
    //
    // TASK 1906 STAGE 3 — THE BATCH IS WHAT MAKES THE ACCUMULATOR READABLE.
    // The setters are delivering publishers now, and a delivery takes and
    // ZEROES `undelivered*_`, so outside a batch these asserts would read a
    // word the setter has already handed over. Inside one the delivery only
    // REGISTERS, which is the same state the pre-stage-3 rig observed and
    // the same state every command's kernel runs in.
    {
        Mesh m = makeCube();
        m.resetSelection();
        beginDeliveryBatchGlobal();
        scope(exit) endDeliveryBatchGlobal();
        m.undeliveredChanges_ = 0; m.undeliveredSelDomains_ = 0;
        const ver0 = m.mutationVersion;
        const top0 = m.topologyVersion;

        m.selectVertex(0);
        assert(m.undeliveredChanges_ & MeshEditScope.Marks, "selectVertex notes Marks");
        assert(m.undeliveredSelDomains_ & SelDomain.Vertex, "selectVertex notes Vertex domain");

        m.selectEdge(0);
        assert(m.undeliveredSelDomains_ & SelDomain.Edge, "selectEdge notes Edge domain");

        m.selectFace(0);
        assert(m.undeliveredSelDomains_ & SelDomain.Face, "selectFace notes Face domain");

        // All three domains accumulate (OR), and NO version bump occurred —
        // marks setters must remain version-stable.
        assert(m.undeliveredSelDomains_ ==
            (SelDomain.Vertex | SelDomain.Edge | SelDomain.Face),
            "domains OR-accumulate");
        assert(m.mutationVersion == ver0, "selection must NOT bump mutationVersion");
        assert(m.topologyVersion == top0, "selection must NOT bump topologyVersion");
    }

    // Bulk setXSelectedFrom compares-before-set: a no-op re-apply of the SAME
    // selection does not publish; a real change does. Batched for the same
    // reason as the block above.
    {
        Mesh m = makeCube();
        m.resetSelection();
        beginDeliveryBatchGlobal();
        scope(exit) endDeliveryBatchGlobal();
        m.undeliveredChanges_ = 0; m.undeliveredSelDomains_ = 0;
        bool[] sel; sel.length = m.vertices.length;
        sel[2] = true;

        m.setVerticesSelectedFrom(sel);           // real change
        assert(m.undeliveredSelDomains_ & SelDomain.Vertex, "first apply publishes");

        m.undeliveredChanges_ = 0; m.undeliveredSelDomains_ = 0;
        m.setVerticesSelectedFrom(sel);           // identical re-apply: no-op
        assert(m.undeliveredSelDomains_ == 0,
            "re-applying identical selection must NOT publish");
        assert((m.undeliveredChanges_ & MeshEditScope.Marks) == 0,
            "no-op restore must NOT note Marks");

        sel[2] = false; sel[5] = true;            // actual change
        m.setVerticesSelectedFrom(sel);
        assert(m.undeliveredSelDomains_ & SelDomain.Vertex,
            "a real selection change publishes again");
    }

    // Bulk setXSelectedFrom restores the "deselected => order==0" invariant
    // for elements it deselects, matching the per-element select*/deselect*
    // setters. Establishes rank via the per-element path FIRST (so the
    // deselected element carries a real nonzero order, unlike the no-op
    // test above where index 2's order was already 0 from init) then
    // bulk-deselects it and checks: (a) its order is zeroed, (b) the
    // surviving element's rank is untouched, and (c) the order-counter
    // itself is untouched by the bulk call (proving rank monotonicity
    // isn't reset — a later per-element select continues from the prior
    // high-water mark rather than restarting).
    {
        Mesh m = makeCube();
        m.resetSelection();

        m.selectFace(0);
        m.selectFace(1);
        assert(m.faceSelectionOrder[0] == 1, "face 0 gets rank 1");
        assert(m.faceSelectionOrder[1] == 2, "face 1 gets rank 2");
        assert(m.faceSelectionOrderCounter == 2, "counter at 2 after two selects");

        bool[] fsel; fsel.length = m.faces.length;
        fsel[0] = true;                            // keep face 0, drop face 1
        m.setFacesSelectedFrom(fsel);

        assert(m.faceSelectionOrder[1] == 0,
            "bulk-deselected face's order is zeroed (the invariant)");
        assert(m.faceSelectionOrder[0] == 1,
            "surviving face keeps its rank");
        assert(m.selectedFaces[0] == true && m.selectedFaces[1] == false,
            "marks reflect the bulk apply");
        assert(m.faceSelectionOrderCounter == 2,
            "bulk deselect must NOT touch the order counter");

        m.selectFace(2);
        assert(m.faceSelectionOrder[2] == 3,
            "next per-element select continues the rank sequence (counter wasn't reset)");
        assert(m.faceSelectionOrderCounter == 3);

        // Mirror for the other two domains (vertex + edge) so all three
        // bulk setters are covered directly.
        m.selectVertex(0);
        m.selectVertex(1);
        assert(m.vertexSelectionOrder[0] == 1 && m.vertexSelectionOrder[1] == 2);
        assert(m.vertexSelectionOrderCounter == 2);
        bool[] vsel; vsel.length = m.vertices.length;
        vsel[0] = true;
        m.setVerticesSelectedFrom(vsel);
        assert(m.vertexSelectionOrder[1] == 0, "bulk-deselected vertex order zeroed");
        assert(m.vertexSelectionOrder[0] == 1, "surviving vertex keeps rank");
        assert(m.vertexSelectionOrderCounter == 2, "vertex counter untouched by bulk deselect");

        m.selectEdge(0);
        m.selectEdge(1);
        assert(m.edgeSelectionOrder[0] == 1 && m.edgeSelectionOrder[1] == 2);
        assert(m.edgeSelectionOrderCounter == 2);
        bool[] esel; esel.length = m.edges.length;
        esel[0] = true;
        m.setEdgesSelectedFrom(esel);
        assert(m.edgeSelectionOrder[1] == 0, "bulk-deselected edge order zeroed");
        assert(m.edgeSelectionOrder[0] == 1, "surviving edge keeps rank");
        assert(m.edgeSelectionOrderCounter == 2, "edge counter untouched by bulk deselect");
    }

    // clear* compares-before-set: clearing an already-empty selection is
    // inert. Batched for the same reason as the blocks above (stage 3).
    {
        Mesh m = makeCube();
        m.resetSelection();
        beginDeliveryBatchGlobal();
        scope(exit) endDeliveryBatchGlobal();
        m.undeliveredChanges_ = 0; m.undeliveredSelDomains_ = 0;
        m.clearFaceSelection();                   // nothing selected → inert
        assert(m.undeliveredSelDomains_ == 0,
            "clearing empty face selection must NOT publish");

        m.selectFace(1);
        m.undeliveredChanges_ = 0; m.undeliveredSelDomains_ = 0;
        m.clearFaceSelection();                   // drops a live selection
        assert(m.undeliveredSelDomains_ & SelDomain.Face,
            "clearing a live face selection publishes Face");
    }
}
