module commands.mesh.vert_merge;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import change_bus : MeshEditScope;
import snapshot : SelectionSnapshot;
import mesh_edit_delta : MeshEditDelta, MeshEditScope,
                        captureSelectedEdgeEnds, restoreSelectedEdgeEnds,
                        acceptRecordedEdit;
import params : Param;

/// Tier 1.2: `vert.merge`. Welds selected vertices that are within
/// `dist` of each other (range=fixed) or coincident (range=auto, eps≈0).
/// Faces that collapse to < 3 unique verts are dropped — `keep` (the
/// "keep 1-vertex polygons" option) is recognized but not yet honored,
/// since vibe3d doesn't store degenerate polys.
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L10-a; the whole-mesh
/// `MeshSnapshot` is gone. There is no fork to select between: this file never
/// carried `undoTrackerEnabled()`, so the recording batch is unconditional,
/// exactly as in `commands/mesh/cleanup.d` after Stage L5-c. Redo re-runs the
/// kernel BATCHLESS from the restored pre-op state.
///
/// WHY THIS CLASS WENT FIRST OF THE THIRTEEN, and it is not size. It is the
/// ONLY member of the topo-misc family whose entire operation log comes from
/// the weld — `Mesh.weldVerticesByMask` and nothing else. Everywhere else in
/// the family the same weld arrives mixed with a collapse (`vert.join`,
/// `mesh.collapse`) or a face drop (`mesh.unify`), and a defect in the weld's
/// own machinery reads as the other kernel's. So a red here is attributable
/// and a red there is not.
///
/// THE THREE THINGS ITS DELTA CARRIES THAT NO COUNT CAN SEE, each closed by a
/// named prerequisite rather than by a belt in this file:
///
///   * the pre-weld WINDINGS. `Mesh.applyVertexRemapAndRebuild`'s single
///     `rewriteFaces` is armed as of Stage L10-P2; before that the revert
///     brought the windings back REMAPPED while V, F and every mark word
///     round-tripped and `revert()` answered true;
///   * edge-set membership that MERGED onto a survivor. `Kind.EdgeSetRekey`
///     (task 2310) records the pre-image, because a merge is not invertible
///     entry by entry;
///   * Point-domain map VALUES on the vertex the weld consumed
///     (`Kind.RemoveVerts`' map payload, task 2330). Before it, a re-inserted
///     vertex came back with its weight zeroed and the map LENGTH right.
///
/// WHAT THE DELTA STILL CANNOT CARRY, and therefore what the belts below are
/// for — MEASURED as the exact residual of an armed revert on this funnel
/// (`tests/unit/face_reindex_arming_test.d`, the
/// `applyVertexRemapAndRebuild` cell): the SELECT bit of `faceMarks` and
/// `edgeMarks`. The kernel's tails (`setFaceMarksFrom(…, ~Marks.Select)`,
/// `clearFaceSelectionResize`, `clearEdgeSelectionResize`) run AFTER the face
/// rewrite, so no face entry can describe them. The NON-Select bits of
/// `faceMarks` DO come back on their own and are not belted here.
///
/// AND WHAT IS *NOT* HERE, stated because its absence is a measurement: no
/// `preMaps_`. `commands/mesh/cleanup.d` carries that belt for the Point-map
/// residual this class's prerequisite closed; an inert belt is green that
/// looks like coverage.
class MeshVertMerge : Command, Operator {
    mixin OperatorActrCommon;

    private MeshEditDelta      delta_;
    private SelectionSnapshot  preSel_;       // vertex/face index-keyed
    private uint[]             preEdgeEnds_;  // flat [a,b, a,b, …]
    /// Set once `evaluate` has recorded a delta. It discriminates FIRST RUN
    /// from REDO — `evaluate` is called again on redo and must re-run the
    /// kernel batchless or the second run records a second delta over the
    /// first — and it is `revert()`'s guard: an instance whose `evaluate`
    /// refused holds an empty delta and must not replay it, which is exactly
    /// what the deleted `if (!snap.filled) return false;` did.
    private bool               recorded_;

