module commands.mesh.weld_vertex_pair;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import params : Param;
import snapshot : MeshSnapshot;

/// Weld vertex `source` into vertex `target`: source is removed and its
/// incident faces are rewritten to reference `target`. The surviving vertex
/// sits at `target`'s original position (target-position rule).
///
/// Reuses mesh.weldVertexPair. Returns false (status:error) when the kernel
/// returns 0: same index, OOB index, shared-face (would yield a self-touching
/// polygon), or both-faceless (both vertices unreferenced by any face).
///
/// Params (injected via /api/command JSON or injectParamsInto):
///   source  — vertex index to remove (the "drop" vertex)
///   target  — vertex index to survive at (the "keep" vertex)
class MeshWeldVertexPair : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;

    private int source_ = -1;
    private int target_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc)
    {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.weldVertexPair"; }
    override string label() const { return "Weld Vertex Pair"; }

    override Param[] params() {
        return [
            Param.int_("source", "Source Vertex", &source_, -1),
            Param.int_("target", "Target Vertex", &target_, -1),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (source_ < 0 || target_ < 0)      return false;
        if (source_ == target_)               return false;
        if (cast(uint)source_ >= mesh.vertices.length) return false;
        if (cast(uint)target_ >= mesh.vertices.length) return false;

        snap = MeshSnapshot.capture(*mesh);
        size_t welded = mesh.weldVertexPair(cast(uint)target_,
                                            cast(uint)source_);
        if (welded == 0) {
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

private:
    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
