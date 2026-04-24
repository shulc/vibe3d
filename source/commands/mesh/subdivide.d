module commands.mesh.subdivide;

import command;
import mesh;
import view;
import editmode;
import viewcache;

class Subdivide : Command {
    private GpuMesh*        gpu;
    private VertexCache*    vc;
    private EdgeCache*      ec;
    private FaceBoundsCache* fc;
    private void delegate() onTopologyChange;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc,
         void delegate() onTopologyChange) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
        this.onTopologyChange = onTopologyChange;
    }

    override string name() const { return "mesh.subdivide"; }

    override bool apply() {
        if (onTopologyChange !is null) onTopologyChange();
        if (mesh.hasAnySelectedFaces())
            *mesh = catmullClarkSelected(*mesh, mesh.selectedFaces);
        else
            *mesh = catmullClark(*mesh);
        mesh.resetSelection();
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length);
        vc.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        ec.resize(mesh.edges.length);
        ec.invalidate();
        return true;
    }
}
