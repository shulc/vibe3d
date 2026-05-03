module commands.select.convert;

import command;
import mesh;
import view;
import editmode;

/// select.convert <vertex|edge|polygon>
///
/// Converts the current selection from the active EditMode to a different
/// element type, then switches EditMode to that type and clears the old
/// selection.
///
/// Conversion rules (matches MODO semantics — verified against modo_cl):
///   vertex  → edge:    select edges where BOTH endpoints are selected.
///   vertex  → polygon: select polygons where ALL vertices are selected.
///   edge    → vertex:  select the endpoints of every selected edge.
///   edge    → polygon: select polygons where ALL edges are selected
///                      ("polygons completely surrounded by selected edges").
///   polygon → vertex:  select all vertices of selected polygons.
///   polygon → edge:    select all edges of selected polygons.
///
/// Not undoable — mode-only / selection-only operation.
class SelectConvertCommand : Command {
    private EditMode* editModePtr;
    private string    targetType;

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr) {
        super(mesh, view, editMode);
        this.editModePtr = editModePtr;
    }

    override string name()  const { return "select.convert"; }
    override bool isUndoable() const { return false; }

    void setTargetType(string t) { targetType = t; }

    override bool apply() {
        mesh.syncSelection();

        EditMode srcMode = *editModePtr;
        EditMode dstMode = parseTargetType(targetType);

        if (srcMode == dstMode) return true; // nothing to do

        switch (srcMode) {
            case EditMode.Vertices:
                if (dstMode == EditMode.Edges)    vertToEdge();
                else                              vertToPoly();
                break;
            case EditMode.Edges:
                if (dstMode == EditMode.Vertices) edgeToVert();
                else                              edgeToPoly();
                break;
            case EditMode.Polygons:
                if (dstMode == EditMode.Vertices) polyToVert();
                else                              polyToEdge();
                break;
            default: assert(false);
        }

        *editModePtr = dstMode;
        return true;
    }

private:

    static EditMode parseTargetType(string t) {
        switch (t) {
            case "vertex":  return EditMode.Vertices;
            case "edge":    return EditMode.Edges;
            case "polygon": return EditMode.Polygons;
            default:
                throw new Exception(
                    "select.convert: unknown type '" ~ t ~
                    "' — expected vertex, edge, or polygon");
        }
    }

    // -----------------------------------------------------------------------
    // vertex → edge: select edges where both endpoints are selected.
    // -----------------------------------------------------------------------
    void vertToEdge() {
        bool[] newSel = new bool[](mesh.edges.length);
        foreach (ei, e; mesh.edges) {
            uint a = e[0], b = e[1];
            if (a < mesh.selectedVertices.length &&
                b < mesh.selectedVertices.length &&
                mesh.selectedVertices[a] &&
                mesh.selectedVertices[b])
            {
                newSel[ei] = true;
            }
        }
        mesh.clearVertexSelection();
        mesh.clearEdgeSelection();
        foreach (ei; 0 .. newSel.length)
            if (newSel[ei]) mesh.selectEdge(cast(int)ei);
    }

    // -----------------------------------------------------------------------
    // vertex → polygon: select polys where ALL vertices are selected.
    // -----------------------------------------------------------------------
    void vertToPoly() {
        bool[] newSel = new bool[](mesh.faces.length);
        foreach (fi, face; mesh.faces) {
            bool allSel = true;
            foreach (vi; face) {
                if (vi >= mesh.selectedVertices.length ||
                    !mesh.selectedVertices[vi])
                {
                    allSel = false;
                    break;
                }
            }
            if (allSel && face.length > 0) newSel[fi] = true;
        }
        mesh.clearVertexSelection();
        mesh.clearFaceSelection();
        foreach (fi; 0 .. newSel.length)
            if (newSel[fi]) mesh.selectFace(cast(int)fi);
    }

    // -----------------------------------------------------------------------
    // edge → vertex: select both endpoints of every selected edge.
    // -----------------------------------------------------------------------
    void edgeToVert() {
        bool[] newSel = new bool[](mesh.vertices.length);
        foreach (ei, sel; mesh.selectedEdges) {
            if (!sel) continue;
            uint a = mesh.edges[ei][0];
            uint b = mesh.edges[ei][1];
            if (a < newSel.length) newSel[a] = true;
            if (b < newSel.length) newSel[b] = true;
        }
        mesh.clearEdgeSelection();
        mesh.clearVertexSelection();
        foreach (vi; 0 .. newSel.length)
            if (newSel[vi]) mesh.selectVertex(cast(int)vi);
    }

    // -----------------------------------------------------------------------
    // edge → polygon: select polys where ALL edges are selected (matches
    // MODO — "polygon completely surrounded by selected edges"). The earlier
    // "any one selected edge" rule meant convert poly→edge→poly added the
    // four neighbouring faces; the ALL rule round-trips back to the source.
    // -----------------------------------------------------------------------
    void edgeToPoly() {
        bool[] newSel = new bool[](mesh.faces.length);
        foreach (fi, face; mesh.faces) {
            if (face.length == 0) continue;
            bool allSel = true;
            foreach (k; 0 .. face.length) {
                uint a = face[k];
                uint b = face[(k + 1) % face.length];
                bool found = false;
                foreach (ei; mesh.edgesAroundVertex(a)) {
                    auto e = mesh.edges[ei];
                    if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a)) {
                        if (ei < mesh.selectedEdges.length
                            && mesh.selectedEdges[ei])
                            found = true;
                        break;
                    }
                }
                if (!found) { allSel = false; break; }
            }
            if (allSel) newSel[fi] = true;
        }
        mesh.clearEdgeSelection();
        mesh.clearFaceSelection();
        foreach (fi; 0 .. newSel.length)
            if (newSel[fi]) mesh.selectFace(cast(int)fi);
    }

    // -----------------------------------------------------------------------
    // polygon → vertex: select all vertices of selected polygons.
    // -----------------------------------------------------------------------
    void polyToVert() {
        bool[] newSel = new bool[](mesh.vertices.length);
        foreach (fi, sel; mesh.selectedFaces) {
            if (!sel) continue;
            foreach (vi; mesh.faces[fi])
                if (vi < newSel.length) newSel[vi] = true;
        }
        mesh.clearFaceSelection();
        mesh.clearVertexSelection();
        foreach (vi; 0 .. newSel.length)
            if (newSel[vi]) mesh.selectVertex(cast(int)vi);
    }

    // -----------------------------------------------------------------------
    // polygon → edge: select all edges of selected polygons.
    // -----------------------------------------------------------------------
    void polyToEdge() {
        bool[] newSel = new bool[](mesh.edges.length);
        foreach (fi, sel; mesh.selectedFaces) {
            if (!sel) continue;
            const uint[] face = mesh.faces[fi];
            foreach (k; 0 .. face.length) {
                uint a = face[k];
                uint b = face[(k + 1) % face.length];
                // Look up the undirected edge by walking the loop structure.
                // edgesAroundVertex emits all edge indices incident to a vertex.
                foreach (ei; mesh.edgesAroundVertex(a)) {
                    auto e = mesh.edges[ei];
                    if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a)) {
                        if (ei < newSel.length) newSel[ei] = true;
                        break;
                    }
                }
            }
        }
        mesh.clearFaceSelection();
        mesh.clearEdgeSelection();
        foreach (ei; 0 .. newSel.length)
            if (newSel[ei]) mesh.selectEdge(cast(int)ei);
    }
}
