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

        // TASK 1903 Stage E1 — the kernel takes `ref MeshEditBatch`, so the
        // batch opens HERE, at the command boundary, and never inside the
        // kernel (plan §4.1). One unify now bumps its version stamp,
        // re-derives hidden geometry and delivers to the change bus ONCE at
        // `close()` instead of once per internal commit
        // (`deleteFacesByMask` → Geometry, its `compactUnreferenced` → Points).
        //
        // UNRECORDED, deliberately: undo here is still the whole-mesh `snap`
        // captured just above (plan §5.1 — track 1 is the conversion axis,
        // track 2 is the undo migration, and mixing them in one commit is what
        // §5.1 forbids), so a RECORDING batch would build a full op-log that
        // nothing reads and `close()` would drop.
        //
        // Scoped to the kernel call ALONE (§4.4a's narrowing rule): the
        // `removed == 0` rejection below must not run inside the frame.
        //
        // No `scope(failure)`, unlike the older `beginEditBatch`/
        // `endEditBatch` spelling at delete.d / remove.d: that pair has no
        // destructor, this handle does. `MeshEditBatch.~this` pops the frame
        // during unwinding — without asserting, because it runs while an
        // exception is in flight — and ticks `changeBus.batchLeaks`, which the
        // suite asserts stays 0.
        //
        // The result is declared MUTABLE and outside the block, and that is the
        // whole cost of scoping the batch: a `const` binding cannot be assigned
        // across the closing brace. It is not re-`const`-ed into a second name
        // afterwards, at any of this family's three call sites, because each
        // reads its value EXACTLY ONCE — in the rejection `if` on the very next
        // line. A shadow `const` there would add a name to protect a value that
        // has no second reader; if a later edit gives one a second read, that is
        // when it earns the extra binding.
        size_t removed;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kCleanupEditScope);
            removed = ed.unifyFaces();
            ed.close();
        }
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
