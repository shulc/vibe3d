module commands.mesh.edge_extrude;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;

/// Edge Extrude (one-shot, undoable): shift the selected edges outward along
/// the average normal of their neighbor polygon(s) by `extrude`, inset those
/// neighbors by `width`, and bridge with new faces. Geometry lives in the
/// reusable kernel Mesh.extrudeEdgesByMask. Edges-mode only; empty selection
/// ⇒ whole mesh; identity params (0/0) are a no-op (snapshot discarded).
/// TASK 1903 STAGE L8-d — **DECLINED, ON A MEASUREMENT, AND THE `MeshSnapshot`
/// BELOW STAYS.** This is the question it answers (§6.6's convention: the
/// decision lives at its own declaration).
///
/// QUESTION: may ``mesh.edge_extrude`` leave the whole-mesh snapshot for the
/// operation-log delta, as the other four members of the extrude/extend family
/// did at stages L8-a/-b/-c?
///
/// ANSWER: no, because it would ship a REGRESSION, and the regression is in a
/// plane a geometry check cannot see. ``Mesh.extrudeEdgesByMask`` ends with a
/// STATED per-corner drop — `dropCornerProvenance(CornerDrop.SweptSurfaceNoLaw)`
/// (task 0830: "an EDGE extrude's wall is a fresh surface and no capture
/// measures its parameterisation") — which zeroes the WHOLE PolyVertex map,
/// the untouched faces' corners included. The whole-mesh snapshot puts those
/// values back on Ctrl+Z. The op-log CANNOT: `MeshEditDelta`'s replay
/// re-declares a drop of its own (`CornerDrop.DeltaReplayDeclined`) and
/// neither of this family's two edge kernels carries an entry whose reverse
/// supplies the pre-op corner values.
///
/// MEASURED BOTH WAYS on `makeTaggedGridBent(3)`, 2026-08-28, before any
/// migration commit: the SNAPSHOT revert leaves a residual of ZERO planes and
/// brings the UV map back as `0, 1, 2, …`; a RECORDING batch around the same
/// kernel reverts without throwing and leaves all 72 UV floats at ZERO, plus
/// the six Select-class planes. Pinned by the decline block in
/// `tests/unit/l8_extrude_delta_test.d`, which asserts BOTH halves — a cell
/// that only measured the delta's loss would be green if the snapshot ever
/// stopped restoring it too, and the decline would then be resting on nothing.
///
/// WHY THE FOUR SIBLINGS ARE FINE AND THESE TWO ARE NOT — the discriminator,
/// stated so it is not re-derived. `extrudeFacesByMask`,
/// `extrudeVerticesByMask` and `extrudePathStep_` all hand their WHOLE new
/// face array to `mesh_planes.rewriteFaces` under a `faceReindexScope()`, and
/// stage J made that call record the pre-rewrite corner values as a
/// `MeshMapDelta` immediately before the face entry — recorded BEFORE the
/// tail drop runs, so the reverse restores them. `extendEdgesByMask` reaches
/// no `rewriteFaces` at all (it is pure-add), and `extrudeEdgesByMask`'s one
/// call is deliberately NOT armed, because `recordRemoveFaces` three lines
/// above it already names that face drop and a second description of one
/// change is the double revert (plan §5.3). Arming it anyway was measured at
/// this stage and moved NOTHING on the family's own operand: the kernel's
/// cleanup branch does not run there, so the log came back byte-identical.
///
/// WHAT WOULD LIFT THE DECLINE, in order of cost: task 0830 revisiting
/// `SweptSurfaceNoLaw` for the ORIGINAL faces' corners (a FORWARD change to a
/// captured law decision, and an owner's call, not a migration stage's); or a
/// `MeshOpEntry` payload whose reverse restores a PolyVertex map wholesale
/// with no face entry to pair with (a new kind — six `final switch`es, a
/// `static assert` count and a ruling table — and the struct is the track's
/// one serialisation point).
class MeshEdgeExtrude : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;
    private float            extrude_ = 0.2f;
    private float            width_   = 0.1f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.edge_extrude"; }
    override string label() const { return "Edge Extrude"; }

    override Param[] params() {
        return [
            Param.float_("extrude", "Extrude", &extrude_, 0.2f),
            Param.float_("width",   "Width",   &width_,   0.1f),
        ];
    }
    // For a future tool's drag path.
    void setExtrude(float v) { extrude_ = v; }
    void setWidth(float v)   { width_   = v; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Edges) return false;
        if (mesh.edges.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        auto mask = mesh.operandEdgeMask();
        // task 1903 Stage H: extrudeEdgesByMask takes `ref MeshEditBatch` now.
        // This command undoes via the MeshSnapshot above, not the op-log, so
        // the batch is unrecorded.
        auto ed = MeshEditBatch.unrecorded(*mesh, kExtrudeEditScope);
        size_t n = ed.extrudeEdgesByMask(mask, extrude_, width_);
        ed.close();
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
