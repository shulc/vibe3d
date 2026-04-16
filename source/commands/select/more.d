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

    // Given secondLast at index 0 and last at index posLast in a loop of
    // length loopLen, returns the index of the next element (2*posLast % L).
    static int extrapolate(int posLast, int loopLen) {
        if (posLast <= 0 || loopLen < 2) return -1;
        return (posLast * 2) % loopLen;
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
                lastFace = cast(int)i;    lastOrd = ord;
            } else if (ord > secondLastOrd) {
                secondLastFace = cast(int)i; secondLastOrd = ord;
            }
        }
        if (lastFace < 0 || secondLastFace < 0) return true;
        if (mesh.faces[lastFace].length != 4 || mesh.faces[secondLastFace].length != 4) return true;

        const slf = mesh.faces[secondLastFace];
        int bestNext = -1, bestPos = int.max;
        for (int j = 0; j < 4; j++) {
            ulong ek = edgeKey(slf[j], slf[(j+1)%4]);
            int[] loop = mesh.walkFaceLoop(secondLastFace, ek);
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

        // Try both adjacent faces of secondLastEdge (each gives one loop direction).
        int bestNext = -1, bestPos = int.max;
        foreach (fi; mesh.facesAroundEdge(cast(uint)secondLastEdge)) {
            int[] loop = mesh.walkEdgeLoop(secondLastEdge, cast(int)fi);
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

        // Try every neighbor of secondLastVert as a possible loop direction.
        int bestNext = -1, bestPos = int.max;
        foreach (i; mesh.edgesAroundVertex(cast(uint)secondLastVert)) {
            uint neighbor = mesh.edgeOtherVertex(i, cast(uint)secondLastVert);

            uint[] seq = mesh.walkVertexLoop(cast(uint)secondLastVert, neighbor);
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
