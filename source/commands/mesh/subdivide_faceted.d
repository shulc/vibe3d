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

    override EditMode[] supportedModes() const {
        return [EditMode.Polygons];
    }

    override bool apply() {
        // Same polygon-mode guard as `mesh.subdivide`: selection-aware
        // subdivision reads `mesh.selectedFaces`, which is only
        // curatable in Polygons mode.
        if (editMode != EditMode.Polygons)
            throw new Exception(
                "mesh.subdivide_faceted requires Polygons edit mode "
                ~ "(switch via `select.typeFrom polygon` or press 3)");

        snap = MeshSnapshot.capture(*mesh);
        if (onTopologyChange !is null) onTopologyChange();
        // Snapshot pre-subdivide selection + per-face vert counts so
        // we can rebuild the output selection deterministically:
        // facetedSubdivide emits sub-faces in cage order — each
        // selected face produces `len_fi` quads, each unselected face
        // produces 1 widened face. `mask` aliases mesh.selectedFaces
        // and dies with the swap, so dup before the call.
        bool hadSelection = mesh.hasAnySelectedFaces();
        auto prevSelectedFaces = mesh.selectedFaces.dup;
        auto prevFaceVertCounts = new size_t[](mesh.faces.length);
        foreach (fi; 0 .. mesh.faces.length)
            prevFaceVertCounts[fi] = mesh.faces[fi].length;
        const bool[] mask = hadSelection
            ? mesh.selectedFaces
            : allTrueMask(mesh.faces.length);
        *mesh = facetedSubdivide(*mesh, mask);
        mesh.resetSelection();
        size_t cursor = 0;
        foreach (fi; 0 .. prevSelectedFaces.length) {
            bool wasSelected = prevSelectedFaces[fi];
            // Selection-active branch splits the face; otherwise it
            // stays as a single widened face. `mask` here matches what
            // facetedSubdivide saw, so the split-vs-pass decision is
            // identical.
            bool splitsHere = fi < mask.length && mask[fi];
            size_t emitted = splitsHere ? prevFaceVertCounts[fi] : 1;
            foreach (j; 0 .. emitted) {
                if (wasSelected && cursor < mesh.faces.length)
                    mesh.selectFace(cast(int)cursor);
                ++cursor;
            }
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

private:
    static bool[] allTrueMask(size_t n) {
        auto m = new bool[](n);
        m[] = true;
        return m;
    }
}
