module commands.mesh.loop_slice;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import params : Param;
import snapshot : MeshSnapshot;

// ---------------------------------------------------------------------------
// selectNewLoopEdges — reference-editor (v11) post-slice selection parity
//   (task 0476). After a loop slice the reference leaves the ACTIVE selection
//   on the freshly-inserted loop: every edge BOTH of whose endpoints is a
//   newly-created loop vertex (index >= `firstNewVert`, the vertex count
//   captured just before the cut). For a single loop this is the 4 transverse
//   loop edges; for count>1 it is every loop's transverse edges PLUS the
//   along-rail segments between consecutive loop midpoints (measured against
//   the reference on the unit cube: count 1 -> 4 edges; count 3 -> 12
//   transverse + 8 along-rail = 20). `insertEdgeLoops` appends every new
//   midpoint via `addVertex` (originals keep their indices) and its internal
//   `resetSelection()` has already cleared the seed selection, so we only ADD
//   the loop edges here, in the caller's current (Edges) mode. The command's
//   snapshot restores the pre-cut selection on undo.
private void selectNewLoopEdges(Mesh* mesh, uint firstNewVert) {
    foreach (ei, e; mesh.edges)
        if (e[0] >= firstNewVert && e[1] >= firstNewVert)
            mesh.selectEdge(cast(int)ei);
}

// ---------------------------------------------------------------------------
// MeshAddLoop — insert one edge loop at a parametric position on the ring
//               crossed by the first selected edge.  Default position = 0.5
//               (midpoint).
// ---------------------------------------------------------------------------
class MeshAddLoop : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    private float position_ = 0.5f;  // `position` attr — 0 = start, 1 = end

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
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

        immutable uint firstNewVert = cast(uint)mesh.vertices.length;
        snap = MeshSnapshot.capture(*mesh);

        bool ok = mesh.insertEdgeLoops(cast(uint)ei, [position_]);
        if (!ok) { snap = MeshSnapshot.init; return false; }

        // Reference parity (task 0476): select the newly-inserted loop.
        selectNewLoopEdges(mesh, firstNewVert);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
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
    private MeshSnapshot     snap;

    private int count_ = 3;  // `count` attr — number of loops to insert

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
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

        immutable uint firstNewVert = cast(uint)mesh.vertices.length;
        snap = MeshSnapshot.capture(*mesh);

        bool ok = mesh.insertEdgeLoops(cast(uint)ei, pos);
        if (!ok) { snap = MeshSnapshot.init; return false; }

        // Reference parity (task 0476): select every newly-inserted loop.
        selectNewLoopEdges(mesh, firstNewVert);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
