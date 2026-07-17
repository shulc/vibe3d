module commands.mesh.sweep;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math    : Vec3;
import params  : Param;
import snapshot : MeshSnapshot;

/// Revolve a selected edge profile (or polygon) around a principal axis to
/// produce a surface of revolution.
///
/// Profile source (determined by the current edit mode):
///   - **Edge mode**: `extractSelectedEdgeChain` reads the selected edge set
///     and produces an ordered vertex chain.  Open chains (2 degree-1
///     endpoints) and closed cycles (all degree-2) are both accepted.
///   - **Polygon mode**: exactly one selected face is required; its vertex
///     ring is used as a closed profile.
///
/// Parameters:
///   - count      — total number of profile copies including the original.
///                  Must be >= 2.
///   - axis       — principal rotation axis: "X", "Y", or "Z".
///   - center     — pivot point for the rotation (default: origin).
///   - angle      — total sweep angle in radians.  360° (≈6.2831853) is the
///                  default; values < 2π − 1e-3 produce an open arc sweep.
///
/// Undo: snapshot-based (MeshSnapshot), consistent with mesh.bridge and
///       mesh.radial_array.
class MeshSweep : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    private int    count_  = 8;
    private string axis_   = "Y";
    private Vec3   center_ = Vec3(0, 0, 0);
    // 2π in radians — full 360° revolve (default).
    private float  angle_  = 6.2831853f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.sweep"; }
    override string label() const { return "Sweep"; }

    override Param[] params() {
        return [
            Param.int_  ("count",  "Count",           &count_,  8).min(2),
            Param.enum_ ("axis",   "Axis",             &axis_,
                         [["X", "X"], ["Y", "Y"], ["Z", "Z"]], "Y"),
            Param.vec3_ ("center", "Center",           &center_, Vec3(0, 0, 0)),
            Param.float_("angle",  "Angle (rad)",      &angle_,  6.2831853f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        // Parameter guards.
        if (count_ < 2) return false;
        if (axis_.length != 1
         || (axis_[0] != 'X' && axis_[0] != 'Y' && axis_[0] != 'Z'))
            return false;

        // Extract profile and closed flag from the current edit mode.
        uint[] profile;
        bool   profileClosed;
        uint   profileFaceIdx = uint.max;   // set for polygon mode to delete after

        if (editMode == EditMode.Polygons) {
            // Exactly one face must be selected.
            uint[] selFaces;
            foreach (fi; 0 .. mesh.faces.length)
                if (mesh.isFaceSelected(fi)) selFaces ~= cast(uint)fi;
            if (selFaces.length != 1) return false;
            profileFaceIdx = selFaces[0];
            profile = mesh.faceVertexRing(profileFaceIdx).dup;
            profileClosed = true;
        } else if (editMode == EditMode.Edges) {
            profile = mesh.extractSelectedEdgeChain(profileClosed);
            if (profile.length == 0) return false;
        } else {
            return false;   // vertex mode — not supported
        }

        snap = MeshSnapshot.capture(*mesh);
        size_t inserted = mesh.revolveProfile(profile, profileClosed,
                                              count_, axis_[0], center_, angle_);
        if (inserted == 0) {
            snap = MeshSnapshot.init;
            return false;
        }

        // Polygon mode: delete the source profile polygon now that the
        // lateral surface has been built.  deleteFacesByMask rebuilds loops
        // internally; snap already covers the pre-mutation state.
        if (profileFaceIdx != uint.max) {
            auto delMask = new bool[](mesh.faces.length);
            delMask[profileFaceIdx] = true;
            mesh.deleteFacesByMask(delMask);
        }

        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
