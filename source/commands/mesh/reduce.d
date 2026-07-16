module commands.mesh.reduce;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;
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
        size_t n = mesh.reduceToTarget(target, pb_);
        if (n == 0) {
            snap = MeshSnapshot.init;
            return false;
        }
        refreshCaches();
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        refreshDisplayActive(mesh);
    }
}
