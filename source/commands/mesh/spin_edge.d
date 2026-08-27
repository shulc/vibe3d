module commands.mesh.spin_edge;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import snapshot : MeshSnapshot, SelectionSnapshot;
import selection_product : repointToEdgeKeys;
import mesh_edit_delta : MeshEditScope;
import commands.mesh.position_undo : RecordedUndo;
import commands.mesh.map_edit_undo : runMapEdit, revertMapEditEmptyOk;

/// Spin (rotate) the shared edge of two adjacent faces to the next diagonal of
/// the combined boundary polygon.
///
/// Edge scope   — spin every selected qualifying edge.
/// Polygon scope — spin the shared interior edges between pairs of selected
///                 faces that both qualify.
/// Vertex scope  — explicit no-op guard (returns false before snapshot).
///
/// Supported face pairs (task 1200, ledger rows 9 + 16): ANY two faces with at
/// least three sides each — a triangle beside a quad, two pentagons, anything.
/// Both faces keep their own valence. This used to demand equal valence and
/// that it be 3 or 4; the reference's gate never asked for either.
/// Direction: new diagonal = (c, e) = (successor-of-b-in-f1,
///   successor-of-a-in-f2); the vibe3d default, and it reproduces the reference
///   on every frozen cell (see doc/spin_quads_plan.md for the quad question the
///   Phase-0 capture never settled).
/// There is no FOLD-OVER guard (ledger row 17): a spin whose new diagonal
/// already exists is performed anyway and leaves a NON-MANIFOLD mesh — three
/// faces on that edge, and an edge count that FALLS. Deliberate; see
/// tests/fixtures/spin_gate_narrower.json.
///
/// TASK 1903 STAGE L2-b — UNDO IS THE OPERATION-LOG DELTA. The old note here
/// read "undo via full MeshSnapshot (same pattern as MeshSplitEdge)".
/// `Mesh.spinEdgeRings_` now installs its two rings through
/// `Mesh.setFaceWindings`, so a recording batch comes back with
/// `[MeshMapDelta, ReshapeFaces]` per spin instead of an EMPTY log whose
/// `revert()` answered true and left both faces spun.
///
/// THE QUIETER COUSIN OF `mesh.flip`'S RESIDUAL, AND WHAT THE WRITER DOES AND
/// DOES NOT CLOSE. A spin rewrites two windings at UNCHANGED arity with no
/// corner rewrite of its own, so `Mesh.resizePolyVertexMaps` takes its
/// KEEP branch and the per-corner values stay on the slots they were on —
/// i.e. the FORWARD leaves UVs on rotated corners. The winding writer does
/// NOT change that and was never going to: it records what the pre-op corners
/// held so the REVERSE can put them back, and the reverse is now exact. The
/// forward half is a separate, PRE-EXISTING question about what a spin should
/// do to a UV — nothing in this stage measured the reference on it — and it is
/// recorded as a divergence in `doc/behavior_gap_registry.md` rather than
/// papered over here. Executable statement of both halves:
/// `tests/unit/flip_and_spin_delta_test.d`, the "spin: the forward LEAVES the
/// UV plane where it was" cell.
class MeshSpinEdge : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;      // the hatch's arm only
    private RecordedUndo     undo_;
    /// The forward SUCCEEDED — see `commands/mesh/flip.d` for why this bit is
    /// not derivable from the two images.
    private bool             applied_;

    /// THE PRE-OP EDGE SELECTION PLANE, HELD DENSELY BY THE COMMAND, endpoint-
    /// keyed: flat `[a, b, order]` triples for every selected edge, plus the
    /// counter. Captured on the recording arm only.
    ///
    /// WHY THE COMMAND HOLDS IT AT ALL — the migration would otherwise restore
    /// LESS than the snapshot did, and the parity fixture is what said so
    /// rather than a review. `repointToEdgeKeys` DESTROYS the pre-op edge
    /// selection (that is its job: it points the selection at the spin's
    /// product), and the op-log has nothing that puts it back. Measured
    /// against `undo_parity/create_stable.json`, frozen on the snapshot path:
    /// with `Kind.EdgeSelByEnds` alone the Select BIT came back and the
    /// `edgeSelectionOrder` STAMP came back as 1 where the snapshot had 3,
    /// because that kind's restore re-selects through `selectEdge`, which mints
    /// a FRESH stamp off the counter. No kind carries a selection-order stamp —
    /// `patchSelection` deliberately does not, and a unit gate in
    /// `l1_declined_census_test.d` asserts it does not — so this is the
    /// third `path` value, `dense-inline`, for ONE plane, next to a delta that
    /// owns the rest.
    ///
    /// AND IT IS THE WHOLE SELECTION, NOT ONLY THE EDGES, for a reason the
    /// fixture also supplied: `repointToEdgeKeys` opens with
    /// `repointToNothing`, which clears ALL THREE domains
    /// (`selection_product.d`) — so a spin over an edge selection silently
    /// destroys the FACE selection too, and the second run of the oracle caught
    /// `faceMarks[7]`'s Select bit missing after the undo. `SelectionSnapshot`
    /// is the instrument that already carries all three domains, both order
    /// arrays and all three counters, and re-zeroes a stamp whose element the
    /// bulk setter refused as hidden.
    ///
    /// THE EDGE HALF IS THEN OVERRIDDEN BY ENDPOINTS, `delete.d`'s established
    /// shape: `SelectionSnapshot` is INDEX-keyed and `finalize`'s
    /// `rebuildEdges` gives the reverted mesh a fresh edge index space, so its
    /// edge half can name the wrong edges. Unlike `delete.d`'s
    /// `restoreSelectedEdgeEnds` — a `selectEdge` loop, which mints a FRESH
    /// order stamp per edge and so restores the bit but not the rank — this
    /// override carries the stamp, because the frozen oracle compares it.
    private SelectionSnapshot preSel_;
    private uint[]            preEdgeSel_;   // [a, b, order] triples
    private int               preEdgeCounter_;

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (see `MeshFlip`).
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "mesh.spinEdge"; }

    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry;
    }

    /// See `MeshFlip.isOperationInverse` — a cheap tell, not the observable.
    override bool isOperationInverse() const { return undo_.armed(); }

    override string label() const {
        final switch (editMode) {
            case EditMode.Vertices: return "Spin Edges";   // guard below blocks this path
            case EditMode.Edges:    return "Spin Edges";
            case EditMode.Polygons: return "Spin Polygons";
        }
    }

    /// EVERY REFUSAL IS RESOLVED HERE, BEFORE THE BATCH OPENS.
    ///
    /// Under the snapshot this file could afford to discover a refusal after
    /// the capture and simply drop the image. Under a delta it cannot: a
    /// `return` out of an open batch leaves the destructor to pop the frame
    /// and tick `changeBus.batchLeaks` (which the suite asserts is 0), and a
    /// `false` from a Model entry's `revert` makes `CommandHistory.undo`
    /// discard that entry AND its whole trailing suffix. So the operand is
    /// computed, and every gate answered, above `runMapEdit`; the kernel below
    /// may only answer false for the one condition that is a true no-op
    /// (`affected == 0`, where `spinEdgesByKeys` wrote nothing).
    ///
    /// The TRANSACTION gate in particular stays pre-flight, which is what its
    /// own note in this file has always argued for on a different ground:
    /// neither of two overlapping spins FAILS, so there is no failure for any
    /// undo image to react to, and the conflict is visible only in the
    /// incidence of the ORIGINAL mesh.
    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        // Vertex mode has no meaningful target — guard like split_edge.d:40.
        if (editMode == EditMode.Vertices) return false;

        immutable bool edgeBranch = (editMode == EditMode.Edges);
        ulong[] keys;

        if (edgeBranch) {
            // Collect endpoint keys up front — edge indices shift after each spin.
            ulong[] selKeys;
            foreach (size_t i, bool sel; mesh.selectedEdges) {
                if (sel) selKeys ~= edgeKey(mesh.edges[i][0], mesh.edges[i][1]);
            }
            if (selKeys.length == 0) return false;

            // TRANSACTION (task 1220, ledger row 10). A spin rewrites BOTH of
            // its edge's faces, so two selected edges that share a face are two
            // rewrites of one face. Applied one after another — which is what
            // the loop below does, each spin rebuilding edges and loops before
            // the next reads them — the second spin acts on a face the first
            // already replaced, and the mesh that comes out depends on the
            // order the edges happened to be selected in. The reference
            // CANCELS the whole command in that case and changes nothing;
            // measured on a 3x3 grid, two interior edges whose face pairs
            // overlap. Its control — the same two edges with DISJOINT pairs —
            // spins both on both engines, so what is refused is the overlap and
            // not multi-edge spin.
            //
            // This is a GATE and not a rollback ON PURPOSE, and the difference
            // is measured, not stylistic: neither of the two overlapping spins
            // FAILS here. Both return true and both apply, so there is no
            // failure for a revert to react to — `MeshSnapshot` would restore
            // nothing because nothing reported trouble. The conflict is only
            // visible BEFORE the first spin, in the incidence of the original
            // mesh.
            //
            // Scoped to the EDGES branch, which is the gesture the reference
            // was driven through (`edge.spinQuads` over an edge selection). The
            // polygon branch below is our own extension — its operand is
            // derived from a face selection, not named edge by edge — and no
            // measurement covers it, so it is left sequential rather than given
            // an invented rule.
            {
                auto edgeFaces = mesh.buildEdgeFaces();
                bool[int] faceSeen;
                foreach (k; selKeys) {
                    auto p = k in edgeFaces;
                    if (p is null) continue;
                    immutable int fA = (*p)[0], fB = (*p)[1];
                    if (fA < 0 || fB < 0) continue;   // boundary — spins nothing
                    if (fA in faceSeen || fB in faceSeen)
                        return false;                 // nothing was mutated
                    faceSeen[fA] = true;
                    faceSeen[fB] = true;
                }
            }

            // Task 1471: ONE bulk call, not one `mesh.spinEdge` per key. The
            // per-key loop paid `rebuildEdges` + `buildLoops` + a commit — all
            // three O(M) — for every edge, which is the measured exponent 1.98.
            // `spinEdgesByKeys` pays them once per ROUND. The gate above already
            // guarantees pairwise-disjoint face pairs, so this branch settles in
            // ONE round and its result is bit-identical; `selKeys` are handed
            // over UNSORTED on purpose (see the kernel's note — sorting would
            // rewrite `edgeSelectionOrder` through `repointToEdgeKeys` below).
            keys = selKeys;

        } else {  // EditMode.Polygons
            if (!mesh.hasAnySelectedFaces()) return false;

            // Gather interior edges: both incident faces must be selected.
            bool[ulong] seen;
            ulong[] intKeys;
            foreach (uint fi; 0 .. cast(uint)mesh.faces.length) {
                if (!mesh.isFaceSelected(fi)) continue;
                foreach (k; 0 .. mesh.faces[fi].length) {
                    uint a = mesh.faces[fi][k];
                    uint b = mesh.faces[fi][(k + 1) % mesh.faces[fi].length];
                    ulong ek = edgeKey(a, b);
                    if (ek in seen) continue;
                    seen[ek] = true;
                    uint ei = mesh.edgeIndexByKey(ek);
                    if (ei == ~0u) continue;
                    // Both incident faces must be selected.
                    // Bounded write: the same collector as
                    // `Mesh.spinEdgeRings_`, and bounded for the same reason —
                    // `EdgeFaceRange` does NOT cap itself at two any more (task
                    // 1290 gave it a `_spill`), so a `uint[2]` filled by a bare
                    // `[n++]` would overflow. The question here is "exactly two
                    // or not", which `nif != 2` answers; a caller that needs
                    // the COUNT must use `edgePolygonCounts` — the ring walk
                    // under-reports a non-manifold fan as one face.
                    uint[2] ifaces; uint nif = 0;
                    foreach (f; mesh.facesAroundEdge(ei)) {
                        if (nif >= 2) { nif = 3; break; }
                        ifaces[nif++] = f;
                    }
                    if (nif != 2) continue;
                    if (!mesh.isFaceSelected(ifaces[0]) ||
                        !mesh.isFaceSelected(ifaces[1])) continue;
                    intKeys ~= ek;
                }
            }

            import std.algorithm : sort;
            sort(intKeys);   // deterministic processing order — OURS, not the
                             // kernel's: `spinEdgesByKeys` processes in caller
                             // order precisely so the Edges branch above can
                             // keep its own.

            // Task 1471, and this branch is where the 66 minutes were measured
            // (`polygons/half` on an n=316 grid). Rounds change WHAT this
            // branch produces on an overlapping face selection — the spins now
            // group into rounds instead of running straight through — and that
            // is taken deliberately: no reference fixture drives this branch
            // (all four frozen spin fixtures select `mode: "edges"`), it is our
            // own extension by the comment above, and today's answer already
            // depends on the order the edges happen to be collected in.
            keys = intKeys;
        }

        // A key list that resolves to nothing is NOT refused here: whether a
        // key still names a spinnable edge is a question about the mesh the
        // kernel walks (`spinEdgesByKeys` re-derives incidence each round), and
        // answering it twice would be a second, unnamed guard in front of the
        // one under test. The kernel's `affected == 0` is a true no-op.
        applied_ = runMapEdit(mesh, undo_, snap, MeshEditScope.Geometry,
                              (ref MeshEditBatch ed) => runKernel(ed, keys, edgeBranch));
        return applied_;
    }

    /// The one mutating body, under whichever arm `runMapEdit` chose.
    private bool runKernel(ref MeshEditBatch ed, ulong[] keys, bool edgeBranch) {
        // The pre-op EDGE selection plane, ENDPOINT-keyed and only on the
        // recording arm (the redo arm keeps the first capture; the hatch has
        // the snapshot). Endpoint-keyed rather than index-keyed because
        // `finalize`'s `rebuildEdges` gives the reverted mesh a fresh edge
        // index space, so an index-keyed restore would name the wrong edges —
        // the same reason `mesh_ops/extrude.d` records `EdgeSelByEnds` by ends.
        // See the field's own note for why the command holds this densely.
        const bool rec = ed.recording();
        if (rec) {
            preSel_ = SelectionSnapshot.capture(ed.mesh);
            captureEdgeSelection(ed.mesh);
        }

        ulong[] productKeys;
        immutable size_t affected = ed.mesh.spinEdgesByKeys(keys, productKeys);
        if (affected == 0) return false;

        if (edgeBranch) {
            // Post-op (task 1180): the old edge no longer exists — re-point the
            // selection at the PRODUCT, the new diagonal. Clearing instead (what
            // this line used to do) is what made two spins of one edge in a row
            // a no-op on the second: `cmd_selection_product/spin_twice`.
            repointToEdgeKeys(&ed.mesh(), productKeys);
        }
        // Polygon scope: face indices are stable (no faces added/removed), so
        // the existing face selection is kept and repeated Spin Polygons works.

        return true;
    }

    /// Snapshot the edge selection plane as `[a, b, order]` triples.
    ///
    /// PRE-SIZED in one pass with a counting pass in front of it, not grown by
    /// `~=`: an element-wise append is a runtime call per element that
    /// `reserve` does not remove (task 2160). A whole-mesh edge selection on a
    /// lane-sized mesh is hundreds of thousands of triples.
    private void captureEdgeSelection(ref Mesh m) {
        import std.array : uninitializedArray;
        size_t n = 0;
        foreach (ei; 0 .. m.edges.length) if (m.isEdgeSelected(ei)) ++n;
        preEdgeCounter_ = m.edgeSelectionOrderCounter;
        preEdgeSel_     = uninitializedArray!(uint[])(n * 3);
        size_t w = 0;
        foreach (ei; 0 .. m.edges.length) {
            if (!m.isEdgeSelected(ei)) continue;
            preEdgeSel_[w++] = m.edges[ei][0];
            preEdgeSel_[w++] = m.edges[ei][1];
            preEdgeSel_[w++] = ei < m.edgeSelectionOrder.length
                             ? cast(uint) m.edgeSelectionOrder[ei] : 0u;
        }
        assert(w == preEdgeSel_.length,
            "MeshSpinEdge.captureEdgeSelection: the counting pass and the "
          ~ "write pass disagree");
    }

    /// Put the whole plane back, AFTER the delta replay has re-derived `edges`.
    ///
    /// ONE bulk `selectEdgesFrom` and then the stamps written directly: the
    /// per-edge `selectEdge` loop would publish a change per element, which is
    /// the task 1330 shape that makes a bulk path quadratic, and it would mint
    /// fresh stamps that this method then has to overwrite anyway.
    private void restoreSelection() {
        if (!preSel_.filled) return;
        // All three domains, their stamps and their counters, index-keyed.
        preSel_.restore(*mesh);

        // …and then the ORDER ARRAYS WHOLESALE, because `SelectionSnapshot`
        // restores LESS of them than `MeshSnapshot` did and the frozen oracle
        // measures the difference. Its tail re-zeroes the stamp of every
        // element that is not selected; a stamp on an UNSELECTED element is a
        // state the mesh's own setters do not produce, but `MeshSnapshot`
        // copied the arrays whole and so put it back, and this command's
        // parity cell froze `faceSelectionOrder [0,0,11,0,0,0,23,1,0]` against
        // the `[0,0,0,0,0,0,0,1,0]` the re-zero produces.
        //
        // The guard that tail exists for is KEPT, narrowed to the case it was
        // written for: an element the capture says was selected and the bulk
        // setter REFUSED (the Select ∧ Hide = ∅ invariant) must not keep a
        // stale rank. Everything else is restored verbatim, which is what
        // "no less than the snapshot" means here.
        mesh.vertexSelectionOrder = preSel_.vertexSelectionOrder.dup;
        mesh.edgeSelectionOrder   = preSel_.edgeSelectionOrder.dup;
        mesh.faceSelectionOrder   = preSel_.faceSelectionOrder.dup;
        mesh.vertexSelectionOrder.length = mesh.vertices.length;
        mesh.edgeSelectionOrder.length   = mesh.edges.length;
        mesh.faceSelectionOrder.length   = mesh.faces.length;
        foreach (i; 0 .. mesh.vertexSelectionOrder.length)
            if (i < preSel_.selectedVertices.length && preSel_.selectedVertices[i]
                && !mesh.isVertexSelected(i)) mesh.vertexSelectionOrder[i] = 0;
        foreach (i; 0 .. mesh.faceSelectionOrder.length)
            if (i < preSel_.selectedFaces.length && preSel_.selectedFaces[i]
                && !mesh.isFaceSelected(i)) mesh.faceSelectionOrder[i] = 0;
        // …then the EDGE half again, by endpoints, because the index-keyed one
        // above may have named the wrong edges after `rebuildEdges`.
        bool[] want = new bool[](mesh.edges.length);
        uint[] slot = new uint[](mesh.edges.length);
        for (size_t k = 0; k + 2 < preEdgeSel_.length; k += 3) {
            immutable uint ei = mesh.edgeIndexByKey(
                edgeKey(preEdgeSel_[k], preEdgeSel_[k + 1]));
            // A pre-op edge that the reverted mesh does not have is SKIPPED,
            // not asserted on: `revert()` is also reached on the empty-delta
            // arm, where nothing was replayed and the mesh is whatever the
            // forward left. Losing one edge's bit there is strictly better
            // than aborting the process out of an undo.
            if (ei == ~0u || ei >= want.length) continue;
            want[ei] = true;
            slot[ei] = preEdgeSel_[k + 2];
        }
        mesh.selectEdgesFrom(want);
        foreach (ei; 0 .. want.length)
            if (want[ei] && ei < mesh.edgeSelectionOrder.length)
                mesh.edgeSelectionOrder[ei] = cast(int) slot[ei];
        mesh.edgeSelectionOrderCounter = preEdgeCounter_;
    }

    override bool revert() {
        // `…EmptyOk` rather than `revertMapEdit`, for the reason spelled out in
        // `commands/mesh/flip.d`: a `false` from a Model entry's `revert()`
        // truncates the undo stack instead of declining one step (regression
        // 0099), so the empty-delta case must answer per this command's own
        // forward rather than inherit a `false` from the absence of both images.
        if (!revertMapEditEmptyOk(mesh, undo_, snap, applied_)) return false;
        // ONLY on the delta arm. The hatch's `MeshSnapshot.restore` already put
        // the whole `edgeMarks` word and both order arrays back, and re-running
        // the overlay over it would be a second writer for a plane that is
        // already correct.
        if (undo_.armed()) restoreSelection();
        return true;
    }
}
