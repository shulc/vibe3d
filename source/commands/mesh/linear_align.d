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
import mesh_edit_delta : undoTrackerEnabled;
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
        /// a command that records nothing falls back to its legacy revert and
        /// restores the right positions anyway, so every result-shaped
        /// assertion — the plane diff, the redo cell, the parity cell — is
        /// GREEN over a deleted recorder. Only reading the log itself is not.
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
        if (undoTrackerEnabled()) {
            auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed, chain.verts);
            undo_.arm(ed.close());
            if (!ok) { undo_.disarm(); return false; }
            return true;
        }
        // Legacy path — the SAME kernel through an UNRECORDED batch, so this
        // file's raw-write census row is 0 on BOTH paths.
        auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
        const ok = applyKernel(ed, chain.verts);
        ed.close();
        return ok;
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

    override bool revert() {
        if (undo_.armed()) return undo_.revert(*mesh);
        // The tracker-off oracle (W-d3c). Its empty arm answers FALSE and is
        // UNREACHABLE with a history entry: the forward above already refuses a
        // chain shorter than two, and past that guard the loop appends every
        // chain vertex unconditionally — so a `true` return implies a non-empty
        // touched set (task 2110's §R2.1 row 5).
        if (touchedIdx.length == 0) return false;
        // TASK 1903 L0-d — THE LEGACY REVERT WRITES THROUGH THE BATCH TOO.
        // The plan's §2.5 template left this loop "untouched"; that is
        // incompatible with its own §1/§3/W-d1, which require this file to read
        // `countRawPositionWrites == 0` — §1's measured table counts THIS LOOP
        // among the file's raw writes. Resolved the way §2.5 already resolved
        // the forward: the same write, through the same primitive, on an
        // UNRECORDED batch. It stays a genuine oracle for W-d3c because it
        // restores from the command's own stored pre-op array while the delta
        // path replays the op-log's `posBefore` — two independent data paths
        // that share only the write primitive, which is what a mutation of the
        // RECORDING has to be measured against. Byte-identical to the loop it
        // replaces: `setVertexPositions` skips only writes whose new value is
        // BIT-identical to the current one, and writing identical bits back was
        // what the loop did there; the bounds guard is the same `continue`.
        auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
        ed.setVertexPositions(touchedIdx, touchedPrev);
        ed.commitChange(MeshEditScope.Position);
        ed.close();
        return true;
    }
}
