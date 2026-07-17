module commands.mesh.unify;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;

/// Remove faces whose unordered vertex set duplicates an earlier face.
/// The first occurrence (lowest index) is kept; all later duplicates are
/// dropped. Operates on the whole active mesh regardless of selection.
/// Undo via MeshSnapshot.
class MeshUnify : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "poly.unify"; }
    override string label() const { return "Unify Polygons"; }

    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry;
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length < 2) return false;

        snap = MeshSnapshot.capture(*mesh);
        const removed = mesh.unifyFaces();
        if (removed == 0) {
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
