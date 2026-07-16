module commands.mesh.spikey;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;

/// All-true selection mask of length `n`, used when nothing is selected
/// (empty selection ⇒ whole mesh). Mirrors the helper in poly_inset.d.
private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}

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
        const all = mesh.nothingSelected(EditMode.Polygons);
        auto mask = all ? allTrue(mesh.faces.length) : mesh.selectedFaces;
        size_t n = mesh.spikeFacesByMask(mask, amount_);
        if (n == 0) {
            snap = MeshSnapshot.init;
            return false;
        }
        refreshCaches();
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        refreshDisplayActive(mesh);
    }
}
