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
/// Conversion rules:
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
    // Selection-types Stage 5 (audit c): route the editMode change through the
    // app geometry-type funnel when installed, so EditMode stays in lockstep
    // with the SelType recent-ordering. Null (default / unit test) writes the
    // pointer directly — identical for callers without an ordering.
    private void delegate(EditMode) promoteType;

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr) {
        super(mesh, view, editMode);
        this.editModePtr = editModePtr;
    }

    override string name()  const { return "select.convert"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    void setTargetType(string t) { targetType = t; }
    SelectConvertCommand setPromoteHook(void delegate(EditMode) h) { promoteType = h; return this; }

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

        if (promoteType !is null) promoteType(dstMode);  // lockstep with SelType
        else                      *editModePtr = dstMode;
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
        // Perf (task 0388): `mesh.selectedVertices` is a @property that
        // rebuilds a whole `bool[]` per read — indexing it twice per edge
        // inside this loop was O(edges * vertices). `isVertexSelected(i)`
        // is the non-allocating, bounds-checked scalar equivalent of
        // `i < selectedVertices.length && selectedVertices[i]`.
        bool[] newSel = new bool[](mesh.edges.length);
        foreach (ei, e; mesh.edges) {
            uint a = e[0], b = e[1];
            if (mesh.isVertexSelected(a) && mesh.isVertexSelected(b))
                newSel[ei] = true;
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
        // Perf (task 0388): see vertToEdge — isVertexSelected(vi) replaces
        // the bounds-check + @property-index pair, dropping the per-face,
        // per-vertex O(vertices) allocation.
        bool[] newSel = new bool[](mesh.faces.length);
        foreach (fi, face; mesh.faces) {
            bool allSel = true;
            foreach (vi; face) {
                if (!mesh.isVertexSelected(vi)) {
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
    // edge → polygon: select polys where ALL edges are selected (a
    // "polygon completely surrounded by selected edges"). The earlier
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
                        // Perf (task 0388): isEdgeSelected(ei) replaces the
                        // bounds-check + @property-index pair (was O(edges)
                        // allocated per face*edge visit).
                        if (mesh.isEdgeSelected(ei))
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
