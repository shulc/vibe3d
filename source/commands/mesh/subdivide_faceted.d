module commands.mesh.subdivide_faceted;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;
import change_bus : MeshEditScope;

class SubdivideFaceted : Command, Operator {
    mixin OperatorActrCommon;
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
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        // Selection-aware subdivision (split only marked faces) only
        // makes sense in Polygons mode where the user can see / curate
        // the face selection. Vertices / Edges mode ignores any stale
        // `mesh.selectedFaces` from a prior polygon session and falls
        // through to the all-true mask (split every face).
        snap = MeshSnapshot.capture(*mesh);
        if (onTopologyChange !is null) onTopologyChange();
        // Snapshot pre-subdivide selection + per-face vert counts so
        // we can rebuild the output selection deterministically:
        // facetedSubdivide emits sub-faces in cage order — each
        // selected face produces `len_fi` quads, each unselected face
        // produces 1 widened face. `mask` aliases mesh.selectedFaces
        // and dies with the swap, so dup before the call.
        bool polygonMode  = editMode == EditMode.Polygons;
        bool hadSelection = polygonMode && mesh.hasAnySelectedFaces();
        auto prevSelectedFaces = polygonMode
            ? mesh.selectedFaces.dup : null;
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
        // Change-notification (Stage 1): facetedSubdivide REPLACED the whole
        // mesh (new verts AND faces) — publish Geometry (Points|Polygons). Same
        // rationale as mesh.subdivide: the `*mesh = ...` swap reset the version
        // counters, so noteChange carries only the class.
        mesh.noteChange(MeshEditScope.Geometry);
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
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }

private:
    static bool[] allTrueMask(size_t n) {
        auto m = new bool[](n);
        m[] = true;
        return m;
    }
}
