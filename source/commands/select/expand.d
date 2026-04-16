module commands.select.expand;

import command;
import mesh;
import view;
import editmode;

class SelectionExpand : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.expand"; }

    override bool apply() {
        if (editMode == EditMode.Vertices) {
            bool[] toAdd = new bool[](mesh.vertices.length);
            foreach (i; 0 .. mesh.selectedVertices.length)
                if (mesh.selectedVertices[i])
                    foreach (ni; mesh.verticesAroundVertex(cast(uint)i))
                        toAdd[ni] = true;
            foreach (i; 0 .. toAdd.length)
                if (toAdd[i]) mesh.selectVertex(cast(int)i);

        } else if (editMode == EditMode.Edges) {
            int[][] edgeAdj = new int[][](mesh.edges.length);
            foreach (i; 0 .. mesh.edges.length)
                foreach (vi; mesh.edges[i])
                    foreach (ni; mesh.edgesAroundVertex(vi))
                        if (ni != i) edgeAdj[i] ~= cast(int)ni;

            bool[] toAdd = new bool[](mesh.edges.length);
            foreach (i; 0 .. mesh.selectedEdges.length)
                if (mesh.selectedEdges[i])
                    foreach (ni; edgeAdj[i])
                        toAdd[ni] = true;
            foreach (i; 0 .. toAdd.length)
                if (toAdd[i]) mesh.selectEdge(cast(int)i);

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
                if (toAdd[i]) mesh.selectFace(cast(int)i);
        }
        return true;
    }
}
