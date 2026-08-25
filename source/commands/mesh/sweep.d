module commands.mesh.sweep;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math    : Vec3;
import params  : Param;
import snapshot : MeshSnapshot;

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
/// Undo: snapshot-based (MeshSnapshot), consistent with mesh.bridge and
///       mesh.radial_array. Task 1903 Stage E2 put the kernel call inside an
///       UNRECORDED `MeshEditBatch` (the commit seam, plan §5.0 axis 0); the
///       undo record is untouched and moves at **L10**.
class MeshSweep : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

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

        snap = MeshSnapshot.capture(*mesh);

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
        // That deletion is untouched by this stage, and folding it into the
        // batch would be a second edit hiding inside a move (D3's rule, and the
        // reason its review had to narrow the transitional block). It moves
        // with the rest of this command's axis-0 obligation at **L10** (plan
        // §5.0: "axis 0 rides along" with the family's own stage).
        //
        // UNRECORDED, deliberately: undo here is still the whole-mesh `snap`
        // captured just above (plan §5.1 — track 1 is the conversion axis,
        // track 2 is the undo migration, and mixing them in one commit is what
        // §5.1 forbids), so a RECORDING batch would build a full op-log that
        // nothing reads and `close()` would drop. `mesh.sweep` is an **L10**
        // row (plan §5.5, the reindexing half of topo-misc) — that is the
        // stage that turns this into a delta, not L5 and not E2.
        //
        // The batch is scoped to the kernel call ALONE and deliberately does
        // NOT span the polygon-mode `deleteFacesByMask` below: that deletion
        // is unchanged by this stage, and folding it in would be a second edit
        // hiding inside a move (D3's rule at commands/mesh/bridge.d).
        //
        // No `scope(failure)`, unlike the older `beginEditBatch`/`endEditBatch`
        // spelling at delete.d / remove.d: that pair has no destructor, this
        // handle does. `MeshEditBatch.~this` pops the frame during unwinding —
        // without asserting, because it runs while an exception is in flight —
        // and ticks `changeBus.batchLeaks`, which the suite asserts stays 0.
        size_t inserted;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kRevolveEditScope);
            inserted = ed.revolveProfile(profile, profileClosed,
                                         count_, axis_[0], center_, angle_);
            ed.close();
        }
        if (inserted == 0) {
            snap = MeshSnapshot.init;
            return false;
        }

        // Polygon mode: delete the source profile polygon now that the
        // lateral surface has been built.  deleteFacesByMask rebuilds loops
        // internally; snap already covers the pre-mutation state.
        if (profileFaceIdx != uint.max) {
            auto delMask = new bool[](mesh.faces.length);
            delMask[profileFaceIdx] = true;
            mesh.deleteFacesByMask(delMask);
        }

        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
