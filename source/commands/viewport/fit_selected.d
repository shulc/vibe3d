module commands.viewport.fit_selected;

import command;
import mesh;
import editmode;
import view;

import math;

class FitSelected : Command {
    // Owner cameras a fit writes to — see commands.viewport.fit for the full
    // rationale (task 0221). `view` (base-class camera) == scale owner
    // (aspect + distance); `focusCam` receives the framed center.
    private View focusCam;

    this(Mesh* mesh, ref View focusCam, ref View scaleCam, EditMode editMode) {
        super(mesh, scaleCam, editMode);
        this.focusCam = focusCam;
    }

    override string name() const { return "viewport.fit_selected"; }
    override CmdFlags cmdFlags() const { return CmdFlags.UI; }   // camera-only

    override bool apply() {
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
        if (verts.length == 0) return true;
        Vec3 c; float d;
        view.computeFrame(verts, c, d);   // view == scale owner
        focusCam.focus = c;
        view.distance  = d;
        return true;
    }
};

