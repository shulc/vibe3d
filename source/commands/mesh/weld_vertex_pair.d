module commands.mesh.weld_vertex_pair;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import change_bus : MeshEditScope;
import snapshot : MeshSnapshot;

/// Weld vertex `source` into vertex `target`: source is removed and its
/// incident faces are rewritten to reference `target`. The surviving vertex
/// sits at `target`'s original position (target-position rule).
///
/// Reuses mesh.weldVertexPair. Returns false (status:error) when the kernel
/// returns 0: same index, OOB index, shared-face (would yield a self-touching
/// polygon), or both-faceless (both vertices unreferenced by any face).
///
/// Params (injected via /api/command JSON or injectParamsInto):
///   source  — vertex index to remove (the "drop" vertex)
///   target  — vertex index to survive at (the "keep" vertex)
class MeshWeldVertexPair : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    private int source_ = -1;
    private int target_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode)
    {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.weldVertexPair"; }
    override string label() const { return "Weld Vertex Pair"; }

    override Param[] params() {
        return [
            Param.int_("source", "Source Vertex", &source_, -1),
            Param.int_("target", "Target Vertex", &target_, -1),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (source_ < 0 || target_ < 0)      return false;
        if (source_ == target_)               return false;
        if (cast(uint)source_ >= mesh.vertices.length) return false;
        if (cast(uint)target_ >= mesh.vertices.length) return false;

        snap = MeshSnapshot.capture(*mesh);
        // TASK 1903 STAGE L10-P0 (axis 0). An UNRECORDED `MeshEditBatch` at
        // the command boundary. This command opened none, so every
        // `commitChange` its kernels made stamped the mesh version and
        // delivered on its own — one `changeBus.unbatchedGeometryCommits` tick
        // each. Inside the batch they defer and stamp ONCE at `close()`.
        //
        // UNRECORDED, not recording: axis 0 is the COMMIT SEAM and moves no
        // undo. Undo here is still the whole-mesh `MeshSnapshot` above.
        size_t welded;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh,
                          MeshEditScope.Geometry | MeshEditScope.Marks);
            welded = ed.weldVertexPair(cast(uint)target_, cast(uint)source_);
            ed.close();
        }
        if (welded == 0) {
            // NO rollback here, and that is not an omission: a `weldVertexPair`
            // that welds nothing has mutated nothing, so there is nothing to
            // restore — which is why this arm drops the snapshot rather than
            // replaying it, unlike `vert.join` and `mesh.mergeFaces` above.
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

private:
}
