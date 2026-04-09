module commands.select.ring;

import command;
import mesh;
import view;
import editmode;

// SelectRing: Edges and Vertices modes.
//
// Edges: for each selected edge, selects all edges in the ring —
//        edges on the opposite side of connected quad polygons.
//
// Vertices: if exactly 2 vertices are selected and a mesh edge connects them,
//           selects the vertices of the corresponding edge ring.
class SelectRing : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.ring"; }

    override bool apply() {
        if (editMode != EditMode.Edges && editMode != EditMode.Vertices) return true;

        // edgeKey(a,b) → list of face indices containing this geometric edge
        uint[][ulong] edgeFaces;
        foreach (fi, face; mesh.faces)
            for (size_t j = 0; j < face.length; j++) {
                uint a = face[j], b = face[(j + 1) % face.length];
                edgeFaces[edgeKey(a, b)] ~= cast(uint)fi;
            }

        // edgeKey(a,b) → edge index in mesh.edges
        int[ulong] keyToEdge;
        foreach (i; 0 .. mesh.edges.length)
            keyToEdge[edgeKey(mesh.edges[i][0], mesh.edges[i][1])] = cast(int)i;

        // Walk the ring from startEdge entering through startFace.
        // For each quad: finds the opposite edge and calls onOpposite(va, vb).
        // Then crosses to the next face via that opposite edge.
        void walkRing(int startEdge, int startFace,
                      scope void delegate(uint a, uint b) onOpposite) {
            bool[int] visited;
            int   curFace = startFace;
            ulong curKey  = edgeKey(mesh.edges[startEdge][0], mesh.edges[startEdge][1]);

            while (true) {
                if (curFace in visited) break;
                const face = mesh.faces[curFace];
                if (face.length != 4) break;

                int j = -1;
                for (int k = 0; k < 4; k++)
                    if (edgeKey(face[k], face[(k + 1) % 4]) == curKey) { j = k; break; }
                if (j < 0) break;

                visited[curFace] = true;

                int   oppJ   = (j + 2) % 4;
                ulong oppKey = edgeKey(face[oppJ], face[(oppJ + 1) % 4]);
                if ((oppKey in keyToEdge) is null) break;

                onOpposite(face[oppJ], face[(oppJ + 1) % 4]);

                auto fp = oppKey in edgeFaces;
                if (!fp) break;
                int nextFace = -1;
                foreach (fi; *fp)
                    if (fi != cast(uint)curFace) { nextFace = cast(int)fi; break; }
                if (nextFace < 0) break;

                curFace = nextFace;
                curKey  = oppKey;
            }
        }

        if (editMode == EditMode.Edges) {
            if (mesh.selectedEdges.length < mesh.edges.length)
                mesh.selectedEdges.length = mesh.edges.length;

            bool[] initSel = mesh.selectedEdges.dup;
            foreach (i; 0 .. initSel.length) {
                if (!initSel[i]) continue;
                ulong key = edgeKey(mesh.edges[i][0], mesh.edges[i][1]);
                auto fp = key in edgeFaces;
                if (!fp) continue;
                foreach (fi; *fp)
                    walkRing(cast(int)i, cast(int)fi, (uint a, uint b) {
                        auto ep = edgeKey(a, b) in keyToEdge;
                        if (ep) mesh.selectEdge(*ep);
                    });
            }
        } else { // Vertices
            // Treat each mesh edge whose both endpoints are selected as a seed,
            // mirroring the multi-edge logic above.
            if (mesh.selectedVertices.length < mesh.vertices.length)
                mesh.selectedVertices.length = mesh.vertices.length;

            bool[] initSel = mesh.selectedVertices.dup;
            foreach (i; 0 .. mesh.edges.length) {
                uint va = mesh.edges[i][0], vb = mesh.edges[i][1];
                if (va >= initSel.length || !initSel[va]) continue;
                if (vb >= initSel.length || !initSel[vb]) continue;
                ulong key = edgeKey(va, vb);
                auto fp = key in edgeFaces;
                if (!fp) continue;
                foreach (fi; *fp)
                    walkRing(cast(int)i, cast(int)fi, (uint a, uint b) {
                        mesh.selectVertex(cast(int)a);
                        mesh.selectVertex(cast(int)b);
                    });
            }
        }

        return true;
    }
}
