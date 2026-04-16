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

    // Walk the face-loop traversal edges starting from startEdge as the entry
    // edge of startFace.  Records the entry edge of every face visited, plus
    // the final exit edge when the loop ends at a boundary (open chain).
    // For a closed loop of L faces this yields L edges; for an open chain of
    // L faces it yields L+1 edges (one on each side of every face).
    int[] walkFaceLoopEdges(int startEdge, int startFace) {
        int[] res;
        bool[int] vis;
        int cur     = startFace;
        int curEdge = startEdge;
        while (true) {
            if (cur in vis) break;
            vis[cur] = true;
            res ~= curEdge;

            const face = mesh.faces[cur];
            if (face.length != 4) break;

            int ei = mesh.findEdgeInFace(cast(uint)cur, mesh.edgeKeyOf(cast(uint)curEdge));
            if (ei < 0) break;

            int   oppIdx  = (ei + 2) % 4;
            ulong oppKey  = edgeKey(face[oppIdx], face[(oppIdx+1)%4]);
            uint  opp_ei  = mesh.edgeIndexByKey(oppKey); if (opp_ei == ~0u) break;
            int   exitEdge = cast(int)opp_ei;

            int nf = mesh.adjacentFaceThrough(opp_ei, cast(uint)cur);
            if (nf < 0) { res ~= exitEdge; break; }

            cur     = nf;
            curEdge = exitEdge;
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
                uint eid = mesh.edgeIndex(face[j], face[(j+1)%4]);
                if (eid == ~0u) continue;
                ulong ek = edgeKey(face[j], face[(j+1)%4]);
                foreach (fi; mesh.facesAroundEdge(eid)) {
                    if (fi == cast(uint)cur || fAsgn[fi]) continue;
                    if (mesh.faces[fi].length != 4) continue;
                    int jn = mesh.findEdgeInFace(fi, ek);
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

        int   bestPos  = int.max;
        int[] bestLoop;

        foreach (fi; mesh.facesAroundEdge(cast(uint)secondLastEdge)) {
            // Approach 1: edge loop (both edges on the same edge loop).
            int[] loop = mesh.walkEdgeLoop(secondLastEdge, cast(int)fi);
            if (loop.length >= 2) {
                int posLast = -1;
                foreach (k, ei; loop) if (ei == lastEdge) { posLast = cast(int)k; break; }
                if (posLast > 0 && posLast < bestPos) { bestPos = posLast; bestLoop = loop; }
            }

            // Approach 2: face-loop traversal (edges on opposite sides of faces
            // in the same face loop, e.g. entry edge of F0 and exit edge of F2).
            int[] floop = walkFaceLoopEdges(secondLastEdge, cast(int)fi);
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

        // Try every neighbour of secondLastVert as a loop direction.
        // Pick the direction where lastVert appears at the smallest position
        // (= the shorter arc). Then select loop[0..posLast] inclusive.
        int    bestPos  = int.max;
        uint[] bestLoop;

        foreach (i; mesh.edgesAroundVertex(cast(uint)secondLastVert)) {
            uint neighbor = mesh.edgeOtherVertex(i, cast(uint)secondLastVert);

            uint[] loop = mesh.walkVertexLoop(cast(uint)secondLastVert, neighbor);
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
