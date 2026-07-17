module commands.mesh.split_edge;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import math : Vec3;
import snapshot : MeshSnapshot;

/// Split the (first) currently selected edge at its midpoint, inserting a
/// new vertex and updating every incident face. Edges are re-derived from
/// faces afterwards. The selection is reset on success.
class MeshSplitEdge : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "mesh.split_edge"; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Edges) return false;
        if (!mesh.hasAnySelectedEdges()) return false;

        int ei = -1;
        foreach (i, sel; mesh.selectedEdges)
            if (sel) { ei = cast(int)i; break; }
        if (ei < 0 || ei >= cast(int)mesh.edges.length) return false;

        // Snapshot before mutation. split_edge inserts a new vert and
        // reshuffles many faces — full mesh snapshot is the simplest
        // correct revert. Cheap enough at typical mesh sizes.
        snap = MeshSnapshot.capture(*mesh);

        uint va = mesh.edges[ei][0];
        uint vb = mesh.edges[ei][1];
        Vec3 mid = (mesh.vertices[va] + mesh.vertices[vb]) * 0.5f;
        uint vm  = mesh.addVertex(mid);

        // Insert vm between (va, vb) (in either traversal direction) in
        // every face containing the edge.
        foreach (ref face; mesh.faces) {
            for (size_t k = 0; k < face.length; k++) {
                uint a = face[k];
                uint b = face[(k + 1) % face.length];
                if ((a == va && b == vb) || (a == vb && b == va)) {
                    face = face[0 .. k + 1] ~ vm ~ face[k + 1 .. $];
                    break;
                }
            }
        }

        // Re-derive edges from faces. addEdge dedupes via edgeIndexMap.
        mesh.edges.length = 0;
        mesh.edgeIndexMap.clear();
        foreach (ref face; mesh.faces) {
            foreach (k; 0 .. face.length) {
                mesh.addEdge(face[k], face[(k + 1) % face.length]);
            }
        }

        mesh.buildLoops();
        mesh.resetSelection();

        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
