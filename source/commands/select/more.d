module commands.select.more;

import command;
import mesh;
import view;
import editmode;

// SelectMore: all edit modes.
// Finds the last 2 manually-selected elements. If they share a loop,
// extrapolates the gap pattern and selects the next element.
class SelectMore : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.more"; }

    override bool apply() {
        if      (editMode == EditMode.Polygons) return applyPolygons();
        else if (editMode == EditMode.Edges)    return applyEdges();
        else if (editMode == EditMode.Vertices) return applyVertices();
        return true;
    }

private:

    // ------------------------------------------------------------------ //
    //  Shared loop-walk helpers                                            //
    // ------------------------------------------------------------------ //

    uint[][ulong] buildEdgeFaces() {
        uint[][ulong] m;
        foreach (fi, face; mesh.faces)
            for (size_t j = 0; j < face.length; j++) {
                uint a = face[j], b = face[(j + 1) % face.length];
                m[edgeKey(a, b)] ~= cast(uint)fi;
            }
        return m;
    }

    // Face loop entered via entryKey into startFace.
    // Returns ordered face indices (startFace at 0).
    int[] walkFaceLoop(int startFace, ulong entryKey, ref uint[][ulong] ef) {
        int[] res;
        bool[int] vis;
        int cur = startFace; ulong entry = entryKey;
        while (true) {
            if (cur in vis) break;
            vis[cur] = true;
            res ~= cur;
            const face = mesh.faces[cur];
            if (face.length != 4) break;
            int ei = -1;
            for (int j = 0; j < 4; j++)
                if (edgeKey(face[j], face[(j+1)%4]) == entry) { ei = j; break; }
            if (ei < 0) break;
            ulong oppKey = edgeKey(face[(ei+2)%4], face[(ei+3)%4]);
            auto p = oppKey in ef; if (!p) break;
            int nf = -1;
            foreach (fi; *p) if (fi != cast(uint)cur) { nf = cast(int)fi; break; }
            if (nf < 0) break;
            cur = nf; entry = oppKey;
        }
        return res;
    }

    // Edge loop starting from startEdge on startFace.
    // Returns ordered edge indices.
    int[] walkEdgeLoop(int startEdge, int startFace,
                       ref uint[][ulong] ef, ref int[ulong] ke) {
        const sfv = mesh.faces[startFace];
        if (sfv.length != 4) return [];
        ulong startKey = edgeKey(mesh.edges[startEdge][0], mesh.edges[startEdge][1]);
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

    // Vertex loop in direction startVert→nextVert.
    // Finds the face where this directed edge exists in winding order,
    // then walks the cross-edge traversal.
    // Returns ordered vertex indices ([startVert, nextVert, …]).
    uint[] walkVertexLoop(uint startVert, uint nextVert, ref uint[][ulong] ef) {
        auto fp = edgeKey(startVert, nextVert) in ef;
        if (!fp) return [];
        // Find a face that has startVert→nextVert in its winding.
        int startFace = -1;
        foreach (fi; *fp) {
            const fv = mesh.faces[fi];
            if (fv.length != 4) continue;
            for (int j = 0; j < 4; j++) {
                if (fv[j] == startVert && fv[(j+1)%4] == nextVert) {
                    startFace = cast(int)fi; break;
                }
            }
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

    // Given secondLast at index 0 and last at index posLast in a loop of
    // length loopLen, returns the index of the next element (2*posLast % L).
    static int extrapolate(int posLast, int loopLen) {
        if (posLast <= 0 || loopLen < 2) return -1;
        return (posLast * 2) % loopLen;
    }

    // ------------------------------------------------------------------ //
    //  Per-mode implementations                                            //
    // ------------------------------------------------------------------ //

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
                lastFace = cast(int)i;    lastOrd = ord;
            } else if (ord > secondLastOrd) {
                secondLastFace = cast(int)i; secondLastOrd = ord;
            }
        }
        if (lastFace < 0 || secondLastFace < 0) return true;
        if (mesh.faces[lastFace].length != 4 || mesh.faces[secondLastFace].length != 4) return true;

        auto ef = buildEdgeFaces();
        const slf = mesh.faces[secondLastFace];
        int bestNext = -1, bestPos = int.max;
        for (int j = 0; j < 4; j++) {
            ulong ek = edgeKey(slf[j], slf[(j+1)%4]);
            int[] loop = walkFaceLoop(secondLastFace, ek, ef);
            if (loop.length < 2) continue;
            int posLast = -1;
            foreach (k, fi; loop) if (fi == lastFace) { posLast = cast(int)k; break; }
            if (posLast <= 0) continue;
            int nextPos = extrapolate(posLast, cast(int)loop.length);
            if (nextPos < 0) continue;
            int nf = loop[nextPos];
            if (nf == lastFace || nf == secondLastFace) continue;
            if (posLast < bestPos) { bestPos = posLast; bestNext = nf; }
        }

        if (bestNext >= 0 && !mesh.selectedFaces[bestNext])
            mesh.selectFace(bestNext);
        return true;
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
                lastEdge = cast(int)i;     lastOrd = ord;
            } else if (ord > secondLastOrd) {
                secondLastEdge = cast(int)i; secondLastOrd = ord;
            }
        }
        if (lastEdge < 0 || secondLastEdge < 0) return true;

        auto ef = buildEdgeFaces();
        int[ulong] keyToEdge;
        foreach (i; 0 .. mesh.edges.length)
            keyToEdge[edgeKey(mesh.edges[i][0], mesh.edges[i][1])] = cast(int)i;

        // Try both adjacent faces of secondLastEdge (each gives one loop direction).
        ulong slKey = edgeKey(mesh.edges[secondLastEdge][0], mesh.edges[secondLastEdge][1]);
        auto fp = slKey in ef;
        if (!fp) return true;

        int bestNext = -1, bestPos = int.max;
        foreach (fi; *fp) {
            int[] loop = walkEdgeLoop(secondLastEdge, cast(int)fi, ef, keyToEdge);
            if (loop.length < 2) continue;
            int posLast = -1;
            foreach (k, ei; loop) if (ei == lastEdge) { posLast = cast(int)k; break; }
            if (posLast <= 0) continue;
            int nextPos = extrapolate(posLast, cast(int)loop.length);
            if (nextPos < 0) continue;
            int ne = loop[nextPos];
            if (ne == lastEdge || ne == secondLastEdge) continue;
            if (posLast < bestPos) { bestPos = posLast; bestNext = ne; }
        }

        if (bestNext >= 0 && !mesh.selectedEdges[bestNext])
            mesh.selectEdge(bestNext);
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
                lastVert = cast(int)i;     lastOrd = ord;
            } else if (ord > secondLastOrd) {
                secondLastVert = cast(int)i; secondLastOrd = ord;
            }
        }
        if (lastVert < 0 || secondLastVert < 0) return true;

        auto ef = buildEdgeFaces();

        // Try every neighbor of secondLastVert as a possible loop direction.
        int bestNext = -1, bestPos = int.max;
        foreach (i; 0 .. mesh.edges.length) {
            uint ea = mesh.edges[i][0], eb = mesh.edges[i][1];
            uint neighbor;
            if      (ea == cast(uint)secondLastVert) neighbor = eb;
            else if (eb == cast(uint)secondLastVert) neighbor = ea;
            else continue;

            uint[] seq = walkVertexLoop(cast(uint)secondLastVert, neighbor, ef);
            if (seq.length < 2) continue;
            int posLast = -1;
            foreach (k, v; seq) if (v == cast(uint)lastVert) { posLast = cast(int)k; break; }
            if (posLast <= 0) continue;
            int nextPos = extrapolate(posLast, cast(int)seq.length);
            if (nextPos < 0) continue;
            int nv = cast(int)seq[nextPos];
            if (nv == lastVert || nv == secondLastVert) continue;
            if (posLast < bestPos) { bestPos = posLast; bestNext = nv; }
        }

        if (bestNext >= 0 && !mesh.selectedVertices[bestNext])
            mesh.selectVertex(bestNext);
        return true;
    }
}
