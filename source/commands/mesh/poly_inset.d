module commands.mesh.poly_inset;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;

/// Polygon Inset (one-shot, undoable): for each selected face, move each
/// corner along its angle BISECTOR by an absolute distance of `inset` world
/// units (see mesh.insetFacesByMask / insetCornerBisector — task 1190 ported
/// that direction off "toward the polygon centroid", which pointed OUT of the
/// face at a reflex corner) and connect the original boundary to the inset
/// boundary with N ring quads.
/// Polygons-mode only; empty selection ⇒ whole mesh. `inset == 0` is NOT a
/// no-op (task 0359, reference-matched: the split always happens, landing a
/// degenerate zero-width ring at inset=0) — the remaining no-op cases are an
/// empty/undersized selection mask AND, since task 1230, a selection in which
/// every face's ring starts at a COLLINEAR corner: the reference refuses that
/// face outright (ledger row 42), the kernel skips it, and a selection with
/// nothing left to process comes back through the same `evaluate → false`
/// door, i.e. `status:error, "command 'mesh.poly_inset' did not apply"`.
/// The OFFSET SIGN is ring-order dependent for the same reason — see
/// `math.ringStartCornerSign`. Both are deliberate adoptions of the
/// reference's reading of the ring, not repairs.
///
/// Default is deliberately NON-zero (task 0359 review): the reference tool's
/// own default is bit-exact 0.0, but that value is a degenerate zero-area
/// ring (coincident-position boundary verts — a NaN Newell-normal hazard if
/// the result is later subdivided/lit without an intervening edit). The
/// scriptable one-shot command keeps a safe non-zero default so a bare
/// `mesh.poly_inset` invocation never manufactures degenerate geometry by
/// accident; the interactive PolyInsetTool (tools/poly_inset_tool.d) still
/// starts at the reference-matched 0.0 (its activate() does not build a
/// preview, so 0.0 is only ever a transient starting value, never silently
/// applied — see PolyInsetTool's class doc-comment).
class MeshPolygonInset : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;
    private float            inset_ = 0.1f;   // safe non-zero default (task 0359 review)

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.poly_inset"; }
    override string label() const { return "Inset"; }

    override Param[] params() {
        return [
            Param.float_("inset", "Inset", &inset_, 0.1f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        auto mask = mesh.operandFaceMask();
        // Task 1903 Stage F2: `insetFacesByMask` is a free function over
        // `ref MeshEditBatch` (source/mesh_ops/poly_bevel.d), so the batch
        // opens HERE — at the command boundary, which is where §4.1 says it
        // belongs. One inset now STAMPS AND DERIVES once at `close()` instead
        // of once per appended corner vertex, once per appended ring quad and
        // once at the kernel's tail.
        //
        // STAMP, NOT DELIVERY. A `MeshEditBatch` (`g_editBatchStack`) and a
        // DELIVERY batch (`g_deliveryDepth`) are different mechanisms and only
        // the second defers a change-bus delivery: `Mesh.deliverPending()`
        // returns early on `g_deliveryDepth > 0` and never consults
        // `g_editBatchStack`. What holds the delivery count down at this call
        // site is `Command.apply`'s own `beginDeliveryBatchGlobal()`.
        // UNRECORDED because this command's undo is still the whole-mesh
        // `snap` above; Stage L7 (`bevel / inset`) flips it to the recording
        // constructor.
        size_t n;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kPolyBevelEditScope);
            n = ed.insetFacesByMask(mask, inset_);
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
