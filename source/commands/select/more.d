module commands.select.more;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

// SelectMore: all edit modes.
// Finds the last 2 manually-selected elements. If they share a loop,
// extrapolates the gap pattern and selects the next element.
class SelectMore : Command {
    private SelectionSnapshot snap;
    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.more"; }

    protected override bool applyImpl() {
        snap = SelectionSnapshot.capture(*mesh);
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
        // The two resizes are preconditions of the WRITE at the bottom of this
        // method, not of the scan: `selectFace` indexes `faceMarks` and
        // `faceSelectionOrder` raw, and `bestNext` comes out of a face-loop
        // walk over `mesh.faces`, which can name a face past either plane.
        // `resizeFaceSelection` deliberately does not grow the pick-order
        // array (`mesh.d:5773`), so both lines are needed and neither is
        // redundant with the other. `select.less` has no such guard because it
        // never selects; see its own comment.
        if (mesh.faceMarks.length < mesh.faces.length)
            mesh.resizeFaceSelection();
        if (mesh.faceSelectionOrder.length < mesh.faces.length)
            mesh.faceSelectionOrder.length = mesh.faces.length;

        // ONE reader for "the last two elements selected" — see
        // `Mesh.lastSelectedInSelectionOrder` (task 2440). It filters by the
        // Select bit BEFORE it ranks, which the hand-written scan this
        // replaced did not: a stale stamp left by `bevel_vertex` / `extrude`
        // gave this command a PHANTOM pair of unselected faces to extrapolate
        // from.
        const sel = mesh.lastSelectedInSelectionOrder(EditMode.Polygons);
        immutable int lastFace = sel.last, secondLastFace = sel.secondLast;
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

        if (bestNext >= 0 && !mesh.isFaceSelected(bestNext))
            mesh.selectFace(bestNext);
        return true;
    }

    bool applyEdges() {
        // Write precondition, as in `applyPolygons` — `selectEdge` indexes
        // `edgeMarks` raw at an index the loop walk produced. Unlike the face
        // plane, `resizeEdgeSelection` DOES grow `edgeSelectionOrder` too.
        if (mesh.edgeMarks.length < mesh.edges.length)
            mesh.resizeEdgeSelection();

        const sel = mesh.lastSelectedInSelectionOrder(EditMode.Edges);
        immutable int lastEdge = sel.last, secondLastEdge = sel.secondLast;
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

        if (bestNext >= 0 && !mesh.isEdgeSelected(bestNext))
            mesh.selectEdge(bestNext);
        return true;
    }

    bool applyVertices() {
        // Write precondition, as in `applyPolygons`.
        if (mesh.vertexMarks.length < mesh.vertices.length)
            mesh.resizeVertexSelection();

        const sel = mesh.lastSelectedInSelectionOrder(EditMode.Vertices);
        immutable int lastVert = sel.last, secondLastVert = sel.secondLast;
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

        if (bestNext >= 0 && !mesh.isVertexSelected(bestNext))
            mesh.selectVertex(bestNext);
        return true;
    }
}
