module commands.mesh.add_point;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import params : Param;
import snapshot : MeshSnapshot;

/// Insert a vertex on the first selected edge at parameter t ∈ (0,1), splitting
/// the edge and every incident face so the new vertex is index-shared (no
/// T-junction).  Default t = 0.5 (midpoint).
///
/// Unlike mesh.addLoop, there is no quad/ring restriction — triangle edges work
/// too.  Only the first selected edge is processed per invocation; multi-edge
/// sweep is a deliberate non-goal (one point per command call, see plan §Scope).
class MeshAddPoint : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    private float t_ = 0.5f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.addPoint"; }
    override string label() const { return "Add Point"; }

    override Param[] params() {
        return [
            Param.float_("t", "Position", &t_, 0.5f)
                 .min(0.001f).max(0.999f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (editMode != EditMode.Edges)       return false;
        if (!mesh.hasAnySelectedEdges())      return false;

        // First selected edge only — one point per invocation.
        // Multi-edge sweep is a deliberate non-goal (see plan §Scope).
        int ei = -1;
        foreach (i, sel; mesh.selectedEdges)
            if (sel) { ei = cast(int)i; break; }
        if (ei < 0 || ei >= cast(int)mesh.edges.length) return false;

        // Open-interval guard: t=0 or t=1 is coincident with an endpoint.
        // This guard is mandatory here — param hints (.min/.max) are display/UI
        // only and are NOT enforced on the HTTP injection path (injectParamsInto
        // Float writes *p.fptr = value with no clamp), so t=1.0 from /api/command
        // reaches t_ verbatim and only this check stops it.
        if (t_ <= 0.0f || t_ >= 1.0f) return false;

        snap = MeshSnapshot.capture(*mesh);

        uint vi = mesh.addEdgePoint(cast(uint)ei, t_);
        if (vi == uint.max) {
            snap = MeshSnapshot.init;
            return false;
        }

        // Leave selection as-is — consistent with the loop-insert family
        // (mesh.addLoop / mesh.loopSlice do not reset selection either).
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
