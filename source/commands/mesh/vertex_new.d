module commands.mesh.vertex_new;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import math : Vec3;
import params : Param;
import snapshot : MeshSnapshot;

/// Add one isolated vertex at an absolute position and auto-select it.
///
/// The new vertex has no edge or face references — it is a free-standing
/// point. Auto-selecting it after insertion enables immediate chaining
/// with position-editing commands without a separate selection step.
///
/// Undo uses a full MeshSnapshot (same as mesh.addPoint / mesh.collapse)
/// because adding a vertex grows the vertices[] array.
class MeshVertexNew : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    private Vec3 pos_ = Vec3(0, 0, 0);

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.addVertex"; }
    override string label() const { return "Add Vertex"; }

    override Param[] params() {
        return [
            Param.vec3_("pos", "Position", &pos_, Vec3(0, 0, 0)),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;

        snap = MeshSnapshot.capture(*mesh);

        uint vi = mesh.addVertex(pos_);
        // CRITICAL: addVertex (mesh.d:480) only appends to vertices[]; it does
        // NOT grow vertexMarks / vertexSelectionOrder. Indexing either array at
        // the new index before resizing causes an out-of-bounds RangeError (an
        // Error, not an Exception — the dispatch catch will NOT swallow it).
        // resizeVertexSelection() (mesh.d:4782) grows both arrays to
        // vertices.length before any selectVertex call.
        mesh.resizeVertexSelection();
        mesh.clearVertexSelection();
        mesh.selectVertex(cast(int)vi);

        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
