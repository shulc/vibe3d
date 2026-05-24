module commands.select.loop;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

class SelectLoop : Command {
    private SelectionSnapshot snap;
    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.loop"; }

    override bool apply() {
        snap = SelectionSnapshot.capture(*mesh);
        // ------------------------------------------------------------------ //
        //  Edge loop                                                           //
        // ------------------------------------------------------------------ //
        if (editMode == EditMode.Edges) {
            if (mesh.selectedEdges.length < mesh.edges.length)
                mesh.selectedEdges.length = mesh.edges.length;

            bool[] initSel = mesh.selectedEdges.dup;
            foreach (i; 0 .. initSel.length) {
                if (!initSel[i]) continue;
                foreach (fi; mesh.facesAroundEdge(cast(uint)i))
                    foreach (ei; mesh.walkEdgeLoop(cast(int)i, cast(int)fi))
                        mesh.selectEdge(ei);
            }
            return true;
        }

        // ------------------------------------------------------------------ //
        //  Vertex loop                                                         //
        // ------------------------------------------------------------------ //
        if (editMode == EditMode.Vertices) {
            if (mesh.selectedVertices.length < mesh.vertices.length)
                mesh.selectedVertices.length = mesh.vertices.length;

            bool[] initVSel = mesh.selectedVertices.dup;
            foreach (i; 0 .. mesh.edges.length) {
                uint va = mesh.edges[i][0], vb = mesh.edges[i][1];
                if (va >= initVSel.length || !initVSel[va]) continue;
                if (vb >= initVSel.length || !initVSel[vb]) continue;
                foreach (vi; mesh.walkVertexLoop(va, vb)) mesh.selectVertex(cast(int)vi);
                foreach (vi; mesh.walkVertexLoop(vb, va)) mesh.selectVertex(cast(int)vi);
            }
            return true;
        }

        // ------------------------------------------------------------------ //
        //  Polygon loop                                                        //
        // ------------------------------------------------------------------ //

        // Squared cosine of angle between two edges (undirected).
        float edgeCos2(ulong k1, ulong k2) {
            uint a1 = cast(uint)(k1 >> 32), b1 = cast(uint)(k1 & 0xFFFF_FFFFu);
            uint a2 = cast(uint)(k2 >> 32), b2 = cast(uint)(k2 & 0xFFFF_FFFFu);
            float dx1 = mesh.vertices[b1].x - mesh.vertices[a1].x;
            float dy1 = mesh.vertices[b1].y - mesh.vertices[a1].y;
            float dz1 = mesh.vertices[b1].z - mesh.vertices[a1].z;
            float dx2 = mesh.vertices[b2].x - mesh.vertices[a2].x;
            float dy2 = mesh.vertices[b2].y - mesh.vertices[a2].y;
            float dz2 = mesh.vertices[b2].z - mesh.vertices[a2].z;
            float dot  = dx1*dx2 + dy1*dy2 + dz1*dz2;
            float len2 = (dx1*dx1 + dy1*dy1 + dz1*dz1) * (dx2*dx2 + dy2*dy2 + dz2*dz2);
            return len2 < 1e-12f ? 0f : dot*dot / len2;
        }

        int selOrder(int fi) {
            if (fi < cast(int)mesh.faceSelectionOrder.length && mesh.faceSelectionOrder[fi] > 0)
                return mesh.faceSelectionOrder[fi];
            return int.max;
        }

        struct Pair { int a, b; ulong key; }
        Pair[] pairs;
        foreach (fi, face; mesh.faces) {
            if (fi >= mesh.selectedFaces.length || !mesh.selectedFaces[fi]) continue;
            foreach (e; mesh.faceEdges(cast(uint)fi)) {
                uint ei = mesh.edgeIndex(e.a, e.b);
                if (ei == ~0u) continue;
                ulong key = edgeKey(e.a, e.b);
                foreach (adjFi; mesh.facesAroundEdge(ei)) {
                    if (adjFi > fi &&
                        adjFi < mesh.selectedFaces.length &&
                        mesh.selectedFaces[adjFi])
                        pairs ~= Pair(cast(int)fi, cast(int)adjFi, key);
                }
            }
        }

        if (pairs.length == 0) return true;

        struct Group { Pair[] pairs; ulong refKey; int score; }
        Group[] groups;
        foreach (ref pair; pairs) {
            int ps = selOrder(pair.a) > selOrder(pair.b) ? selOrder(pair.a) : selOrder(pair.b);
            bool added = false;
            foreach (ref g; groups) {
                if (edgeCos2(g.refKey, pair.key) >= 0.8f) {
                    g.pairs ~= pair;
                    if (ps < g.score) g.score = ps;
                    added = true;
                    break;
                }
            }
            if (!added)
                groups ~= Group([pair], pair.key, ps);
        }

        for (size_t i = 0; i < groups.length; i++) {
            size_t best = i;
            for (size_t j = i + 1; j < groups.length; j++)
                if (groups[j].score < groups[best].score) best = j;
            if (best != i) { auto tmp = groups[i]; groups[i] = groups[best]; groups[best] = tmp; }
        }

        bool[] origSel = mesh.selectedFaces.dup;
        bool[] covered = new bool[](mesh.faces.length);

        foreach (ref g; groups) {
            bool hasUncovered = false;
            foreach (ref pair; g.pairs) {
                if ((pair.a < cast(int)origSel.length && origSel[pair.a] && !covered[pair.a]) ||
                    (pair.b < cast(int)origSel.length && origSel[pair.b] && !covered[pair.b])) {
                    hasUncovered = true;
                    break;
                }
            }
            if (!hasUncovered) continue;

            foreach (ref pair; g.pairs) {
                foreach (fi; mesh.walkFaceLoop(pair.a, pair.key)) mesh.selectFace(fi);
                foreach (fi; mesh.walkFaceLoop(pair.b, pair.key)) mesh.selectFace(fi);
                covered[pair.a] = true;
                covered[pair.b] = true;
            }
        }

        return true;
    }
}
