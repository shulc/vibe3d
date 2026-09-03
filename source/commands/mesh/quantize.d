module commands.mesh.quantize;

import std.array : uninitializedArray;
import command;
import mesh;
import view;
import editmode;
import math : Vec3, Viewport, AimViewport, aimSpace;
import document : primaryModelSpace;
import params : Param;
import change_bus : MeshEditScope;
import commands.mesh.position_undo : PositionUndo;
import toolpipe.packets : FalloffPacket, SubjectPacket;
import falloff : evaluateFalloff, IFalloffAware;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;

import std.math : floor;

/// Snap each selected vertex to a regular grid: pos = round(pos / step) * step
/// per axis. The `mesh.quantize` deform command uses this operation.
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
        auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
        const ok = applyKernel(ed, aim);
        undo_.arm(this, ed.close());
        if (!ok) { undo_.disarm(this); return false; }
        return true;
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
        // PRE-SIZED, NOT APPEND-GROWN (task 2160). `~=` is a runtime call per
        // element that looks the block's used-length up in the GC; over a
        // hundred thousand vertices that is ~0.85 ms of pure bookkeeping, and
        // this array exists only to be handed to `setVertexPositions` and
        // dropped. The ceiling is exact — the loop writes at most one entry per
        // visited vertex — and `Vec3` holds no pointer, so the unwritten tail
        // is nothing the collector can misread; it is sliced off at the call.
        auto newPos = uninitializedArray!(Vec3[])(mesh.vertices.length);
        size_t nNew = 0;
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
            newPos[nNew++] = nv;
        }

        ed.setVertexPositions(touchedIdx, newPos[0 .. nNew]);
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