    private string range_ = "auto";
    private float  dist_  = 0.001f;
    private bool   keep_  = false;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "vert.merge"; }
    override string label() const { return "Merge Vertices"; }

    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry;
    }

    override Param[] params() {
        return [
            Param.enum_("range", "Range", &range_,
                        [["auto", "Automatic"], ["fixed", "Fixed"]],
                        "auto"),
            Param.float_("dist", "Distance", &dist_, 0.001f)
                 .min(0.0001f).max(100.0f).fmt("%.4f"),
            Param.bool_ ("keep", "Keep 1-Vertex Polygons", &keep_, false),
        ];
    }

    override bool paramEnabled(string name) const {
        if (name == "dist") return range_ == "fixed";
        return true;
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (!mesh.hasAnySelectedVertices()) return false;

        // range:auto ("Automatic") uses a tiny eps to weld only
        // coincident verts (within 1e-5 in linear distance ≈ 1e-10
        // squared). range:fixed honors the user-supplied dist parameter.
        double eps = (range_ == "fixed")
            ? cast(double)dist_
            : 1e-5;
        double epsSq = eps * eps;

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS — no batch open means every tracker hook takes its
        // `editRecorder_ is null` early-out — and keep the FIRST delta rather
        // than record a second one over it.
        if (recorded_) {
            size_t rw;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh,
                              MeshEditScope.Geometry | MeshEditScope.Marks);
                rw = ed.weldVerticesByMask(mesh.selectedVertices, epsSq, true);
                ed.close();
            }
            return rw != 0;
        }

        // The belts, captured BEFORE the batch opens, for the residual named
        // at this class's doc comment.
        preSel_      = SelectionSnapshot.capture(*mesh);
        preEdgeEnds_ = captureSelectedEdgeEnds(*mesh);

        // TASK 1903 STAGE L10-P0 gave this command its first `MeshEditBatch`
        // (axis 0: the COMMIT SEAM — the weld commits several times on its way
        // through, and inside a frame they defer and stamp ONCE at `close()`).
        // STAGE L10-a makes it RECORDING, which is axis 2: the undo.
        //
        // THE RAII HANDLE, not `beginEditBatch`/`endEditBatch` + a
        // `scope(failure)`: the unwind path is then the destructor's, which
        // pops the frame WITHOUT stamping and ticks `changeBus.batchLeaks` —
        // the suite asserts that stays 0.
        size_t welded;
        {
            auto ed = MeshEditBatch(*mesh,
                          MeshEditScope.Geometry | MeshEditScope.Marks);
            // average:true — merged vertex lands at the per-cluster centroid
            // of its coincident members (reference parity), not the
            // lowest-index pos.
            welded = ed.weldVerticesByMask(mesh.selectedVertices, epsSq, true);
            delta_ = ed.close();
        }

        // THE POST-CLOSE RULING, shared with `mesh.delete` / `mesh.remove` /
        // `mesh.cleanup` (ruling Q-K6). `welded == 0` is the HONEST refusal
        // this command has always made. `welded > 0` with an EMPTY delta is
        // the contradiction, and it ticks `changeBus.emptyDeltaOverMutation`
        // instead of passing silently — before Stage L10-P2 armed
        // `applyVertexRemapAndRebuild` that arm was NOT reachable here (the
        // compaction always logs), which is why the arming commit came first
        // and this one second.
        //
        // §6.5 item 1: the refusal returns `false` and drops every image. It
        // is NOT spelled as a `false` from `revert()`: that pops the entry off
        // BOTH history stacks and truncates the suffix after it
        // (`command_history.d`, regression 0099).
        if (!acceptRecordedEdit(welded, delta_)) {
            delta_       = MeshEditDelta.init;
            preSel_      = SelectionSnapshot.init;
            preEdgeEnds_ = null;
            return false;
        }
        recorded_ = true;
        return true;
    }

    override bool revert() {
        // An instance whose `evaluate` refused holds an empty delta and every
        // pre-image nulled; replaying it would run the belts below over a mesh
        // they were never sized against. It is correct to answer false here
        // ONLY because the funnel never records an entry for a refused
        // forward — see the ruling in `evaluate`.
        if (!recorded_) return false;

        delta_.revert(*mesh);     // LIFO inverse replay restores geometry

        // Vertex/face selection re-aligns by index — the delta restored those
        // index spaces exactly. `preSel_` also restores EDGE selection by
        // index, but the re-derived edge order is not index-stable across
        // `rebuildEdges`, so OVERRIDE it with the endpoint-keyed capture.
        preSel_.restore(*mesh);
        mesh.clearEdgeSelection();
        restoreSelectedEdgeEnds(*mesh, preEdgeEnds_);
        return true;
    }
}
