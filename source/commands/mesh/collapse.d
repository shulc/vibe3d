module commands.mesh.collapse;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math : Vec3;
import change_bus : MeshEditScope;
import snapshot : MeshSnapshot;

/// Tier 1.x: `mesh.collapse`. Collapses the selected elements to a point,
/// merging topology and removing faces that degenerate below 3 unique
/// corners as a result.
///
/// - Vertices: all selected verts → one combined centroid (no island/
///   connectivity notion — matches `vert.join average:true` semantics;
///   deliberately a distinct command).
/// - Edges: each connected island of selected edges → its midpoint/centroid.
///   A single selected edge collapses to the midpoint of its two endpoints.
/// - Polygons: each connected island of selected faces → the centroid of
///   the island's corner vertices.
///
/// In the Edge and Polygon scopes two disjoint selections collapse to their
/// own independent centroids (per-island behavior). This is the documented
/// vibe3d default; the difference vs a single-combined-centroid is visible
/// only when multiple disconnected islands are selected.
///
/// Undo: `MeshSnapshot`-based (same as `vert.join`).
class MeshCollapse : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "mesh.collapse"; }

    override string label() const {
        final switch (editMode) {
            case EditMode.Vertices: return "Collapse Vertices";
            case EditMode.Edges:    return "Collapse Edges";
            case EditMode.Polygons: return "Collapse Polygons";
        }
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        final switch (editMode) {
            case EditMode.Vertices: return evalVertices();
            case EditMode.Edges:    return evalEdges();
            case EditMode.Polygons: return evalPolygons();
        }
    }

    private bool evalVertices() {
        if (!mesh.hasAnySelectedVertices()) return false;

        // Capture the selection mask once before any mutation.
        auto sel = mesh.selectedVertices;

        Vec3 sum   = Vec3(0, 0, 0);
        int  count = 0;
        foreach (vi; 0 .. mesh.vertices.length) {
            if (vi >= sel.length || !sel[vi]) continue;
            sum = sum + mesh.vertices[vi];
            ++count;
        }
        if (count < 2) return false;   // single vert — no-op

        Vec3 centroid = Vec3(sum.x / count, sum.y / count, sum.z / count);
        snap = MeshSnapshot.capture(*mesh);
        // TASK 1903 STAGE L10-P0 (axis 0) — an UNRECORDED `MeshEditBatch` at
        // the command boundary; see this class's doc comment. The batch closes
        // BEFORE the rollback: `snap.restore` is a wholesale `*mesh = …` and
        // the refusal path must leave no frame open (§S-6).
        size_t welded;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh,
                          MeshEditScope.Geometry | MeshEditScope.Marks);
            ed.collapseVerticesByMask(sel, centroid);
            welded = ed.weldVerticesByMask(sel, 1e-12);
            ed.close();
        }
        if (welded == 0) {
            snap.restore(*mesh);
            snap = MeshSnapshot.init;
            return false;
        }
        return true;
    }

    private bool evalEdges() {
        if (!mesh.hasAnySelectedEdges()) return false;

        // Capture mask before snapshot so the kernel receives the
        // pre-op selection (weldVerticesByMask clears edge selection).
        auto sel = mesh.selectedEdges;
        snap = MeshSnapshot.capture(*mesh);
        // TASK 1903 STAGE L10-P0 (axis 0) — an UNRECORDED `MeshEditBatch` at
        // the command boundary; see this class's doc comment. The batch closes
        // BEFORE the rollback: `snap.restore` is a wholesale `*mesh = …` and
        // the refusal path must leave no frame open (§S-6).
        size_t welded;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh,
                          MeshEditScope.Geometry | MeshEditScope.Marks);
            welded = ed.collapseEdgesByMask(sel);
            ed.close();
        }
        if (welded == 0) {
            snap.restore(*mesh);
            snap = MeshSnapshot.init;
            return false;
        }
        return true;
    }

    private bool evalPolygons() {
        if (!mesh.hasAnySelectedFaces()) return false;

        auto sel = mesh.selectedFaces;
        snap = MeshSnapshot.capture(*mesh);
        // TASK 1903 STAGE L10-P0 (axis 0) — an UNRECORDED `MeshEditBatch` at
        // the command boundary; see this class's doc comment. The batch closes
        // BEFORE the rollback: `snap.restore` is a wholesale `*mesh = …` and
        // the refusal path must leave no frame open (§S-6).
        size_t welded;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh,
                          MeshEditScope.Geometry | MeshEditScope.Marks);
            welded = ed.collapseFacesByMask(sel);
            ed.close();
        }
        if (welded == 0) {
            snap.restore(*mesh);
            snap = MeshSnapshot.init;
            return false;
        }
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
