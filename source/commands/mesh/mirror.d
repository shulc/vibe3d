module commands.mesh.mirror_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math    : Vec3;
import params  : Param;
import snapshot : MeshSnapshot;

/// Mirror the selected polygons across an axis-aligned plane (axis
/// passed through `center`). Reflects every cloned vert; winding is
/// reversed when `flipNormals` is on so the mirrored surface has
/// outward-facing normals; a non-zero `weld` folds coincident seam
/// verts into one vertex (the canonical "symmetric duplicate" mode).
///
/// Empty face selection ⇒ mirror the whole mesh.
///
/// Revert via full MeshSnapshot — same shape as MeshDelete /
/// MeshDuplicate; mirror touches both `vertices` and `faces`.
class MeshMirror : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    // Param-backed schema fields. Stored as plain T so &field works.
    private string axis_         = "X";
    private Vec3   center_       = Vec3(0, 0, 0);
    private float  weld_         = 0.001f;
    private bool   flipNormals_  = true;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.mirror"; }
    override string label() const { return "Mirror"; }

    // Mirror operates on the face selection (or whole mesh when no faces
    // are selected) — orthogonal to the current edit mode. It's a
    // topology op that doesn't care whether the user is in vert/edge/poly
    // select mode.

    override Param[] params() {
        return [
            Param.enum_("axis", "Axis", &axis_,
                        [["X","X"], ["Y","Y"], ["Z","Z"]], "X"),
            Param.vec3_("center", "Center", &center_, Vec3(0, 0, 0)),
            Param.float_("weld", "Weld Distance", &weld_, 0.001f).min(0.0f),
            Param.bool_("flip_normals", "Flip Normals", &flipNormals_, true),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0)               return false;
        if (axis_.length != 1
         || (axis_[0] != 'X' && axis_[0] != 'Y' && axis_[0] != 'Z'))
            return false;

        // Build face mask. Empty user selection ⇒ mirror the whole mesh
        // ("no selection ⇒ act on everything", as in mesh.quantize /
        // mesh.smooth).
        bool[] mask = new bool[](mesh.faces.length);
        bool any = false;
        foreach (i, b; mesh.selectedFaces) {
            if (b) { mask[i] = true; any = true; }
        }
        if (!any) {
            foreach (i; 0 .. mesh.faces.length) mask[i] = true;
        }

        snap = MeshSnapshot.capture(*mesh);
        size_t inserted = mesh.mirrorFaces(mask, axis_[0], center_, weld_, flipNormals_);
        if (inserted == 0) {
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
