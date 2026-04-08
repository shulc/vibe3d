module commands.select.expand;

import command;
import mesh;
import view;
import editmode;

class SelectionExpand : Command {
    this(ref Mesh mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.expand"; }

    override bool apply() {
        if (editMode == EditMode.Vertices) {
            int[][] vertAdj = new int[][](mesh.vertices.length);
            foreach (edge; mesh.edges) {
                vertAdj[edge[0]] ~= cast(int)edge[1];
                vertAdj[edge[1]] ~= cast(int)edge[0];
            }
            bool[] toAdd = new bool[](mesh.vertices.length);
            foreach (i; 0 .. mesh.selectedVertices.length)
                if (mesh.selectedVertices[i])
                    foreach (ni; vertAdj[i])
                        toAdd[ni] = true;
            foreach (i; 0 .. toAdd.length)
                if (toAdd[i]) mesh.selectedVertices[i] = true;

        } else if (editMode == EditMode.Edges) {
            int[][] vertEdges = new int[][](mesh.vertices.length);
            foreach (i; 0 .. mesh.edges.length) {
                vertEdges[mesh.edges[i][0]] ~= cast(int)i;
                vertEdges[mesh.edges[i][1]] ~= cast(int)i;
            }
            int[][] edgeAdj = new int[][](mesh.edges.length);
            foreach (i; 0 .. mesh.edges.length)
                foreach (vi; mesh.edges[i])
                    foreach (ni; vertEdges[vi])
                        if (ni != cast(int)i) edgeAdj[i] ~= ni;

            bool[] toAdd = new bool[](mesh.edges.length);
            foreach (i; 0 .. mesh.selectedEdges.length)
                if (mesh.selectedEdges[i])
                    foreach (ni; edgeAdj[i])
                        toAdd[ni] = true;
            foreach (i; 0 .. toAdd.length)
                if (toAdd[i]) mesh.selectedEdges[i] = true;

        } else if (editMode == EditMode.Polygons) {
            // Adjacency via shared vertices (includes diagonal neighbours).
            uint[][] vertFaces = new uint[][](mesh.vertices.length);
            foreach (fi, face; mesh.faces)
                foreach (vi; face)
                    vertFaces[vi] ~= cast(uint)fi;

            int[][] faceAdj = new int[][](mesh.faces.length);
            foreach (fi, face; mesh.faces) {
                bool[int] seen;
                foreach (vi; face)
                    foreach (adjFi; vertFaces[vi])
                        if (adjFi != cast(uint)fi && (cast(int)adjFi) !in seen) {
                            seen[cast(int)adjFi] = true;
                            faceAdj[fi] ~= cast(int)adjFi;
                        }
            }

            bool[] toAdd = new bool[](mesh.faces.length);
            foreach (i; 0 .. mesh.selectedFaces.length)
                if (mesh.selectedFaces[i])
                    foreach (ni; faceAdj[i])
                        toAdd[ni] = true;
            foreach (i; 0 .. toAdd.length)
                if (toAdd[i]) mesh.selectedFaces[i] = true;
        }
        return true;
    }
}
