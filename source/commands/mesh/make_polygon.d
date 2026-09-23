module commands.mesh.make_polygon;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import selection_product : repointToFaces;
import mesh_edit_delta : MeshEditScope;
import commands.mesh.position_undo  : RecordedUndo;
import commands.mesh.map_edit_undo  : runMapEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// `mesh.makePolygon` — build one face from the current (ordered) vertex
/// selection. Winding follows the vertex SELECTION ORDER (the order in which
/// `selectVertex` was called, stamped in `Mesh.vertexSelectionOrder[]`), with
/// an optional `flip` parameter that reverses it.
///
/// Vertex-command convention: this command fires on lingering vertex selection
/// regardless of the current EditMode (gates only on
/// `mesh.hasAnySelectedVertices()`), matching the existing vertex-command
/// convention used by vert.join and vert.merge.
///
/// Task 1200 — this command has NO refusal gate beyond "give me at least two
/// corners". The reference editor's Make Polygon has none either (ledger row
/// 7): it builds a zero-area triangle from three collinear free vertices, a
/// two-point polygon from two, a self-intersecting quad from a bow-tie click
/// order, and a DUPLICATE face on the ring of an existing one (2 faces -> 3,
/// edge count unchanged). Each of those four cells is frozen in
/// `tests/fixtures/make_polygon_gates.json`.
///
/// So the kernel is asked for `Mesh.MakePolyGates.none`. The gates themselves
/// are not deleted — the Topology Pen builds every face it makes through the
/// same kernel and relies on the zero-area refusal, and it is a different tool
/// with a deliberately different law.
///
/// Rejections (no-op, no snapshot, no undo entry):
///   - fewer than 2 selected vertices. Not a gate that was left in place: a
///     one-corner polygon is a shape nobody has measured on either engine, and
///     the smallest ring the reference was actually seen to build has two.
/// TASK 1903 STAGE L2-g — UNDO IS THE OPERATION-LOG DELTA. Like `mesh.addVertex`
/// this needed no new publisher (`Mesh.addFace` is hooked), and like it the
/// migration's content is the SELECTION half: `repointToFaces` opens with
/// `repointToNothing`, which clears all three domains, and no op-log kind
/// carries a selection-order stamp.
///
/// The selection TYPE does not change: from an edge selection the mode stays
/// edge, from a vertex selection it stays vertex; the new face is selected in
/// the polygon domain behind the current type. Captured, not chosen (task
/// 7132): `make_polygon_selection_mode` in
/// `tests/fixtures/delete_makepoly_lasso_hide_keys.json`, pinned live by
/// `tests/test_make_polygon_edges_key.d`.
class MeshMakePolygon : Command, Operator {
    mixin OperatorActrCommon;
    private RecordedUndo     undo_;
    private DenseSelectionUndo preSel_;

    private bool flip_ = false;

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (see `MeshFlip`).
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.makePolygon"; }
    override string label() const { return "Make Polygon"; }

    override MeshEditScope editScope() const { return MeshEditScope.Geometry; }

    /// See `MeshFlip.isOperationInverse` — a cheap tell, not the observable.
    override bool isOperationInverse() const { return undo_.armed(); }

