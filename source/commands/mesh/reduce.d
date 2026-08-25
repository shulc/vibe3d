module commands.mesh.reduce;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;
import std.math : lround;

/// One-shot polygon reduction command. Collapses edges iteratively using a
/// greedy priority queue until the mesh reaches `targetFaces` alive faces or
/// no valid collapse remains. Operates on the whole active mesh (no
/// selection-subset; v1 scope). Undo via MeshSnapshot.
///
/// Params:
///   ratio           — fraction of original faces to keep (0..1). Default 0.5.
///   count           — absolute target face count; overrides ratio when > 0.
///   preserveBoundary — when true, boundary edges and vertices are not collapsed.
class MeshReduce : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;
    private float            ratio_  = 0.5f;
    private int              count_  = 0;
    private bool             pb_     = true;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.reduce"; }
    override string label() const { return "Reduce"; }

    override Param[] params() {
        return [
            Param.float_("ratio",            "Ratio",            &ratio_, 0.5f).min(0).max(1),
            Param.int_  ("count",            "Target Faces",     &count_, 0).min(0),
            Param.bool_ ("preserveBoundary", "Preserve Boundary", &pb_,    true),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        size_t origFaces = mesh.faces.length;
        size_t target;
        if (count_ > 0)
            target = cast(size_t)(count_ < cast(int)origFaces ? count_ : origFaces);
        else
            target = cast(size_t)lround(ratio_ * cast(double)origFaces);
        if (target < 1) target = 1;
        if (target >= origFaces) return false; // no-op

        snap = MeshSnapshot.capture(*mesh);

        // TASK 1903 Stage D2 — the kernel takes `ref MeshEditBatch`, so the
        // batch opens HERE, at the command boundary, and never inside the
        // kernel (plan §4.1). What that buys is not tidiness: one reduce now
        // bumps its version stamp, re-derives hidden geometry and delivers to
        // the change bus ONCE at `close()`, instead of once per
        // `commitChange` the finalising weld makes on its way through.
        //
        // UNRECORDED, deliberately, and the reason is the plan's two-axis
        // split (§5.1): undo here is still the whole-mesh `snap` captured
        // above, so a RECORDING batch would build a full op-log that nothing
        // reads and `close()` would drop on the floor.
        //
        // Stage L10 is where this command's undo becomes the delta, and it is
        // NOT just this constructor — measured at the D2 review (MAJOR-2). A
        // recording batch over the kernel yields
        // `[SetPos:1, Reindex:1, RemoveVerts:1]` and a `revert()` that returns
        // true while restoring the vertices and only HALF the faces (96 of
        // 192 on a subdivided-cube stand): the face drops leave through
        // `rewriteFaces`, whose `FaceReindex` publisher is disarmed by default
        // and armed by no production code. L10 must arm it for this kernel or
        // refuse to write the delta — Stage B's precondition for the `&rw`
        // site, inherited verbatim. Swapping the constructor alone would
        // replace this whole-mesh snapshot with an undo that silently drops
        // faces. See source/mesh_ops/decimate.d's header, decision (3).
        //
        // L10 is also when reverting the kernel's `setVertexPositions` back to
        // a raw write starts being able to redden an undo fixture
        // (plan §5.7, M-D2).
        //
        // No `scope(failure)` here, unlike the older
        // `beginEditBatch`/`endEditBatch` spelling at delete.d / remove.d:
        // that pair has no destructor, this handle does. `MeshEditBatch.~this`
        // pops the frame during unwinding — without asserting, because it runs
        // while an exception is in flight — and ticks `changeBus.batchLeaks`,
        // which the suite asserts stays 0.
        size_t n;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kReduceEditScope);
            n = ed.reduceToTarget(target, pb_);
            ed.close();
        }

        if (n == 0) {
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
