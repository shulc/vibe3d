module commands.mesh.vert_join;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import selection_product : repointToNothing;
import view;
import editmode;
import math : Vec3;
import change_bus : MeshEditScope;
import mesh_edit_delta : MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;
import params : Param;

/// Tier 1.2: `vert.join`. Collapses the selected vertices to a single point —
/// the centroid (`average=true`) or the SURVIVOR's position (`average=false`)
/// — then welds them.
///
/// THREE MEASURED LAWS live here (task 1210, dogfood ledger rows 11 + 21,
/// frozen in `tests/fixtures/vert_join_survivor.json` and
/// `tests/fixtures/vert_join_degenerate.json`):
///
///   1. THE SURVIVOR IS THE LAST-SELECTED VERTEX, not the lowest-indexed one.
///      Select (0,0,0) then (2,0,0) on a 2x1 plate and the reference keeps
///      (2,0,0); we used to keep (0,0,0). The DISCRIMINATOR is the same pair in
///      the opposite order — there "last selected" and "lowest index" name the
///      same vertex, the two engines agree, and that agreement is what rules
///      out the rival reading "highest index". Confirmed again on three
///      vertices of a valence-6 pole. The order comes from
///      `Mesh.selectedVerticesBySelectionOrder` (a stamp every user-reachable
///      selection path maintains); with `average=true` the survivor's IDENTITY
///      still decides which vertex's per-vertex data (weight maps, morph
///      deltas, set membership) the join carries forward, even though the
///      POSITION is the centroid either way.
///
///   2. THE JOINED VERTEX IS NEVER SWEPT AWAY. Collapsing every vertex of a
///      plate drops every face, and the tail compaction used to take the mesh
///      to EMPTY; the reference leaves ONE FREE VERTEX at the join point. This
///      is `vert.join`'s own rule and not a general "welds keep orphans" one —
///      the same capture CUTS every face of that plate and is left with zero
///      vertices.
///
///   3. `keep` IS HONOURED. It keeps the polygons the join leaves with two
///      distinct corners: joining a fan's hub to one of its ring vertices
///      leaves the reference 8 faces, two of them TWO-POINT polygons, where we
///      left 6. The previous comment here said "`keep` is recognized but not
///      yet honored" — that admission is now a measurement.
///
/// The post-command selection is CLEARED (`repointToNothing`): the reference
/// leaves nothing selected after a join, the same answer the vertex split gave
/// in task 1180's selection-product port.
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L10-b; the whole-mesh
/// `MeshSnapshot` is gone. This class is a weld-group member — the collapse
/// runs first and the weld's `applyVertexRemapAndRebuild` tail is what needed
/// Stage L10-P2's arming — and it is the one member whose weld carries a
/// POLICY (`JoinWeldPolicy`), so its cell in `weld_merge.json` is the only one
/// that measures law 2 (the pinned survivor) surviving a round trip.
///
/// THE SELECTION IS `DenseSelectionUndo`, and here it is load-bearing rather
/// than a belt: the forward CLEARS the selection outright
/// (`repointToNothing`, law 3), so there is nothing in the mesh for an
/// index-keyed re-derive to read after the revert.
class MeshVertJoin : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    /// Set once `evaluate` recorded a delta: FIRST RUN vs REDO, and
    /// `revert()`'s guard. It is the role the deleted `if (!snap.filled)`
    /// played.
    private bool               recorded_;

    private bool average_ = true;
    private bool keep_    = false;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "vert.join"; }
    override string label() const { return "Join Vertices"; }

    override Param[] params() {
        // The `keep` label is kept verbatim, but what was MEASURED is that the
        // flag preserves TWO-point polygons; no cell shows a ONE-point polygon
        // surviving, so the arity floor it lowers stops at 2. If a capture ever
        // produces a one-corner remnant, that is the measurement that would
        // move `JoinWeldPolicy.keepTwoPointFaces` down another step.
        return [
            Param.bool_("average", "Average", &average_, true),
            Param.bool_("keep",    "Keep 1-Vertex Polygons", &keep_, false),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (!mesh.hasAnySelectedVertices()) return false;

        // Law 1: the SURVIVOR is the last-selected vertex. The ordered read is
        // shared with mesh.makePolygon so the tie-breaks cannot drift.
        const ordered = mesh.selectedVerticesBySelectionOrder();
        if (ordered.length < 2) return false;     // single vert — no-op

        Vec3 sum = Vec3(0, 0, 0);
        foreach (vi; ordered) sum = sum + mesh.vertices[vi];
        const int survivor = cast(int) ordered[$ - 1];

        Vec3 target = average_
            ? Vec3(sum.x / ordered.length, sum.y / ordered.length,
                   sum.z / ordered.length)
            : mesh.vertices[survivor];

        auto selMask = mesh.selectedVertices;   // materialise once

        // Laws 1-3 in one place: keep `survivor` as the cluster head, pin it
        // so a join that consumed every face still leaves it behind, and
        // honour `keep`.
        JoinWeldPolicy policy;
        policy.survivor           = survivor;
        policy.keepOrphanSurvivor = true;
        policy.keepTwoPointFaces  = keep_;

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernels
        // BATCHLESS — no recording frame means every tracker hook takes its
        // `editRecorder_ is null` early-out — and keep the FIRST delta rather
        // than record a second one over it.
        if (recorded_) {
            size_t rw;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kJoinScope);
                ed.collapseVerticesByMask(selMask, target);
                rw = ed.weldVerticesByMask(selMask, 1e-12, false, policy);
                if (rw != 0) repointToNothing(mesh);
                ed.close();
            }
            return rw != 0;
        }

        // The dense selection image, taken BEFORE the batch opens — and here
        // it is the whole undo of the selection, not a belt: the forward
        // CLEARS every domain (law 3).
        preSel_.capture(*mesh);

        // TASK 1903 STAGE L10-P0 gave this command its first `MeshEditBatch`
        // (axis 0, the commit seam: the collapse and the weld each committed
        // on their own before it, and inside a frame they defer and stamp ONCE
        // at `close()`). STAGE L10-b makes it RECORDING — axis 2, the undo.
        //
        // THE BATCH CLOSES BEFORE THE ROLLBACK, so the refusal path leaves no
        // frame open and `changeBus.batchLeaks` unmoved (§S-6).
        size_t welded;
        {
            auto ed = MeshEditBatch(*mesh, kJoinScope);
            ed.collapseVerticesByMask(selMask, target);
            // Tiny eps is enough since collapseVerticesByMask sets exact
            // equality.
            welded = ed.weldVerticesByMask(selMask, 1e-12, false, policy);
            // The reference leaves NOTHING selected after a join (task 1210).
            if (welded != 0) repointToNothing(mesh);
            delta_ = ed.close();
        }

        // THE POST-CLOSE RULING (§S-6, ruling Q-K6), and the two arms behind
        // its single `false` roll back differently:
        //
        //   * `welded == 0` is this class's pre-existing GIGO case — the verts
        //     did not actually weld, but `collapseVerticesByMask` has already
        //     moved every one of them onto `target`. The partial edit is
        //     replayed BACKWARDS and every image dropped, which is what the
        //     deleted `snap.restore` did;
        //   * `welded > 0` with an EMPTY delta is the contradiction
        //     `acceptRecordedEdit` ticks `changeBus.emptyDeltaOverMutation`
        //     for. Nothing rolls back — there is nothing to replay, and
        //     re-imposing the pre-op selection over a mesh whose arrays have
        //     already moved would RESIZE the mark arrays back to the pre-op
        //     length. The live defect is documented at that counter.
        if (!acceptRecordedEdit(welded, delta_)) {
            if (welded == 0) {
                delta_.revert(*mesh);
                preSel_.restore(*mesh);
            }
            delta_  = MeshEditDelta.init;
            preSel_ = DenseSelectionUndo.init;
            return false;
        }
        recorded_ = true;
        return true;
    }

    /// The declared scope, written once for the recording and the redo frame.
    /// `Marks` is not decoration: `repointToNothing` clears all three
    /// selection domains, and declaring `Geometry` alone would declare less
    /// than the command does.
    private enum uint kJoinScope =
        MeshEditScope.Geometry | MeshEditScope.Marks;

    override bool revert() {
        // An instance whose `evaluate` refused holds an empty delta and a
        // nulled selection image; replaying it would run `preSel_` over a mesh
        // it was never sized against. Answering false here is correct ONLY
        // because the funnel records no history entry for a refused forward.
        if (!recorded_) return false;
        delta_.revert(*mesh);     // LIFO inverse replay restores geometry
        preSel_.restore(*mesh);   // …then the three selection domains
        return true;
    }
}
