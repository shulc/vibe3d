module commands.mesh.edge_slice;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;

// ---------------------------------------------------------------------------
// MeshEdgeSlice — cut a strip of edges through the mesh between two given edges.
//
// Params:
//   edges — two edge indices [edgeA, edgeB] (IntArray, required length == 2)
//   tA    — cut position along edgeA (float, default 0.5; range [0,1])
//   tB    — cut position along edgeB (float, default 0.5; range [0,1])
//
// The shortest dual-graph path from any face incident to edgeA to any face
// incident to edgeB is found by BFS; every face on the path is split into two
// sub-faces by a chord connecting the cut points on its two boundary edges.
// Interior path edges are cut at their midpoint (t=0.5) in v1.
//
// Index-share (no T-junctions): the cut vertex on each interior edge is
// inserted once and referenced by both adjacent path sub-faces by the same
// vertex index, identical to mesh.axisSlice.
//
// Undo = MeshSnapshot; no snapshot is taken when nothing is cut (returns false).
// ---------------------------------------------------------------------------
class MeshEdgeSlice : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    private uint[] edges_; // IntArray: the two edge indices
    private float  tA_   = 0.5f;
    private float  tB_   = 0.5f;

    this(Mesh* mesh, ref View view, EditMode editMode)
    {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.edgeSlice"; }
    override string label() const { return "Edge Slice"; }

    override Param[] params() {
        return [
            Param.intArray_("edges", "Edges", &edges_),
            Param.float_("tA", "t on Edge A", &tA_, 0.5f).min(0.0f).max(1.0f),
            Param.float_("tB", "t on Edge B", &tB_, 0.5f).min(0.0f).max(1.0f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (edges_.length != 2) return false;

        snap = MeshSnapshot.capture(*mesh);

        // Mesh-robustness batch (fuzz-found): gate on `!r.meshChanged`, NOT
        // `facesSplit==0` — a chain that degenerates to a plain edge-split
        // (a real vertex kept and finalized by the kernel, facesSplit==0 but
        // meshChanged==true) must be recorded as a successful edit, not
        // force-reverted. Only a TRUE no-op (meshChanged==false) rolls back.
        auto r = mesh.edgeSliceEx(edges_[0], edges_[1], tA_, tB_);

        if (!r.meshChanged) {
            snap.restore(*mesh);
            snap = MeshSnapshot.init;
            return false;
        }

        refreshDisplayActive(mesh);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshDisplayActive(mesh);
        return true;
    }
}
