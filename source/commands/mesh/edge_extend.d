module commands.mesh.edge_extend;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import math : Vec3;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;

/// Edge Extend (one-shot, undoable): ADDITIVE, non-manifold. Per selected edge
/// (with ≥1 adjacent face) spawn 2 ridge verts + 1 bridge quad WITHOUT modifying
/// the source mesh; vertices shared by multiple selected edges WELD to one new
/// vert (chains / loops / star junctions). Each new vert is positioned by a
/// world-frame TRS law (Offset world-axis applied last; Rotate then Scale about
/// the world origin; world-frame inset/shift drop from the original geometry).
/// Geometry lives in the standalone kernel Mesh.extendEdgesByMask. Edges-mode
/// only; empty selection ⇒ whole mesh; a 0-result (no edge with an adjacent
/// face) is a no-op (snapshot discarded).
/// TASK 1903 STAGE L8-d — **DECLINED, ON A MEASUREMENT, AND THE `MeshSnapshot`
/// BELOW STAYS.** This is the question it answers (§6.6's convention: the
/// decision lives at its own declaration).
///
/// QUESTION: may ``mesh.edge_extend`` leave the whole-mesh snapshot for the
/// operation-log delta, as the other four members of the extrude/extend family
/// did at stages L8-a/-b/-c?
///
/// ANSWER: no, because it would ship a REGRESSION, and the regression is in a
/// plane a geometry check cannot see. ``Mesh.extendEdgesByMask`` ends with a
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
class MeshEdgeExtend : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;
    private float            inset_   = 0.1f;
    private float            shift_   = 0.0f;
    private float            offsetX_ = 0.0f, offsetY_ = 0.0f, offsetZ_ = 0.0f;
    private float            rotateX_ = 0.0f, rotateY_ = 0.0f, rotateZ_ = 0.0f;
    private float            scaleX_  = 1.0f, scaleY_  = 1.0f, scaleZ_  = 1.0f;
    private int              segments_ = 1;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.edge_extend"; }
    override string label() const { return "Edge Extend"; }

    override Param[] params() {
        return [
            Param.float_("inset",    "Local Inset", &inset_,   0.1f),
            Param.float_("shift",    "Local Shift", &shift_,   0.0f),
            Param.float_("offsetX",  "Offset X",    &offsetX_, 0.0f),
            Param.float_("offsetY",  "Offset Y",    &offsetY_, 0.0f),
            Param.float_("offsetZ",  "Offset Z",    &offsetZ_, 0.0f),
            Param.float_("rotateX",  "Rotate X",    &rotateX_, 0.0f).angle(),
            Param.float_("rotateY",  "Rotate Y",    &rotateY_, 0.0f).angle(),
            Param.float_("rotateZ",  "Rotate Z",    &rotateZ_, 0.0f).angle(),
            Param.float_("scaleX",   "Scale X",     &scaleX_,  1.0f),
            Param.float_("scaleY",   "Scale Y",     &scaleY_,  1.0f),
            Param.float_("scaleZ",   "Scale Z",     &scaleZ_,  1.0f),
            // `.max(1024).enforceBounds()` matches Mesh.extendEdgesByMask's
            // internal `MAX_EXTEND_SEGMENTS` cap — the Param bound alone is
            // a UI-only hint and does not clamp a raw HTTP write.
            Param.int_("segments",   "Segments",    &segments_, 1).min(1).max(1024).enforceBounds(),
        ];
    }
    // For a future tool's drag path.
    void setInset(float v)  { inset_ = v; }
    void setShift(float v)  { shift_ = v; }
    void setOffset(Vec3 v)  { offsetX_ = v.x; offsetY_ = v.y; offsetZ_ = v.z; }
    void setRotate(Vec3 v)  { rotateX_ = v.x; rotateY_ = v.y; rotateZ_ = v.z; }
    void setScale(Vec3 v)   { scaleX_  = v.x; scaleY_  = v.y; scaleZ_  = v.z; }
    void setSegments(int v) { segments_ = v; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Edges) return false;
        if (mesh.edges.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        auto mask = mesh.operandEdgeMask();
        // task 1903 Stage H: extendEdgesByMask takes `ref MeshEditBatch` now.
        // This command undoes via the MeshSnapshot above, not the op-log, so
        // the batch is unrecorded.
        auto ed = MeshEditBatch.unrecorded(*mesh, kExtrudeEditScope);
        size_t n = ed.extendEdgesByMask(
            mask, inset_, shift_,
            Vec3(offsetX_, offsetY_, offsetZ_),
            Vec3(rotateX_, rotateY_, rotateZ_),
            Vec3(scaleX_,  scaleY_,  scaleZ_),
            segments_);
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
