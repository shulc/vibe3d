module commands.mesh.jitter;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import math : Vec3, Viewport;
import params : Param;
import change_bus : MeshEditScope;
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
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
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

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
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
        return this.applyKernel();
    }

    override bool paramEnabled(string name) const {
        if (name == "rangeX") return enableX_;
        if (name == "rangeY") return enableY_;
        if (name == "rangeZ") return enableZ_;
        return true;
    }

    private bool applyKernel() {
        // Build affected-vertex mask the same way MeshTransform / MeshQuantize do.
        bool[] vmask = new bool[](mesh.vertices.length);
        bool any = false;
        if (editMode == EditMode.Vertices) {
            foreach (i; 0 .. mesh.selectedVertices.length)
                if (mesh.selectedVertices[i]) { vmask[i] = true; any = true; }
        } else if (editMode == EditMode.Edges) {
            foreach (i; 0 .. mesh.selectedEdges.length)
                if (mesh.selectedEdges[i])
                    foreach (vi; mesh.edges[i]) { vmask[vi] = true; any = true; }
        } else {
            foreach (i; 0 .. mesh.selectedFaces.length)
                if (mesh.selectedFaces[i])
                    foreach (vi; mesh.faces[i]) { vmask[vi] = true; any = true; }
        }
        if (!any)
            foreach (i; 0 .. mesh.vertices.length) vmask[i] = true;

        // Mt19937 with a fixed seed gives identical sequences across
        // runs and platforms — the test relies on this. uniform01
        // returns [0, 1); we map to [-1, 1) for centred displacement.
        Mt19937 rng;
        rng.seed(cast(uint)seed_);

        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        Viewport vp;   // unused for non-screen falloff types
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
                ? evaluateFalloff(falloff_, mesh.vertices[i], cast(int)i, vp)
                : 1.0f;
            if (enableX_) mesh.vertices[i].x += u * rangeX_ * fw;
            if (enableY_) mesh.vertices[i].y += v * rangeY_ * fw;
            if (enableZ_) mesh.vertices[i].z += w * rangeZ_ * fw;
        }

        mesh.commitChange(MeshEditScope.Position);
        gpu.upload(*mesh);
        vc.invalidate();
        ec.invalidate();
        fc.invalidate();
        return true;
    }

    override bool revert() {
        if (touchedIdx.length == 0) return false;
        foreach (i, vi; touchedIdx)
            if (vi < mesh.vertices.length) mesh.vertices[vi] = touchedPrev[i];
        mesh.commitChange(MeshEditScope.Position);
        gpu.upload(*mesh);
        vc.invalidate();
        ec.invalidate();
        fc.invalidate();
        return true;
    }
}
