module commands.mesh.linear_align;

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
import tools.alignment.align_kernels : extractAlignChain, linearAlignTargets, lerp3;

/// Align a selected vertex CHAIN between its two fixed endpoints (task
/// 0361 — replaces the previous bbox-collapse-to-centroid-line algorithm,
/// which did not match the reference "Linear Align" tool at all). See
/// `tools/align_kernels.d`'s module doc comment for the full captured
/// law: the chain is extracted via edge-connectivity (falling back to
/// selection order), its two endpoints never move, and every interior
/// vertex lands on the line between them — either by its own spatial
/// projection (`uniform=false`) or by equal chain-index spacing
/// (`uniform=true`).
///
/// This one-shot Command has no falloff plumbing (that lives in the
/// interactive `xfrm.linearAlignTool`, tools/linear_align_tool.d, which
/// shares this same kernel) — `weight` here is a plain uniform blend.
class MeshLinearAlign : Command, Operator {
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

    // `mode=curve` isn't captured/implemented — see
    // align_kernels.linearAlignTargets's doc comment; both modes route
    // through the same line-interpolation.
    private string mode_    = "line";
    private bool   uniform_ = false;
    private float  weight_  = 1.0f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.linear_align"; }
    override string label() const { return "Linear Align"; }

    override Param[] params() {
        return [
            Param.enum_("mode", "Mode", &mode_,
                [["line", "Line"], ["curve", "Curve"]], "line"),
            Param.bool_("uniform", "Uniform", &uniform_, false),
            Param.float_("weight", "Weight", &weight_, 1.0f)
                .min(0.0f).max(1.0f).enforceBounds(),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        // §2.4 — the chain guard is resolved BEFORE the batch is opened. A
        // `return` out of an open batch leaves `~MeshEditBatch` to pop the
        // frame and tick `changeBus.batchLeaks`, asserted 0 by the suite.
        auto chain = extractAlignChain(mesh, editMode);
        if (chain.verts.length < 2) return false;

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

        // `mode=curve` falls back to the same line-interpolation — see
        // this class's doc comment.
        auto aligned = linearAlignTargets(source, uniform_);

        // Task 1903 L0-d4 — local accumulate + ONE `ed.setVertexPositions`.
        // `source[i]` IS `touchedPrev[i]`, so the recorded `posBefore` is the
        // same array the retired revert loop wrote back.
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
