module commands.select.loop;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

class SelectLoop : Command {
    private SelectionSnapshot snap;
    protected override void revertImpl() {
        snap.restore(*mesh);
    }
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.loop"; }

    protected override bool applyImpl() {
        // Settled-mesh precondition (debug-only, stripped from release
        // builds): this command only READS the loops family / edgeIndexMap
        // (walkEdgeLoop/walkFaceLoop/walkVertexLoop, mesh.edgeIndex) and
        // never mutates topology itself. The command dispatcher runs one
        // Command.apply() to completion — including any terminal
        // buildLoops() a prior topology-mutating command performed — before
        // starting the next, so by the time this apply() begins the mesh is
        // always settled. Catches a hypothetical future topology mutator
        // that forgets its buildLoops() before the next select.loop runs.
        //
        // TASK 0833 — the FIRST of these two is demonstrated: a test in
        // tests/unit/commands/select/loop_test.d hands apply() a mesh whose
        // loops are stale (a plain `addFace` without a terminal buildLoops)
        // and requires the throw; deleting the line turns that test red.
        //
        // The SECOND one cannot be the sole failure, and that was measured,
        // not assumed — deleting `assertEdgeMapValid()` alone leaves the same
        // test GREEN. There is no producer of (loops valid, edgeMap stale) on
        // this tree: every primitive that leaves the map Stale bumps
        // structVersion and invalidates the loops stamp in the same breath,
        // `markDerivedEmpty()` drops both states together, and the one arm
        // that could once validate loops while leaving the map empty —
        // `buildLoops(bool rebuildEdgeIndexMap)`'s `false` branch — no longer
        // exists at all: task 0790 deleted the parameter after finding zero
        // callers repo-wide for three months. So this state is unreachable BY
        // CONSTRUCTION now, not merely unobserved. `assertEdgeMapValid()` is
        // kept anyway — it is a one-compare debug-only check, free in
        // release, and stays a correct guard should some future primitive
        // reintroduce a way to invalidate the map without invalidating loops;
        // case 7 of the stamp trace table in tests/unit/mesh_test.d is the
        // tripwire that will go red the day that happens (a mutator that
        // stops bumping structVersion).
        mesh.assertLoopsValid();
        mesh.assertEdgeMapValid();
        snap = SelectionSnapshot.capture(*mesh);
        noteUndoRecorded();   // task 2500 — the flag and the image, one statement apart
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
                // `mesh` is a `Mesh*`: the member call auto-derefs, the UFCS free
                // function (task 1903 Stage C) does not — hence `(*mesh).` beside `mesh.`.
                foreach (ei; (*mesh).selectLoopEdges(cast(uint)i))
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
        // command's own Edges branch above. `Mesh.selectVerticesFrom` /
        // `selectFacesFrom` are the bulk form of that primitive: commit the
        // selection AND stamp what it newly selects. See their doc comment in
        // mesh.d for why the restore setters must NOT do this themselves.

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
            mesh.selectVerticesFrom((*mesh).selectLoopVertices());
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
        // faces.length array and the commit setter resizes faceMarks to it
        // (and grows faceSelectionOrder too, which resizeFaceSelection does
        // not) — so the guard was redundant, and reading it through the
        // allocating `mesh.selectedFaces` @property cost a whole-mesh bool[].
        mesh.selectFacesFrom((*mesh).selectLoopFaces());

        return true;
    }
}
