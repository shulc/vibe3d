module commands.mesh.loop_slice;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import viewcache;
import params : Param;
import snapshot : MeshSnapshot;

// ---------------------------------------------------------------------------
// MeshAddLoop — insert one edge loop at a parametric position on the ring
//               crossed by the first selected edge.  Default position = 0.5
//               (midpoint).
// ---------------------------------------------------------------------------
class MeshAddLoop : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;

    private float position_ = 0.5f;  // `position` attr — 0 = start, 1 = end

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu; this.vc = vc; this.ec = ec; this.fc = fc;
    }

    override string name()  const { return "mesh.addLoop"; }
    override string label() const { return "Add Loop"; }

    override Param[] params() {
        return [
            Param.float_("position", "Position", &position_, 0.5f)
                 .min(0.001f).max(0.999f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (editMode != EditMode.Edges)       return false;
        if (!mesh.hasAnySelectedEdges())      return false;

        int ei = -1;
        foreach (i, sel; mesh.selectedEdges)
            if (sel) { ei = cast(int)i; break; }
        if (ei < 0 || ei >= cast(int)mesh.edges.length) return false;

        // Enforce open-interval: position 0 or 1 is coincident with a corner.
        if (position_ <= 0.0f || position_ >= 1.0f) return false;

        // Dry-run: check that a ring exists before taking a snapshot.
        bool closed;
        auto ring = mesh.collectEdgeRing(cast(uint)ei, closed);
        if (ring.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);

        bool ok = mesh.insertEdgeLoops(cast(uint)ei, [position_]);
        if (!ok) { snap = MeshSnapshot.init; return false; }

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
// MeshLoopSlice — insert N evenly-spaced edge loops on the ring crossed by
//                 the first selected edge.  Default count = 3 (→ 4 equal
//                 segments; positions = 1/4, 2/4, 3/4).
// ---------------------------------------------------------------------------
class MeshLoopSlice : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;

    private int count_ = 3;  // `count` attr — number of loops to insert

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu; this.vc = vc; this.ec = ec; this.fc = fc;
    }

    override string name()  const { return "mesh.loopSlice"; }
    override string label() const { return "Loop Slice"; }

    override Param[] params() {
        return [
            // `.max(256).enforceBounds()` matches Mesh.insertEdgeLoopsMulti's
            // internal `MAX_LOOP_SLICE_COUNT` cap — the Param bound alone is
            // a UI-only hint and does not clamp a raw HTTP write.
            Param.int_("count", "Count", &count_, 3).min(1).max(256).enforceBounds(),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (editMode != EditMode.Edges)       return false;
        if (!mesh.hasAnySelectedEdges())      return false;
        if (count_ < 1)                       return false;

        int ei = -1;
        foreach (i, sel; mesh.selectedEdges)
            if (sel) { ei = cast(int)i; break; }
        if (ei < 0 || ei >= cast(int)mesh.edges.length) return false;

        // Dry-run ring check before snapshot.
        bool closed;
        auto ring = mesh.collectEdgeRing(cast(uint)ei, closed);
        if (ring.length == 0) return false;

        // Evenly-spaced positions: (k+1) / (count+1) for k in 0..count.
        float[] pos;
        pos.reserve(count_);
        foreach (k; 0 .. count_)
            pos ~= (k + 1.0f) / (count_ + 1.0f);

        snap = MeshSnapshot.capture(*mesh);

        bool ok = mesh.insertEdgeLoops(cast(uint)ei, pos);
        if (!ok) { snap = MeshSnapshot.init; return false; }

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
