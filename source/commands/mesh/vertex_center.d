module commands.mesh.vertex_center;

import display_sync : refreshDisplay;
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

/// Zero the chosen axis component(s) of every selected vertex to the origin.
///
/// axis ∈ {x, y, z, all}
///
/// This is a "zero to origin" operation — NOT a centroid collapse (that is
/// mesh.collapse). Vertex count and topology are unchanged; verts that were
/// distinct before the call remain distinct after (even if they now share a
/// coordinate value). No welding occurs.
///
/// No-op (returns false) when nothing is selected or when an unknown axis
/// string is supplied.
///
/// Undo uses a lightweight per-index position restore (no topology change
/// requires the heavier MeshSnapshot path).
class MeshCenterVertices : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;

    private string axis_ = "all";

    // Position-restore undo state (lightweight — no topology change).
    private int[]  idxs;
    private Vec3[] orig;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.centerVertices"; }
    override string label() const { return "Center Vertices"; }

    override Param[] params() {
        return [
            Param.enum_("axis", "Axis", &axis_,
                [["x","X"],["y","Y"],["z","Z"],["all","All"]], "all"),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null)      return false;
        if (!mesh.hasAnySelectedVertices())        return false;

        // Determine which axis components to zero.
        bool zx, zy, zz;
        if      (axis_ == "x")   { zx = true; }
        else if (axis_ == "y")   { zy = true; }
        else if (axis_ == "z")   { zz = true; }
        else if (axis_ == "all") { zx = zy = zz = true; }
        else return false;   // unknown axis string — guard against HTTP injection

        // Read the selection mask ONCE into a local (selectedVertices allocates a
        // fresh bool[] every call — re-calling it inside the loop wastes GC and
        // would be O(n²) for large meshes).
        auto sel = mesh.selectedVertices;

        idxs = [];
        orig = [];
        foreach (i; 0 .. sel.length) {
            if (!sel[i]) continue;
            idxs ~= cast(int)i;
            orig ~= mesh.vertices[i];
            Vec3 v = mesh.vertices[i];
            if (zx) v.x = 0;
            if (zy) v.y = 0;
            if (zz) v.z = 0;
            mesh.vertices[i] = v;
        }

        mesh.commitChange(MeshEditScope.Position);
        refreshDisplay(mesh, gpu, vc, ec, fc);
        return true;
    }

    override bool revert() {
        if (idxs.length == 0) return false;
        foreach (k; 0 .. idxs.length)
            mesh.vertices[idxs[k]] = orig[k];
        mesh.commitChange(MeshEditScope.Position);
        refreshDisplay(mesh, gpu, vc, ec, fc);
        return true;
    }
}
