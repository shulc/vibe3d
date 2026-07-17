module commands.mesh.cut_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import geometry_clipboard : geometryClipboard, GeometryClip;

/// Cut the currently selected faces: fill the clipboard with their geometry,
/// then delete them from the mesh. Snapshot undo restores the pre-cut cage.
///
/// Clipboard semantics on revert: the clipboard KEEPS the cut content after
/// undo — undoing a cut does not wipe the clip (standard cut/undo behavior).
///
/// Clipboard fill ordering (Minor 7): the clip is captured from the
/// pre-delete selection into a local `GeometryClip`, and only committed
/// to `geometryClipboard` after the delete confirms `affected > 0`. This
/// prevents a failed delete from silently overwriting a valid prior clip.
/// In practice the `hasAnySelectedFaces` guard makes 0-affected unreachable,
/// but the ordering makes the invariant local rather than relying on the
/// precondition.
class MeshCut : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.cut"; }
    override string label() const { return "Cut"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Polygons];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Polygons) return false;
        if (!mesh.hasAnySelectedFaces())   return false;

        // Capture the clip from the pre-delete selection first (Minor 7):
        // build into a local and commit only after the delete succeeds.
        auto localClip = GeometryClip.fromSelectedFaces(*mesh);

        snap = MeshSnapshot.capture(*mesh);
        size_t affected = mesh.deleteFacesByMask(mesh.selectedFaces);
        if (affected == 0) {
            snap = MeshSnapshot.init;
            return false;
        }
        // Delete succeeded — now commit to the global clipboard.
        geometryClipboard = localClip;
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        // Snapshot restores geometry. The clipboard intentionally keeps its
        // content — undoing a cut does not wipe the clip.
        snap.restore(*mesh);
        return true;
    }
}
