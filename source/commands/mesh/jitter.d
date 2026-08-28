module commands.mesh.jitter;

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

import std.random : Mt19937, uniform01;
import std.math   : sqrt, cos, sin, PI;

/// Random per-vertex displacement, weighted independently per axis.
/// Selection-aware (same mask as MeshTransform / MeshQuantize); empty
/// selection ⇒ whole mesh.
///
/// Determinism: a fixed `seed` produces a fixed displacement pattern
/// for the SAME vertex enumeration order. Because vibe3d's vert
/// indices are stable across `scene.reset` + selection edits (no
/// reorder happens until topology mutates), the same script twice
/// gives the same output. This is a vibe3d-original deformer.
class MeshJitter : Command, Operator, IFalloffAware {
    // Per-axis jitter amplitude (`rangeX/Y/Z`).
    private float            rangeX_ = 0.1f;
    private float            rangeY_ = 0.1f;
    private float            rangeZ_ = 0.1f;
    private int              seed_   = 0;
    // Per-axis enable gates (`enableX/Y/Z`). When false, that axis's
    // jitter is suppressed without losing the stored Range value —
    // toggling back on restores the previous behaviour. Functionally
    // equivalent to setting the corresponding Range to 0, exposed
    // separately as a distinct UI control.
    private bool             enableX_ = true;
    private bool             enableY_ = true;
    private bool             enableZ_ = true;
    // Optional falloff packet — when `enabled`, per-vertex weight scales
    // the displacement: `delta *= weight`. RNG rolls stay unweighted so
    // toggling falloff doesn't desync the seed sequence (same reasoning
    // as the enableX/Y/Z gates).
    private FalloffPacket    falloff_;
    // Snapshot for revert.
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

    override string name()  const { return "mesh.jitter"; }
    override string label() const { return "Jitter"; }

    override Param[] params() {
        // Schema uses `rangeX/Y/Z`. vibe3d previously used `sclX/Y/Z`
        // names — renamed without back-compat aliases on the rationale
        // that the only callers were inside this repo.
        return [
            Param.bool_ ("enableX", "Enable X", &enableX_, true),
            Param.bool_ ("enableY", "Enable Y", &enableY_, true),
            Param.bool_ ("enableZ", "Enable Z", &enableZ_, true),
            Param.float_("rangeX",  "Range X",  &rangeX_,  0.1f),
            Param.float_("rangeY",  "Range Y",  &rangeY_,  0.1f),
            Param.float_("rangeZ",  "Range Z",  &rangeZ_,  0.1f),
            Param.int_  ("seed",    "Seed",     &seed_,    0),
        ];
    }

