module commands.mesh.sweep;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math    : Vec3;
import params  : Param;
import change_bus : MeshEditScope;
import mesh_edit_delta : MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Revolve a selected edge profile (or polygon) around a principal axis to
/// produce a surface of revolution.
///
/// Profile source (determined by the current edit mode):
///   - **Edge mode**: `extractSelectedEdgeChain` reads the selected edge set
///     and produces an ordered vertex chain.  Open chains (2 degree-1
///     endpoints) and closed cycles (all degree-2) are both accepted.
///   - **Polygon mode**: exactly one selected face is required; its vertex
///     ring is used as a closed profile.
///
/// Parameters:
///   - count      — total number of profile copies including the original.
///                  Must be >= 2.
///   - axis       — principal rotation axis: "X", "Y", or "Z".
///   - center     — pivot point for the rotation (default: origin).
///   - angle      — total sweep angle in radians.  360° (≈6.2831853) is the
///                  default; values < 2π − 1e-3 produce an open arc sweep.
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L10-e; the whole-mesh
/// `MeshSnapshot` is gone. Two things landed together:
///
///   1. THE BATCH GREW OVER THE PROFILE-FACE DELETION (P-L10-4). Stage E2 left
///      it outside on purpose and measured what that cost — a polygon-mode
///      sweep read `unbatchedGeometryCommits` **+2** where an edge-cycle sweep
///      of the same closed profile read **+0**. Those two ticks are gone now,
///      and `tests/test_mesh_sweep.d`'s `unbatchedPoly == 2` is a `0`, which
///      is what that assertion's own message asked for.
///      It is not only the seam: a delta recorded across the revolve alone
///      describes the appends and says NOTHING about the deletion, so its
///      revert would leave the profile face gone.
///   2. THE MARKS. `revolveProfileEx` calls `clearVertexSelection`, the only
///      kernel in this family that does, and
///      `tests/unit/mesh_ops/revolve_test.d` measured the kernel's revert as
///      geometry-EXACT with the mark planes ABSENT — its `:643` note asked
///      this stage for exactly that. `DenseSelectionUndo` is the answer, at
///      the command, where the pre-op image still exists.
///
/// WHAT IS INERT ON THIS PATH: no weld runs here, so the edge-set MERGE record
/// (task 2310) and the Point-domain map payload (task 2330) on
/// `Kind.RemoveVerts` are never exercised. `mesh.sweep` also has NO cell in
/// `weld_merge.json` — the stage's stand cannot present a profile plus a path
/// — so its oracle is `revolve_test.d`, at the kernel, plus the suite.
class MeshSweep : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    /// Set once `evaluate` recorded a delta: FIRST RUN vs REDO, and
    /// `revert()`'s guard — the role the deleted `if (!snap.filled)` played.
    private bool               recorded_;

    private int    count_  = 8;
    private string axis_   = "Y";
    private Vec3   center_ = Vec3(0, 0, 0);
    // 2π in radians — full 360° revolve (default).
    private float  angle_  = 6.2831853f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.sweep"; }
    override string label() const { return "Sweep"; }

    override Param[] params() {
        return [
            Param.int_  ("count",  "Count",           &count_,  8).min(2),
            Param.enum_ ("axis",   "Axis",             &axis_,
                         [["X", "X"], ["Y", "Y"], ["Z", "Z"]], "Y"),
            Param.vec3_ ("center", "Center",           &center_, Vec3(0, 0, 0)),
            Param.float_("angle",  "Angle (rad)",      &angle_,  6.2831853f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        // Parameter guards.
        if (count_ < 2) return false;
        if (axis_.length != 1
         || (axis_[0] != 'X' && axis_[0] != 'Y' && axis_[0] != 'Z'))
            return false;

        // Extract profile and closed flag from the current edit mode.
        uint[] profile;
        bool   profileClosed;
        uint   profileFaceIdx = uint.max;   // set for polygon mode to delete after

        if (editMode == EditMode.Polygons) {
            // Exactly one face must be selected.
            uint[] selFaces;
            foreach (fi; 0 .. mesh.faces.length)
                if (mesh.isFaceSelected(fi)) selFaces ~= cast(uint)fi;
            if (selFaces.length != 1) return false;
            profileFaceIdx = selFaces[0];
            profile = mesh.faceVertexRing(profileFaceIdx).dup;
            profileClosed = true;
        } else if (editMode == EditMode.Edges) {
            profile = mesh.extractSelectedEdgeChain(profileClosed);
            if (profile.length == 0) return false;
        } else {
            return false;   // vertex mode — not supported
        }

        // The dense selection image, taken BEFORE the batch opens. NOT
        // re-taken on the redo arm: a second capture would image the POST-op
        // selection, and the first one is the one `revert()` needs.
        if (!recorded_) preSel_.capture(*mesh);

        // TASK 1903 Stage E2 — the kernel takes `ref MeshEditBatch`, so the
        // batch opens HERE, at the command boundary, and never inside the
        // kernel (plan §4.1). One sweep now bumps its version stamp,
        // re-derives hidden geometry and delivers to the change bus ONCE at
        // `close()` instead of once per `addVertex`/`addFace` the kernel makes
        // on its way through — and BOTH profile arms do, which is the part E2
        // changes. Until this commit `revolveProfileEx` opened a transitional
        // batch around its CLOSED-profile ring loop only (Stage D3, plan
        // §4.4a), leaving the open-profile arm committing per face. Measured
        // over `/api/changes`, `unbatchedGeometryCommits` per `mesh.sweep`
        // (arc of 4 segments, count=6, 360°): open +49 → **+0**.
        //
        // WHAT IS STILL UNBATCHED HERE, MEASURED AND OWNED: the polygon-mode
        // source-face deletion below. A polygon-mode sweep reads **+2** where
        // an edge-cycle sweep of the same closed profile reads **+0** — which
        // is how we know the remaining two are the deletion and not the
        // kernel. With the batch taken away entirely (`Mesh.commitChange`'s
        // deferral disabled) the same two cells read **+62** and **+60**.
        //
        // WHICH TWO: traced by printing `flags` at the counter's own tick site,
        // they are `0x4` then `0x6` — Polygons, from the `rebuildEdges()`
        // `deleteFacesByMask` runs over the surviving faces (its `inserted` arm
        // commits Polygons on its own), then Geometry, from that primitive's
        // tail commit. `compactUnreferenced` is NOT one of the two: it
        // early-returns at `removed == 0`, before its commit, because this
        // command leaves `startAngle` at 0 and `revolveProfileEx` then has
        // ring 0 REUSE the profile's own vertices — deleting the profile face
        // orphans nothing. It only fires when the deletion DOES orphan a
        // vertex, which on this family means `RadialSweepTool`'s non-zero
        // Start Angle (ring 0 rotated off the profile): the same
        // `deleteFacesByMask` call reads **+4** there, measured.
        //
        // TASK 1903 STAGE L10-e CLOSED BOTH OF THOSE. The batch is RECORDING
        // — `close()`'s delta is what `revert()` replays — and it SPANS the
        // polygon-mode `deleteFacesByMask` below, so the +2 measured above is
        // now 0 and the deletion is inside the log that has to invert it.
        //
        // No `scope(failure)`, unlike the older `beginEditBatch`/`endEditBatch`
        // spelling at delete.d / remove.d: that pair has no destructor, this
        // handle does. `MeshEditBatch.~this` pops the frame during unwinding —
        // without asserting, because it runs while an exception is in flight —
        // and ticks `changeBus.batchLeaks`, which the suite asserts stays 0.
        size_t inserted;
        {
            auto ed = openBatch();
            inserted = ed.revolveProfile(profile, profileClosed,
                                         count_, axis_[0], center_, angle_);
            // Polygon mode: delete the source profile polygon now that the
            // lateral surface has been built, INSIDE the same frame.
            // `deleteFacesByMask` rebuilds loops internally.
            if (inserted != 0 && profileFaceIdx != uint.max) {
                auto delMask = new bool[](mesh.faces.length);
                delMask[profileFaceIdx] = true;
                ed.deleteFacesByMask(delMask);
            }
            auto d = ed.close();
            if (!recorded_) delta_ = d;
        }

        // THE POST-CLOSE RULING (§S-6, ruling Q-K6). `inserted == 0` is the
        // refusal this command has always made, and it needs no rollback: a
        // `revolveProfile` that inserts nothing has mutated nothing, and the
        // deletion above is gated on it. The other arm — mutated, recorded
        // nothing — ticks `changeBus.emptyDeltaOverMutation`.
        if (recorded_) return inserted != 0;
        if (!acceptRecordedEdit(inserted, delta_)) {
            delta_  = MeshEditDelta.init;
            preSel_ = DenseSelectionUndo.init;
            return false;
        }
        recorded_ = true;
        return true;
    }

    /// The batch this command opens: RECORDING on the first run, UNRECORDED on
    /// the redo. `CommandHistory.redo` re-runs `apply()`, and a second
    /// recording run would record a second delta over the first; unrecorded,
    /// every tracker hook takes its `editRecorder_ is null` early-out.
    private MeshEditBatch openBatch() {
        if (recorded_) return MeshEditBatch.unrecorded(*mesh, kRevolveEditScope);
        return MeshEditBatch(*mesh, kRevolveEditScope);
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
