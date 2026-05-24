module commands.mesh.quantize;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import math : Vec3, Viewport;
import params : Param;
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
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
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

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
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
        return this.applyKernel();
    }

    private bool applyKernel() {
        if (stepX_ <= 0 || stepY_ <= 0 || stepZ_ <= 0) return false;

        // Build affected-vertex mask the same way MeshTransform does.
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
        // No selection → quantize the whole mesh.
        if (!any) {
            foreach (i; 0 .. mesh.vertices.length) vmask[i] = true;
        }

        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        Viewport vp;   // unused for non-screen falloff
        foreach (i; 0 .. mesh.vertices.length) {
            if (!vmask[i]) continue;
            touchedIdx  ~= cast(uint)i;
            touchedPrev ~= mesh.vertices[i];
            // floor(x / step + 0.5) is the standard banker-free round for
            // positive AND negative values when step > 0. Using
            // round(x / step) would be cleaner but std.math.round drags
            // in libm and rounds half-to-even; floor(...+0.5) gives
            // half-away-from-zero, the intuitive snap for an editor.
            float qx = floor(mesh.vertices[i].x / stepX_ + 0.5f) * stepX_;
            float qy = floor(mesh.vertices[i].y / stepY_ + 0.5f) * stepY_;
            float qz = floor(mesh.vertices[i].z / stepZ_ + 0.5f) * stepZ_;
            // Falloff blend: lerp between original and quantised pos.
            // Weight is evaluated at the original (pre-quantise) pos
            // so the per-vert weight is deterministic regardless of
            // step granularity.
            float fw = falloff_.enabled
                ? evaluateFalloff(falloff_, mesh.vertices[i], cast(int)i, vp)
                : 1.0f;
            Vec3 orig = mesh.vertices[i];
            mesh.vertices[i].x = orig.x + (qx - orig.x) * fw;
            mesh.vertices[i].y = orig.y + (qy - orig.y) * fw;
            mesh.vertices[i].z = orig.z + (qz - orig.z) * fw;
        }

        ++mesh.mutationVersion;
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
        ++mesh.mutationVersion;
        gpu.upload(*mesh);
        vc.invalidate();
        ec.invalidate();
        fc.invalidate();
        return true;
    }
}
