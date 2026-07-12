module commands.mesh.radial_array_;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import math    : Vec3;
import params  : Param;
import snapshot : MeshSnapshot;

/// Radial array — insert `count-1` rotated copies of the selected
/// faces (or the whole mesh on empty selection). Each step rotates
/// the source by `i * total_angle / count` around an X/Y/Z axis
/// through `center`, plus an optional `i * extra_step_translate`
/// shift (for helices). `weld > 0` welds coincident verts and drops
/// duplicate seam faces — useful for closed 360° rings.
///
/// Axis is restricted to the principal axes (X/Y/Z). Arbitrary axis
/// vectors are a follow-up; their main downstream use case is the
/// helix sweep, which currently uses extra_step_translate instead.
class MeshRadialArray : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;

    private int    count_        = 6;
    private string axis_         = "Y";
    private Vec3   center_       = Vec3(0, 0, 0);
    // 2π in radians — full circle (the default for a radial array).
    private float  totalAngle_   = 6.2831853f;
    private Vec3   extraShift_   = Vec3(0, 0, 0);
    private float  weld_         = 0.001f;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.radial_array"; }
    override string label() const { return "Radial Array"; }

    override Param[] params() {
        return [
            // `.max(256).enforceBounds()` matches Mesh.radialArrayFaces'
            // internal `MAX_RADIAL_ARRAY_COUNT` cap — added for read-back-
            // clamp parity with the kernel's already-present cap.
            Param.int_  ("count",       "Count", &count_, 6).min(1).max(256).enforceBounds(),
            Param.enum_ ("axis",        "Axis",  &axis_,
                         [["X","X"], ["Y","Y"], ["Z","Z"]], "Y"),
            Param.vec3_ ("center",      "Center", &center_, Vec3(0, 0, 0)),
            Param.float_("total_angle", "Total Angle (rad)", &totalAngle_, 6.2831853f),
            Param.vec3_ ("extra_step_translate", "Extra Step Translate",
                         &extraShift_, Vec3(0, 0, 0)),
            Param.float_("weld",        "Weld Distance", &weld_, 0.001f).min(0.0f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;
        if (count_ <= 1)            return false;
        if (axis_.length != 1
         || (axis_[0] != 'X' && axis_[0] != 'Y' && axis_[0] != 'Z'))
            return false;

        bool[] mask = new bool[](mesh.faces.length);
        bool any = false;
        foreach (i, b; mesh.selectedFaces) {
            if (b) { mask[i] = true; any = true; }
        }
        if (!any) {
            foreach (i; 0 .. mesh.faces.length) mask[i] = true;
        }

        snap = MeshSnapshot.capture(*mesh);
        size_t inserted = mesh.radialArrayFaces(mask, count_, axis_[0], center_,
                                                totalAngle_, extraShift_, weld_);
        if (inserted == 0) {
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
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
