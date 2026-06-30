module commands.mesh.spin_edge;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import viewcache;
import snapshot : MeshSnapshot;

/// Spin (rotate) the shared edge of two adjacent triangle or quad faces to the
/// other diagonal of the combined boundary polygon.
///
/// Edge scope   — spin every selected qualifying edge.
/// Polygon scope — spin the shared interior edges between pairs of selected
///                 faces that both qualify.
/// Vertex scope  — explicit no-op guard (returns false before snapshot).
///
/// Supported face pairs: tri–tri (n=3) and quad–quad (n=4).
/// Quad direction: new diagonal = (c, e) = (successor-of-b-in-f1,
///   successor-of-a-in-f2); this is the vibe3d default (vibe3d-divergence;
///   Phase-0 reference capture deferred — see doc/spin_quads_plan.md).
/// Mixed tri↔quad pairs and n-gon (n≥5) pairs are silently skipped.
///
/// Undo via full MeshSnapshot (same pattern as MeshSplitEdge).
class MeshSpinEdge : Command, Operator {
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

    override string name() const { return "mesh.spinEdge"; }

    override string label() const {
        final switch (editMode) {
            case EditMode.Vertices: return "Spin Edges";   // guard below blocks this path
            case EditMode.Edges:    return "Spin Edges";
            case EditMode.Polygons: return "Spin Polygons";
        }
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        // Vertex mode has no meaningful target — guard like split_edge.d:40.
        if (editMode == EditMode.Vertices) return false;

        snap = MeshSnapshot.capture(*mesh);
        size_t affected = 0;

        if (editMode == EditMode.Edges) {
            // Collect endpoint keys up front — edge indices shift after each spin.
            ulong[] selKeys;
            foreach (size_t i, bool sel; mesh.selectedEdges) {
                if (sel) selKeys ~= edgeKey(mesh.edges[i][0], mesh.edges[i][1]);
            }
            if (selKeys.length == 0) {
                snap = MeshSnapshot.init;
                return false;
            }
            foreach (k; selKeys) {
                uint ei = mesh.edgeIndexByKey(k);
                if (ei == ~0u) continue;   // earlier spin consumed this edge
                if (mesh.spinEdge(ei)) ++affected;
            }
            // Post-op: the old edge no longer exists; clear stale edge selection.
            if (affected > 0) mesh.clearEdgeSelection();

        } else {  // EditMode.Polygons
            if (!mesh.hasAnySelectedFaces()) {
                snap = MeshSnapshot.init;
                return false;
            }

            // Gather interior edges: both incident faces must be selected.
            bool[ulong] seen;
            ulong[] intKeys;
            foreach (uint fi; 0 .. cast(uint)mesh.faces.length) {
                if (!mesh.isFaceSelected(fi)) continue;
                foreach (k; 0 .. mesh.faces[fi].length) {
                    uint a = mesh.faces[fi][k];
                    uint b = mesh.faces[fi][(k + 1) % mesh.faces[fi].length];
                    ulong ek = edgeKey(a, b);
                    if (ek in seen) continue;
                    seen[ek] = true;
                    uint ei = mesh.edgeIndexByKey(ek);
                    if (ei == ~0u) continue;
                    // Both incident faces must be selected.
                    uint[2] ifaces; uint nif = 0;
                    foreach (f; mesh.facesAroundEdge(ei)) ifaces[nif++] = f;
                    if (nif != 2) continue;
                    if (!mesh.isFaceSelected(ifaces[0]) ||
                        !mesh.isFaceSelected(ifaces[1])) continue;
                    intKeys ~= ek;
                }
            }

            import std.algorithm : sort;
            sort(intKeys);   // deterministic processing order

            foreach (k; intKeys) {
                uint ei = mesh.edgeIndexByKey(k);
                if (ei == ~0u) continue;   // earlier spin removed this edge
                if (mesh.spinEdge(ei)) ++affected;
            }
            // Polygon scope: face indices are stable (no faces added/removed),
            // keep the existing face selection so repeated Spin Polygons works.
        }

        if (affected == 0) {
            snap = MeshSnapshot.init;
            return false;
        }

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
