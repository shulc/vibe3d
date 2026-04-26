module commands.mesh.bevel;

import command;
import mesh;
import view;
import editmode;
import shader;
import viewcache;
import bevel : applyEdgeBevelTopology, updateEdgeBevelPositions,
               BevelOp, BevelWidthMode;

/// Non-interactive edge bevel — applies the topology change on the currently
/// selected edges and slides each new BoundVert outward by `width` using the
/// chosen `mode`. After success the selection is replaced with the
/// bevel-quad edges.
///
/// Parameters (set via setWidth/setMode before apply()):
///   width — user width (>= 0); meaning depends on mode.
///   mode  — Offset (default), Width, Depth, or Percent.
class MeshBevel : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private float            width = 0.0f;
    private BevelWidthMode   mode  = BevelWidthMode.Offset;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name() const { return "mesh.bevel"; }

    void setWidth(float w) { width = (w < 0.0f) ? 0.0f : w; }
    void setMode(BevelWidthMode m) { mode = m; }
    void setMode(string s) {
        switch (s) {
            case "width":   mode = BevelWidthMode.Width;   break;
            case "depth":   mode = BevelWidthMode.Depth;   break;
            case "percent": mode = BevelWidthMode.Percent; break;
            case "offset":  mode = BevelWidthMode.Offset;  break;
            default: throw new Exception("unknown bevel mode '" ~ s ~ "'");
        }
    }

    override bool apply() {
        if (editMode != EditMode.Edges)            return false;
        if (!mesh.hasAnySelectedEdges())           return false;

        BevelOp op = applyEdgeBevelTopology(mesh, mesh.selectedEdges, mode);
        if (width > 0.0f)
            updateEdgeBevelPositions(mesh, op, width);

        mesh.clearEdgeSelection();
        foreach (eidx; op.bevelQuadEdges)
            if (eidx >= 0 && eidx < cast(int)mesh.edges.length)
                mesh.selectEdge(eidx);

        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length); vc.invalidate();
        ec.resize(mesh.edges.length);    ec.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        return true;
    }
}
