module commands.mesh.duplicate_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;

/// Duplicate the currently selected faces in place. Verts shared by
/// multiple selected faces are cloned once; new faces reference the
/// cloned verts; the selection is switched to the new copies.
///
/// Polygons-mode-only: in vibe3d's face-derived edge model, duplicating
/// vert / edge selections produces orphan topology with no useful
/// downstream semantics, so non-Polygons modes are rejected.
class MeshDuplicate : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.duplicate"; }
    override string label() const { return "Duplicate Selected"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Polygons];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Polygons)        return false;
        if (mesh.faces.length == 0)               return false;
        if (!mesh.hasAnySelectedFaces())          return false;

        snap = MeshSnapshot.capture(*mesh);
        size_t cloned = mesh.duplicateSelectedFaces();
        if (cloned == 0) {
            snap = MeshSnapshot.init;
            return false;
        }
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
