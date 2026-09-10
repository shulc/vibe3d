module commands.mesh.edge_slide;

import command;
import mesh;
import view;
import editmode;
import math : Vec3, Viewport;
import params : Param;
import change_bus : MeshEditScope;
import commands.mesh.position_undo : PositionUndo;
import commands.mesh.vertex_position_result : VertexPositionResult,
    VertexPositionResultBuilder;
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
class MeshEdgeSlide : Command, Operator, VertexPositionResultBuilder {
    private float            t_ = 0.0f;
    // Recorded `Kind.SetPos` undo (task 1903 L0-d4).
    private PositionUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 1903 §L0-d,
        /// witness W-d3a). The op-log SHAPE is not derivable from the outside:
        /// a command that records nothing answers `true` from the BASE
        /// `Command.revert` (task 2500) and the mesh is already where the undo
        /// wants it, so every result-shaped assertion — the plane diff, the
        /// redo cell, the parity cell — is GREEN over a deleted recorder. Only
        /// reading the log itself is not.
        /// `version (unittest)`, so this is not a door in a shipped build; both
        /// gate lanes compile the sources with `-unittest`. `public` on the
        /// declaration and NOT a `public:` section — a section marker here
        /// would silently change the protection of every member below it.
        public ref const(PositionUndo) recordedUndo() const return { return undo_; }
    }

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

        // Build before opening the batch: empty edge selection is a refusal,
        // while t=0 and missing rails are accepted empty results.
        VertexPositionResult result;
        if (!buildVertexPositionResult(mesh.vertices, vts, result)) return false;
        if (result.empty) return true;

        // REDO: re-run the kernel UNRECORDED and keep the first delta.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            applyResult(ed, result);
            ed.close();
            return true;
        }
        auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
        applyResult(ed, result);
        undo_.arm(this, ed.close());
        return true;
    }

    override bool buildVertexPositionResult(const(Vec3)[] source,
                                            ref VectorStack vts,
                                            out VertexPositionResult result) {
        result.clear();
        auto subj = vts.get!SubjectPacket();
        if (subj is null || subj.mesh is null || subj.mesh !is mesh ||
            source.length != subj.mesh.vertices.length) return false;
        Mesh* subject = subj.mesh;

        // Snapshot selectedEdges ONCE: it is a materialising property, and the
        // command refuses an empty edge selection before any edit batch opens.
        bool[] edgeMask = subject.selectedEdges.dup;
        size_t selectedEdgeCount;
        foreach (s; edgeMask) if (s) ++selectedEdgeCount;
        if (selectedEdgeCount == 0) return false;

        // Topology and selection belong to the bound Subject. Both endpoint
        // and stationary rail coordinates belong to the explicit baseline.
        Vec3[] newPos = edgeSlidePositions(*subject, source, edgeMask, t_);

        // Build only changed vertices (diff kernel output vs explicit source).
        // TASK 1903 L0-d4 — THE `==` FILTER STAYS, and that is a ruling (§2.3).
        // `ed.setVertexPositions` filters on `sameBits`, which is STRICTER than
        // `==`: `==` says `-0.0 == +0.0` and `sameBits` does not. Handing the
        // full `0 .. V` list to `setVertexPositions` would therefore WRITE the
        // `==`-but-not-bit-identical cells and flip a signed zero — the exact
        // class measured at Stage D2 (9 of 320 cells, `mesh.d`'s `sameBits`
        // comment). Every index in the `==`-filtered list below is not `==`, so
        // `sameBits` is false for all of them and every write happens: the
        // recorded path ≡ the retired raw loop, byte for byte, with the
        // predicate spelled ONCE rather than exported twice.
        const resultCapacity = selectedEdgeCount <= source.length / 2
            ? selectedEdgeCount * 2 : source.length;
        result.indices.reserve(resultCapacity);
        result.before.reserve(resultCapacity);
        result.after.reserve(resultCapacity);
        foreach (i; 0 .. source.length) {
            Vec3 np = newPos[i];
            Vec3 op = source[i];
            if (np.x == op.x && np.y == op.y && np.z == op.z) continue;
            result.indices ~= cast(uint)i;
            result.before ~= op;
            result.after ~= np;
        }
        return true;
    }

    private static void applyResult(ref MeshEditBatch ed,
                                    ref const VertexPositionResult result) {
        ed.setVertexPositions(result.indices, result.after);
        ed.commitChange(MeshEditScope.Position);
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `RecordedUndo.arm` raises the flag
        // only for a NON-EMPTY delta, and `Command.revert` answers both the
        // empty-edit case and the never-applied case before this body runs. The
        // hand-rolled `setVertexPositions(touchedIdx, touchedPrev)` fallback that
        // used to sit under this line was reachable ONLY on `!armed()`, so it is
        // gone with the predicate that reached it.
        undo_.revert(*mesh);
    }
}
