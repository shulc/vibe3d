module commands.mesh.remove_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot, SelectionSnapshot;
import mesh_edit_delta : MeshEditDelta, MeshEditTracker, MeshEditScope,
                        captureSelectedEdgeEnds, restoreSelectedEdgeEnds,
                        undoTrackerEnabled;

/// All-true selection mask of length `n`, used when nothing is selected
/// (empty selection ⇒ whole mesh).
private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}

/// Tier 1.1: "Remove" (`vert.remove` / `edge.remove false` /
/// `poly.remove`, dispatched by edit mode). Remove and Delete are
/// DISTINCT topological operations, not aliases:
///   - Vertices: both dissolve (identical result).
///   - Edges:    both dissolve the edge / merge the incident faces.
///   - Polygons: Delete removes the faces AND their now-orphaned points;
///     Remove removes ONLY the faces and leaves the orphaned points
///     floating in place (keepOrphans — task 0465). This mirrors the
///     reference editor, where poly-Delete drops points but poly-Remove
///     keeps them.
/// The two commands stay separate so the menu structure, shortcut layout,
/// and (for polygons) the keep-points semantic can distinguish them.
///
/// Revert: a full MeshSnapshot of the pre-op cage by default; when the
/// VIBE3D_UNDO_TRACKER env toggle is on the kernel run is wrapped in a
/// Mesh edit batch and the resulting operation-log MeshEditDelta drives
/// undo (O(Δ) — doc/undo_change_tracker_plan.md Phase 3). Redo re-runs the
/// kernel batchless from the restored pre-op selection.
class MeshRemove : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    // Phase 3 delta path — see MeshDelete for the rationale. Vertex/face
    // selection is index-keyed (SelectionSnapshot); edge selection is endpoint-
    // keyed (re-derived edge order is not index-stable across rebuildEdges); the
    // Subpatch (POL_TYPE) plane is index-keyed (re-overlaid on revert — the delta
    // only carries the subpatch bit for DROPPED faces, see MeshDelete + the
    // Phase 4 burn-in finding in test_marks_authority).
    private MeshEditDelta      delta_;
    private SelectionSnapshot  preSel_;
    private uint[]             preEdgeEnds_;
    private bool[]             preSubpatch_;
    private bool               useDelta_;

    // Stable label: captured once in runKernel() — see MeshDelete.appliedMode_.
    private EditMode appliedMode_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
        this.appliedMode_ = editMode;   // stable default before apply() runs
    }

    override string name()  const { return "mesh.remove"; }

    // Change-scope metadata (Phase 4 §b) — see MeshDelete.
    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry | MeshEditScope.Marks;
    }
    override bool isOperationInverse() const { return useDelta_; }

    override string label() const {
        final switch (appliedMode_) {
            case EditMode.Vertices: return "Remove Vertices";
            case EditMode.Edges:    return "Remove Edges";
            case EditMode.Polygons: return "Remove Polygons";
        }
    }

    // The kernel mutation, shared by the first run and the redo re-run.
    // Delete and Remove differ ONLY for edges (both dissolve there); for
    // vertices and polygons they are identical. Selection is read live.
    //
    // effectiveDeleteMode is used instead of the raw editMode so that a
    // selection that lives in a DIFFERENT element type from the active mode is
    // honoured. Without the redirect, nothingSelected(current) fires true and
    // the whole-mesh all-true mask wipes the mesh even though a selection
    // exists elsewhere (task 0110).
    private size_t runKernel() {
        const mode = mesh.effectiveDeleteMode(editMode);
        appliedMode_ = mode;   // freeze for label() — stable after apply()
        const all  = mesh.nothingSelected(mode);
        final switch (mode) {
            case EditMode.Vertices:
                // keepOrphans (measured, task delete-remove-dissolve): matches
                // vertex Delete — removes EXACTLY the selected verts and keeps
                // collateral orphans as loose points (reference-editor parity).
                return mesh.dissolveVerticesByMask(
                    all ? allTrue(mesh.vertices.length) : mesh.selectedVertices,
                    /*keepOrphans=*/true);
            case EditMode.Edges:
                auto n = mesh.removeEdgesByMask(
                    all ? allTrue(mesh.edges.length) : mesh.selectedEdges);
                // Scope the 2-valent cleanup to the removed edges' endpoints
                // (task 0474): a pre-existing 2-valent vertex the remove did not
                // touch — a 90° corner, a straight-through midpoint elsewhere —
                // must survive (reference-editor parity). keepOrphans keeps
                // collateral orphans the merge/cleanup leaves behind (task
                // delete-remove-dissolve).
                if (n > 0) mesh.dissolveDegree2Verts(mesh.edgeDeleteRegion(),
                                                     /*keepOrphans=*/true);
                return n;
            case EditMode.Polygons:
                // Remove ≠ Delete for polygons: Remove drops ONLY the faces
                // and leaves orphaned vertices floating (keepOrphans=true),
                // whereas Delete (mesh.delete) also compacts orphans. This
                // matches the reference editor's poly-Remove vs Delete
                // distinction (task 0465).
                return mesh.deleteFacesByMask(
                    all ? allTrue(mesh.faces.length) : mesh.selectedFaces,
                    /*keepOrphans=*/true);
        }
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        // Redo: re-run the kernel BATCHLESS (no double record).
        if (useDelta_) {
            const affected = runKernel();
            if (affected == 0) return false;
            return true;
        }

        if (undoTrackerEnabled()) {
            preSel_      = SelectionSnapshot.capture(*mesh);
            preEdgeEnds_ = captureSelectedEdgeEnds(*mesh);
            preSubpatch_ = mesh.isSubpatch.dup;
            auto rec = MeshEditTracker();
            mesh.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
            const affected = runKernel();
            delta_ = mesh.endEditBatch();
            if (affected == 0 || delta_.isEmpty) {
                delta_       = MeshEditDelta.init;
                preSel_      = SelectionSnapshot.init;
                preEdgeEnds_ = null;
                preSubpatch_ = null;
                return false;
            }
            useDelta_ = true;
            return true;
        }

        snap = MeshSnapshot.capture(*mesh);
        const affected = runKernel();
        if (affected == 0) {
            snap = MeshSnapshot.init;
            return false;
        }
        return true;
    }

    override bool revert() {
        if (useDelta_) {
            delta_.revert(*mesh);
            // See MeshDelete.revert: preSel_ restores vertex/face by index;
            // override the (index-unstable) edge selection with the endpoint
            // capture.
            preSel_.restore(*mesh);
            if (preSubpatch_.length)
                mesh.setFaceSubpatchFrom(preSubpatch_);
            mesh.clearEdgeSelection();
            restoreSelectedEdgeEnds(*mesh, preEdgeEnds_);
            return true;
        }
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
