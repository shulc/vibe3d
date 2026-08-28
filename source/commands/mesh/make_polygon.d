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
/// WHAT NEITHER PATH RESTORES, recorded rather than fixed here: the selection
/// TYPE. `promoteType(EditMode.Polygons)` writes `SelType`, not the mesh, and
/// `MeshSnapshot` never carried it either — so an undo of this command leaves
/// the editor in Polygons mode on BOTH paths. That is unchanged behaviour, not
/// a regression of the migration, and fixing it is a SelType question rather
/// than an undo one.
class MeshMakePolygon : Command, Operator {
    mixin OperatorActrCommon;
    private RecordedUndo     undo_;
    private DenseSelectionUndo preSel_;

    private bool flip_ = false;

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (see `MeshFlip`).
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    // Task 1180: the app's geometry-type funnel (`promoteGeometryType`), taken
    // exactly as `select.convert` takes it. Re-pointing at the new FACE is a
    // geometry selection that changes the element TYPE, and `editMode` is never
    // written independently of the SelType recent-ordering (see seltype.d).
    // Null in unit tests / any host without an ordering — the selection is
    // re-pointed either way, only the type promotion is skipped.
    private void delegate(EditMode) promoteType;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    MeshMakePolygon setPromoteHook(void delegate(EditMode) h) {
        promoteType = h;
        return this;
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
                              (ref MeshEditBatch ed) => runKernel(ed, ordered));
        return applied_;
    }

    /// The one mutating body, under whichever arm `runMapEdit` chose.
    private bool runKernel(ref MeshEditBatch ed, uint[] ordered) {
        // Recording arm only — the redo arm keeps the first capture, the hatch
        // has the snapshot.
        if (ed.recording() && !preSel_.filled()) preSel_.capture(ed.mesh);

        immutable int fi = ed.mesh.makePolygonFromVerts(
            ordered, flip_, /*autoOrient*/true, Mesh.MakePolyGates.none);
        if (fi < 0) return false;

        // Post-success (task 1180): re-point at the PRODUCT — the new face —
        // and drop the vertices it consumed. This is the one command in the
        // family whose product sits a dimension ABOVE its input, so it is also
        // the one that promotes the selection TYPE: selecting a face while the
        // type stayed Vertex is exactly the incoherence the previous comment
        // here named as its reason for leaving the vertices alone. The funnel
        // (not a direct `editMode` write) is what keeps EditMode in lockstep
        // with the SelType ordering, and it promotes WITHOUT dropping the
        // active tool — a selection is not a mode switch.
        repointToFaces(&ed.mesh(), [cast(uint) fi]);
        if (promoteType !is null) promoteType(EditMode.Polygons);
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
