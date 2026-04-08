module commands.viewport.fit_selected;

import command;
import mesh;
import editmode;
import view;

import math;

class FitSelected : Command {
    this(ref Mesh mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "viewport.fitSelected"; }

    override void apply() {
        // Frame selected (or whole mesh if nothing selected).
        Vec3[] verts;
        if (editMode == EditMode.Vertices) {
            bool any = mesh.hasAnySelectedVertices();
            foreach (i; 0 .. mesh.vertices.length)
                if (!any || mesh.selectedVertices[i]) verts ~= mesh.vertices[i];
        } else if (editMode == EditMode.Edges) {
            bool any = mesh.hasAnySelectedEdges();
            bool[] vis = new bool[](mesh.vertices.length);
            foreach (i; 0 .. mesh.edges.length) {
                if (any && !mesh.selectedEdges[i]) continue;
                foreach (vi; mesh.edges[i])
                    if (!vis[vi]) { verts ~= mesh.vertices[vi]; vis[vi] = true; }
            }
        } else if (editMode == EditMode.Polygons) {
            bool any = mesh.hasAnySelectedFaces();
            bool[] vis = new bool[](mesh.vertices.length);
            foreach (i; 0 .. mesh.faces.length) {
                if (any && !mesh.selectedFaces[i]) continue;
                foreach (vi; mesh.faces[i])
                    if (!vis[vi]) { verts ~= mesh.vertices[vi]; vis[vi] = true; }
            }
        }
        view.frameToVertices(verts);
    }
};

