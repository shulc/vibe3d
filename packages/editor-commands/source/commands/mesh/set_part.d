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
/// PERMANENTLY DENSE — task 1903 Stage L0, owner's ruling of 2026-08-27.
///
/// THE DECISION. `origPart` stays a whole-array `dup` of `facePart` for good.
/// `mesh.setPart` does not move to a recorded `MeshEditDelta`, and no
/// fifteenth `MeshOpEntry.Kind` is added for it.
///
/// THE QUESTION IT ANSWERS. "Which delta kind records a `facePart` change?"
/// — the answer is NONE, and none is being written. There is today no
/// `MeshOpEntry.Kind` whose payload is `facePart`, so migrating this command
/// means inventing one.
///
/// THE REASON, and it is arithmetic on both sides. What a `PartDelta` would
/// SAVE: `origPart` is one `uint` per face, so ~400 KB on a 100 000-face mesh
/// — the entire cost of this command's undo, whatever the selection was. What
/// it would COST: a new `MeshOpEntry.Kind` owes a branch in every exhaustive
/// `final switch` over that enum, for good — six of them in
/// `source/mesh_edit_delta.d` today (the four L0.P1 predicates and the
/// `applyForward` / `applyReverse` dispatchers), all `final switch` ON PURPOSE
/// so a new kind is a compile error rather than a silent `default:`. And the
/// kind would be BORN with no production caller but this one, i.e. one step
/// from the state `Kind.HideDelta` is in, whose dispatch has never executed at
/// all. 400 KB of transient undo state is not worth a permanent widening of
/// the type that every future kind then has to be read against.
///
/// WHAT IS NOT BEING SAID, stated because the short version reads like it.
/// `facePart` is NOT unhandled by the delta machinery. It rides RENUMBERING as
/// a passenger already: `mesh_edit_delta.d:2420` restores it for a surviving
/// face across a `FaceReindex` reversal, and the drop-set overlay just below
/// carries `facePrt` for the faces that did not survive; `RemoveFaces` carries
/// it too. What is absent is a kind that changes `facePart` as its PAYLOAD.
/// A reader who takes "no PartDelta" for "part ids are lost by undo" has read
/// this backwards.
///
class MeshSetPart : Command, Operator {
    mixin OperatorActrCommon;
    private int    partId_ = 0;
    private uint[] origPart;

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
        noteUndoRecorded();   // task 2500 — the image and its flag, one statement

        auto selView = mesh.selectedFaces;
        foreach (fi; 0 .. mesh.faces.length) {
            if (fi < selView.length && selView[fi])
                mesh.facePart[fi] = cast(uint) partId_;
        }

        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    protected override void revertImpl() {
        mesh.facePart = origPart.dup;
        mesh.commitChange(MeshEditScope.Material);
    }
}
