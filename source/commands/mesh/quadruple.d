module commands.mesh.quadruple;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
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
    private void delegate()  onTopologyChange;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode,
         void delegate() onTopologyChange) {
        super(mesh, view, editMode);
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

        // Mode-gated fallback — visibleFaceMask(), not operandFaceMask()
        // (task 0613, S5; see the helper's doc comment in mesh.d).
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
            ed.quadrupleFacesByMask(mask);
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

