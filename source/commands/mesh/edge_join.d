module commands.mesh.edge_join;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import params : Param;
import change_bus : MeshEditScope;
import mesh_edit_delta : MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;
import math : Vec3;

/// Join two selected edges sharing a degree-2 vertex into a single edge by
/// dissolving the shared middle vertex. Inverse of mesh.split_edge.
///
/// mode 0 (plain join):   endpoints preserved, middle vertex removed.
/// mode 1 (averaged):     each sub-edge endpoint moves to the midpoint of its
///                        own sub-edge before the middle vertex is dissolved.
///                        Result: single edge (midpoint(a,m), midpoint(m,b)).
///
/// Guards (evaluate returns false → status:error):
///   - not in Edges edit mode
///   - not exactly 2 edges selected
///   - selected edges share no common vertex (disjoint)
///   - shared vertex has edge-degree ≠ 2
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L10-c; the whole-mesh
/// `MeshSnapshot` is gone. This command was already nearly free: its kernel
/// `Mesh.dissolveVerticesByMask` describes its own face change
/// (`ReshapeFaces` + `RemoveFaces`) and is on the §5.3 audit's **do-not-arm**
/// list, so this migration adds no arming at all — arming it batch-wide is
/// what re-runs Stage K's red row.
///
/// WHAT IS INERT ON THIS PATH: no weld runs here, so the edge-set MERGE record
/// (task 2310) and the Point-domain map payload (task 2330) on
/// `Kind.RemoveVerts` are never exercised. A green cell for this command says
/// nothing about either.
class MeshEdgeJoin : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    /// Set once `evaluate` recorded a delta: FIRST RUN vs REDO, and
    /// `revert()`'s guard — the role the deleted `if (!snap.filled)` played.
    private bool               recorded_;

    private int mode_ = 0;  // 0 = plain join, 1 = averaged

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.edgeJoin"; }
    override string label() const { return mode_ == 0 ? "Join" : "Join Averaged"; }

    override Param[] params() {
        return [
            Param.int_("mode", "Mode", &mode_, 0).min(0).max(1),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Edges) return false;

        // Collect exactly 2 selected edge indices.
        int e0 = -1, e1 = -1;
        foreach (i, sel; mesh.selectedEdges) {
            if (!sel) continue;
            if      (e0 < 0) e0 = cast(int)i;
            else if (e1 < 0) e1 = cast(int)i;
            else             return false;  // more than 2 selected
        }
        if (e0 < 0 || e1 < 0) return false;  // fewer than 2 selected

        // Find the shared vertex m and the far endpoints a, b.
        uint ea0 = mesh.edges[e0][0], ea1 = mesh.edges[e0][1];
        uint eb0 = mesh.edges[e1][0], eb1 = mesh.edges[e1][1];

        uint m = uint.max, a = uint.max, b = uint.max;
        if      (ea0 == eb0) { m = ea0; a = ea1; b = eb1; }
        else if (ea0 == eb1) { m = ea0; a = ea1; b = eb0; }
        else if (ea1 == eb0) { m = ea1; a = ea0; b = eb1; }
        else if (ea1 == eb1) { m = ea1; a = ea0; b = eb0; }
        else                 return false;  // disjoint — no shared vertex

        // Guard: shared vertex must have exactly 2 incident edges.
        int degree = 0;
        foreach (e; mesh.edges)
            if (e[0] == m || e[1] == m) ++degree;
        if (degree != 2) return false;

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS — no recording frame means every tracker hook takes its
        // `editRecorder_ is null` early-out — and keep the FIRST delta rather
        // than record a second one over it.
        if (recorded_) {
            size_t rw;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kJoinScope);
                rw = runKernel(ed, a, b, m);
                ed.close();
            }
            return rw != 0;
        }

        // The dense selection image, taken BEFORE the batch opens: the kernel's
        // tail calls `resetSelection`, and the reverted mesh gets a FRESH edge
        // index space out of `finalize`'s `rebuildEdges`, so the edge half has
        // to be re-keyed by endpoints.
        preSel_.capture(*mesh);

        // TASK 1903 STAGE L10-P0 gave this command its first `MeshEditBatch`
        // (axis 0, the commit seam: the position write, the dissolve and the
        // selection reset each stamped and delivered on their own before it).
        // STAGE L10-c makes it RECORDING — axis 2, the undo.
        size_t n;
        {
            auto ed = MeshEditBatch(*mesh, kJoinScope);
            n = runKernel(ed, a, b, m);
            delta_ = ed.close();
        }

        // THE POST-CLOSE RULING (§S-6, ruling Q-K6), AND THE ROLLBACK THIS
        // FILE ASKED FOR IN WRITING. The deleted comment here said: *"In mode 1
        // the two endpoint positions have already moved by the time the
        // dissolve can refuse, so dropping the snapshot here leaves them moved
        // with no undo entry … Migrating this command (Stage L10-c) is where
        // it gets a rollback or a measurement."* It gets the rollback: the
        // partial edit is replayed BACKWARDS out of the delta and every image
        // dropped. Whether the arm is reachable at all — every guard above has
        // already established a 2-valent shared vertex — is still NOT
        // measured, which is precisely why the safe branch is the one to write.
        //
        // The second arm behind the same `false` — mutated, recorded nothing —
        // ticks `changeBus.emptyDeltaOverMutation` inside `acceptRecordedEdit`
        // and is NOT rolled back: there is nothing to replay, and re-imposing
        // the pre-op selection over a mesh whose arrays have already moved
        // would resize the mark arrays back to the pre-op length.
        if (!acceptRecordedEdit(n, delta_)) {
            if (n == 0) {
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

    private enum uint kJoinScope =
        MeshEditScope.Geometry | MeshEditScope.Marks;

    /// The optional midpoint write plus the dissolve, written once so the
    /// recording run and the redo run cannot drift.
    private size_t runKernel(ref MeshEditBatch ed, uint a, uint b, uint m)
    {
        // Mode 1 (averaged): shift each sub-edge endpoint to its own midpoint.
        //   a → midpoint(a, m),  b → midpoint(b, m)
        if (mode_ == 1) {
            Vec3 vm = mesh.vertices[m];
            // SPELLED `mesh.`, NOT `ed.`, and that is deliberate: what makes
            // this write batched is that a frame is OPEN, not which handle
            // names it — `MeshEditBatch` has `alias mesh this`, so the two
            // spellings compile to the same call. The census in
            // `tests/unit/commit_seam_census_test.d` pins this exact literal
            // as the two-sided half of its `raw == 0` row (task 2310), so
            // renaming the receiver here reads to that gate as "the recorded
            // write vanished".
            mesh.setVertexPositions([a, b],
                [(mesh.vertices[a] + vm) * 0.5f,
                 (mesh.vertices[b] + vm) * 0.5f]);
        }

        // Dissolve the middle vertex: drops m from every incident face
        // boundary, rebuilds edges, and compacts the now-orphan vertex out.
        auto mask = new bool[](mesh.vertices.length);
        mask[m] = true;
        immutable size_t n = ed.dissolveVerticesByMask(mask);
        if (n != 0) ed.resetSelection();
        return n;
    }

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
