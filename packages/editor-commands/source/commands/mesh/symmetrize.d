module commands.mesh.symmetrize;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import vibe3d.editing.contracts.editmode;
import math   : Vec3;
import vibe3d.editing.params.params : Param;
import vibe3d.mesh.change.change_bus : MeshEditScope;
import commands.mesh.position_undo : PositionUndo;
import toolpipe.packets : SymmetryPacket, SubjectPacket;
import symmetry : rebuildPairing, rebuildPairingTopological, applySymmetryMirror;

/// One-shot command that snaps a drifted-symmetric mesh back to exact symmetry by
/// ABSOLUTE-reflecting the driver side onto the partner side across an axis-aligned
/// plane.  Reuses `applySymmetryMirror` (the same absolute position-copy primitive
/// used during interactive deformation) with an all-true selection mask and
/// `baseSide` set to the caller-specified driver side.
///
/// Pairing is rebuilt locally — this command is self-contained and does not read
/// from any pipeline stage or SymmetryStage.  It therefore works headlessly via
/// `/api/command` with no toolpipe state required.
///
/// Undo is a positional snapshot (like MeshJitter / MeshTransform): `revert`
/// writes back the pre-apply positions.  No topology is ever changed — symmetrize
/// only moves vertex positions.
///
/// `topology:false` (default): spatial pairing — pairs each vertex with the mesh
/// vertex nearest to its mirror image within `epsilon`.  Works for small drift.
/// `topology:true`: connectivity-based pairing — walks mesh connectivity from
/// on-plane seam vertices; pairs large-drift meshes the spatial builder cannot.
/// Requires a connected on-plane seam (shared seam vertices between the two
/// halves); degrades to no-pairing (safe: nothing moves) on disconnected meshes.
///
/// On-plane vertices (within `epsilon` of the plane) are projected onto the plane.
/// Unpaired off-plane vertices are left untouched (safe degradation).
///
/// A no-op check diffs the pre-apply snapshot against the live positions after
/// `applySymmetryMirror` — no history entry is pushed when nothing actually moved
/// (avoids spurious undo stack growth on an already-symmetric mesh).
class MeshSymmetrize : Command, Operator {
    mixin OperatorActrCommon;

    // Param-backed schema fields — plain T so &field works.
    private string axis_     = "X";
    private string side_     = "positive";
    private bool   topology_ = false;
    private float  offset_   = 0.0f;
    private float  epsilon_  = 1e-4f;

    // Positional undo snapshot. Kept after task 1903 §L0-b as the TRACKER-OFF
    // ORACLE and as the movement gate's pre-image — `undo_` below serves the
    // default undo path.
    private Vec3[] prevPositions;

