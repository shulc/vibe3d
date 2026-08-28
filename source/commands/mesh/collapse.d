module commands.mesh.collapse;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math : Vec3;
import change_bus : MeshEditScope;
import mesh_edit_delta : MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Tier 1.x: `mesh.collapse`. Collapses the selected elements to a point,
/// merging topology and removing faces that degenerate below 3 unique
/// corners as a result.
///
/// - Vertices: all selected verts → one combined centroid (no island/
///   connectivity notion — matches `vert.join average:true` semantics;
///   deliberately a distinct command).
/// - Edges: each connected island of selected edges → its midpoint/centroid.
///   A single selected edge collapses to the midpoint of its two endpoints.
/// - Polygons: each connected island of selected faces → the centroid of
///   the island's corner vertices.
///
/// In the Edge and Polygon scopes two disjoint selections collapse to their
/// own independent centroids (per-island behavior). This is the documented
/// vibe3d default; the difference vs a single-combined-centroid is visible
/// only when multiple disconnected islands are selected.
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L10-b; the whole-mesh
/// `MeshSnapshot` is gone. ONE class, THREE kernels — §6.2's "MeshCollapse ×3"
/// is a miscount of classes that is a correct count of BEHAVIOURS, and the
/// parity fixture carries a cell per mode for exactly that reason.
///
/// EVERY MODE ENDS IN THE WELD, which is why this class is a member of the
/// weld group and could not land before Stage L10-P2 armed
/// `Mesh.applyVertexRemapAndRebuild`'s `rewriteFaces`: without it the revert
/// brought the windings back REMAPPED while V, F and every mark word
/// round-tripped and `revert()` answered true. What a count cannot see, the
/// frozen `weld_merge.json` cells can.
///
/// THE SELECTION IS `DenseSelectionUndo`. The collapse kernels re-derive
/// edges, so the edge half must be re-keyed by ENDPOINTS, and the weld's tails
/// clear selection AFTER the face rewrite so no face entry can describe them.
class MeshCollapse : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "mesh.collapse"; }

    override string label() const {
        final switch (editMode) {
            case EditMode.Vertices: return "Collapse Vertices";
            case EditMode.Edges:    return "Collapse Edges";
            case EditMode.Polygons: return "Collapse Polygons";
        }
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        final switch (editMode) {
            case EditMode.Vertices: return evalVertices();
            case EditMode.Edges:    return evalEdges();
            case EditMode.Polygons: return evalPolygons();
        }
    }

    private bool evalVertices() {
        if (!mesh.hasAnySelectedVertices()) return false;

        // Capture the selection mask once before any mutation.
        auto sel = mesh.selectedVertices;

        Vec3 sum   = Vec3(0, 0, 0);
        int  count = 0;
        foreach (vi; 0 .. mesh.vertices.length) {
            if (vi >= sel.length || !sel[vi]) continue;
            sum = sum + mesh.vertices[vi];
            ++count;
        }
        if (count < 2) return false;   // single vert — no-op

        Vec3 centroid = Vec3(sum.x / count, sum.y / count, sum.z / count);

        // REDO: re-run the kernel BATCHLESS and keep the first delta — see
        // the note above `revert()`.
        if (undoRecorded()) {
            size_t rw;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kCollapseScope);
                ed.collapseVerticesByMask(sel, centroid);
                rw = ed.weldVerticesByMask(sel, 1e-12);
                ed.close();
            }
            return rw != 0;
        }

        preSel_.capture(*mesh);
        // TASK 1903 STAGE L10-P0 gave this arm its `MeshEditBatch` (axis 0,
        // the commit seam); STAGE L10-b makes it RECORDING, which is axis 2 —
        // the undo. The batch closes BEFORE the rollback below, so the refusal
        // path leaves no frame open (§S-6).
        size_t welded;
        {
            auto ed = MeshEditBatch(*mesh, kCollapseScope);
            ed.collapseVerticesByMask(sel, centroid);
            welded = ed.weldVerticesByMask(sel, 1e-12);
            delta_ = ed.close();
        }
        if (!accept(welded)) return false;
        return true;
    }

    private bool evalEdges() {
        if (!mesh.hasAnySelectedEdges()) return false;

        // Capture mask before snapshot so the kernel receives the
        // pre-op selection (weldVerticesByMask clears edge selection).
        auto sel = mesh.selectedEdges;

        if (undoRecorded()) {
            size_t rw;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kCollapseScope);
                rw = ed.collapseEdgesByMask(sel);
                ed.close();
            }
            return rw != 0;
        }

        preSel_.capture(*mesh);
        size_t welded;
        {
            auto ed = MeshEditBatch(*mesh, kCollapseScope);
            welded = ed.collapseEdgesByMask(sel);
            delta_ = ed.close();
        }
        if (!accept(welded)) return false;
        return true;
    }

    private bool evalPolygons() {
        if (!mesh.hasAnySelectedFaces()) return false;

        auto sel = mesh.selectedFaces;

        if (undoRecorded()) {
            size_t rw;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kCollapseScope);
                rw = ed.collapseFacesByMask(sel);
                ed.close();
            }
            return rw != 0;
        }

        preSel_.capture(*mesh);
        size_t welded;
        {
            auto ed = MeshEditBatch(*mesh, kCollapseScope);
            welded = ed.collapseFacesByMask(sel);
            delta_ = ed.close();
        }
        if (!accept(welded)) return false;
        return true;
    }

    /// The declared scope of all three arms, written once. `Marks` is not
    /// decoration: every mode rewrites the selection through the weld's
    /// resize tails, and declaring `Geometry` alone would declare less than
    /// the command does.
    private enum uint kCollapseScope =
        MeshEditScope.Geometry | MeshEditScope.Marks;

    /// THE POST-CLOSE RULING, shared by the three arms (§S-6, ruling Q-K6),
    /// and the two arms behind its single `false` are NOT rolled back the
    /// same way:
    ///
    ///   * `welded == 0` is the GIGO case this class has always had — the
    ///     kernel mutated (a collapse writes positions before the weld can
    ///     refuse) and then refused. The partial edit is replayed BACKWARDS
    ///     and every image dropped: `delta.revert` then discard, `return
    ///     false`. NOT "close the batch and record an empty delta", which
    ///     lands a history entry describing nothing;
    ///   * `welded > 0` with an EMPTY delta is the contradiction
    ///     `acceptRecordedEdit` ticks `changeBus.emptyDeltaOverMutation` for.
    ///     NOTHING rolls back, deliberately: there is nothing to replay, and
    ///     re-imposing the pre-op selection over a mesh whose arrays have
    ///     already moved would RESIZE the mark arrays back to the pre-op
    ///     length (`applySelectedFrom_` resizes to its argument). The live
    ///     defect is documented at that counter's declaration.
    private bool accept(size_t welded) {
        if (acceptRecordedEdit(welded, delta_)) {
            noteUndoRecorded();
            return true;
        }
        if (welded == 0) {
            delta_.revert(*mesh);
            preSel_.restore(*mesh);
        }
        delta_  = MeshEditDelta.init;
        preSel_ = DenseSelectionUndo.init;
        return false;
    }

    // REDO, and it is why each arm opens with `if (undoRecorded())`.
    // `CommandHistory.redo` re-runs `apply()` → `evaluate` → the same arm
    // (`editMode` is fixed at construction), so each arm re-runs its own
    // kernel BATCHLESS — no recording frame means every tracker hook takes its
    // `editRecorder_ is null` early-out — and the FIRST delta is kept rather
    // than a second recorded over it.
    protected override void revertImpl() {
        // An instance whose `evaluate` refused holds an empty delta and a
        // nulled selection image; replaying it would run `preSel_` over a mesh
        // it was never sized against. Answering false here is correct ONLY
        // because the funnel records no history entry for a refused forward.
        delta_.revert(*mesh);     // LIFO inverse replay restores geometry
        preSel_.restore(*mesh);   // …then the three selection domains
    }
}
