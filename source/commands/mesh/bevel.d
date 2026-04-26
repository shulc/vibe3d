module commands.mesh.bevel;

import command;
import mesh;
import view;
import editmode;
import shader;
import viewcache;
import bevel : applyEdgeBevelTopology, updateEdgeBevelPositions, BevelOp;

/// Non-interactive edge bevel — applies the topology change on the currently
/// selected edges and slides each new BoundVert outward by `width`. After
/// success the selection is replaced with the bevel-quad edges.
///
/// Parameters (set via setWidth before apply()):
///   width — slide distance for each BoundVert (>= 0).
class MeshBevel : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private float            width = 0.0f;

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

    override bool apply() {
        if (editMode != EditMode.Edges)            return false;
        if (!mesh.hasAnySelectedEdges())           return false;

        BevelOp op = applyEdgeBevelTopology(mesh, mesh.selectedEdges);
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
