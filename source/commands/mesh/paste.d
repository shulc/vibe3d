module commands.mesh.paste_;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import geometry_clipboard : geometryClipboard;

/// Append the clipboard geometry to the active mesh and select the pasted
/// faces. Snapshot undo restores the pre-paste cage.
///
/// Mode-agnostic: paste works in any edit mode — it always injects face
/// topology regardless of the current picking mode. This is the intended
/// asymmetry vs. mesh.copy / mesh.cut (Polygons-only): paste should remain
/// available from any mode so a future UI Paste button can stay enabled
/// everywhere (button gating reads supportedModes).
class MeshPaste : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.paste"; }
    override string label() const { return "Paste"; }

    // No supportedModes override → inherits the unrestricted base set.
    // paste is deliberately mode-agnostic (see class doc).

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (geometryClipboard.empty) return false;

        snap = MeshSnapshot.capture(*mesh);
        size_t n = mesh.appendGeometry(
            geometryClipboard.verts,
            geometryClipboard.faces,
            geometryClipboard.subpatch,
            geometryClipboard.material,
            geometryClipboard.part);
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