    override Param[] params() {
        return [
            Param.bool_("flip", "Flip Winding", &flip_, false),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        // EDGE BRANCH (task 7132): in Edges mode with an edge selection the
        // ring is the selected edges walked as ONE chain (`edgeChainWalk`; an
        // open chain closes implicitly), winding from the same neighbour
        // vote. The new face is selected, vertices dropped, the EDGE
        // selection KEPT; a branching, split or sub-3-vertex set is refused.
        // Law: `tests/fixtures/delete_makepoly_lasso_hide_keys.json`.
        if (editMode == EditMode.Edges && mesh.hasAnySelectedEdges()) {
            uint[] walk = edgeChainWalk(*mesh);
            if (walk.length < 3) return false;
            return runMapEdit(this, mesh, undo_, MeshEditScope.Geometry,
                              (ref MeshEditBatch ed) => runKernel(ed, walk, true));
        }

        // Vertex-command convention: fire regardless of EditMode (same as vert.join:53).
        if (!mesh.hasAnySelectedVertices()) return false;

        // --- Collect selected vertices in CLICK ORDER ---
        // `Mesh.selectedVerticesBySelectionOrder` is the one home for that
        // read (task 1210): click-ordered first by ascending stamp, then the
        // ones whose stamp is 0 — "selected via a bulk path that assigned no
        // click order" — by ascending vertex index, so the result is always
        // deterministic. It is shared with `vert.join`, which takes the LAST
        // entry of the same list as the vertex that survives its weld; the two
        // commands read opposite ends of one ordering and must not drift.
        uint[] ordered = mesh.selectedVerticesBySelectionOrder();

        // Pre-check: fewer than 2 distinct verts -> no-op, no snapshot.
        // TWO, not three -- see the class doc: the reference builds a
        // two-point polygon (ledger row 7) and we now do too. The order
        // itself comes from the shared selection-order accessor above,
        // so this command and vert.join read one ordering (task 1210).
        if (ordered.length < 2) return false;

        // THE REFUSAL IS PRE-FLIGHT AND ATOMIC — VERIFIED, NOT ASSUMED. Plan
        // §L2.4 listed this command among the four whose kernel refusal might
        // only be discoverable AFTER a mutation, and predicted it would need
        // an explicit `delta.revert` before returning false. Measured on the
        // kernel: every one of `makePolygonFromVerts`' return paths — the ring
        // floor, the bounds check, the duplicate collapse, and the three
        // gates — answers -1 BEFORE its single `addFace`, so the
        // `snap.restore(*mesh)` this replaces was rolling back a mutation that
        // cannot happen. The kernel below may simply answer false from inside
        // the batch.
        const bool applied_ = runMapEdit(this, mesh, undo_, MeshEditScope.Geometry,
                              (ref MeshEditBatch ed) => runKernel(ed, ordered, false));
        return applied_;
    }

    /// The one mutating body, under whichever arm `runMapEdit` chose.
    private bool runKernel(ref MeshEditBatch ed, uint[] ordered, bool fromEdges) {
        // Recording arm only — the redo arm keeps the first capture, the hatch
        // has the snapshot.
        if (ed.recording() && !preSel_.filled()) preSel_.capture(ed.mesh);

        immutable int fi = ed.mesh.makePolygonFromVerts(
            ordered, flip_, /*autoOrient*/true, Mesh.MakePolyGates.none);
        if (fi < 0) return false;

        // Post-success: re-point at the PRODUCT — the new face — and drop the
        // vertices it consumed. The selection TYPE is left alone (see the
        // class doc): the face is selected in the polygon domain only.
        if (fromEdges) {
            // Edge branch: the edge selection is the input AND survives.
            // (the kernel already grew the selection planes for the face)
            auto m = &ed.mesh();
            m.clearVertexSelection();
            m.clearFaceSelection();
            m.selectFace(fi);
        } else {
            repointToFaces(&ed.mesh(), [cast(uint) fi]);
        }
        return true;
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `runMapEdit` raises the flag only
        // when the delta came back NON-EMPTY, and `Command.revert` answers the
        // empty case — and the never-applied case — before this body is entered.
        undo_.revert(*mesh);
        preSel_.restore(*mesh);
    }
}

/// The selected edges as one vertex ring, or `[]` when they are not a single
/// chain. A closed loop starts at the first selected edge (selection order,
/// then index) and runs from its stored `v0` to `v1`; an open chain starts at
/// the end whose edge was selected first. A single edge answers its two
/// vertices (the caller refuses rings under 3). Refused: a vertex of degree
/// > 2, and more than one component — which with degrees <= 2 also covers
/// "more than two open ends", since each path owns exactly two. Winding is
/// NOT decided here; the kernel's neighbour vote does it. Pinned by
/// `tests/unit/make_polygon_edge_chain_test.d`.
uint[] edgeChainWalk(ref const Mesh m) {
    import std.algorithm : sort;
    struct E { uint ei; int order; }
    E[] sel;
    foreach (ei; 0 .. m.edges.length) {
        if (!m.isEdgeSelected(ei)) continue;
        const int ord = (ei < m.edgeSelectionOrder.length)
                      ? m.edgeSelectionOrder[ei] : 0;
        sel ~= E(cast(uint) ei, ord > 0 ? ord : int.max);
    }
    // By-construction guard: `evaluate` never calls with no edge selected, so
    // this can only redden as a RangeError on `sel[0]` below.
    if (sel.length == 0) return null;
    sel.sort!((a, b) => a.order != b.order ? a.order < b.order : a.ei < b.ei);

    // Vertex -> positions (into `sel`) of its incident selected edges.
    size_t[][uint] inc;
    foreach (k, e; sel)
        foreach (v; m.edges[e.ei]) inc[v] ~= k;
    foreach (v, list; inc)
        if (list.length > 2) return null;

    // Start: a closed loop at sel[0].v0 -> v1; an open chain at the degree-1
    // end whose incident edge comes first in selection order.
    uint start = m.edges[sel[0].ei][0];
    uint cur   = m.edges[sel[0].ei][1];
    size_t prevEdge = 0;
    size_t best = size_t.max;
    // In `sel` order, stored v0 before v1: deterministic (an AA is not).
    ends: foreach (k, e; sel)
        foreach (v; m.edges[e.ei])
            if (inc[v].length == 1) { best = k; start = v; break ends; }
    if (best != size_t.max) {
        const e = m.edges[sel[best].ei];
        cur = (e[0] == start) ? e[1] : e[0];
        prevEdge = best;
    }
    uint[] walk = [start, cur];
    size_t used = 1;
    foreach (_; 1 .. sel.length) {
        size_t next = size_t.max;
        foreach (k; inc[cur]) if (k != prevEdge) { next = k; break; }
        // By-construction guard: an open chain's far end has no other selected
        // edge; without this break `sel[next]` is a RangeError, never a wrong ring.
        if (next == size_t.max) break;
        const e = m.edges[sel[next].ei];
        cur = (e[0] == cur) ? e[1] : e[0];
        prevEdge = next;
        ++used;
        if (cur == start) break;                       // loop closed
        walk ~= cur;
    }
    if (used != sel.length) return null;               // another component
    return walk;
}
