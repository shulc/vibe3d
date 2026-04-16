module commands.select.contract;

import command;
import mesh;
import view;
import editmode;

class SelectionContract : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.contract"; }

    override bool apply() {
        if (editMode == EditMode.Vertices) {
            bool[] toRemove = new bool[](mesh.selectedVertices.length);
            foreach (i; 0 .. mesh.selectedVertices.length)
                if (mesh.selectedVertices[i])
                    foreach (ni; mesh.verticesAroundVertex(cast(uint)i))
                        if (ni >= mesh.selectedVertices.length || !mesh.selectedVertices[ni]) {
                            toRemove[i] = true;
                            break;
                        }
            foreach (i; 0 .. toRemove.length)
                if (toRemove[i]) mesh.deselectVertex(cast(int)i);

        } else if (editMode == EditMode.Edges) {
            int[][] edgeAdj = new int[][](mesh.edges.length);
            foreach (i; 0 .. mesh.edges.length)
                foreach (vi; mesh.edges[i])
                    foreach (ni; mesh.edgesAroundVertex(vi))
                        if (ni != i) edgeAdj[i] ~= cast(int)ni;

            bool[] toRemove = new bool[](mesh.selectedEdges.length);
            foreach (i; 0 .. mesh.selectedEdges.length)
                if (mesh.selectedEdges[i])
                    foreach (ni; edgeAdj[i])
                        if (ni >= cast(int)mesh.selectedEdges.length || !mesh.selectedEdges[ni]) {
                            toRemove[i] = true;
                            break;
                        }
            foreach (i; 0 .. toRemove.length)
                if (toRemove[i]) mesh.deselectEdge(cast(int)i);

        } else if (editMode == EditMode.Polygons) {
            // Adjacency via shared vertices (mirrors SelectionExpand).
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

            bool[] toRemove = new bool[](mesh.selectedFaces.length);
            foreach (i; 0 .. mesh.selectedFaces.length)
                if (mesh.selectedFaces[i])
                    foreach (ni; faceAdj[i])
                        if (ni >= cast(int)mesh.selectedFaces.length || !mesh.selectedFaces[ni]) {
                            toRemove[i] = true;
                            break;
                        }
            foreach (i; 0 .. toRemove.length)
                if (toRemove[i]) mesh.deselectFace(cast(int)i);
        }
        return true;
    }
}
