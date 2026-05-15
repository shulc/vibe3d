module commands.mesh.quantize;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import math : Vec3;
import params : Param;

import std.math : floor;

/// Snap each selected vertex to a regular grid: pos = round(pos / step) * step
/// per axis. Mirrors MODO's `vert.quantize` deform command.
///
/// Selection-aware via the same edit-mode mask `MeshTransform` uses:
/// vertex mode → selected verts; edge/polygon mode → verts of the selected
/// edges/faces. Empty selection falls through to the whole mesh — matches
/// MODO's "no selection ⇒ act on everything" convention.
class MeshQuantize : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private float            step_ = 0.1f;

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
        return [
            Param.float_("step", "Step", &step_, 0.1f).min(1e-6f),
        ];
    }

    override bool apply() {
        if (step_ <= 0) return false;

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
        // No selection → quantize the whole mesh (MODO convention).
        if (!any) {
            foreach (i; 0 .. mesh.vertices.length) vmask[i] = true;
        }

        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        foreach (i; 0 .. mesh.vertices.length) {
            if (!vmask[i]) continue;
            touchedIdx  ~= cast(uint)i;
            touchedPrev ~= mesh.vertices[i];
            // floor(x / step + 0.5) is the standard banker-free round for
            // positive AND negative values when step > 0. Using
            // round(x / step) would be cleaner but std.math.round drags
            // in libm and rounds half-to-even; floor(...+0.5) matches
            // MODO's vert.quantize behaviour (half-away-from-zero is the
            // intuitive snap for an editor).
            mesh.vertices[i].x = floor(mesh.vertices[i].x / step_ + 0.5f) * step_;
            mesh.vertices[i].y = floor(mesh.vertices[i].y / step_ + 0.5f) * step_;
            mesh.vertices[i].z = floor(mesh.vertices[i].z / step_ + 0.5f) * step_;
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
