module commands.select.connect;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

private void bfsSelect(bool[] selection, int[][] adj, int seed) {
    bool[] visited = new bool[](selection.length);
    int[] queue;
    foreach (i; 0 .. selection.length)
        if (selection[i]) { queue ~= cast(int)i; visited[i] = true; }
    if (seed >= 0 && !visited[seed]) {
        queue ~= seed;
        visited[seed] = true;
    }
    int head = 0;
    while (head < queue.length) {
        int cur = queue[head++];
        selection[cur] = true;
        foreach (ni; adj[cur]) {
            if (!visited[ni]) {
                visited[ni] = true;
                queue ~= ni;
            }
        }
    }
}


class SelectConnect : Command {
    private SelectionSnapshot snap;
    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.connect"; }

    override bool apply() {
        snap = SelectionSnapshot.capture(*mesh);
        // Connected selection — flood-fill from current selection / hovered element.
        // `selectedX` is now a materialized read view; bfsSelect mutates the
        // bool[] in place, so capture the view into a local, flood-fill it,
        // then write the result back through the setter.
        if (editMode == EditMode.Vertices) {
            // Deliberately loop-based (verticesAroundVertex, the half-edge
            // fan walk) — NOT folded onto the edge-based mesh.vertexAdjacencyCSR
            // provider. On non-manifold / multi-fan vertices the two relations
            // yield different neighbor sets (see the mesh.d 0190 non-manifold
            // unittest); substituting CSR here would silently change
            // connected-component reachability. Left as its own copy.
            int[][] vertAdj = new int[][](mesh.vertices.length);
            foreach (vi; 0 .. mesh.vertices.length)
                foreach (ni; mesh.verticesAroundVertex(cast(uint)vi))
                    vertAdj[vi] ~= cast(int)ni;
            auto sel = mesh.selectedVertices;
            bfsSelect(sel, vertAdj, -1);
            mesh.setVerticesSelectedFrom(sel);
        } else if (editMode == EditMode.Edges) {
            // Build edge → adjacent edges map via shared vertices
            auto edgeAdj = mesh.edgeAdjacencySharingVertex();
            auto sel = mesh.selectedEdges;
            bfsSelect(sel, edgeAdj, -1);
            mesh.setEdgesSelectedFrom(sel);
        } else if (editMode == EditMode.Polygons) {
            // Edge-adjacent faces (mesh.adjacentFaces) — a DIFFERENT relation
            // from the shared-vertex adjacency (mesh.faceAdjacencySharingVertex)
            // used by expand/contract: connect does not cross diagonal
            // neighbours. Intentionally kept separate; do not unify with C.
            int[][] faceAdj = new int[][](mesh.faces.length);
            foreach (fi; 0 .. mesh.faces.length)
                foreach (adjFi; mesh.adjacentFaces(cast(uint)fi))
                    faceAdj[fi] ~= cast(int)adjFi;
            auto sel = mesh.selectedFaces;
            bfsSelect(sel, faceAdj, -1);
            mesh.setFacesSelectedFrom(sel);
        }
        return true;
    }
};