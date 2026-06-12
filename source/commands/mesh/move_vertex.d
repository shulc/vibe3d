module commands.mesh.move_vertex;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import viewcache;
import math : Vec3;
import params : Param;
import change_bus : MeshEditScope;

/// Move a vertex from one position to another, identified by current world
/// coordinates (within EPS tolerance). Useful for test scenarios that need
/// a non-default cube geometry without adding a new primitive.
class MeshMoveVertex : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private Vec3             from_ = Vec3(0, 0, 0);
    private Vec3             to_   = Vec3(0, 0, 0);

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.move_vertex"; }
    override string label() const { return "Move Vertex"; }

    override Param[] params() {
        return [
            Param.vec3_("from", "From", &from_, Vec3(0, 0, 0)),
            Param.vec3_("to",   "To",   &to_,   Vec3(0, 0, 0)),
        ];
    }

    private int  movedIdx = -1;     // vertex that was actually moved
    private Vec3 origPos;            // its pre-apply position

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        import std.math : abs;
        enum float EPS = 1e-4f;
        int found = -1;
        foreach (i, v; mesh.vertices) {
            if (abs(v.x - from_.x) < EPS && abs(v.y - from_.y) < EPS && abs(v.z - from_.z) < EPS) {
                found = cast(int)i;
                break;
            }
        }
        if (found < 0) return false;
        movedIdx = found;
        origPos  = mesh.vertices[found];
        mesh.vertices[found] = to_;

        // Change-notification (Stage 1): the forward apply moved a position but
        // historically did NOT bump mutationVersion (only revert did). Preserve
        // that exactly — noteChange publishes the Position class WITHOUT touching
        // the counters, so the bus sees the move while the version stays put.
        mesh.noteChange(MeshEditScope.Position);

        gpu.upload(*mesh);
        vc.invalidate();
        ec.invalidate();
        fc.invalidate();
        return true;
    }

    override bool revert() {
        if (movedIdx < 0 || movedIdx >= cast(int)mesh.vertices.length) return false;
        mesh.vertices[movedIdx] = origPos;
        mesh.commitChange(MeshEditScope.Position);
        gpu.upload(*mesh);
        vc.invalidate();
        ec.invalidate();
        fc.invalidate();
        return true;
    }
}
