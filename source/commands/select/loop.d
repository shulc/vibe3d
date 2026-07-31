module commands.select.loop;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

class SelectLoop : Command {
    private SelectionSnapshot snap;
    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.loop"; }

    override bool apply() {
        // Settled-mesh precondition (debug-only, stripped from release
        // builds): this command only READS the loops family / edgeIndexMap
        // (walkEdgeLoop/walkFaceLoop/walkVertexLoop, mesh.edgeIndex) and
        // never mutates topology itself. The command dispatcher runs one
        // Command.apply() to completion — including any terminal
        // buildLoops() a prior topology-mutating command performed — before
        // starting the next, so by the time this apply() begins the mesh is
        // always settled. Catches a hypothetical future topology mutator
        // that forgets its buildLoops() before the next select.loop runs.
        mesh.assertLoopsValid();
        mesh.assertEdgeMapValid();
        snap = SelectionSnapshot.capture(*mesh);
        // ------------------------------------------------------------------ //
        //  Edge loop                                                           //
        // ------------------------------------------------------------------ //
        if (editMode == EditMode.Edges) {
            // Read the marks array's length directly: `mesh.selectedEdges` is
            // a @property that materializes a whole-mesh bool[] per read, and
            // `.length` was the only thing wanted from it.
            if (mesh.edgeMarks.length < mesh.edges.length)
                mesh.resizeEdgeSelection();

            bool[] initSel = mesh.selectedEdges.dup;
            foreach (i; 0 .. initSel.length) {
                if (!initSel[i]) continue;
                foreach (ei; mesh.selectLoopEdges(cast(uint)i))
                    mesh.selectEdge(ei);
            }
            return true;
        }

        // ------------------------------------------------------------------ //
        //  Vertex loop                                                         //
        // ------------------------------------------------------------------ //
        if (editMode == EditMode.Vertices) {
            // Same non-allocating length read as the edge branch above. The
            // resize itself STAYS: unlike the polygon branch below,
            // resizeVertexSelection() also resizes the Point-domain mesh maps,
            // which setVerticesSelectedFrom() does not do.
            if (mesh.vertexMarks.length < mesh.vertices.length)
                mesh.resizeVertexSelection();

            // Recovered-algorithm core (task 0390, mesh.selectLoopVertices):
            // seed = adjacent selected vertex PAIR; result REPLACES the
            // selection (reference purge-then-commit — a lone selected
            // vertex therefore clears it).
            mesh.setVerticesSelectedFrom(mesh.selectLoopVertices());
            return true;
        }

        // ------------------------------------------------------------------ //
        //  Polygon loop                                                        //
        // ------------------------------------------------------------------ //
        // Recovered-algorithm core (task 0390, mesh.selectLoopFaces): pure
        // topological band — even-sided partner pairing across a directed
        // shared edge (axis perpendicular to it), single-seed axis from the
        // polygon's own vertex order (edges 0 and nverts/2), odd-sided
        // neighbours skipped, visited polygons stop the trace, multi-group
        // rescan over the remaining selected polygons. Result REPLACES the
        // selection (reference purge-then-commit).
        // No resizeFaceSelection() guard here: selectLoopFaces() returns a
        // faces.length array and setFacesSelectedFrom() resizes faceMarks to
        // it (and grows faceSelectionOrder too, which resizeFaceSelection
        // does not) — so the guard was redundant, and reading it through the
        // allocating `mesh.selectedFaces` @property cost a whole-mesh bool[].
        mesh.setFacesSelectedFrom(mesh.selectLoopFaces());

        return true;
    }
}
