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
        return [EditMode.Polygons];
    }

    override bool apply() {
        // Subdivide is a polygon-mode operation — its selection-aware
        // behaviour (`catmullClarkSelected` vs full `catmullClark`)
        // reads `mesh.selectedFaces`, which the user can only curate
        // visually while in Polygons mode. Refuse in Vertices / Edges
        // modes so a stale face selection from a previous polygon
        // session doesn't silently scope the subdivision.
        if (editMode != EditMode.Polygons)
            throw new Exception(
                "mesh.subdivide requires Polygons edit mode "
                ~ "(switch via `select.typeFrom polygon` or press 3)");

        // Full mesh snapshot — Catmull-Clark replaces the entire mesh
        // (verts, edges, faces, selection, etc.). One OSD pass handles
        // both full and selected-faces variants; an empty mask
        // refines the whole cage, a non-empty mask refines only the
        // marked faces and widens adjacent un-marked faces around the
        // OSD edge-points (T-junction handling).
        snap = MeshSnapshot.capture(*mesh);
        if (onTopologyChange !is null) onTopologyChange();
        bool[] mask = mesh.hasAnySelectedFaces()
                      ? mesh.selectedFaces : null;
        // Snapshot pre-subdivide selection so children of selected
        // cage faces stay selected after the topology swap. `mask` is
        // a slice into mesh.selectedFaces and dies with the swap, so
        // dup before calling.
        auto prevSelectedFaces = mesh.selectedFaces.dup;
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
