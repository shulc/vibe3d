module commands.mesh.edge_extrude;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;

/// All-true selection mask of length `n`, used when nothing is selected
/// (empty selection ⇒ whole mesh). Mirrors the helper in delete_.d.
private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}

/// Edge Extrude (one-shot, undoable): shift the selected edges outward along
/// the average normal of their neighbor polygon(s) by `extrude`, inset those
/// neighbors by `width`, and bridge with new faces. Geometry lives in the
/// reusable kernel Mesh.extrudeEdgesByMask. Edges-mode only; empty selection
/// ⇒ whole mesh; identity params (0/0) are a no-op (snapshot discarded).
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
        const all = mesh.nothingSelected(EditMode.Edges);
        auto mask = all ? allTrue(mesh.edges.length) : mesh.selectedEdges;
        size_t n = mesh.extrudeEdgesByMask(mask, extrude_, width_);
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
