module commands.mesh.set_part;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import change_bus : MeshEditScope;
import params : Param;

/// Assigns a per-face numeric part id to every selected face.
/// Only active in Polygons edit mode; empty selection is a no-op (no history
/// entry). The facePart array is grown to faces.length before writing so
/// index-out-of-range is impossible.
///
/// Undo note: origPart captures the (possibly grown, zero-filled) facePart
/// slice before mutation; revert() restores it verbatim.
class MeshSetPart : Command, Operator {
    mixin OperatorActrCommon;
    private int    partId_ = 0;
    private uint[] origPart;
    private bool   captured;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.setPart"; }
    override string label() const { return "Set Part"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Polygons];
    }

    override Param[] params() {
        return [ Param.int_("partId", "Part", &partId_, 0) ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        if (editMode != EditMode.Polygons)
            throw new Exception(
                "mesh.setPart requires Polygons edit mode "
                ~ "(switch via `select.typeFrom polygon` or press 3)");

        if (partId_ < 0)
            throw new Exception("mesh.setPart: partId must be >= 0");

        mesh.syncSelection();
        if (!mesh.hasAnySelectedFaces()) return false;

        if (mesh.facePart.length < mesh.faces.length)
            mesh.facePart.length = mesh.faces.length;
        origPart = mesh.facePart.dup;
        captured = true;

        auto selView = mesh.selectedFaces;
        foreach (fi; 0 .. mesh.faces.length) {
            if (fi < selView.length && selView[fi])
                mesh.facePart[fi] = cast(uint) partId_;
        }

        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        if (!captured) return false;
        mesh.facePart = origPart.dup;
        mesh.commitChange(MeshEditScope.Material);
        return true;
    }
}
