module commands.mesh.paste_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import geometry_clipboard : geometryClipboard;

/// Append the clipboard geometry to the active mesh and select what it pasted —
/// the faces for a face clip, the points for a vertex-mode clip (task 1200,
/// ledger row 19). Snapshot undo restores the pre-paste cage.
///
/// Mode-agnostic: paste works in any edit mode — what it injects is decided by
/// the CLIP, not by the current picking mode. This is the intended
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
        // A clip with points and no faces is a VERTEX-mode copy (task 1200,
        // ledger row 19). `appendGeometry` answers 0 to an empty face list by
        // design — it has nothing to remap or to select — so the loose points
        // get their own append, which selects them the same way appendGeometry
        // selects the faces it pasted.
        size_t n = geometryClipboard.looseOnly
            ? mesh.appendLooseVertices(geometryClipboard.verts)
            : mesh.appendGeometry(
                geometryClipboard.verts,
                geometryClipboard.faces,
                geometryClipboard.subpatch,
                geometryClipboard.material,
                geometryClipboard.part,
                geometryClipboard.setMask);
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
