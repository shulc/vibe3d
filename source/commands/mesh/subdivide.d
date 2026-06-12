module commands.mesh.subdivide;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;
import subpatch_osd : catmullClarkOsd;
import change_bus : MeshEditScope;

class Subdivide : Command, Operator {
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

    override string name() const { return "mesh.subdivide"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
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
        // Change-notification (Stage 1): Catmull-Clark REPLACED the whole mesh
        // (new verts AND faces) — publish the Geometry class (Points|Polygons).
        // noteChange (not commitChange): the `*mesh = ...` swap reset the fresh
        // struct's version counters to 0, and subdivide historically did not
        // re-bump them; the bus only needs the class so caches rebuild. (Also
        // keeps the Stage-1 shadow check quiet — the version DID change here.)
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
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length);
        vc.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        ec.resize(mesh.edges.length);
        ec.invalidate();
    }
}
