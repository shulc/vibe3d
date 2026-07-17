module commands.mesh.flip;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;

/// All-true selection mask of length `n`, used when nothing is selected
/// (empty selection ⇒ whole mesh).
private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}

/// Reverse the winding order of selected polygons, inverting their normals.
/// Empty face-selection flips every face of the active layer (matching the
/// `mesh.delete` empty-selection convention). Always operates in the face
/// domain regardless of the current edit mode — editMode is NOT branched on
/// (R3: flip is a polygon-domain operation only). Undo via MeshSnapshot
/// (R4: snapshot-only path; MeshEditDelta has no winding-reverse op today).
class MeshFlip : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.flip"; }
    override string label() const { return "Flip Polygons"; }

    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry;
    }

    // The kernel mutation: always face-domain, never editMode-dependent (R3).
    private size_t runKernel() {
        const all = !mesh.hasAnySelectedFaces();
        return mesh.flipFacesByMask(
            all ? allTrue(mesh.faces.length) : mesh.selectedFaces);
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        const affected = runKernel();
        if (affected == 0) {
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
