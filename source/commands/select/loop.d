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

        // --- Selection-order stamping (task 0554), both branches below -------
        // Both walks pick their SEED from the selection in selection-history
        // order: selectLoopVertices / selectLoopFaces sort the selected
        // elements by vertex/faceSelectionOrder, mapping "0 or absent" to
        // int.max so an UNSTAMPED element sorts LAST. But the commit setters
        // setVerticesSelectedFrom / setFacesSelectedFrom are state-RESTORE
        // setters — they write the Select bit and nothing else. So an element
        // the walk ADDED came out with order 0 and sorted behind anything the
        // user clicked AFTERWARDS, even though the walk had selected it first.
        // That inverts the oldest-first rule the walk documents for itself,
        // and it changes the result: on a 5x5 grid, click 2 polygons →
        // select.loop → shift-add a 3rd → select.loop lands on a different
        // band than the same history with the order preserved.
        //
        // Every other derived-selection command in this family stamps its
        // output through Mesh.selectVertex/selectEdge/selectFace (select.ring,
        // select.expand, select.between, select.more) — and so does THIS
        // command's own Edges branch above. That primitive's contract is: an
        // element that was NOT already selected takes the next counter value,
        // an already-selected one keeps the order it had. The two branches
        // below reproduce exactly that contract on top of the bulk commit —
        // surviving seeds keep the order of the click that made them, newly
        // walked elements take fresh increasing values in index order, and
        // dropped elements are cleared by the setter itself.
        //
        // The stamp is deliberately NOT pushed down into the shared setters:
        // their other callers are state restores and internal re-selects
        // (SelectionSnapshot.restore, select.connect, select.fill, and the
        // post-topology reselects in mesh.d) where minting new order values
        // would be wrong.

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
            bool[] loopSel = mesh.selectLoopVertices();
            // Which vertices the walk ADDS — must be read BEFORE the commit
            // marks them selected (see the stamping note above).
            bool[] added = new bool[](loopSel.length);
            foreach (i; 0 .. loopSel.length)
                added[i] = loopSel[i] && !mesh.isVertexSelected(i);
            mesh.setVerticesSelectedFrom(loopSel);
            // The commit setter grew vertexSelectionOrder to loopSel.length.
            foreach (i; 0 .. added.length)
                if (added[i])
                    mesh.vertexSelectionOrder[i] = ++mesh.vertexSelectionOrderCounter;
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
        bool[] loopSel = mesh.selectLoopFaces();
        bool[] added   = new bool[](loopSel.length);
        foreach (i; 0 .. loopSel.length)
            added[i] = loopSel[i] && !mesh.isFaceSelected(cast(int)i);
        mesh.setFacesSelectedFrom(loopSel);
        // The commit setter grew faceSelectionOrder to loopSel.length.
        foreach (i; 0 .. added.length)
            if (added[i])
                mesh.faceSelectionOrder[i] = ++mesh.faceSelectionOrderCounter;

        return true;
    }
}