    // Setters for XfrmJitterTool's drag-modulates-attrs path.
    void setScale(float x, float y, float z) {
        rangeX_ = x; rangeY_ = y; rangeZ_ = z;
    }
    void setSeed(int v) { seed_ = v; }
    void setEnable(bool x, bool y, bool z) {
        enableX_ = x; enableY_ = y; enableZ_ = z;
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
        // §2.4 — jitter's only guards are the two `return false`s above, both
        // already resolved before this point, so the batch opens clean.

        // REDO: re-run the kernel UNRECORDED and keep the first delta.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed, aim);
            ed.close();
            return ok;
        }
        auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
        const ok = applyKernel(ed, aim);
        undo_.arm(ed.close());
        if (!ok) { undo_.disarm(); return false; }
        return true;
    }

    override bool paramEnabled(string name) const {
        if (name == "rangeX") return enableX_;
        if (name == "rangeY") return enableY_;
        if (name == "rangeZ") return enableZ_;
        return true;
    }

    private bool applyKernel(ref MeshEditBatch ed, const ref AimViewport aim) {
        // Build affected-vertex mask the same way MeshTransform / MeshQuantize do.
        //
        // Perf (task 0388): `mesh.selectedX` is a @property that rebuilds a
        // whole `bool[]` per read — indexing it inside these loops was
        // O(mesh²). Iterate the lock-step `*Marks.length` and test via the
        // non-allocating `isXSelected(i)` scalar accessor instead.
        // L1 funnel (task 0613, S5): the modal fan-in this used to open-code,
        // with the whole-mesh fallback narrowed to the VISIBLE vertices.
        bool[] vmask = mesh.operandVertexMask(editMode);

        // Mt19937 with a fixed seed gives identical sequences across
        // runs and platforms — the test relies on this. uniform01
        // returns [0, 1); we map to [-1, 1) for centred displacement.
        Mt19937 rng;
        rng.seed(cast(uint)seed_);

        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        // Task 1903 L0-d4 — the per-component `mesh.vertices[i].x += …` writes
        // became a local accumulate plus ONE `ed.setVertexPositions` after the
        // loop. Byte-identical: every read this loop makes of vertex `i` (the
        // `touchedPrev` capture, and the falloff evaluation) already happened
        // BEFORE the write to `i`, and no vertex is visited twice.
        // PRE-SIZED, NOT APPEND-GROWN (task 2160). `~=` is a runtime call per
        // element that looks the block's used-length up in the GC; over a
        // hundred thousand vertices that is ~0.85 ms of pure bookkeeping, and
        // this array exists only to be handed to `setVertexPositions` and
        // dropped. The ceiling is exact — the loop writes at most one entry per
        // visited vertex — and `Vec3` holds no pointer, so the unwritten tail
        // is nothing the collector can misread; it is sliced off at the call.
        auto newPos = uninitializedArray!(Vec3[])(mesh.vertices.length);
        size_t nNew = 0;
        // Task 0619: the empty `Viewport vp;` that used to sit here is gone.
        // It was NOT harmless-because-unreachable: `parseFalloffJson` rejects
        // the two pixel-based types, but this command is also an `Operator`,
        // and `evaluate(vts)` above copies the LIVE packet — which can be
        // Screen or Lasso — over `falloff_`. The aim space now arrives as a
        // parameter, built once from the subject packet's real viewport.
        foreach (i; 0 .. mesh.vertices.length) {
            // Drain THREE rolls per vert regardless of mask so the seed
            // sequence stays stable when the user changes selection
            // between runs (otherwise selecting vert 5 vs vert 3 would
            // give it a different random vector). The skipped rolls
            // are cheap.
            float u = uniform01!float(rng) * 2.0f - 1.0f;
            float v = uniform01!float(rng) * 2.0f - 1.0f;
            float w = uniform01!float(rng) * 2.0f - 1.0f;
            if (!vmask[i]) continue;
            touchedIdx  ~= cast(uint)i;
            touchedPrev ~= mesh.vertices[i];
            // Falloff scales the displacement uniformly — evaluated at
            // the PRE-jitter position so the weight is deterministic
            // across runs (post-jitter pos would drift the weight
            // each call). enableX/Y/Z gates the per-axis write; RNG
            // rolls stay unconditional.
            float fw = falloff_.enabled
                ? evaluateFalloff(falloff_, mesh.vertices[i], cast(int)i, aim)
                : 1.0f;
            Vec3 nv = mesh.vertices[i];
            if (enableX_) nv.x += u * rangeX_ * fw;
            if (enableY_) nv.y += v * rangeY_ * fw;
            if (enableZ_) nv.z += w * rangeZ_ * fw;
            newPos[nNew++] = nv;
        }

        ed.setVertexPositions(touchedIdx, newPos[0 .. nNew]);
        ed.commitChange(MeshEditScope.Position);
        return true;
    }

    override bool revert() {
        if (undo_.armed()) return undo_.revert(*mesh);
        // THE EMPTY-DELTA ARM. `RecordedUndo.arm` leaves the holder DISARMED
        // when the batch came back with an empty log, so this is the live
        // answer for a forward that succeeded and moved nothing a bitwise diff
        // could see — not dead code, and not a fallback for a path that no
        // longer exists. Until task 1903 Stage N it was also the tracker-off
        // ORACLE the plane-diff cells measured the recorded revert against
        // (W-d3c); that reading died with the hatch, this one did not.
        //
        // It is also the 0099 arm (task 2110): a no-op jitter must answer
        // TRUE, because a `false` from a Model entry's `revert()` makes
        // `CommandHistory.undo` discard that entry AND its whole trailing
        // suffix.
        if (touchedIdx.length == 0) return true;   // no-op jitter: positions unchanged, revert succeeds
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
