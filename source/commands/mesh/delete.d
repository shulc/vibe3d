module commands.mesh.delete_;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot, SelectionSnapshot;
import mesh_edit_delta : MeshEditDelta, MeshEditTracker, MeshEditScope,
                        captureSelectedEdgeEnds, restoreSelectedEdgeEnds;
import tools.edge_extrude : undoTrackerEnabled;

/// All-true selection mask of length `n`, used when nothing is selected
/// (empty selection ⇒ whole mesh).
private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}

/// Tier 1.1: delete the current selection. Dispatches by edit mode:
///   - Vertices: delete every face incident to a selected vert
///   - Edges:    delete every face incident to a selected edge
///   - Polygons: delete the selected faces directly
/// In all cases this funnels through Mesh.deleteFacesByMask, which
/// re-derives edges from the surviving faces and drops orphan verts.
///
/// Revert: a full MeshSnapshot of the pre-delete cage by default
/// (VIBE3D_UNDO_TRACKER unset/off). When the tracker is enabled the kernel
/// run is wrapped in a Mesh edit batch and the resulting operation-log
/// MeshEditDelta drives undo (O(Δ) — see doc/undo_change_tracker_plan.md
/// Phase 3); redo re-runs the kernel batchless from the restored pre-op
/// state (the bulk-op forward replay is not used for delete/dissolve, so
/// the kernel is the forward authority and the delta inverts undo only).
class MeshDelete : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;

    // Phase 3 delta path (env-gated). When `useDelta_` is set the undo entry
    // is the operation-log delta + a lightweight pre-op selection capture (the
    // kernel clears selection, so revert must re-overlay it). The snapshot path
    // stays intact as the fallback.
    //
    // Vertex/face selection is captured by INDEX (the delta revert restores the
    // exact pre-op vertex/face index space, so the index-keyed SelectionSnapshot
    // re-aligns). Edge selection is captured by ENDPOINT PAIR — edges are
    // re-derived by rebuildEdges on revert and their ORDER is not guaranteed to
    // match the pre-op array, so an index-keyed restore would select the wrong
    // edges (doc §1.3, the same reason extrude uses EdgeSelByEnds).
    //
    // SUBPATCH (POL_TYPE) plane is ALSO captured by face index and re-overlaid on
    // revert. The op-log delta's RemoveFaces only carries the subpatch bit for the
    // faces it DROPS; surviving-but-shifted faces have their Subpatch bit scrambled
    // by the face re-insertion (faces.insertInPlace shifts `faces` but not the
    // faceMarks word). The snapshot path restores the whole faceMarks word
    // (Select+Subpatch together) and so never had this gap. Capturing the full
    // pre-op subpatch plane here, index-keyed (the delta revert restores the exact
    // pre-op face index space), re-establishes it bit-identically — mirroring how
    // preSel_ re-overlays the Select plane. (Found by the Phase 4 burn-in gate:
    // test_marks_authority B4 failed only under the delta path.)
    private MeshEditDelta      delta_;
    private SelectionSnapshot  preSel_;     // vertex/face index-keyed
    private uint[]             preEdgeEnds_; // flat [a,b, a,b, …] for edge mode
    private bool[]             preSubpatch_; // face Subpatch (POL_TYPE) plane, by pre-op face index
    private bool               useDelta_;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.delete"; }

    // Change-scope metadata (Phase 4 §b). Delete touches topology (faces removed,
    // verts dropped via compaction) + marks (selection cleared/re-derived).
    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry | MeshEditScope.Marks;
    }
    // True iff this instance actually stored an operation-log delta (tracker on);
    // the snapshot escape hatch (VIBE3D_UNDO_TRACKER=off) reports false honestly.
    override bool isOperationInverse() const { return useDelta_; }

    override string label() const {
        final switch (editMode) {
            case EditMode.Vertices: return "Delete Vertices";
            case EditMode.Edges:    return "Delete Edges";
            case EditMode.Polygons: return "Delete Polygons";
        }
    }

    // The kernel mutation, shared by the first run and the redo re-run.
    // Returns the number of affected elements. Selection is read live (after
    // undo the SelectionSnapshot has restored it, so the redo mask matches).
    private size_t runKernel() {
        const all = mesh.nothingSelected(editMode);
        final switch (editMode) {
            case EditMode.Vertices:
                return mesh.dissolveVerticesByMask(
                    all ? allTrue(mesh.vertices.length) : mesh.selectedVertices);
            case EditMode.Edges:
                auto n = mesh.removeEdgesByMask(
                    all ? allTrue(mesh.edges.length) : mesh.selectedEdges);
                if (n > 0) mesh.dissolveDegree2Verts();
                return n;
            case EditMode.Polygons:
                return mesh.deleteFacesByMask(
                    all ? allTrue(mesh.faces.length) : mesh.selectedFaces);
        }
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        // Redo path: the delta already recorded the first run; re-run the
        // kernel BATCHLESS (no batch open ⇒ Ph1 hooks inert ⇒ no double
        // record) from the restored pre-op selection.
        if (useDelta_) {
            const affected = runKernel();
            if (affected == 0) return false;
            refreshCaches();
            return true;
        }

        // Empty selection ⇒ operate on the whole mesh (mesh.nothingSelected
        // is the single source of truth for the "everything is selected"
        // convention; runKernel feeds an all-true mask in that case).
        if (undoTrackerEnabled()) {
            // Delta path: capture the pre-op selection, run the kernel inside a
            // Mesh edit batch so it self-records an operation-log delta.
            preSel_      = SelectionSnapshot.capture(*mesh);
            preEdgeEnds_ = captureSelectedEdgeEnds(*mesh);
            preSubpatch_ = mesh.isSubpatch.dup;   // full POL_TYPE plane, by face index
            auto rec = MeshEditTracker();
            mesh.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
            const affected = runKernel();
            delta_ = mesh.endEditBatch();
            if (affected == 0 || delta_.isEmpty) {
                // No-op / degenerate delta — fall back to the snapshot path so
                // a well-formed (but trivial) command is still recordable.
                delta_       = MeshEditDelta.init;
                preSel_      = SelectionSnapshot.init;
                preEdgeEnds_ = null;
                preSubpatch_ = null;
                return false;
            }
            useDelta_ = true;
            refreshCaches();
            return true;
        }

        // Snapshot path (default / VIBE3D_UNDO_TRACKER=off).
        snap = MeshSnapshot.capture(*mesh);
        const affected = runKernel();
        if (affected == 0) {
            snap = MeshSnapshot.init;
            return false;
        }
        refreshCaches();
        return true;
    }

    override bool revert() {
        if (useDelta_) {
            delta_.revert(*mesh);     // LIFO inverse replay restores geometry
            // Re-overlay the pre-op selection on the restored geometry. Vertex/
            // face selection re-aligns by index. preSel_ also restores edge
            // selection by INDEX, but the re-derived edge order is not index-
            // stable across rebuildEdges, so OVERRIDE the edge selection with
            // the endpoint-keyed capture (clear the index-keyed edges first,
            // then re-resolve the recorded endpoints through edgeIndexMap).
            preSel_.restore(*mesh);
            // Re-overlay the Subpatch (POL_TYPE) plane: the delta revert restored
            // the pre-op face index space, so the index-keyed capture re-aligns.
            // setFaceSubpatchFrom touches only the Subpatch bit, leaving the Select
            // bits preSel_ just restored intact (different bit in the same word).
            if (preSubpatch_.length)
                mesh.setFaceSubpatchFrom(preSubpatch_);
            mesh.clearEdgeSelection();
            restoreSelectedEdgeEnds(*mesh, preEdgeEnds_);
            refreshCaches();
            return true;
        }
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
