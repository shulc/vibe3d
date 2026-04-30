module commands.mesh.subdivide_faceted;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;

class SubdivideFaceted : Command {
    private GpuMesh*        gpu;
    private VertexCache*    vc;
    private EdgeCache*      ec;
    private FaceBoundsCache* fc;
    private void delegate() onTopologyChange;
    private MeshSnapshot snap;

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

    override string name() const { return "mesh.subdivide_faceted"; }

    override bool apply() {
        snap = MeshSnapshot.capture(*mesh);
        if (onTopologyChange !is null) onTopologyChange();
        const bool[] mask = mesh.hasAnySelectedFaces()
            ? mesh.selectedFaces
            : allTrueMask(mesh.faces.length);
        *mesh = facetedSubdivide(*mesh, mask);
        mesh.resetSelection();
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

private:
    static bool[] allTrueMask(size_t n) {
        auto m = new bool[](n);
        m[] = true;
        return m;
    }
}
