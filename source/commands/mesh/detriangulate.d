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

        // TASK 1903 STAGE L10-P0 (axis 0). An UNRECORDED `MeshEditBatch` at
        // the command boundary. Nine of this stage's thirteen commands opened
        // none at all, so every `commitChange` their kernels made stamped the
        // mesh version and delivered on its own — `changeBus`'s
        // `unbatchedGeometryCommits` counted each one. Inside the batch they
        // defer into the frame and stamp ONCE at `close()`.
        //
        // UNRECORDED, not recording: axis 0 is the COMMIT SEAM and moves no
        // undo. Undo here is still the whole-mesh `MeshSnapshot` above.
        //
        // The `publishChange` tail sits INSIDE the batch as of this stage —
        // with a frame open the delivery defers and `close()` makes it, which
        // is the same one delivery by a structural route.
        {
            auto ed = MeshEditBatch.unrecorded(*mesh,
                          MeshEditScope.Geometry | MeshEditScope.Marks);
            ed.detriangulateFacesByMask(mask);
            ed.resetSelection();
            ed.publishChange(MeshEditScope.Geometry);
            ed.close();
        }
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}

