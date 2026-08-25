module commands.mesh.detriangulate;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import change_bus : MeshEditScope;

/// Merge adjacent coplanar faces into n-gons by dissolving every interior
/// edge whose two incident masked faces satisfy dot(nA,nB) > 0.999 (the
/// in-repo ExEdge.coplanar threshold). Non-coplanar neighbours and boundary
/// edges are left untouched. Generalises `mesh.quadruple` to full coplanar
/// region merges (not just triangle pairs).
///
/// Selection-aware (Polygons mode + non-empty selection): only selected faces
/// participate; otherwise the whole active layer.
/// Post-op selection is cleared (no clean origin map through union-find).
///
/// v1 restriction: 2-valent / collinear boundary vertices that survive on a
/// partially-dissolved coplanar region are NOT cleaned up (`dissolveDegree2Verts`
/// is intentionally not wired here — tested cube/quad cases have no such verts).
///
/// Undo via MeshSnapshot.
class MeshDetriangulate : Command, Operator {
    mixin OperatorActrCommon;
    private void delegate()  onTopologyChange;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode,
         void delegate() onTopologyChange) {
        super(mesh, view, editMode);
        this.onTopologyChange = onTopologyChange;
    }

    override string name() const { return "mesh.detriangulate"; }

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

        // Mode-gated fallback: NOT the plain nothingSelected convention, so it
        // stays on visibleFaceMask() rather than operandFaceMask() — see the
        // helper's doc comment in mesh.d (task 0613, S5).
        bool[] mask = hasSelection
            ? mesh.selectedFaces
            : mesh.visibleFaceMask();

        mesh.detriangulateFacesByMask(mask);
        mesh.resetSelection();

        // TASK 1906 STAGE 2 — `publishChange`, not `noteChange`: this is the
        // command's LAST mesh publisher, and a command's tail must DELIVER.
        // `Mesh.publishChange`'s doc comment carries the whole rule and the
        // reason (same flags, same version-silence, one delivery at the batch
        // close — but structural instead of incidental).
        mesh.publishChange(MeshEditScope.Geometry);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}

