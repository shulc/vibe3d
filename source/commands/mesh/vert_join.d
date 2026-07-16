module commands.mesh.vert_join;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math : Vec3;
import snapshot : MeshSnapshot;
import params : Param;

/// Tier 1.2: `vert.join`. Collapses the selected vertices to a
/// single point — the centroid (`average=true`) or the first selected
/// vert's position (`average=false`) — then welds them. Faces that
/// collapse to < 3 unique verts are dropped. `keep` is recognized but
/// not yet honored (vibe3d drops degenerate polys).
class MeshVertJoin : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    private bool average_ = true;
    private bool keep_    = false;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "vert.join"; }
    override string label() const { return "Join Vertices"; }

    override Param[] params() {
        return [
            Param.bool_("average", "Average", &average_, true),
            Param.bool_("keep",    "Keep 1-Vertex Polygons", &keep_, false),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (!mesh.hasAnySelectedVertices()) return false;

        // Find the target position (centroid OR first-selected) and
        // collect the indices being joined.
        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        int  firstIdx = -1;
        // Perf (task 0388): isVertexSelected(vi) replaces the bounds-check +
        // @property-index pair — `mesh.selectedVertices` rebuilds a whole
        // `bool[]` per read, which was O(mesh²) inside this loop.
        foreach (vi; 0 .. mesh.vertices.length) {
            if (!mesh.isVertexSelected(vi)) continue;
            if (firstIdx < 0) firstIdx = cast(int)vi;
            sum = sum + mesh.vertices[vi];
            ++count;
        }
        if (count < 2) return false;     // single vert — no-op

        Vec3 target = average_
            ? Vec3(sum.x / count, sum.y / count, sum.z / count)
            : mesh.vertices[firstIdx];

        snap = MeshSnapshot.capture(*mesh);
        mesh.collapseVerticesByMask(mesh.selectedVertices, target);
        // Weld the now-coincident verts. Tiny eps is enough since
        // collapseVerticesByMask sets exact equality.
        size_t welded = mesh.weldVerticesByMask(mesh.selectedVertices, 1e-12);
        if (welded == 0) {
            // Verts didn't actually weld (selection not contiguous?) —
            // restore and fail.
            snap.restore(*mesh);
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
        refreshDisplayActive(mesh);
    }
}
