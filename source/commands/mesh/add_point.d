module commands.mesh.add_point;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import params : Param;
import mesh_edit_delta : MeshEditScope;
import commands.mesh.position_undo  : RecordedUndo;
import commands.mesh.map_edit_undo  : runMapEdit, revertMapEditEmptyOk;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Insert a vertex on the first selected edge at parameter t ∈ (0,1), splitting
/// the edge and every incident face so the new vertex is index-shared (no
/// T-junction).  Default t = 0.5 (midpoint).
///
/// Unlike mesh.addLoop, there is no quad/ring restriction — triangle edges work
/// too.  Only the first selected edge is processed per invocation; multi-edge
/// sweep is a deliberate non-goal (one point per command call, see plan §Scope).
///
/// TASK 1903 STAGE L2-c — UNDO IS THE OPERATION-LOG DELTA. `Mesh.addEdgePoint`
/// reaches `insertEdgePoint`, whose corner splice now goes through
/// `Mesh.setFaceWindings`, so a recording batch comes back with
/// `[AddVerts, MeshMapDelta, ReshapeFaces]` instead of `[AddVerts]` alone.
/// Before that publisher the delta path's `revert()` truncated the new vertex
/// while every incident winding still named it and THREW out of
/// `finalize`→`buildLoops` — the loud half of §5.3's two failure shapes.
class MeshAddPoint : Command, Operator {
    mixin OperatorActrCommon;
    private RecordedUndo     undo_;
    /// The pre-op selection, restored on the delta arm — see
    /// `commands/mesh/selection_undo.d`. This command does not TOUCH the
    /// selection itself, but `addEdgePoint`'s `rebuildEdges` re-lays the edge
    /// index space around the split, and the `MeshSnapshot` it replaces put
    /// every selection plane back verbatim.
    private DenseSelectionUndo preSel_;
    /// The forward SUCCEEDED — see `commands/mesh/flip.d` for why this bit is
    /// not derivable from the two images.
    private bool             applied_;

    private float t_ = 0.5f;

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (see `MeshFlip`).
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.addPoint"; }
    override string label() const { return "Add Point"; }

    override MeshEditScope editScope() const { return MeshEditScope.Geometry; }

    /// See `MeshFlip.isOperationInverse` — a cheap tell, not the observable.
    override bool isOperationInverse() const { return undo_.armed(); }

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

        // EVERY REFUSAL IS ALREADY PRE-FLIGHT, which is why nothing is hoisted
        // here (the L8 rule, plan §L2.4's refusal ruling). `addEdgePoint`
        // answers `uint.max` for exactly two conditions — an out-of-range edge
        // index and a `t` outside (0, 1) — and both are checked ABOVE, before
        // the batch opens, and both refuse before the primitive's first
        // mutation. So the kernel below cannot refuse after mutating, and this
        // command is not one of the four that `snap.restore` on a kernel
        // refusal.
        applied_ = runMapEdit(mesh, undo_, MeshEditScope.Geometry,
                              (ref MeshEditBatch ed) => runKernel(ed, cast(uint)ei));
        return applied_;
    }

    /// The one mutating body, under whichever arm `runMapEdit` chose.
    private bool runKernel(ref MeshEditBatch ed, uint ei) {
        // Recording arm only: the redo arm must keep the first capture (a
        // second would image the POST-op selection) and the hatch has the
        // whole-mesh snapshot.
        if (ed.recording() && !preSel_.filled()) preSel_.capture(ed.mesh);

        // Leave selection as-is — consistent with the loop-insert family
        // (mesh.addLoop / mesh.loopSlice do not reset selection either).
        return ed.mesh.addEdgePoint(ei, t_) != uint.max;
    }

    override bool revert() {
        // `…EmptyOk`, not `revertMapEdit`, and the `if (!snap.filled) return
        // false;` this replaces was DELETED rather than translated: a `false`
        // from a Model entry's `revert()` makes `CommandHistory.undo` discard
        // that entry AND its whole trailing suffix (regression 0099), so it
        // does not decline one step — it destroys every older one.
        if (!revertMapEditEmptyOk(mesh, undo_, applied_)) return false;
        // Guarded on `armed()` because the unarmed arm restored nothing here
        // to begin with: before task 1903 Stage N that arm was the hatch's
        // `MeshSnapshot.restore`, which put every selection plane back by
        // itself, and a second writer over a correct plane is how a restore
        // starts disagreeing with itself. With the hatch gone the unarmed arm
        // is the "nothing was recorded" case, which owns no selection image
        // either — so the guard stays, and it stays for the same reason.
        if (undo_.armed()) preSel_.restore(*mesh);
        return true;
    }
}
