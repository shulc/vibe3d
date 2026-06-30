module commands.mesh.set_material;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import change_bus : MeshEditScope;
import params : Param;

/// Assigns a per-face material index (surface slot) to every selected face.
/// Only active in Polygons edit mode; empty selection is a no-op (no history
/// entry). The faceMaterial array is grown to faces.length before writing so
/// index-out-of-range is impossible. Out-of-range materialId values are
/// accepted — render sites defend with a 0 fallback (mesh.d:11133).
///
/// Undo note: origMaterial captures the (possibly grown, zero-filled)
/// faceMaterial slice before mutation; revert() restores it verbatim.
/// Newly appended zero slots are harmless — read sites defend fi<len?:0.
class MeshSetMaterial : Command, Operator {
    mixin OperatorActrCommon;
    private int    materialId_ = 0;
    private uint[] origMaterial;
    private bool   captured;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.setMaterial"; }
    override string label() const { return "Set Material"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Polygons];
    }

    override Param[] params() {
        return [ Param.int_("materialId", "Material", &materialId_, 0) ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        // Per-face operation — require Polygons mode so a stale face
        // selection from another mode cannot silently retag wrong faces.
        if (editMode != EditMode.Polygons)
            throw new Exception(
                "mesh.setMaterial requires Polygons edit mode "
                ~ "(switch via `select.typeFrom polygon` or press 3)");

        if (materialId_ < 0)
            throw new Exception("mesh.setMaterial: materialId must be >= 0");

        mesh.syncSelection();
        if (!mesh.hasAnySelectedFaces()) return false; // no-op: empty selection

        // Snapshot only faceMaterial[] — the sole field we mutate.
        // Grow to faces.length first so origMaterial is the full post-grow
        // state; revert restores it verbatim.
        if (mesh.faceMaterial.length < mesh.faces.length)
            mesh.faceMaterial.length = mesh.faces.length;
        origMaterial = mesh.faceMaterial.dup;
        captured     = true;

        // Materialize selectedFaces once (each access allocates).
        auto selView = mesh.selectedFaces;
        foreach (fi; 0 .. mesh.faces.length) {
            if (fi < selView.length && selView[fi])
                mesh.faceMaterial[fi] = cast(uint) materialId_;
        }

        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        if (!captured) return false;
        mesh.faceMaterial = origMaterial.dup;
        mesh.commitChange(MeshEditScope.Material);
        return true;
    }
}
