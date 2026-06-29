module commands.mesh.collapse;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import math : Vec3;
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
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
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
        mesh.collapseVerticesByMask(sel, centroid);
        size_t welded = mesh.weldVerticesByMask(sel, 1e-12);
        if (welded == 0) {
            snap.restore(*mesh);
            snap = MeshSnapshot.init;
            return false;
        }
        refreshCaches();
        return true;
    }

    private bool evalEdges() {
        if (!mesh.hasAnySelectedEdges()) return false;

        // Capture mask before snapshot so the kernel receives the
        // pre-op selection (weldVerticesByMask clears edge selection).
        auto sel = mesh.selectedEdges;
        snap = MeshSnapshot.capture(*mesh);
        size_t welded = mesh.collapseEdgesByMask(sel);
        if (welded == 0) {
            snap.restore(*mesh);
            snap = MeshSnapshot.init;
            return false;
        }
        refreshCaches();
        return true;
    }

    private bool evalPolygons() {
        if (!mesh.hasAnySelectedFaces()) return false;

        auto sel = mesh.selectedFaces;
        snap = MeshSnapshot.capture(*mesh);
        size_t welded = mesh.collapseFacesByMask(sel);
        if (welded == 0) {
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
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
