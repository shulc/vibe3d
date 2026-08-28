module commands.mesh.triple;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import change_bus : MeshEditScope;

/// Split every selected (or whole-mesh) n-gon into triangles by fanning from
/// the first vertex. Convex polygons (quads, convex n-gons) are handled
/// correctly; concave polygons are a documented v1 limitation (ear-clip
/// follow-up). Already-triangles are left untouched.
///
/// Selection-aware (Polygons mode + non-empty selection): only the selected
/// faces are triangulated; children of selected parents are re-selected.
/// Otherwise: whole active layer (same convention as mesh.delete).
///
/// Undo via MeshSnapshot (whole-mesh snapshot — topology-replacing op).
class MeshTriple : Command, Operator {
    mixin OperatorActrCommon;
    private void delegate()  onTopologyChange;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode,
         void delegate() onTopologyChange) {
        super(mesh, view, editMode);
        this.onTopologyChange = onTopologyChange;
    }

    override string name() const { return "mesh.triple"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        snap = MeshSnapshot.capture(*mesh);
        if (onTopologyChange !is null) onTopologyChange();

        bool   polygonMode        = editMode == EditMode.Polygons;
        bool   hasSelection       = polygonMode && mesh.hasAnySelectedFaces();
        bool[] prevSelectedFaces  = hasSelection ? mesh.selectedFaces.dup : null;

        // Whole-mesh: every VISIBLE face (NOT null — length-checked kernel).
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
        // UNRECORDED, not recording, and that is the whole point of separating
        // this commit from the migration: axis 0 is the COMMIT SEAM and moves
        // no undo. Undo here is still the whole-mesh `MeshSnapshot` above.
        {
            auto ed = MeshEditBatch.unrecorded(*mesh,
                          MeshEditScope.Geometry | MeshEditScope.Marks);
            uint[] faceOrigin;
            ed.triangulateFacesByMask(mask, &faceOrigin);

            // Re-select children of originally-selected parents.
            if (hasSelection) {
                ed.resetSelection();
                foreach (k, parentFi; faceOrigin) {
                    if (parentFi < prevSelectedFaces.length
                        && prevSelectedFaces[parentFi])
                        ed.selectFace(cast(int)k);
                }
            }

            // TASK 1906 STAGE 2 — `publishChange`, not `noteChange`: this is
            // the command's LAST mesh publisher, and a command's tail must
            // DELIVER. It sits INSIDE the batch as of Stage L10-P0: with a
            // frame open the delivery defers and `close()` makes it, which is
            // the same one delivery by a structural route instead of an
            // incidental one.
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

