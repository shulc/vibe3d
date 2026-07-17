module commands.mesh.vertex_set;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import math : Vec3;
import params : Param;
import change_bus : MeshEditScope;

/// Set every selected vertex to an absolute XYZ position.
///
/// All selected vertices are moved to the exact same point. This is an
/// absolute-coordinate operation — distinct from mesh.move_vertex (which
/// identifies a vertex by its current coordinates and moves it by
/// from→to). Vertex count and topology are unchanged; no welding occurs
/// even when multiple selected vertices land on the same point.
///
/// No-op (returns false) when nothing is selected.
///
/// Undo uses lightweight per-index position restore.
class MeshSetPosition : Command, Operator {
    mixin OperatorActrCommon;

    private Vec3 pos_ = Vec3(0, 0, 0);

    // Position-restore undo state.
    private int[]  idxs;
    private Vec3[] orig;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.setPosition"; }
    override string label() const { return "Set Position"; }

    override Param[] params() {
        return [
            Param.vec3_("pos", "Position", &pos_, Vec3(0, 0, 0)),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null)  return false;
        if (!mesh.hasAnySelectedVertices())   return false;

        // Read the selection mask ONCE (selectedVertices allocates a fresh bool[]
        // each call — re-calling inside the loop would be O(n²)).
        auto sel = mesh.selectedVertices;

        idxs = [];
        orig = [];
        foreach (i; 0 .. sel.length) {
            if (!sel[i]) continue;
            idxs ~= cast(int)i;
            orig ~= mesh.vertices[i];
            mesh.vertices[i] = pos_;
        }

        mesh.commitChange(MeshEditScope.Position);
        return true;
    }

    override bool revert() {
        if (idxs.length == 0) return false;
        foreach (k; 0 .. idxs.length)
            mesh.vertices[idxs[k]] = orig[k];
        mesh.commitChange(MeshEditScope.Position);
        return true;
    }
}
