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
/// `fixFaceOrientation` (source/mesh_ops/cleanup.d) for the full algorithm —
/// Stage E1 made it a free function over `ref MeshEditBatch`, which is why the
/// batch below opens here at the command boundary.
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

        // TASK 1903 Stage E1 — the kernel takes `ref MeshEditBatch`, so the
        // batch opens HERE, at the command boundary, and never inside the
        // kernel (plan §4.1). The batch is UNRECORDED because undo here is
        // still the whole-mesh `snap` above (plan §5.1), and it is scoped to
        // the kernel call ALONE so the `nFlipped == 0` rejection below runs
        // outside the frame. See commands/mesh/unify.d for the full note,
        // including why there is no `scope(failure)`.
        size_t nFlipped;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kCleanupEditScope);
            nFlipped = ed.fixFaceOrientation();
            ed.close();
        }
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
