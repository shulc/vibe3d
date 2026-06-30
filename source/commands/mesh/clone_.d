module commands.mesh.clone_;

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

/// Single-copy placement — duplicate the selected faces (or the whole mesh
/// when nothing is selected) and offset the copy by `offset`.
///
/// Distinct from `mesh.array` in two ways:
///   - `count` is fixed at 2 (one original + exactly one copy).
///   - `weld` is pinned to 0.0f so a zero-offset clone keeps the coincident
///     copy rather than welding it back into the original.  This is the only
///     thing distinguishing `mesh.clone` from a careless `mesh.array{count:2}`
///     call, and the reason the dedicated command + the zero-offset test exist.
///
/// Edit-mode-orthogonal: reads the face selection (empty ⇒ whole-mesh
/// fallback, same as mesh.array / mesh.mirror).  Interactive tools that
/// want a selection-required policy gate upstream in the tool handler.
class MeshClone : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;

    private Vec3 offset_ = Vec3(1, 0, 0);

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.clone"; }
    override string label() const { return "Clone"; }

    override Param[] params() {
        return [
            Param.vec3_("offset", "Offset", &offset_, Vec3(1, 0, 0)),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        // Build face mask — empty selection ⇒ whole mesh (same convention
        // as mesh.array / mesh.mirror).
        bool[] mask = new bool[](mesh.faces.length);
        bool any = false;
        foreach (i, b; mesh.selectedFaces) {
            if (b) { mask[i] = true; any = true; }
        }
        if (!any) {
            foreach (i; 0 .. mesh.faces.length) mask[i] = true;
        }

        snap = MeshSnapshot.capture(*mesh);
        // weld=0 PINNED — a zero-offset clone must keep the coincident copy
        // rather than collapsing it back to the original (the default
        // array weld of 0.001 would do that).
        size_t inserted = mesh.arrayFaces(mask, 2, offset_, 0.0f);
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
