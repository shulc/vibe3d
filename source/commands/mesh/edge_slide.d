module commands.mesh.edge_slide;

import command;
import mesh;
import view;
import editmode;
import math : Vec3, Viewport;
import params : Param;
import change_bus : MeshEditScope;
import toolpipe.packets : SubjectPacket;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;

/// Slide the endpoints of every selected edge along their "rail" neighbours —
/// the vertices at the far end of the non-selected face-edges inside flanking
/// faces — by a normalised parameter `t ∈ [-1, 1]`.  t = 0 is a no-op;
/// t = ±1 lands the endpoint exactly on the rail neighbour.
///
/// Return contract (the 0099/0100 trap):
///   • Empty edge selection → false (HTTP: {"status":"error"}, no history).
///   • Any selected edge    → true, even when no rail exists on the
///     requested side (graceful degradation: touchedIdx is empty, the
///     recorded undo entry's revert() is a no-op, caller gets "ok").
class MeshEdgeSlide : Command, Operator {
    private float            t_ = 0.0f;
    // Positional snapshot for revert (jitter.d pattern).
    private uint[] touchedIdx;
    private Vec3[] touchedPrev;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.edge_slide"; }
    override string label() const { return "Edge Slide"; }

    override Param[] params() {
        // Float literals (.min/-1.0f/.max(1.0f)) bind the float overload of
        // Param.min/max — int literals would silently target minI/maxI instead.
        return [
            Param.float_("t", "Slide", &t_, 0.0f)
                .min(-1.0f).max(1.0f),
        ];
    }

    /// Setter for the interactive tool's drag-modulates-t path.
    void setT(float t) { t_ = t; }

    /// Live slide parameter — the authoritative value regardless of whether it
    /// was set by a drag, a panel edit, or a headless `t:` argstring. Read by
    /// EdgeSlideTool.toolStateJson() for the step-trace `tool` block.
    float slideT() const { return t_; }

    // Operator interface.
    mixin OperatorActrCommon;
    bool evaluate(ref VectorStack vts) {
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        return this.applyKernel();
    }

    private bool applyKernel() {
        // Snapshot selectedEdges ONCE — avoid O(n²) @property access in loop.
        bool[] edgeMask = mesh.selectedEdges.dup;

        // Empty selection → cannot run; no history entry.
        bool any = false;
        foreach (s; edgeMask) if (s) { any = true; break; }
        if (!any) return false;

        // Compute new positions (pure — no mutation of mesh).
        Vec3[] newPos = edgeSlidePositions(*mesh, edgeMask, t_);

        // Snapshot only changed vertices (diff kernel output vs current).
        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        foreach (i; 0 .. mesh.vertices.length) {
            Vec3 np = newPos[i];
            Vec3 op = mesh.vertices[i];
            if (np.x == op.x && np.y == op.y && np.z == op.z) continue;
            touchedIdx  ~= cast(uint)i;
            touchedPrev ~= op;
            mesh.vertices[i] = np;
        }

        mesh.commitChange(MeshEditScope.Position);
        // Always true for a non-empty edge selection — even if no rail existed
        // on the requested side (touchedIdx is empty, undo is a no-op).
        return true;
    }

    override bool revert() {
        if (touchedIdx.length == 0) return true;   // no-op slide: positions unchanged, revert succeeds
        foreach (i, vi; touchedIdx)
            if (vi < mesh.vertices.length) mesh.vertices[vi] = touchedPrev[i];
        mesh.commitChange(MeshEditScope.Position);
        return true;
    }
}
