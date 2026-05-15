module commands.mesh.subdivide;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;
import subpatch_osd : catmullClarkOsd;

class Subdivide : Command {
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

    override string name() const { return "mesh.subdivide"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    override bool apply() {
        // Selection-aware subdivision (refine only marked faces) only
        // makes sense when the user could see and curate the face
        // selection — i.e. in Polygons mode. In Vertices / Edges mode
        // we ignore any stale `mesh.selectedFaces` from a prior
        // polygon session and refine the whole cage. Full mesh
        // snapshot — Catmull-Clark replaces the entire mesh (verts,
        // edges, faces, selection, etc.).
        snap = MeshSnapshot.capture(*mesh);
        if (onTopologyChange !is null) onTopologyChange();
        bool polygonMode = editMode == EditMode.Polygons;
        bool[] mask = (polygonMode && mesh.hasAnySelectedFaces())
                      ? mesh.selectedFaces : null;
        // Snapshot pre-subdivide selection so children of selected
        // cage faces stay selected after the topology swap. `mask` is
        // a slice into mesh.selectedFaces and dies with the swap, so
        // dup before calling.
        auto prevSelectedFaces = polygonMode
            ? mesh.selectedFaces.dup : null;
        uint[] faceOrigin;
        *mesh = catmullClarkOsd(*mesh, mask, &faceOrigin);
        mesh.resetSelection();
        foreach (k, parentFi; faceOrigin) {
            if (parentFi < prevSelectedFaces.length
                && prevSelectedFaces[parentFi])
                mesh.selectFace(cast(int)k);
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