    // Recorded `Kind.SetPos` undo (task 1903 §L0-b).
    private PositionUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 1903 §L0-b,
        /// witness W-b2). THIS COMMAND HAS NO FORWARD POSITION WRITE OF ITS
        /// OWN — its entire forward is the `applySymmetryMirror` call below —
        /// so "recorded nothing" is a state in which the census reads 0, the
        /// forward geometry is right, and `revert()` still answers `true` off
        /// the legacy array. Only reading the log sees it. `version
        /// (unittest)`, so this is not a door in a shipped build; `public` on
        /// the declaration and NOT a `public:` section.
        public ref const(PositionUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.symmetrize"; }
    override string label() const { return "Symmetrize"; }

    override Param[] params() {
        return [
            Param.enum_ ("axis",     "Axis",              &axis_,
                         [["X","X"],["Y","Y"],["Z","Z"]], "X"),
            Param.enum_ ("side",     "Driver Side",       &side_,
                         [["positive","Positive"],["negative","Negative"]], "positive"),
            Param.bool_ ("topology", "Topological Pairing", &topology_, false),
            Param.float_("offset",   "Plane Offset",      &offset_,   0.0f),
            Param.float_("epsilon",  "Tolerance",         &epsilon_,  1e-4f).min(1e-7f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.vertices.length == 0) return false;
        if (axis_.length != 1
         || (axis_[0] != 'X' && axis_[0] != 'Y' && axis_[0] != 'Z'))
            return false;
        // §2.4 — all three guards above resolve BEFORE any batch opens; this
        // command has no `throw`, so those `return false`s are the whole set.

        // REDO (CommandHistory.redo): re-run the kernel UNRECORDED and keep
        // the first delta. The kernel rebuilds its own pairing from the
        // restored pre-op mesh and its own params — it reads no pipeline state
        // at all — so the replay lands where the first run landed.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed);
            ed.close();
            return ok;
        }
        auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
        const ok = applyKernel(ed);
        undo_.arm(this, ed.close());
        if (!ok) { undo_.disarm(this); return false; }
        return true;
    }

    // -----------------------------------------------------------------------
    // THE RECORDING STRATEGY IS shape (D), AND IT IS THE ONLY ONE AVAILABLE
    // (plan §L0.3; task 1903 §L0-b).
    //
    // This command makes ZERO forward position writes of its own: its entire
    // forward is the `applySymmetryMirror(mesh, …)` call below, in
    // `packages/interaction-query/source/symmetry.d` — a module this stage may not change (its other
    // callers are `source/tools/transform/**`, task 1905/T2's zone) and which
    // writes `mesh.vertices[…]` RAW. Under a RECORDING batch a raw write
    // produces no op-log entry, because `alias mesh this` makes that spelling
    // compile. So the recorder cannot be a write and cannot be an index list
    // either: the writer's own `alsoTouched` output is not one (see the
    // movement gate below, which had already measured that). It is a DIFF
    // against the pre-op image the command already keeps.
    // -----------------------------------------------------------------------
    private bool applyKernel(ref MeshEditBatch ed) {
        // Positional snapshot — taken BEFORE apply so we can diff and revert.
        // It is TWO things at once now: the movement gate's reference and
        // `recordPositionDiff`'s pre-image. It used to be three — the third
        // was the EMPTY-DELTA revert arm's source, an arm reachable only on
        // `!undo_.armed()`, which task 2500 made unreachable by answering
        // that state in `Command.revert` before any body runs. The arm went
        // with the predicate that reached it.
        prevPositions = mesh.vertices.dup;

        // Build a self-contained SymmetryPacket.
        SymmetryPacket sp;
        sp.enabled    = true;
        sp.axisIndex  = (axis_[0] == 'X') ? 0 : (axis_[0] == 'Y') ? 1 : 2;
        sp.offset     = offset_;
        sp.epsilonWorld = epsilon_;
        sp.baseSide   = (side_ == "positive") ? +1 : -1;

        // Plane: unit normal along the chosen axis, plane point = normal * offset.
        Vec3 n;
        if      (sp.axisIndex == 0) n = Vec3(1, 0, 0);
        else if (sp.axisIndex == 1) n = Vec3(0, 1, 0);
        else                        n = Vec3(0, 0, 1);
        sp.planeNormal = n;
        sp.planePoint  = n * offset_;

        // Build the pairing into separate locals, then assign into sp — mirrors
        // the pattern in stages/symmetry.d:82-99 to avoid aliasing sp fields
        // as both in-param and out-param in the same call.
        int[]  pairOf;
        bool[] onPlane;
        int[]  vertSign;
        if (topology_)
            rebuildPairingTopological(*mesh, sp, pairOf, onPlane, vertSign);
        else
            rebuildPairing           (*mesh, sp, pairOf, onPlane, vertSign);
        sp.pairOf   = pairOf;
        sp.onPlane  = onPlane;
        sp.vertSign = vertSign;

        // Apply: whole-mesh mask (all-true) + baseSide → driver side preserved,
        // partner side snapped to mirror of driver.  On-plane verts projected.
        // Unpaired verts untouched.
        auto selected    = new bool[](mesh.vertices.length);  selected[]    = true;
        auto alsoTouched = new bool[](mesh.vertices.length);  alsoTouched[] = false;
        applySymmetryMirror(mesh, sp, selected, alsoTouched);

        // THE RECORDER, placed immediately after the write it records. On an
        // unrecorded batch it early-outs before the O(V) compare.
        ed.recordPositionDiff(prevPositions);

        // Movement gate: diff pre-apply snapshot vs live positions.
        // Do NOT use alsoTouched — it under-reports on-plane projection
        // changes and over-reports no-op mirror writes (see plan §Undo shape).
        // That sentence is also why the recorder above is a diff: an
        // under-reporting index list loses a vertex from the delta, and the
        // one it loses comes back at its POST-op position on undo.
        bool moved = false;
        foreach (i; 0 .. prevPositions.length) {
            if (i < mesh.vertices.length && mesh.vertices[i] != prevPositions[i]) {
                moved = true;
                break;
            }
        }
        if (!moved) return false;   // already symmetric — no history entry

        ed.commitChange(MeshEditScope.Position);
        return true;
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `RecordedUndo.arm` raises the flag
        // only for a NON-EMPTY delta, and `Command.revert` answers both the
        // empty-edit case and the never-applied case before this body runs. The
        // hand-rolled `setVertexPositions(touchedIdx, touchedPrev)` fallback that
        // used to sit under this line was reachable ONLY on `!armed()`, so it is
        // gone with the predicate that reached it.
        undo_.revert(*mesh);
    }
}

