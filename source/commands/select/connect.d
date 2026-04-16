module commands.select.connect;

import command;
import mesh;
import view;
import editmode;

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
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.connect"; }

    override bool apply() {
        // Connected selection — flood-fill from current selection / hovered element.
        if (editMode == EditMode.Vertices) {
            int[][] vertAdj = new int[][](mesh.vertices.length);
            foreach (edge; mesh.edges) {
                vertAdj[edge[0]] ~= cast(int)edge[1];
                vertAdj[edge[1]] ~= cast(int)edge[0];
            }
            bfsSelect(mesh.selectedVertices, vertAdj, -1);
        } else if (editMode == EditMode.Edges) {
            // Build edge → adjacent edges map via shared vertices
            int[][] edgeAdj = new int[][](mesh.edges.length);
            foreach (i; 0 .. mesh.edges.length)
                foreach (vi; mesh.edges[i])
                    foreach (ni; mesh.edgesAroundVertex(vi))
                        if (ni != i) edgeAdj[i] ~= cast(int)ni;
            bfsSelect(mesh.selectedEdges, edgeAdj, -1);
        } else if (editMode == EditMode.Polygons) {
            int[][] faceAdj = new int[][](mesh.faces.length);
            foreach (fi; 0 .. mesh.faces.length)
                foreach (adjFi; mesh.adjacentFaces(cast(uint)fi))
                    faceAdj[fi] ~= cast(int)adjFi;
            bfsSelect(mesh.selectedFaces, faceAdj, -1);
        }
        return true;
    }
};