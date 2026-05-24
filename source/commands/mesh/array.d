module commands.mesh.array_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import math    : Vec3;
import params  : Param;
import snapshot : MeshSnapshot;

/// Linear array — insert `count-1` shifted copies of the selected
/// faces (or the whole mesh when nothing is selected). `count`
/// includes the original. `weld > 0` folds
/// coincident verts and drops duplicate seam polygons (same dedup
/// pipeline as `mesh.mirror`).
///
/// Per-step rotate / scale are deferred to a follow-up — see
/// doc/duplicate_plan.md. The `*.Radial Array` tool (PR-4) carries
/// the rotation pivot/axis schema so it's the natural home for those
/// modes.
class MeshArray : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;

    private int   count_  = 2;
    private Vec3  offset_ = Vec3(1, 0, 0);
    private float weld_   = 0.001f;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.array"; }
    override string label() const { return "Array"; }

    // Edit-mode-orthogonal — same as mesh.mirror. The operation reads
    // the face selection (or whole mesh if empty), independent of
    // which selection mode the user is currently in.

    override Param[] params() {
        return [
            Param.int_  ("count",  "Count",  &count_,  2).min(1),
            Param.vec3_ ("offset", "Offset", &offset_, Vec3(1, 0, 0)),
            Param.float_("weld",   "Weld Distance", &weld_, 0.001f).min(0.0f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;
        if (count_ <= 1)            return false;

        // Build face mask (empty user selection ⇒ whole mesh, same
        // convention as mesh.mirror / mesh.smooth).
        bool[] mask = new bool[](mesh.faces.length);
        bool any = false;
        foreach (i, b; mesh.selectedFaces) {
            if (b) { mask[i] = true; any = true; }
        }
        if (!any) {
            foreach (i; 0 .. mesh.faces.length) mask[i] = true;
        }

        snap = MeshSnapshot.capture(*mesh);
        size_t inserted = mesh.arrayFaces(mask, count_, offset_, weld_);
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
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length);
        vc.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        ec.resize(mesh.edges.length);
        ec.invalidate();
    }
}
