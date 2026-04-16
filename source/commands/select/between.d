module commands.select.between;

import command;
import mesh;
import view;
import editmode;

// SelectBetween: Polygons and Vertices modes.
//
// Polygons: takes the last 2 manually-selected faces as opposite corners of a
// rectangle on the face grid and selects all faces inside. Grid coordinates
// are assigned via BFS with orientation propagation (orient = edge index to
// EXIT for +col):
//   exit via orient       → +col,  orient_next = (j_next+2)%4
//   exit via (orient+2)%4 → -col,  orient_next =  j_next
//   exit via (orient+1)%4 → +row,  orient_next = (j_next+1)%4
//   exit via (orient+3)%4 → -row,  orient_next = (j_next+3)%4
//
// Vertices: works only when the last 2 selected vertices share a vertex loop.
// Selects all vertices on the shorter arc between them.
class SelectBetween : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.between"; }

    override bool apply() {
        if      (editMode == EditMode.Polygons) return applyPolygons();
        else if (editMode == EditMode.Edges)    return applyEdges();
        else if (editMode == EditMode.Vertices) return applyVertices();
        return true;
    }

private:

    uint[][ulong] buildEdgeFaces() {
        uint[][ulong] ef;
        foreach (fi, face; mesh.faces)
            for (size_t j = 0; j < face.length; j++) {
                uint a = face[j], b = face[(j + 1) % face.length];
                ef[edgeKey(a, b)] ~= cast(uint)fi;
            }
        return ef;
    }

    // Walk vertex loop in direction startVert→nextVert.
    // Returns ordered vertex indices starting with startVert.
    uint[] walkVertexLoop(uint startVert, uint nextVert, ref uint[][ulong] ef) {
        auto fp = edgeKey(startVert, nextVert) in ef;
        if (!fp) return [];
        int startFace = -1;
        foreach (fi; *fp) {
            const fv = mesh.faces[fi];
            if (fv.length != 4) continue;
            for (int j = 0; j < 4; j++)
                if (fv[j] == startVert && fv[(j+1)%4] == nextVert) { startFace = cast(int)fi; break; }
            if (startFace >= 0) break;
        }
        if (startFace < 0) return [];

        uint a = startVert, b = nextVert;
        int curFace = startFace;
        uint[] res; bool[ulong] vis;
        while (true) {
            ulong ck = edgeKey(a, b);
            if (ck in vis) break;
            vis[ck] = true;
            res ~= a;
            const face = mesh.faces[curFace];
            if (face.length != 4) break;
            int jb = -1;
            for (int j = 0; j < 4; j++) if (face[j] == b) { jb = j; break; }
            if (jb < 0) break;
            uint prev = face[(jb-1+4)%4], next = face[(jb+1)%4], c;
            if      (prev == a) c = next;
            else if (next == a) c = prev;
            else break;
            auto fp2 = edgeKey(b, c) in ef; if (!fp2) break;
            int nf = -1;
            foreach (fi; *fp2) if (fi != cast(uint)curFace) { nf = cast(int)fi; break; }
            if (nf < 0) break;
            const nface = mesh.faces[nf];
            if (nface.length != 4) break;
            int jb2 = -1;
            for (int j = 0; j < 4; j++) if (nface[j] == b) { jb2 = j; break; }
            if (jb2 < 0) break;
            uint p2 = nface[(jb2-1+4)%4], n2 = nface[(jb2+1)%4], d;
            if      (p2 == c) d = n2;
            else if (n2 == c) d = p2;
            else break;
            a = b; b = d; curFace = nf;
        }
        return res;
    }

    bool applyPolygons() {
        if (mesh.selectedFaces.length < mesh.faces.length)
            mesh.selectedFaces.length = mesh.faces.length;
        if (mesh.faceSelectionOrder.length < mesh.faces.length)
            mesh.faceSelectionOrder.length = mesh.faces.length;

        int lastFace = -1, secondLastFace = -1, lastOrd = 0, secondLastOrd = 0;
        foreach (i; 0 .. mesh.selectedFaces.length) {
            if (i >= mesh.faceSelectionOrder.length) break;
            int ord = mesh.faceSelectionOrder[i];
            if (ord <= 0) continue;
            if (ord > lastOrd) {
                secondLastFace = lastFace; secondLastOrd = lastOrd;
                lastFace       = cast(int)i; lastOrd = ord;
            } else if (ord > secondLastOrd) {
                secondLastFace = cast(int)i; secondLastOrd = ord;
            }
        }
        if (lastFace < 0 || secondLastFace < 0) return true;

        auto ef = buildEdgeFaces();

        int[]  fRow    = new int[](mesh.faces.length);
        int[]  fCol    = new int[](mesh.faces.length);
        int[]  fOrient = new int[](mesh.faces.length);
        bool[] fAsgn   = new bool[](mesh.faces.length);

        fAsgn[secondLastFace] = true;

        int[] queue = [secondLastFace];
        int   head  = 0;
        while (head < queue.length) {
            int cur = queue[head++];
            const face = mesh.faces[cur];
            if (face.length != 4) continue;
            int oc = fOrient[cur];

            for (int j = 0; j < 4; j++) {
                ulong ek = edgeKey(face[j], face[(j + 1) % 4]);
                auto p = ek in ef; if (!p) continue;
                foreach (fi; *p) {
                    if (fi == cast(uint)cur || fAsgn[fi]) continue;
                    if (mesh.faces[fi].length != 4) continue;
                    int jn = -1;
                    const nface = mesh.faces[fi];
                    for (int k = 0; k < 4; k++)
                        if (edgeKey(nface[k], nface[(k + 1) % 4]) == ek) { jn = k; break; }
                    if (jn < 0) continue;
                    int dr, dc, on;
                    if      (j == oc)       { dc=+1; dr= 0; on=(jn+2)%4; }
                    else if (j==(oc+2)%4)   { dc=-1; dr= 0; on= jn;      }
                    else if (j==(oc+1)%4)   { dc= 0; dr=+1; on=(jn+1)%4; }
                    else                    { dc= 0; dr=-1; on=(jn+3)%4; }
                    fRow[fi]    = fRow[cur]  + dr;
                    fCol[fi]    = fCol[cur]  + dc;
                    fOrient[fi] = on;
                    fAsgn[fi]   = true;
                    queue ~= cast(int)fi;
                }
            }
        }

        if (!fAsgn[lastFace]) return true;

        int rb = fRow[lastFace], cb = fCol[lastFace];
        int rMin = rb < 0 ? rb : 0, rMax = rb > 0 ? rb : 0;
        int cMin = cb < 0 ? cb : 0, cMax = cb > 0 ? cb : 0;

        foreach (i; 0 .. mesh.faces.length) {
            if (!fAsgn[i]) continue;
            if (fRow[i] >= rMin && fRow[i] <= rMax &&
                fCol[i] >= cMin && fCol[i] <= cMax)
                mesh.selectFace(cast(int)i);
        }
        return true;
    }

    // Walk edge loop starting from startEdge on startFace.
    // Returns ordered edge indices.
    int[] walkEdgeLoop(int startEdge, int startFace,
                       ref uint[][ulong] ef, ref int[ulong] ke) {
        const sfv = mesh.faces[startFace];
        if (sfv.length != 4) return [];
        ulong startKey = mesh.edgeKeyOf(cast(uint)startEdge);
        int si = -1;
        for (int j = 0; j < 4; j++)
            if (edgeKey(sfv[j], sfv[(j+1)%4]) == startKey) { si = j; break; }
        if (si < 0) return [];
        uint a = sfv[si], b = sfv[(si+1)%4];
        int curEdge = startEdge, curFace = startFace;
        int[] res; bool[ulong] vis;
        while (true) {
            ulong ck = edgeKey(a, b);
            if (ck in vis) break;
            vis[ck] = true;
            res ~= curEdge;
            const face = mesh.faces[curFace];
            if (face.length != 4) break;
            int jb = -1;
            for (int j = 0; j < 4; j++) if (face[j] == b) { jb = j; break; }
            if (jb < 0) break;
            uint prev = face[(jb-1+4)%4], next = face[(jb+1)%4], c;
            if      (prev == a) c = next;
            else if (next == a) c = prev;
            else break;
            auto fp2 = edgeKey(b, c) in ef; if (!fp2) break;
            int nf = -1;
            foreach (fi; *fp2) if (fi != cast(uint)curFace) { nf = cast(int)fi; break; }
            if (nf < 0) break;
            const nface = mesh.faces[nf];
            if (nface.length != 4) break;
            int jb2 = -1;
            for (int j = 0; j < 4; j++) if (nface[j] == b) { jb2 = j; break; }
            if (jb2 < 0) break;
            uint p2 = nface[(jb2-1+4)%4], n2 = nface[(jb2+1)%4], d;
            if      (p2 == c) d = n2;
            else if (n2 == c) d = p2;
            else break;
            auto ep = edgeKey(b, d) in ke; if (!ep) break;
            a = b; b = d; curEdge = *ep; curFace = nf;
        }
        return res;
    }

    // Walk the face-loop traversal edges starting from startEdge as the entry
    // edge of startFace.  Records the entry edge of every face visited, plus
    // the final exit edge when the loop ends at a boundary (open chain).
    // For a closed loop of L faces this yields L edges; for an open chain of
    // L faces it yields L+1 edges (one on each side of every face).
    int[] walkFaceLoopEdges(int startEdge, int startFace,
                            ref uint[][ulong] ef, ref int[ulong] ke) {
        int[] res;
        bool[int] vis;
        int cur     = startFace;
        int curEdge = startEdge;
        while (true) {
            if (cur in vis) break;           // closed — entry of first face already recorded
            vis[cur] = true;
            res ~= curEdge;                  // entry edge of cur

            const face = mesh.faces[cur];
            if (face.length != 4) break;

            // Find curEdge in face winding.
            ulong ek = mesh.edgeKeyOf(cast(uint)curEdge);
            int ei = -1;
            for (int j = 0; j < 4; j++)
                if (edgeKey(face[j], face[(j+1)%4]) == ek) { ei = j; break; }
            if (ei < 0) break;

            // Exit via opposite edge.
            int   oppIdx  = (ei + 2) % 4;
            ulong oppKey  = edgeKey(face[oppIdx], face[(oppIdx+1)%4]);
            auto  ep      = oppKey in ke; if (!ep) break;
            int   exitEdge = *ep;

            // Cross to next face.
            auto p = oppKey in ef; if (!p) { res ~= exitEdge; break; }
            int nf = -1;
            foreach (fi; *p) if (fi != cast(uint)cur) { nf = cast(int)fi; break; }
            if (nf < 0) { res ~= exitEdge; break; }

            cur     = nf;
            curEdge = exitEdge;
        }
        return res;
    }

    bool applyEdges() {
        if (mesh.selectedEdges.length < mesh.edges.length)
            mesh.selectedEdges.length = mesh.edges.length;
        if (mesh.edgeSelectionOrder.length < mesh.edges.length)
            mesh.edgeSelectionOrder.length = mesh.edges.length;

        int lastEdge = -1, secondLastEdge = -1, lastOrd = 0, secondLastOrd = 0;
        foreach (i; 0 .. mesh.selectedEdges.length) {
            if (i >= mesh.edgeSelectionOrder.length) break;
            int ord = mesh.edgeSelectionOrder[i];
            if (ord <= 0) continue;
            if (ord > lastOrd) {
                secondLastEdge = lastEdge; secondLastOrd = lastOrd;
                lastEdge       = cast(int)i; lastOrd = ord;
            } else if (ord > secondLastOrd) {
                secondLastEdge = cast(int)i; secondLastOrd = ord;
            }
        }
        if (lastEdge < 0 || secondLastEdge < 0) return true;

        auto ef = buildEdgeFaces();

        int[ulong] keyToEdge;
        foreach (i; 0 .. mesh.edges.length)
            keyToEdge[mesh.edgeKeyOf(cast(uint)i)] = cast(int)i;

        // Try both adjacent faces of secondLastEdge (each gives one loop direction).
        ulong slKey = mesh.edgeKeyOf(cast(uint)secondLastEdge);
        auto fp = slKey in ef;
        if (!fp) return true;

        int   bestPos  = int.max;
        int[] bestLoop;

        foreach (fi; *fp) {
            // Approach 1: edge loop (both edges on the same edge loop).
            int[] loop = walkEdgeLoop(secondLastEdge, cast(int)fi, ef, keyToEdge);
            if (loop.length >= 2) {
                int posLast = -1;
                foreach (k, ei; loop) if (ei == lastEdge) { posLast = cast(int)k; break; }
                if (posLast > 0 && posLast < bestPos) { bestPos = posLast; bestLoop = loop; }
            }

            // Approach 2: face-loop traversal (edges on opposite sides of faces
            // in the same face loop, e.g. entry edge of F0 and exit edge of F2).
            int[] floop = walkFaceLoopEdges(secondLastEdge, cast(int)fi, ef, keyToEdge);
            if (floop.length >= 2) {
                int posLast = -1;
                foreach (k, ei; floop) if (ei == lastEdge) { posLast = cast(int)k; break; }
                if (posLast > 0 && posLast < bestPos) { bestPos = posLast; bestLoop = floop; }
            }
        }

        if (bestLoop.length == 0) return true;

        foreach (k; 0 .. bestPos + 1)
            mesh.selectEdge(bestLoop[k]);

        return true;
    }

    bool applyVertices() {
        if (mesh.selectedVertices.length < mesh.vertices.length)
            mesh.selectedVertices.length = mesh.vertices.length;
        if (mesh.vertexSelectionOrder.length < mesh.vertices.length)
            mesh.vertexSelectionOrder.length = mesh.vertices.length;

        int lastVert = -1, secondLastVert = -1, lastOrd = 0, secondLastOrd = 0;
        foreach (i; 0 .. mesh.selectedVertices.length) {
            if (i >= mesh.vertexSelectionOrder.length) break;
            int ord = mesh.vertexSelectionOrder[i];
            if (ord <= 0) continue;
            if (ord > lastOrd) {
                secondLastVert = lastVert; secondLastOrd = lastOrd;
                lastVert       = cast(int)i; lastOrd = ord;
            } else if (ord > secondLastOrd) {
                secondLastVert = cast(int)i; secondLastOrd = ord;
            }
        }
        if (lastVert < 0 || secondLastVert < 0) return true;

        auto ef = buildEdgeFaces();

        // Try every neighbour of secondLastVert as a loop direction.
        // Pick the direction where lastVert appears at the smallest position
        // (= the shorter arc). Then select loop[0..posLast] inclusive.
        int    bestPos  = int.max;
        uint[] bestLoop;

        foreach (i; 0 .. mesh.edges.length) {
            uint ea = mesh.edges[i][0], eb = mesh.edges[i][1];
            if (ea != cast(uint)secondLastVert && eb != cast(uint)secondLastVert) continue;
            uint neighbor = mesh.edgeOtherVertex(cast(uint)i, cast(uint)secondLastVert);

            uint[] loop = walkVertexLoop(cast(uint)secondLastVert, neighbor, ef);
            if (loop.length < 2) continue;

            int posLast = -1;
            foreach (k, v; loop) if (v == cast(uint)lastVert) { posLast = cast(int)k; break; }
            if (posLast <= 0) continue;

            if (posLast < bestPos) { bestPos = posLast; bestLoop = loop; }
        }

        if (bestLoop.length == 0) return true;

        foreach (k; 0 .. bestPos + 1)
            mesh.selectVertex(cast(int)bestLoop[k]);

        return true;
    }
}
