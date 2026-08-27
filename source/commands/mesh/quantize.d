module commands.mesh.quantize;

import command;
import mesh;
import view;
import editmode;
import math : Vec3, Viewport, AimViewport, aimSpace;
import document : primaryModelSpace;
import params : Param;
import change_bus : MeshEditScope;
import mesh_edit_delta : undoTrackerEnabled;
import commands.mesh.position_undo : PositionUndo;
import toolpipe.packets : FalloffPacket, SubjectPacket;
import falloff : evaluateFalloff, IFalloffAware;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;

import std.math : floor;

/// Snap each selected vertex to a regular grid: pos = round(pos / step) * step
/// per axis. A `vert.quantize` deform command.
///
/// Selection-aware via the same edit-mode mask `MeshTransform` uses:
/// vertex mode → selected verts; edge/polygon mode → verts of the selected
/// edges/faces. Empty selection falls through to the whole mesh —
/// "no selection ⇒ act on everything".
class MeshQuantize : Command, Operator, IFalloffAware {
    // Per-axis grid spacing (`X/Y/Z` attrs). vibe3d used a single
    // isotropic `step` earlier — hard rename, no back-compat alias.
    private float            stepX_ = 0.1f;
    private float            stepY_ = 0.1f;
    private float            stepZ_ = 0.1f;
    // Optional falloff packet — when enabled, each vert lerps between
    // its original and quantised position by the per-vert weight.
    private FalloffPacket    falloff_;

    // Snapshot for revert. Captures pre-apply positions of every vert we
    // mutated; revert restores them. Same shape as MeshTransform.
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

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.quantize"; }
    override string label() const { return "Quantize"; }

    override Param[] params() {
        // Schema is three per-axis float attrs. U/V (UV-space quantize)
        // and `lockUV` / `morph` remain deferred (need UV / morph-map
        // subsystems).
        return [
            Param.float_("X", "Step X", &stepX_, 0.1f).min(1e-6f),
            Param.float_("Y", "Step Y", &stepY_, 0.1f).min(1e-6f),
            Param.float_("Z", "Step Z", &stepZ_, 0.1f).min(1e-6f),
        ];
    }

    // Setters for XfrmQuantizeTool's drag-modulates-attrs path.
    void setStepXYZ(float x, float y, float z) {
        stepX_ = x; stepY_ = y; stepZ_ = z;
    }
    void setFalloff(FalloffPacket fp) { falloff_ = fp; }

    // Operator interface.
    mixin OperatorActrCommon;
    bool evaluate(ref VectorStack vts) {
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (auto fp = vts.get!FalloffPacket())
            this.falloff_ = *fp;
        // Task 0619: the real viewport is right here on the subject
        // packet. This command can be handed the LIVE falloff packet
        // below, which may be a Screen/Lasso type, so it needs a real
        // aim space — it used to declare an empty `Viewport` instead.
        const auto aim = aimSpace(subj.viewport, primaryModelSpace());

        // §2.4 — the step guard is resolved BEFORE the batch is opened. A
        // `return` out of an open batch leaves `~MeshEditBatch` to pop the
        // frame and tick `changeBus.batchLeaks`, asserted 0 by the suite.
        if (stepX_ <= 0 || stepY_ <= 0 || stepZ_ <= 0) return false;

        // REDO: re-run the kernel UNRECORDED and keep the first delta.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed, aim);
            ed.close();
            return ok;
        }
        if (undoTrackerEnabled()) {
            auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed, aim);
            undo_.arm(ed.close());
            if (!ok) { undo_.disarm(); return false; }
            return true;
        }
        // Legacy path — the SAME kernel through an UNRECORDED batch, so this
        // file's raw-write census row is 0 on BOTH paths.
        auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
        const ok = applyKernel(ed, aim);
        ed.close();
        return ok;
    }

    private bool applyKernel(ref MeshEditBatch ed, const ref AimViewport aim) {

        // Build affected-vertex mask the same way MeshTransform does.
        //
        // Perf (task 0388): `mesh.selectedX` is a @property that rebuilds a
        // whole `bool[]` per read — indexing it inside these loops was
        // O(mesh²). Iterate the lock-step `*Marks.length` and test via the
        // non-allocating `isXSelected(i)` scalar accessor instead.
        // L1 funnel (task 0613, S5): the modal fan-in this used to open-code,
        // with the whole-mesh fallback narrowed to the VISIBLE vertices.
        bool[] vmask = mesh.operandVertexMask(editMode);

        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        // Task 1903 L0-d4 — local accumulate + ONE `ed.setVertexPositions`.
        // Byte-identical: every read of vertex `i` below already happened
        // before the write to `i`, and no vertex is visited twice.
        Vec3[] newPos;
        // Task 0619: cursorless — see jitter.d. No viewport, by design.
        foreach (i; 0 .. mesh.vertices.length) {
            if (!vmask[i]) continue;
            touchedIdx  ~= cast(uint)i;
            touchedPrev ~= mesh.vertices[i];
            // Snap with floor(pos/step + 0.5) — round-half-toward-+∞ — but
            // evaluate the ratio in DOUBLE precision. In float, a coord like
            // 0.45f (stored as 0.44999998807907104, genuinely below 0.45)
            // divided by 0.1f rounds to *exactly* 4.5 because both operands'
            // float error conspires; floor(4.5+0.5) then snaps it a whole
            // grid cell too far (0.5 instead of 0.4). In double the true ratio
            // is 4.4999998, which floors to the correct cell. Only the
            // precision changes — the tie-break stays floor(x+0.5).
            Vec3 v = mesh.vertices[i];
            float qx = cast(float)(floor(cast(double)v.x / cast(double)stepX_ + 0.5) * cast(double)stepX_);
            float qy = cast(float)(floor(cast(double)v.y / cast(double)stepY_ + 0.5) * cast(double)stepY_);
            float qz = cast(float)(floor(cast(double)v.z / cast(double)stepZ_ + 0.5) * cast(double)stepZ_);
            // Falloff blend: lerp between original and quantised pos.
            // Weight is evaluated at the original (pre-quantise) pos
            // so the per-vert weight is deterministic regardless of
            // step granularity.
            float fw = falloff_.enabled
                ? evaluateFalloff(falloff_, mesh.vertices[i], cast(int)i, aim)
                : 1.0f;
            Vec3 orig = mesh.vertices[i];
            Vec3 nv;
            nv.x = orig.x + (qx - orig.x) * fw;
            nv.y = orig.y + (qy - orig.y) * fw;
            nv.z = orig.z + (qz - orig.z) * fw;
            newPos ~= nv;
        }

        ed.setVertexPositions(touchedIdx, newPos);
        ed.commitChange(MeshEditScope.Position);
        return true;
    }

    override bool revert() {
        if (undo_.armed()) return undo_.revert(*mesh);
        // The tracker-off oracle (W-d3c), and the 0099 arm (task 2110).
        if (touchedIdx.length == 0) return true;   // no-op quantize: positions unchanged, revert succeeds
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
