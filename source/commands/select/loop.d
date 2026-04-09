module commands.select.loop;

import command;
import mesh;
import view;
import editmode;

class SelectLoop : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.loop"; }

    override bool apply() {
        // Build edge → faces map (used by both modes).
        uint[][ulong] edgeFaces;
        foreach (fi, face; mesh.faces) {
            for (size_t j = 0; j < face.length; j++) {
                uint a = face[j], b = face[(j + 1) % face.length];
                edgeFaces[edgeKey(a, b)] ~= cast(uint)fi;
            }
        }

        // ------------------------------------------------------------------ //
        //  Edge loop                                                           //
        // ------------------------------------------------------------------ //
        if (editMode == EditMode.Edges) {
            // Build edge key → edge index map.
            int[ulong] keyToEdge;
            foreach (i; 0 .. mesh.edges.length)
                keyToEdge[edgeKey(mesh.edges[i][0], mesh.edges[i][1])] = cast(int)i;

            // Ensure selectedEdges covers all edges.
            if (mesh.selectedEdges.length < mesh.edges.length)
                mesh.selectedEdges.length = mesh.edges.length;

            // Walk an edge loop starting from `startEdge` through face `startFace`.
            // Direction: a→b per winding. At b, find side vertex c (≠ a), cross into the
            // adjacent face via side edge (b,c), then in that face find d (≠ c at b) —
            // edge (b,d) is the next loop edge. This makes consecutive edges share a vertex.
            void walkEdge(int startEdge, int startFace) {
                const startFaceVerts = mesh.faces[startFace];
                if (startFaceVerts.length != 4) return;

                ulong startKey = edgeKey(mesh.edges[startEdge][0], mesh.edges[startEdge][1]);
                int startIdx = -1;
                for (int j = 0; j < 4; j++) {
                    if (edgeKey(startFaceVerts[j], startFaceVerts[(j + 1) % 4]) == startKey) {
                        startIdx = j; break;
                    }
                }
                if (startIdx < 0) return;

                uint a = startFaceVerts[startIdx];
                uint b = startFaceVerts[(startIdx + 1) % 4];
                int  curEdge = startEdge;
                int  curFace = startFace;

                bool[ulong] visitedKeys;
                while (true) {
                    ulong curKey = edgeKey(a, b);
                    if (curKey in visitedKeys) break;
                    visitedKeys[curKey] = true;
                    mesh.selectEdge(curEdge);

                    const face = mesh.faces[curFace];
                    if (face.length != 4) break;

                    // At b: find side vertex c (the neighbor of b in face that is ≠ a).
                    int jb = -1;
                    for (int j = 0; j < 4; j++)
                        if (face[j] == b) { jb = j; break; }
                    if (jb < 0) break;

                    uint prev = face[(jb - 1 + 4) % 4];
                    uint next = face[(jb + 1) % 4];
                    uint c;
                    if      (prev == a) c = next;
                    else if (next == a) c = prev;
                    else break;

                    // Cross into the face adjacent to side edge (b,c).
                    auto fp2 = edgeKey(b, c) in edgeFaces;
                    if (!fp2) break;
                    int nextFace = -1;
                    foreach (fi; *fp2)
                        if (fi != cast(uint)curFace) { nextFace = cast(int)fi; break; }
                    if (nextFace < 0) break;

                    // In nextFace at b: find d, the neighbor of b that is ≠ c.
                    const nface = mesh.faces[nextFace];
                    if (nface.length != 4) break;

                    int jb2 = -1;
                    for (int j = 0; j < 4; j++)
                        if (nface[j] == b) { jb2 = j; break; }
                    if (jb2 < 0) break;

                    uint prev2 = nface[(jb2 - 1 + 4) % 4];
                    uint next2 = nface[(jb2 + 1) % 4];
                    uint d;
                    if      (prev2 == c) d = next2;
                    else if (next2 == c) d = prev2;
                    else break;

                    // Next loop edge is (b,d) in nextFace.
                    auto ep = edgeKey(b, d) in keyToEdge;
                    if (!ep) break;

                    a = b;
                    b = d;
                    curEdge = *ep;
                    curFace = nextFace;
                }
            }

            // Snapshot initial selection; only walk loops from originally selected edges,
            // not from edges added during the walk (each edge can belong to different loops).
            bool[] initSel = mesh.selectedEdges.dup;

            // For each originally selected edge walk the loop in both face directions.
            foreach (i; 0 .. initSel.length) {
                if (!initSel[i]) continue;
                ulong key = edgeKey(mesh.edges[i][0], mesh.edges[i][1]);
                auto fp = key in edgeFaces;
                if (!fp) continue;
                foreach (fi; *fp)
                    walkEdge(cast(int)i, cast(int)fi);
            }

            return true;
        }

        // ------------------------------------------------------------------ //
        //  Vertex loop                                                         //
        // ------------------------------------------------------------------ //
        if (editMode == EditMode.Vertices) {
            if (mesh.selectedVertices.length < mesh.vertices.length)
                mesh.selectedVertices.length = mesh.vertices.length;

            // Same traversal as edge loop, but selects the two vertices of each
            // loop edge instead of the edge itself.
            void walkVertexLoop(int startEdge, int startFace) {
                const startFaceVerts = mesh.faces[startFace];
                if (startFaceVerts.length != 4) return;

                ulong startKey = edgeKey(mesh.edges[startEdge][0], mesh.edges[startEdge][1]);
                int startIdx = -1;
                for (int j = 0; j < 4; j++) {
                    if (edgeKey(startFaceVerts[j], startFaceVerts[(j + 1) % 4]) == startKey) {
                        startIdx = j; break;
                    }
                }
                if (startIdx < 0) return;

                uint a = startFaceVerts[startIdx];
                uint b = startFaceVerts[(startIdx + 1) % 4];
                int  curFace = startFace;

                bool[ulong] visitedKeys;
                while (true) {
                    ulong curKey = edgeKey(a, b);
                    if (curKey in visitedKeys) break;
                    visitedKeys[curKey] = true;
                    mesh.selectVertex(cast(int)a);
                    mesh.selectVertex(cast(int)b);

                    const face = mesh.faces[curFace];
                    if (face.length != 4) break;

                    int jb = -1;
                    for (int j = 0; j < 4; j++)
                        if (face[j] == b) { jb = j; break; }
                    if (jb < 0) break;

                    uint prev = face[(jb - 1 + 4) % 4];
                    uint next = face[(jb + 1) % 4];
                    uint c;
                    if      (prev == a) c = next;
                    else if (next == a) c = prev;
                    else break;

                    auto fp2 = edgeKey(b, c) in edgeFaces;
                    if (!fp2) break;
                    int nextFace = -1;
                    foreach (fi; *fp2)
                        if (fi != cast(uint)curFace) { nextFace = cast(int)fi; break; }
                    if (nextFace < 0) break;

                    const nface = mesh.faces[nextFace];
                    if (nface.length != 4) break;

                    int jb2 = -1;
                    for (int j = 0; j < 4; j++)
                        if (nface[j] == b) { jb2 = j; break; }
                    if (jb2 < 0) break;

                    uint prev2 = nface[(jb2 - 1 + 4) % 4];
                    uint next2 = nface[(jb2 + 1) % 4];
                    uint d;
                    if      (prev2 == c) d = next2;
                    else if (next2 == c) d = prev2;
                    else break;

                    a = b;
                    b = d;
                    curFace = nextFace;
                }
            }

            // Starting edges: those with both endpoints initially selected.
            // Snapshot to avoid cascade from newly selected vertices.
            bool[] initVSel = mesh.selectedVertices.dup;

            foreach (i; 0 .. mesh.edges.length) {
                uint va = mesh.edges[i][0], vb = mesh.edges[i][1];
                if (va >= initVSel.length || vb >= initVSel.length) continue;
                if (!initVSel[va] || !initVSel[vb]) continue;
                auto fp = edgeKey(va, vb) in edgeFaces;
                if (!fp) continue;
                foreach (fi; *fp)
                    walkVertexLoop(cast(int)i, cast(int)fi);
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
            for (size_t j = 0; j < face.length; j++) {
                uint va = face[j], vb = face[(j + 1) % face.length];
                ulong key = edgeKey(va, vb);
                if (auto p = key in edgeFaces) {
                    foreach (adjFi; *p) {
                        if (adjFi > fi &&
                            adjFi < mesh.selectedFaces.length &&
                            mesh.selectedFaces[adjFi])
                            pairs ~= Pair(cast(int)fi, cast(int)adjFi, key);
                    }
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

        void walkFace(int startFace, ulong entryKey) {
            bool[int] visited;
            int   cur   = startFace;
            ulong entry = entryKey;
            while (true) {
                if (cur in visited) break;
                visited[cur] = true;
                mesh.selectFace(cur);

                const face = mesh.faces[cur];
                if (face.length != 4) break;

                int entryIdx = -1;
                for (int j = 0; j < 4; j++) {
                    if (edgeKey(face[j], face[(j + 1) % 4]) == entry) {
                        entryIdx = j; break;
                    }
                }
                if (entryIdx < 0) break;

                int oppIdx = (entryIdx + 2) % 4;
                ulong oppKey = edgeKey(face[oppIdx], face[(oppIdx + 1) % 4]);

                auto p = oppKey in edgeFaces;
                if (!p) break;

                int nextFace = -1;
                foreach (adjFi; *p)
                    if (adjFi != cast(uint)cur) { nextFace = cast(int)adjFi; break; }
                if (nextFace < 0) break;

                cur   = nextFace;
                entry = oppKey;
            }
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
                walkFace(pair.a, pair.key);
                walkFace(pair.b, pair.key);
                covered[pair.a] = true;
                covered[pair.b] = true;
            }
        }

        return true;
    }
}
