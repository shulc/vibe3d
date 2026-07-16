module commands.mesh.edge_join;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import params : Param;
import snapshot : MeshSnapshot;
import math : Vec3;

/// Join two selected edges sharing a degree-2 vertex into a single edge by
/// dissolving the shared middle vertex. Inverse of mesh.split_edge.
///
/// mode 0 (plain join):   endpoints preserved, middle vertex removed.
/// mode 1 (averaged):     each sub-edge endpoint moves to the midpoint of its
///                        own sub-edge before the middle vertex is dissolved.
///                        Result: single edge (midpoint(a,m), midpoint(m,b)).
///
/// Guards (evaluate returns false → status:error):
///   - not in Edges edit mode
///   - not exactly 2 edges selected
///   - selected edges share no common vertex (disjoint)
///   - shared vertex has edge-degree ≠ 2
class MeshEdgeJoin : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    private int mode_ = 0;  // 0 = plain join, 1 = averaged

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.edgeJoin"; }
    override string label() const { return mode_ == 0 ? "Join" : "Join Averaged"; }

    override Param[] params() {
        return [
            Param.int_("mode", "Mode", &mode_, 0).min(0).max(1),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Edges) return false;

        // Collect exactly 2 selected edge indices.
        int e0 = -1, e1 = -1;
        foreach (i, sel; mesh.selectedEdges) {
            if (!sel) continue;
            if      (e0 < 0) e0 = cast(int)i;
            else if (e1 < 0) e1 = cast(int)i;
            else             return false;  // more than 2 selected
        }
        if (e0 < 0 || e1 < 0) return false;  // fewer than 2 selected

        // Find the shared vertex m and the far endpoints a, b.
        uint ea0 = mesh.edges[e0][0], ea1 = mesh.edges[e0][1];
        uint eb0 = mesh.edges[e1][0], eb1 = mesh.edges[e1][1];

        uint m = uint.max, a = uint.max, b = uint.max;
        if      (ea0 == eb0) { m = ea0; a = ea1; b = eb1; }
        else if (ea0 == eb1) { m = ea0; a = ea1; b = eb0; }
        else if (ea1 == eb0) { m = ea1; a = ea0; b = eb1; }
        else if (ea1 == eb1) { m = ea1; a = ea0; b = eb0; }
        else                 return false;  // disjoint — no shared vertex

        // Guard: shared vertex must have exactly 2 incident edges.
        int degree = 0;
        foreach (e; mesh.edges)
            if (e[0] == m || e[1] == m) ++degree;
        if (degree != 2) return false;

        // Snapshot before any mutation.
        snap = MeshSnapshot.capture(*mesh);

        // Mode 1 (averaged): shift each sub-edge endpoint to its own midpoint.
        //   a → midpoint(a, m),  b → midpoint(b, m)
        if (mode_ == 1) {
            Vec3 vm = mesh.vertices[m];
            mesh.vertices[a] = (mesh.vertices[a] + vm) * 0.5f;
            mesh.vertices[b] = (mesh.vertices[b] + vm) * 0.5f;
        }

        // Dissolve the middle vertex: drops m from every incident face boundary,
        // rebuilds edges, and compacts the now-orphan vertex out.
        auto mask = new bool[](mesh.vertices.length);
        mask[m] = true;
        auto n = mesh.dissolveVerticesByMask(mask);
        if (n == 0) {
            snap = MeshSnapshot.init;
            return false;
        }

        mesh.resetSelection();
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
