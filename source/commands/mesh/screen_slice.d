module commands.mesh.screen_slice;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;
import math : Vec3, cameraPlaneFromScreenLine;

// ---------------------------------------------------------------------------
// MeshScreenSlice — cut the mesh with the camera plane defined by a dragged
// screen-space line segment.
//
// Given two screen endpoints (ax,ay)→(bx,by) and the current camera, the cut
// plane is the plane through the camera eye that contains both screen rays.
// Under a perspective camera every ray shares the eye as origin, so the two
// endpoint rays uniquely span a plane; cutByPlane then cuts every mesh face
// the infinite plane crosses.
//
// Params:
//   ax, ay — first  screen endpoint (pixels, Y-down)
//   bx, by — second screen endpoint (pixels, Y-down)
//
// Degenerate guard (fires BEFORE any snapshot):
//   - screen endpoints closer than 1 px  → no-op (no snapshot, no undo entry)
//   - cross-product of rays near-zero    → no-op (numerical backstop)
//
// If the plane is valid but misses every face, the snapshot is restored and
// the command returns false (same behaviour as mesh.axisSlice).
//
// Undo = MeshSnapshot (full topology restore); no snapshot taken when
// nothing is cut.
// ---------------------------------------------------------------------------
class MeshScreenSlice : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    private float ax_ = 0, ay_ = 0, bx_ = 0, by_ = 0;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.screenSlice"; }
    override string label() const { return "Screen Slice"; }

    override Param[] params() {
        return [
            Param.float_("ax", "Ax", &ax_, 0),
            Param.float_("ay", "Ay", &ay_, 0),
            Param.float_("bx", "Bx", &bx_, 0),
            Param.float_("by", "By", &by_, 0),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (mesh.vertices.length == 0) return false;

        auto vp = effectiveViewport();

        // Build the camera plane BEFORE capturing a snapshot so that a
        // degenerate short line produces no undo entry and leaves the mesh
        // completely intact.
        Vec3 p, n;
        if (!cameraPlaneFromScreenLine(vp, ax_, ay_, bx_, by_, p, n))
            return false;

        // Capture snapshot and cut.
        snap = MeshSnapshot.capture(*mesh);
        auto nSplit = mesh.cutByPlane(p, n);

        if (nSplit == 0) {
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
