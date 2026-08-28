module commands.mesh.radial_align;

import std.array : uninitializedArray;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math : Vec3;
import params : Param;
import change_bus : MeshEditScope;
import commands.mesh.position_undo : PositionUndo;
import tools.alignment.align_kernels : extractAlignChain, radialAlignTargets, lerp3,
                              MAX_ALIGN_SIDES;

/// Distribute a selected vertex CHAIN at equal angular slots around a
/// circle (task 0361 — replaces the previous sphere-projection algorithm,
/// which did not match the reference "Radial Align" tool: the reference
/// has NO cylinder/sphere mode, only planar `circle`/`nside`). See
/// `tools/align_kernels.d`'s module doc comment for the full captured
/// law: center = mean chain position, radius = mean distance from
/// center, N points at equal `360/N`-degree slots in chain order.
///
/// This one-shot Command has no falloff plumbing (that lives in the
/// interactive `xfrm.radialAlignTool`, tools/radial_align_tool.d, which
/// shares this same kernel) — `weight` here is a plain uniform blend.
class MeshRadialAlign : Command, Operator {
    mixin OperatorActrCommon;
    private uint[] touchedIdx;
    private Vec3[] touchedPrev;
    // Recorded `Kind.SetPos` undo (task 1903 L0-d4).
    private PositionUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 1903 §L0-d,
        /// witness W-d3a). The op-log SHAPE is not derivable from the outside:
        /// a command that records nothing answers `true` from the BASE
        /// `Command.revert` (task 2500) and the mesh is already where the undo
        /// wants it, so every result-shaped assertion — the plane diff, the
        /// redo cell, the parity cell — is GREEN over a deleted recorder. Only
        /// reading the log itself is not.
        /// `version (unittest)`, so this is not a door in a shipped build; both
        /// gate lanes compile the sources with `-unittest`. `public` on the
        /// declaration and NOT a `public:` section — a section marker here
        /// would silently change the protection of every member below it.
        public ref const(PositionUndo) recordedUndo() const return { return undo_; }
    }

    private string mode_   = "circle";
    private int    side_   = 4;
    private float  rotate_ = 0.0f;
    private float  angle_  = 0.0f;
    private float  weight_ = 1.0f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.radial_align"; }
    override string label() const { return "Radial Align"; }

    // `radius`/`centerX/Y/Z` interactive override and `smooth`/`flatten`
    // (Polygons-mode-only smoothing) are intentionally not exposed — see
    // tools/radial_align_tool.d's params() doc comment (same reasoning
    // applies to this one-shot Command).
    override Param[] params() {
        return [
            Param.enum_("mode", "Mode", &mode_,
                [["circle", "Circle"], ["nside", "N-Sided"]], "circle"),
            Param.int_("side", "Side", &side_, 4)
                .min(1).max(MAX_ALIGN_SIDES).enforceBounds(),
            Param.float_("rotate", "Rotate", &rotate_, 0.0f).angle(),
            Param.float_("angle", "Angle", &angle_, 0.0f).angle(),
            Param.float_("weight", "Weight", &weight_, 1.0f)
                .min(0.0f).max(1.0f).enforceBounds(),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        // §2.4 — the chain guard is resolved BEFORE the batch is opened.
        auto chain = extractAlignChain(mesh, editMode);
        if (chain.verts.length < 1) return false;

        // REDO: re-run the kernel UNRECORDED and keep the first delta.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed, chain.verts);
            ed.close();
            return ok;
        }
        auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
        const ok = applyKernel(ed, chain.verts);
        undo_.arm(this, ed.close());
        if (!ok) { undo_.disarm(this); return false; }
        return true;
    }

    private bool applyKernel(ref MeshEditBatch ed, in uint[] chainVerts) {
        Vec3[] source = new Vec3[](chainVerts.length);
        foreach (i, vi; chainVerts) source[i] = mesh.vertices[vi];

        bool nsideMode = (mode_ == "nside");
        auto aligned = radialAlignTargets(source, nsideMode, side_, angle_, rotate_);

        // Task 1903 L0-d4 — local accumulate + ONE `ed.setVertexPositions`.
        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        // PRE-SIZED, NOT append-grown (task 2160): an exact-length map,
        // one output per `chainVerts` entry.
        auto newPos = uninitializedArray!(Vec3[])(chainVerts.length);
        foreach (i, vi; chainVerts) {
            touchedIdx  ~= vi;
            touchedPrev ~= mesh.vertices[vi];
            newPos[i]    = lerp3(source[i], aligned[i], weight_);
        }

        ed.setVertexPositions(touchedIdx, newPos);
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
