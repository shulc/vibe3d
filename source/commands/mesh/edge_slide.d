module commands.mesh.edge_slide;

import command;
import mesh;
import view;
import editmode;
import math : Vec3, Viewport;
import params : Param;
import change_bus : MeshEditScope;
import mesh_edit_delta : undoTrackerEnabled;
import commands.mesh.position_undo : PositionUndo;
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
    // Recorded `Kind.SetPos` undo (task 1903 L0-d4).
    private PositionUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 1903 §L0-d,
        /// witness W-d3a). The op-log SHAPE is not derivable from the outside:
        /// a command that records nothing falls back to its legacy revert and
        /// restores the right positions anyway, so every result-shaped
        /// assertion — the plane diff, the redo cell, the parity cell — is
        /// GREEN over a deleted recorder. Only reading the log itself is not.
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

        // §2.4 — the empty-selection refusal is resolved BEFORE the batch is
        // opened. Snapshot selectedEdges ONCE — avoid O(n²) @property access.
        bool[] edgeMask = mesh.selectedEdges.dup;

        // Empty selection → cannot run; no history entry.
        bool any = false;
        foreach (s; edgeMask) if (s) { any = true; break; }
        if (!any) return false;

        // REDO: re-run the kernel UNRECORDED and keep the first delta.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed, edgeMask);
            ed.close();
            return ok;
        }
        if (undoTrackerEnabled()) {
            auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed, edgeMask);
            undo_.arm(ed.close());
            if (!ok) { undo_.disarm(); return false; }
            return true;
        }
        // Legacy path — the SAME kernel through an UNRECORDED batch, so this
        // file's raw-write census row is 0 on BOTH paths.
        auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
        const ok = applyKernel(ed, edgeMask);
        ed.close();
        return ok;
    }

    private bool applyKernel(ref MeshEditBatch ed, in bool[] edgeMask) {
        // Compute new positions (pure — no mutation of mesh).
        Vec3[] newPos = edgeSlidePositions(*mesh, edgeMask, t_);

        // Snapshot only changed vertices (diff kernel output vs current).
        // TASK 1903 L0-d4 — THE `==` FILTER STAYS, and that is a ruling (§2.3).
        // `ed.setVertexPositions` filters on `sameBits`, which is STRICTER than
        // `==`: `==` says `-0.0 == +0.0` and `sameBits` does not. Handing the
        // full `0 .. V` list to `setVertexPositions` would therefore WRITE the
        // `==`-but-not-bit-identical cells and flip a signed zero — the exact
        // class measured at Stage D2 (9 of 320 cells, `mesh.d`'s `sameBits`
        // comment). Every index in the `==`-filtered list below is not `==`, so
        // `sameBits` is false for all of them and every write happens: delta
        // path ≡ legacy path ≡ the retired raw loop, byte for byte, with the
        // predicate spelled ONCE rather than exported twice.
        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        Vec3[] moved;
        foreach (i; 0 .. mesh.vertices.length) {
            Vec3 np = newPos[i];
            Vec3 op = mesh.vertices[i];
            if (np.x == op.x && np.y == op.y && np.z == op.z) continue;
            touchedIdx  ~= cast(uint)i;
            touchedPrev ~= op;
            moved       ~= np;
        }

        ed.setVertexPositions(touchedIdx, moved);
        ed.commitChange(MeshEditScope.Position);
        // Always true for a non-empty edge selection — even if no rail existed
        // on the requested side (touchedIdx is empty, undo is a no-op).
        return true;
    }

    override bool revert() {
        if (undo_.armed()) return undo_.revert(*mesh);
        // The tracker-off oracle (W-d3c), and the 0099 arm. THIS COMMAND IS
        // WHERE 0099 WAS FIXED: a rail-less slide answers `ok` with an empty
        // touched set, so a `false` here makes `CommandHistory.undo` discard
        // the entry AND its whole trailing suffix. `delete.d`'s fallback
        // returns FALSE on an empty delta; copying that shape here regresses
        // `tests/test_edge_slide.d:296`. The empty-delta arm in `evaluate`
        // above therefore leaves `undo_` UNARMED rather than forcing an entry,
        // and this line answers true for it.
        if (touchedIdx.length == 0) return true;   // no-op slide: positions unchanged, revert succeeds
        // TASK 1903 L0-d — THE LEGACY REVERT WRITES THROUGH THE BATCH TOO.
        // The plan's §2.5 template left this loop "untouched"; that is
        // incompatible with its own §1/§3/W-d1, which require this file to read
        // `countRawPositionWrites == 0` — §1's measured table counts THIS LOOP
        // among the file's raw writes. Resolved the way §2.5 already resolved
        // the forward: the same write, through the same primitive, on an
        // UNRECORDED batch. It stays a genuine oracle for W-d3c because it
        // restores from the command's own stored pre-op array while the delta
        // path replays the op-log's `posBefore` — two independent data paths
        // that share only the write primitive, which is what a mutation of the
        // RECORDING has to be measured against. Byte-identical to the loop it
        // replaces: `setVertexPositions` skips only writes whose new value is
        // BIT-identical to the current one, and writing identical bits back was
        // what the loop did there; the bounds guard is the same `continue`.
        auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
        ed.setVertexPositions(touchedIdx, touchedPrev);
        ed.commitChange(MeshEditScope.Position);
        ed.close();
        return true;
    }
}
