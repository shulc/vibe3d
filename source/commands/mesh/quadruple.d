module commands.mesh.quadruple;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;
import change_bus : MeshEditScope;

/// Pair adjacent triangles into convex coplanar quads where possible.
/// The accept predicate requires BOTH coplanarity (dot(nA,nB) > 0.999) and
/// convexity of the merged quad — this prevents cross-face bent-quad merges
/// that would appear geometrically convex in the projected plane but span
/// two non-coplanar mesh faces (e.g. after `mesh.triple` on a cube, every
/// cube edge is shared by two triangles; without the coplanarity gate the
/// greedy matcher could pick cube edges over the intra-face diagonal).
///
/// Selection-aware (Polygons mode + non-empty selection): only the selected
/// faces participate; otherwise the whole active layer.
/// Post-op selection is cleared (no clean origin map through union-find).
///
/// Undo via MeshSnapshot.
class MeshQuadruple : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private void delegate()  onTopologyChange;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc,
         void delegate() onTopologyChange) {
        super(mesh, view, editMode);
        this.gpu              = gpu;
        this.vc               = vc;
        this.ec               = ec;
        this.fc               = fc;
        this.onTopologyChange = onTopologyChange;
    }

    override string name() const { return "mesh.quadruple"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        snap = MeshSnapshot.capture(*mesh);
        if (onTopologyChange !is null) onTopologyChange();

        bool polygonMode  = editMode == EditMode.Polygons;
        bool hasSelection = polygonMode && mesh.hasAnySelectedFaces();

        bool[] mask = hasSelection
            ? mesh.selectedFaces
            : allTrue(mesh.faces.length);

        mesh.quadrupleFacesByMask(mask);
        mesh.resetSelection();

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
}

private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}
