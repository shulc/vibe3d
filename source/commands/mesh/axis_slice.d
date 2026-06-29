module commands.mesh.axis_slice;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import params : Param;
import snapshot : MeshSnapshot;
import math : Vec3;

// ---------------------------------------------------------------------------
// MeshAxisSlice — cut the mesh with N evenly-spaced planes along a chosen axis.
//
// Params:
//   axis  — 0=X, 1=Y, 2=Z (default 1, Y-axis)
//   count — number of planes (default 1)
//
// No edit-mode gate: the cut is geometry-global and works in any mode.
// Undo = MeshSnapshot (topology rewrite); no snapshot taken if nothing is cut.
// ---------------------------------------------------------------------------
class MeshAxisSlice : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;

    private int axis_  = 1; // 0=X 1=Y 2=Z
    private int count_ = 1;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu; this.vc = vc; this.ec = ec; this.fc = fc;
    }

    override string name()  const { return "mesh.axisSlice"; }
    override string label() const { return "Axis Slice"; }

    override Param[] params() {
        return [
            Param.int_("axis",  "Axis",  &axis_,  1).min(0).max(2),
            Param.int_("count", "Count", &count_, 1).min(1),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (count_ < 1) return false;

        // Compute bounding box along the chosen axis.
        if (mesh.vertices.length == 0) return false;
        float minV = axisCoord(mesh.vertices[0], axis_);
        float maxV = minV;
        foreach (v; mesh.vertices) {
            float c = axisCoord(v, axis_);
            if (c < minV) minV = c;
            if (c > maxV) maxV = c;
        }
        float span = maxV - minV;
        if (span < 1e-6f) return false;

        Vec3 planeNormal = axisNormal(axis_);

        // Capture snapshot BEFORE any cuts so we can restore if nothing splits.
        snap = MeshSnapshot.capture(*mesh);

        size_t totalSplit = 0;
        foreach (k; 0 .. count_) {
            float pos = minV + span * cast(float)(k + 1) / cast(float)(count_ + 1);
            Vec3 planePoint = planeNormal * pos;
            totalSplit += mesh.cutByPlane(planePoint, planeNormal);
        }

        if (totalSplit == 0) {
            snap.restore(*mesh);
            snap = MeshSnapshot.init;
            return false;
        }

        refreshDisplay(mesh, gpu, vc, ec, fc);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshDisplay(mesh, gpu, vc, ec, fc);
        return true;
    }
}

// ---------------------------------------------------------------------------
// MeshJulienne — grid cut: axis slice on two axes sequentially.
//
// Params:
//   axisA, countA — first axis and count (default X, 1)
//   axisB, countB — second axis and count (default Z, 1)
//
// Single MeshSnapshot wraps both cuts (one undo entry for both passes).
// ---------------------------------------------------------------------------
class MeshJulienne : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;

    private int axisA_  = 0; // 0=X 1=Y 2=Z
    private int countA_ = 1;
    private int axisB_  = 2; // 0=X 1=Y 2=Z
    private int countB_ = 1;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu; this.vc = vc; this.ec = ec; this.fc = fc;
    }

    override string name()  const { return "mesh.julienne"; }
    override string label() const { return "Julienne"; }

    override Param[] params() {
        return [
            Param.int_("axisA",  "Axis A",  &axisA_,  0).min(0).max(2),
            Param.int_("countA", "Count A", &countA_, 1).min(1),
            Param.int_("axisB",  "Axis B",  &axisB_,  2).min(0).max(2),
            Param.int_("countB", "Count B", &countB_, 1).min(1),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (countA_ < 1 || countB_ < 1) return false;
        if (mesh.vertices.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);

        size_t totalSplit = 0;
        totalSplit += sliceAlongAxis(axisA_, countA_);
        if (axisB_ != axisA_)
            totalSplit += sliceAlongAxis(axisB_, countB_);

        if (totalSplit == 0) {
            snap.restore(*mesh);
            snap = MeshSnapshot.init;
            return false;
        }

        refreshDisplay(mesh, gpu, vc, ec, fc);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshDisplay(mesh, gpu, vc, ec, fc);
        return true;
    }

    private size_t sliceAlongAxis(int axis, int count) {
        float minV = axisCoord(mesh.vertices[0], axis);
        float maxV = minV;
        foreach (v; mesh.vertices) {
            float c = axisCoord(v, axis);
            if (c < minV) minV = c;
            if (c > maxV) maxV = c;
        }
        float span = maxV - minV;
        if (span < 1e-6f) return 0;

        Vec3 n = axisNormal(axis);
        size_t total = 0;
        foreach (k; 0 .. count) {
            float pos = minV + span * cast(float)(k + 1) / cast(float)(count + 1);
            total += mesh.cutByPlane(n * pos, n);
        }
        return total;
    }
}

// ---------------------------------------------------------------------------
// Helpers shared by both commands
// ---------------------------------------------------------------------------

private float axisCoord(Vec3 v, int axis) {
    if (axis == 0) return v.x;
    if (axis == 2) return v.z;
    return v.y; // default Y (axis==1)
}

private Vec3 axisNormal(int axis) {
    if (axis == 0) return Vec3(1, 0, 0);
    if (axis == 2) return Vec3(0, 0, 1);
    return Vec3(0, 1, 0); // default Y (axis==1)
}
