module commands.mesh.vert_merge;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;
import params : Param;

/// Tier 1.2: MODO `vert.merge`. Welds selected vertices that are within
/// `dist` of each other (range=fixed) or coincident (range=auto, eps≈0).
/// Faces that collapse to < 3 unique verts are dropped — `keep` (= MODO's
/// "Keep 1-Vertex Polygons") is recognized but not yet honored, since
/// vibe3d doesn't store degenerate polys.
class MeshVertMerge : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;

    private string range_ = "auto";
    private float  dist_  = 0.001f;
    private bool   keep_  = false;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "vert.merge"; }
    override string label() const { return "Merge Vertices"; }

    override Param[] params() {
        return [
            Param.enum_("range", "Range", &range_,
                        [["auto", "Automatic"], ["fixed", "Fixed"]],
                        "auto"),
            Param.float_("dist", "Distance", &dist_, 0.001f)
                 .min(0.0001f).max(100.0f).fmt("%.4f"),
            Param.bool_ ("keep", "Keep 1-Vertex Polygons", &keep_, false),
        ];
    }

    override bool paramEnabled(string name) const {
        if (name == "dist") return range_ == "fixed";
        return true;
    }

    override bool apply() {
        if (!mesh.hasAnySelectedVertices()) return false;

        // range:auto matches MODO's "Automatic" — uses a tiny eps to weld
        // only coincident verts (within 1e-5 in linear distance ≈ 1e-10
        // squared). range:fixed honors the user-supplied dist parameter.
        double eps = (range_ == "fixed")
            ? cast(double)dist_
            : 1e-5;
        double epsSq = eps * eps;

        snap = MeshSnapshot.capture(*mesh);
        size_t welded = mesh.weldVerticesByMask(mesh.selectedVertices, epsSq);
        if (welded == 0) {
            snap = MeshSnapshot.init;
            return false;
        }
        refreshCaches();
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length);
        vc.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        ec.resize(mesh.edges.length);
        ec.invalidate();
    }
}
