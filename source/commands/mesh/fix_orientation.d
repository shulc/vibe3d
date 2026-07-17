module commands.mesh.fix_orientation;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;

/// `mesh.fixOrientation` — "Fix Orientation" cleanup op (task 0394 Part B):
/// heals inconsistently-wound faces (already-corrupt imports, old saves, or
/// hand-built geometry) by making every manifold-adjacent face pair traverse
/// their shared edge in OPPOSITE directions, seeded outward per connected
/// component. Mirrors a reference open-source DCC's Recalculate Normals. See
/// `Mesh.fixFaceOrientation` (mesh.d) for the full algorithm.
///
/// Operates on the whole mesh, EXCEPT: if any face is currently selected,
/// only the connected component(s) containing a selected face are touched
/// (mirrors that operation's selection-restricted behavior) -- this is
/// automatic, not a parameter, so no dialog is needed.
///
/// Rejections (no-op, no snapshot, no undo entry):
///   - 0 faces flipped (mesh already consistently wound, or the selected
///     component(s) already were)
class MeshFixOrientation : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.fixOrientation"; }
    override string label() const { return "Fix Orientation"; }

    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry;
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        snap = MeshSnapshot.capture(*mesh);
        size_t nFlipped = mesh.fixFaceOrientation();
        if (nFlipped == 0) {
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
