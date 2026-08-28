module commands.mesh.move_vertex;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import math : Vec3;
import params : Param;
import change_bus : MeshEditScope;

/// Move a vertex from one position to another, identified by current world
/// coordinates (within EPS tolerance). Useful for test scenarios that need
/// a non-default cube geometry without adding a new primitive.
class MeshMoveVertex : Command, Operator {
    mixin OperatorActrCommon;
    private Vec3             from_ = Vec3(0, 0, 0);
    private Vec3             to_   = Vec3(0, 0, 0);

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
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
        noteUndoRecorded();   // task 2500 — the image and its flag, one statement
        mesh.vertices[found] = to_;

        // Change-notification (Stage 1): the forward apply moved a position but
        // historically did NOT bump mutationVersion (only revert did). Preserve
        // that exactly — publishChange publishes the Position class WITHOUT touching
        // the counters, so the bus sees the move while the version stays put.
        // TASK 1906 STAGE 2 — `publishChange`, not `noteChange`: this is the
        // command's LAST mesh publisher, and a command's tail must DELIVER.
        // `Mesh.publishChange`'s doc comment carries the whole rule and the
        // reason (same flags, same version-silence, one delivery at the batch
        // close — but structural instead of incidental).
        mesh.publishChange(MeshEditScope.Position);

        return true;
    }

    protected override void revertImpl() {
        // A GENUINE restore failure: the vertex this command moved is no
        // longer in the mesh, so its position cannot be put back.
        if (movedIdx < 0 || movedIdx >= cast(int)mesh.vertices.length) {
            failRevert("the moved vertex is no longer in the mesh");
            return;
        }
        mesh.vertices[movedIdx] = origPos;
        mesh.commitChange(MeshEditScope.Position);
    }
}
