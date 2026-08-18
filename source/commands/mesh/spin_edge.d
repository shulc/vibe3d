module commands.mesh.spin_edge;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import snapshot : MeshSnapshot;
import selection_product : repointToEdgeKeys;

/// Spin (rotate) the shared edge of two adjacent faces to the next diagonal of
/// the combined boundary polygon.
///
/// Edge scope   — spin every selected qualifying edge.
/// Polygon scope — spin the shared interior edges between pairs of selected
///                 faces that both qualify.
/// Vertex scope  — explicit no-op guard (returns false before snapshot).
///
/// Supported face pairs (task 1200, ledger rows 9 + 16): ANY two faces with at
/// least three sides each — a triangle beside a quad, two pentagons, anything.
/// Both faces keep their own valence. This used to demand equal valence and
/// that it be 3 or 4; the reference's gate never asked for either.
/// Direction: new diagonal = (c, e) = (successor-of-b-in-f1,
///   successor-of-a-in-f2); the vibe3d default, and it reproduces the reference
///   on every frozen cell (see doc/spin_quads_plan.md for the quad question the
///   Phase-0 capture never settled).
/// There is no FOLD-OVER guard (ledger row 17): a spin whose new diagonal
/// already exists is performed anyway and leaves a NON-MANIFOLD mesh — three
/// faces on that edge, and an edge count that FALLS. Deliberate; see
/// tests/fixtures/spin_gate_narrower.json.
///
/// Undo via full MeshSnapshot (same pattern as MeshSplitEdge).
class MeshSpinEdge : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
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
            ulong[] productKeys;
            foreach (k; selKeys) {
                uint ei = mesh.edgeIndexByKey(k);
                if (ei == ~0u) continue;   // earlier spin consumed this edge
                uint[2] diag;
                if (mesh.spinEdge(ei, diag)) {
                    ++affected;
                    productKeys ~= edgeKey(diag[0], diag[1]);
                }
            }
            // Post-op (task 1180): the old edge no longer exists — re-point the
            // selection at the PRODUCT, the new diagonal. Clearing instead (what
            // this line used to do) is what made two spins of one edge in a row
            // a no-op on the second: `cmd_selection_product/spin_twice`.
            if (affected > 0) repointToEdgeKeys(mesh, productKeys);

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
                    // Bounded write: see the same collector in Mesh.spinEdge —
                    // `EdgeFaceRange` caps at two today, and a `uint[2]` filled
                    // by a bare `[n++]` overflows the day it does not.
                    uint[2] ifaces; uint nif = 0;
                    foreach (f; mesh.facesAroundEdge(ei)) {
                        if (nif >= 2) { nif = 3; break; }
                        ifaces[nif++] = f;
                    }
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

        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
