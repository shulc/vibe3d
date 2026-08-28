module commands.mesh.fix_orientation;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import mesh_edit_delta : MeshEditScope;
import commands.mesh.position_undo : RecordedUndo;
import commands.mesh.map_edit_undo : runMapEdit, revertMapEditEmptyOk;

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
/// Rejections (no-op, no undo image, no undo entry):
///   - 0 faces flipped (mesh already consistently wound, or the selected
///     component(s) already were)
///
/// TASK 1903 STAGE L2-a — the batch is now RECORDING and the undo image is the
/// operation-log delta. It reaches `Mesh.flipFacesByMask` (through
/// `fixFaceOrientation`), the same primitive `mesh.flip` drives, and the pin
/// that measured this gap — `tests/unit/mesh_ops/cleanup_test.d`'s
/// "fixFaceOrientation: the delta is EMPTY, so its revert is a no-op" block —
/// was written with its three assertions inverted so that it MUST be rewritten
/// by this commit and cannot be green both before and after.
class MeshFixOrientation : Command, Operator {
    mixin OperatorActrCommon;
    private RecordedUndo     undo_;
    /// The forward SUCCEEDED — see `MeshFlip.applied_` for why the bit is not
    /// derivable from the two images.
    private bool             applied_;

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (see `MeshFlip`).
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.fixOrientation"; }
    override string label() const { return "Fix Orientation"; }

    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry;
    }

    /// See `MeshFlip.isOperationInverse` — a cheap tell, not the observable.
    override bool isOperationInverse() const { return undo_.armed(); }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        // TASK 1903 Stage E1 put the batch here, at the command boundary, and
        // never inside the kernel (plan §4.1); Stage L2-a only changed WHICH
        // batch. `runMapEdit` supplies the two arms — redo (re-run unrecorded,
        // keep the FIRST delta) and record — and closes the batch on both,
        // which is what keeps `changeBus.batchLeaks` at 0. There was a third,
        // the `VIBE3D_UNDO_TRACKER=0` hatch; stage N deleted it.
        //
        // `fixFaceOrientation` returning 0 is a TRUE no-op: it computes the
        // flip mask first and `flipFacesByMask` returns before its first write
        // on an empty one. So answering false from inside the batch is atomic
        // and no roll-back is owed. See `MeshFlip.evaluate` for the four
        // commands that are NOT in that position.
        applied_ = runMapEdit(mesh, undo_, kCleanupEditScope,
                              (ref MeshEditBatch ed) => ed.fixFaceOrientation() != 0);
        return applied_;
    }

    override bool revert() {
        // `…EmptyOk` for the same reason as `mesh.flip`: a face that is its own
        // reverse records nothing, and a `false` from `revert()` truncates the
        // undo stack rather than declining one step (regression 0099).
        return revertMapEditEmptyOk(mesh, undo_, applied_);
    }
}
