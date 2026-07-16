module commands.mesh.polygon_align;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;

/// One-shot command that, for each connected island of selected faces,
/// computes the island's area-weighted average plane and orthogonally
/// projects every vertex touched by that island onto the plane —
/// flattening non-planar / tilted selected faces to coplanar.
///
/// Polygons scope only (a plane requires at least one face).  Returns
/// false (no history entry) when not in Polygon mode, no face is
/// selected, or the selection is already planar within the
/// coordinate-scaled threshold.
///
/// **Shared-vertex semantic**: vertices shared between selected and
/// unselected faces are projected; the adjacent unselected faces
/// connected to them are therefore deformed.  Test fixtures should use
/// topologically isolated geometry to get unambiguous residuals.
///
/// Undo: MeshSnapshot-based (same as mesh.collapse polygon path).
class MeshAlign : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.align"; }
    override string label() const { return "Align Polygons"; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Polygons) return false;
        if (!mesh.hasAnySelectedFaces()) return false;

        auto sel = mesh.selectedFaces;
        snap = MeshSnapshot.capture(*mesh);
        auto n = mesh.alignFacesByMask(sel);
        if (n == 0) {
            snap.restore(*mesh);
            snap = MeshSnapshot.init;
            return false;
        }
        refreshDisplayActive(mesh);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshDisplayActive(mesh);
        return true;
    }
}
