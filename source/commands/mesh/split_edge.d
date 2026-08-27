module commands.mesh.split_edge;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;
import commands.mesh.position_undo  : RecordedUndo;
import commands.mesh.map_edit_undo  : runMapEdit, revertMapEditEmptyOk;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Split the (first) currently selected edge at its midpoint, inserting a
/// new vertex and updating every incident face. Edges are re-derived from
/// faces afterwards. The selection is reset on success.
///
/// The split itself is `Mesh.addEdgePoint(ei, 0.5)` — the same primitive
/// `mesh.addPoint` drives, at a fixed parameter. See `evaluate` for why this
/// command stopped carrying its own copy of the splice (task 1903 §L2-P0).
/// TASK 1903 STAGE L2-c — UNDO IS THE OPERATION-LOG DELTA, and this command
/// needs TWO images rather than one. The topology half is the op-log
/// (`[AddVerts, MeshMapDelta, ReshapeFaces]`, through `insertEdgePoint`'s
/// winding door); the selection half is a DENSE capture, because
/// `mesh.resetSelection()` below clears all three domains and no delta kind
/// carries a selection-order stamp — see `commands/mesh/selection_undo.d` for
/// the measurement that settled that.
class MeshSplitEdge : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;      // the hatch's arm only
    private RecordedUndo     undo_;
    /// The pre-op selection of all three domains — `resetSelection()` destroys
    /// it and the op-log has nothing that puts it back.
    private DenseSelectionUndo preSel_;
    /// The forward SUCCEEDED — see `commands/mesh/flip.d`.
    private bool             applied_;

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (see `MeshFlip`).
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "mesh.split_edge"; }

    override MeshEditScope editScope() const { return MeshEditScope.Geometry; }

    /// See `MeshFlip.isOperationInverse` — a cheap tell, not the observable.
    override bool isOperationInverse() const { return undo_.armed(); }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Edges) return false;
        if (!mesh.hasAnySelectedEdges()) return false;

        int ei = -1;
        foreach (i, sel; mesh.selectedEdges)
            if (sel) { ei = cast(int)i; break; }
        if (ei < 0 || ei >= cast(int)mesh.edges.length) return false;

        // THE MIDPOINT SPLIT IS `Mesh.addEdgePoint(ei, 0.5)` — not a private
        // copy of it (task 1903 Stage L2-P0).
        //
        // This command used to splice the new corner into every incident
        // winding with its own loop right here, and then call
        // `rebuildEdges()` / `buildLoops()` by hand. `mesh.addPoint` already
        // reached the same splice through `addEdgePoint`, so the tree carried
        // the same edit twice, and only one of the two copies was correct:
        //
        //   * the splice changes the mesh's TOTAL corner count, and the copy
        //     here opened no corner rewrite at all, so `buildLoops`'s
        //     `resizePolyVertexMaps` fell through to the length insurance and
        //     ZEROED every PolyVertex map WHOLE — a point added on one edge
        //     cost the entire mesh its UVs, on the FORWARD; and
        //   * in a `-debug` build (which is what the module-unittest lane is)
        //     that same fall-through trips `mesh.d`'s
        //     `debug assert(false, "corner provenance: a face rewrite reached
        //     buildLoops without declaring what became of the corners…")`,
        //     so the command ABORTED the process on any map-carrying mesh
        //     rather than merely losing the plane.
        //
        // `addEdgePoint` is the sanctioned home: it wraps the identical
        // `insertEdgePoint` splice in the `beginCornerRewrite()` /
        // `declareCornerProvenance()` pair (mesh.d), carrying each new corner
        // as the per-FACE blend of its two endpoint corners, and then runs the
        // same `rebuildEdges()` / `buildLoops()` tail. Nothing about the
        // geometry changes: one vertex at the midpoint, spliced between the
        // endpoints in every incident winding.
        //
        // Two deliberate consequences, neither an accident:
        //   * the midpoint is now `a + 0.5·(b − a)` rather than `(a + b)·0.5`,
        //     which can differ by one ulp on coordinates that are not exactly
        //     representable. It is the SAME arithmetic `mesh.addPoint` has
        //     always used at t = 0.5, and one spelling of a midpoint in the
        //     tree is worth more than a bit-for-bit freeze of the other; and
        //   * `resetSelection()` stays HERE. `addEdgePoint` deliberately
        //     leaves the selection alone (the loop-insert family does too);
        //     this command's contract is that the selection is reset on
        //     success, and that is this line, not the primitive's.
        // EVERY REFUSAL IS ALREADY PRE-FLIGHT (the L8 rule): `addEdgePoint`
        // answers `uint.max` only for an out-of-range edge index — checked
        // above — and for a `t` outside (0, 1), a literal here, and it refuses
        // before its first mutation. So the kernel cannot refuse after
        // mutating and nothing has to be hoisted.
        applied_ = runMapEdit(mesh, undo_, snap, MeshEditScope.Geometry,
                              (ref MeshEditBatch ed) => runKernel(ed, cast(uint)ei));
        return applied_;
    }

    /// The one mutating body, under whichever arm `runMapEdit` chose.
    private bool runKernel(ref MeshEditBatch ed, uint ei) {
        // Recording arm only — the redo arm keeps the first capture, the hatch
        // has the snapshot.
        if (ed.recording() && !preSel_.filled()) preSel_.capture(ed.mesh);

        immutable uint vm = ed.mesh.addEdgePoint(ei, 0.5f);
        if (vm == uint.max) {
            // Unreachable on today's guards (see the comment above the call).
            // Kept so that a later parameterisation of the split position
            // cannot silently mutate nothing and report success; a refusal
            // here has changed nothing, so `runMapEdit` disarms the empty
            // delta and `applyImpl` lands no history entry.
            return false;
        }

        mesh.resetSelection();
        return true;
    }

    override bool revert() {
        // `…EmptyOk`, and the `if (!snap.filled) return false;` this replaces
        // was DELETED rather than translated — a `false` from a Model entry's
        // `revert()` truncates the undo stack instead of declining one step
        // (regression 0099).
        if (!revertMapEditEmptyOk(mesh, undo_, snap, applied_)) return false;
        // ONLY on the delta arm — the hatch's snapshot already restored every
        // selection plane.
        if (undo_.armed()) preSel_.restore(*mesh);
        return true;
    }
}
