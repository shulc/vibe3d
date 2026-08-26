module commands.mesh.spikey;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;

/// Spikey (one-shot, undoable): for each selected face, add an apex vertex at
/// the face centroid displaced along the face normal by `amount * (perimeter/N)`
/// (D1-B: amount is percent of average edge length), then replace the face with
/// a triangle fan to that apex — one tri per original edge. The parent face's
/// material and subpatch flag are carried to every fan tri. Polygons mode only;
/// empty selection ⇒ whole mesh; `amount == 0` still fans (in-place triangulate).
/// Returns status:error only when no face in the selection has ≥ 3 verts.
class MeshSpikey : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;
    private float            amount_ = 0.5f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.spikey"; }
    override string label() const { return "Spikey"; }

    override Param[] params() {
        return [
            Param.float_("amount", "Amount", &amount_, 0.5f),
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
        // Task 1903 Stage F2 — the batch opens at the command boundary, for
        // the reason `mesh.poly_inset`'s does (§4.1). One spike now stamps
        // once at `close()` instead of once per apex vertex, once per appended
        // fan triangle and once at the tail. UNRECORDED: undo here is still
        // the whole-mesh `snap` above, and `spikey` is a Stage **L2**
        // command (create + index-stable topo-misc), not an L7 one — the
        // kernel ships in this family's file but the L table is keyed by
        // COMMAND (памятка E1 №3).
        size_t n;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kPolyBevelEditScope);
            n = ed.spikeFacesByMask(mask, amount_);
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
