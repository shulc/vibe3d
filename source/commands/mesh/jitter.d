module commands.mesh.jitter;

import command;
import mesh;
import view;
import editmode;
import math : Vec3, Viewport, AimViewport, aimSpace;
import document : primaryModelSpace;
import params : Param;
import change_bus : MeshEditScope;
import commands.mesh.position_undo : PositionUndo;
import commands.mesh.vertex_position_result : VertexPositionResult,
    VertexPositionResultBuilder;
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
class MeshJitter : Command, Operator, IFalloffAware,
                   VertexPositionResultBuilder {
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
        if (auto fp = vts.get!FalloffPacket()) {
            this.falloff_ = *fp;
        } else {
            // Command.apply() carries HTTP-injected falloff in the command
            // field. Publish it as an explicit builder input; a direct builder
            // call never falls back to state retained by an earlier evaluate.
            vts.put(&falloff_);
        }

        VertexPositionResult result;
        if (!buildVertexPositionResult(mesh.vertices, vts, result)) return false;
        // Accepted identity edits must stay representable on the command
        // surface (task 2110): CommandHistory records this successful command
        // even though its PositionUndo intentionally remains unarmed.
        if (result.empty) return true;

        // REDO: re-run the kernel UNRECORDED and keep the first delta.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            applyResult(ed, result);
            ed.close();
            return true;
        }
        auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
        applyResult(ed, result);
        undo_.arm(this, ed.close());
        return true;
    }

    override bool paramEnabled(string name) const {
        if (name == "rangeX") return enableX_;
        if (name == "rangeY") return enableY_;
        if (name == "rangeZ") return enableZ_;
        return true;
    }

    override bool buildVertexPositionResult(const(Vec3)[] source,
                                            ref VectorStack vts,
                                            out VertexPositionResult result) {
        result.clear();
        auto subj = vts.get!SubjectPacket();
        if (subj is null || subj.mesh is null || subj.mesh !is mesh ||
            source.length != subj.mesh.vertices.length) return false;
        Mesh* subject = subj.mesh;
        FalloffPacket resultFalloff;
        if (auto fp = vts.get!FalloffPacket()) resultFalloff = *fp;

        // Task 0619: Screen/Lasso consume the real subject viewport. Position
        // sampling below still comes exclusively from the explicit baseline.
        const auto aim = aimSpace(subj.viewport, primaryModelSpace());

        // Build affected-vertex mask the same way MeshTransform / MeshQuantize do.
        //
        // Perf (task 0388): `mesh.selectedX` is a @property that rebuilds a
        // whole `bool[]` per read — indexing it inside these loops was
        // O(mesh²). Iterate the lock-step `*Marks.length` and test via the
        // non-allocating `isXSelected(i)` scalar accessor instead.
        // L1 funnel (task 0613, S5): the modal fan-in this used to open-code,
        // with the whole-mesh fallback narrowed to the VISIBLE vertices.
        bool[] vmask = subject.operandVertexMask(editMode);

        // Mt19937 with a fixed seed gives identical sequences across
        // runs and platforms — the test relies on this. uniform01
        // returns [0, 1); we map to [-1, 1) for centred displacement.
        Mt19937 rng;
        rng.seed(cast(uint)seed_);

        result.indices.reserve(source.length);
        result.before.reserve(source.length);
        result.after.reserve(source.length);
        // Task 0619: the empty `Viewport vp;` that used to sit here is gone.
        // It was NOT harmless-because-unreachable: `parseFalloffJson` rejects
        // the two pixel-based types, but this command is also an `Operator`,
        // and `evaluate(vts)` above copies the LIVE packet — which can be
        // Screen or Lasso — over `falloff_`. The aim space now arrives as a
        // parameter, built once from the subject packet's real viewport.
        foreach (i; 0 .. source.length) {
            // Drain THREE rolls per vert regardless of mask so the seed
            // sequence stays stable when the user changes selection
            // between runs (otherwise selecting vert 5 vs vert 3 would
            // give it a different random vector). The skipped rolls
            // are cheap.
            float u = uniform01!float(rng) * 2.0f - 1.0f;
            float v = uniform01!float(rng) * 2.0f - 1.0f;
            float w = uniform01!float(rng) * 2.0f - 1.0f;
            if (!vmask[i]) continue;
            // Falloff scales the displacement uniformly — evaluated at
            // the PRE-jitter position so the weight is deterministic
            // across runs (post-jitter pos would drift the weight
            // each call). enableX/Y/Z gates the per-axis write; RNG
            // rolls stay unconditional.
            float fw = resultFalloff.enabled
                ? evaluateFalloff(resultFalloff, source[i], cast(int)i, aim)
                : 1.0f;
            Vec3 orig = source[i];
            Vec3 nv = orig;
            if (enableX_) nv.x += u * rangeX_ * fw;
            if (enableY_) nv.y += v * rangeY_ * fw;
            if (enableZ_) nv.z += w * rangeZ_ * fw;
            if (nv == orig) continue;
            result.indices ~= cast(uint)i;
            result.before ~= orig;
            result.after ~= nv;
        }
        return true;
    }

    private static void applyResult(ref MeshEditBatch ed,
                                    ref const VertexPositionResult result) {
        ed.setVertexPositions(result.indices, result.after);
        ed.commitChange(MeshEditScope.Position);
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
