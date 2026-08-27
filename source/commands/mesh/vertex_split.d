module commands.mesh.vertex_split;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import selection_product : repointToNothing;
import mesh_edit_delta : MeshEditScope;
import commands.mesh.position_undo  : RecordedUndo;
import commands.mesh.map_edit_undo  : runMapEdit, revertMapEditEmptyOk;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// `mesh.vertexSplit` — unweld each selected vertex: keep it in its
/// lowest-indexed incident face and give every later incident face its
/// own coincident copy. This is the inverse of weld / `vert.merge`.
///
/// Only the Vertex edit mode is meaningful; the command is a no-op in
/// Edge and Polygon modes (no vertices selected → evaluate returns false).
/// A vertex that is already incident to only one face produces no copies
/// and the command returns an error (no-op).
///
/// TASK 1903 STAGE L2-e — UNDO IS THE OPERATION-LOG DELTA. `splitVerticesByMask`
/// now repoints its corners through `Mesh.setFaceWindings`, so a recording batch
/// comes back with `[AddVerts, MeshMapDelta, ReshapeFaces]` instead of
/// `[AddVerts]` alone — under which the reverse truncated the coincident copies
/// while the surviving windings still named them, and `finalize`→`buildLoops`
/// THREW.
///
/// Q-L2-3, ANSWERED FROM THE CODE (plan §L2.9 left it to a reading). The kernel
/// also propagates Point-domain map VALUES onto the copies, by writing
/// `MeshMap.data` / `MeshMap.present` directly, and the question was whether
/// that wants `Kind.MapValueDelta` as its second production consumer. It does
/// NOT, and the reason is structural rather than a preference: that kind's
/// whole contract is a value edit over an UNCHANGED index space (its recorder
/// refuses where a corner space can move), and every row this kernel writes is
/// on a vertex it has just APPENDED. There is no pre-image to restore, and the
/// reverse does not need one — `finalize`'s `resizeAllMeshMaps` shrinks the
/// arrays with the vertices and the copied rows go with them. Recording them
/// would be a payload nobody reads.
class MeshVertexSplit : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;      // the hatch's arm only
    private RecordedUndo     undo_;
    /// The pre-op selection — `repointToNothing` clears all three domains and
    /// the op-log has nothing that puts it back. See
    /// `commands/mesh/selection_undo.d`.
    private DenseSelectionUndo preSel_;
    /// The forward SUCCEEDED — see `commands/mesh/flip.d`.
    private bool             applied_;

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (see `MeshFlip`).
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.vertexSplit"; }
    override string label() const { return "Split Vertices"; }

    override MeshEditScope editScope() const { return MeshEditScope.Geometry; }

    /// See `MeshFlip.isOperationInverse` — a cheap tell, not the observable.
    override bool isOperationInverse() const { return undo_.armed(); }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (!mesh.hasAnySelectedVertices()) return false;

        // Read the operand mask BEFORE the batch opens (same discipline as
        // evalVertices in collapse.d): `selectedVertices` is a materialising
        // VIEW, and the restore below writes the selection planes.
        auto sel = mesh.selectedVertices;

        // THE REFUSAL IS PRE-FLIGHT AND ATOMIC — and at L2-e it became so BY
        // CONSTRUCTION rather than by rollback. `splitVerticesByMask` now runs
        // a counting pass before its first `addVertex` and answers 0 from
        // there, so the `snap.restore(*mesh)` this replaces was undoing a
        // mutation that can no longer happen. That matters because under a
        // delta the old shape is not available: `MeshEditDelta` carries no
        // pre-image of the face array, so nothing downstream could detect a
        // half-revert, and a `false` from a Model entry's `revert()` truncates
        // the undo stack (plan §L2.4, regression 0099).
        applied_ = runMapEdit(mesh, undo_, snap, MeshEditScope.Geometry,
                              (ref MeshEditBatch ed) => runKernel(ed, sel));
        return applied_;
    }

    /// The one mutating body, under whichever arm `runMapEdit` chose.
    private bool runKernel(ref MeshEditBatch ed, bool[] sel) {
        // Recording arm only — the redo arm keeps the first capture, the hatch
        // has the snapshot.
        if (ed.recording() && !preSel_.filled()) preSel_.capture(ed.mesh);

        if (ed.mesh.splitVerticesByMask(sel) == 0) return false;

        // Task 1180: the input vertex is GONE — it was unwelded into two or
        // more coincident copies — and the reference selects neither copy, so
        // the post-op selection is empty. Leaving the input's index selected
        // (what this did before) names one arbitrary copy of a vertex the user
        // no longer has.
        repointToNothing(&ed.mesh());
        return true;
    }

    override bool revert() {
        // `…EmptyOk`, and the `if (!snap.filled) return false;` this replaces
        // was DELETED rather than translated (regression 0099).
        if (!revertMapEditEmptyOk(mesh, undo_, snap, applied_)) return false;
        // ONLY on the delta arm — the hatch's snapshot already restored every
        // selection plane.
        if (undo_.armed()) preSel_.restore(*mesh);
        return true;
    }
}
