module commands.mesh.make_polygon;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import params : Param;

/// `mesh.makePolygon` — build one face from the current (ordered) vertex
/// selection. Winding follows the vertex SELECTION ORDER (the order in which
/// `selectVertex` was called, stamped in `Mesh.vertexSelectionOrder[]`), with
/// an optional `flip` parameter that reverses it.
///
/// Vertex-command convention: this command fires on lingering vertex selection
/// regardless of the current EditMode (gates only on
/// `mesh.hasAnySelectedVertices()`), matching the existing vertex-command
/// convention used by vert.join and vert.merge.
///
/// Rejections (no-op, no snapshot, no undo entry):
///   - fewer than 3 selected vertices
///   - collinear / zero-area selection (Newell normal < 1e-6)
///   - duplicate face (same unordered vertex set already exists)
class MeshMakePolygon : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    private bool flip_ = false;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.makePolygon"; }
    override string label() const { return "Make Polygon"; }

    override Param[] params() {
        return [
            Param.bool_("flip", "Flip Winding", &flip_, false),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        import std.algorithm : sort;

        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        // Vertex-command convention: fire regardless of EditMode (same as vert.join:53).
        if (!mesh.hasAnySelectedVertices()) return false;

        // --- Collect selected vertices paired with their click order ---
        // order == 0 means "selected via a bulk path that did not assign a
        // click order" (e.g. select.all, box, lasso). Those verts are appended
        // AFTER click-ordered ones, sorted by ascending vertex index, so the
        // result is always deterministic.
        struct VOrderPair {
            uint vi;
            int  order; // 1-based click counter; 0 = unordered
        }
        VOrderPair[] pairs;
        const sv = mesh.selectedVertices;      // materialised bool[] snapshot
        const so = mesh.vertexSelectionOrder;  // public int[] field
        foreach (vi; 0 .. sv.length) {
            if (!sv[vi]) continue;
            int ord = (vi < so.length) ? so[vi] : 0;
            pairs ~= VOrderPair(cast(uint)vi, ord);
        }

        // Pre-check: fewer than 3 distinct verts → no-op, no snapshot
        if (pairs.length < 3) return false;

        // Sort: click-ordered first (ascending order value), then unordered
        // (order==0) appended in ascending vertex-index order.
        sort!((a, b) {
            int oa = (a.order > 0) ? a.order : int.max;
            int ob = (b.order > 0) ? b.order : int.max;
            if (oa != ob) return oa < ob;
            return a.vi < b.vi;
        })(pairs);

        uint[] ordered;
        ordered.length = pairs.length;
        foreach (i, p; pairs) ordered[i] = p.vi;

        // Snapshot before mutation (mirrors vert_join.d / split_edge.d pattern).
        snap = MeshSnapshot.capture(*mesh);

        int fi = mesh.makePolygonFromVerts(ordered, flip_);
        if (fi < 0) {
            // Kernel rejected (collinear, degenerate, duplicate, etc.) —
            // restore snapshot so the undo stack is left untouched.
            snap.restore(*mesh);
            snap = MeshSnapshot.init;
            return false;
        }

        // Post-success: leave vertex selection intact (selecting a face while
        // EditMode == Vertices would be incoherent; no test or UI depends on it
        // here). The new face fi is already addressable via /api/model.
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
