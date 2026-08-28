module commands.mesh.spin_edge;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import selection_product : repointToEdgeKeys;
import mesh_edit_delta : MeshEditScope;
import commands.mesh.position_undo : RecordedUndo;
import commands.mesh.map_edit_undo : runMapEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

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
    private RecordedUndo     undo_;

    /// THE PRE-OP SELECTION, HELD DENSELY BY THE COMMAND.
    ///
    /// WHY THE COMMAND HOLDS IT AT ALL — the migration would otherwise restore
    /// LESS than the snapshot did, and the parity fixture is what said so
    /// rather than a review. `repointToEdgeKeys` DESTROYS the pre-op edge
    /// selection (that is its job: it points the selection at the spin's
    /// product), it opens with `repointToNothing` which clears ALL THREE
    /// domains, and the op-log has nothing that puts any of it back. The three
    /// measured losses, the reason `Kind.SelectionDelta` cannot carry them and
    /// the endpoint re-keying all live at `commands/mesh/selection_undo.d` —
    /// this file was where they were found, and Stage L2-c moved the mechanism
    /// there when seven more commands turned out to need it.
    private DenseSelectionUndo preSel_;

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
        const bool applied_ = runMapEdit(this, mesh, undo_, MeshEditScope.Geometry,
                              (ref MeshEditBatch ed) => runKernel(ed, keys, edgeBranch));
        return applied_;
    }

    /// The one mutating body, under whichever arm `runMapEdit` chose.
    private bool runKernel(ref MeshEditBatch ed, ulong[] keys, bool edgeBranch) {
        // The pre-op selection, on the RECORDING arm only: the redo arm must
        // keep the first capture (a second would image the POST-spin
        // selection) and the hatch has the whole-mesh snapshot. See
        // `commands/mesh/selection_undo.d` for why it is dense, why it is all
        // three domains, and why the edge half is re-keyed by endpoints.
        if (ed.recording() && !preSel_.filled()) preSel_.capture(ed.mesh);

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

    protected override void revertImpl() {
        // Armed by construction (task 2500): `runMapEdit` raises the flag only
        // when the delta came back NON-EMPTY, and `Command.revert` answers the
        // empty case — and the never-applied case — before this body is entered.
        undo_.revert(*mesh);
        preSel_.restore(*mesh);
    }
}
