// selection_undo — the DENSE selection image a delta-migrated command holds
// beside its op-log (task 1903 Stage L2).
//
// EXTRACTED FROM `spin_edge.d` AT STAGE L2-c, NOT RE-WRITTEN. Stage L2-b
// spelled this once, privately, for one command, after the frozen parity
// oracle caught it restoring LESS than the snapshot did — three times in a
// row. Seven more L2 commands destroy selection state on their forward
// (`split_edge`'s `resetSelection`, `vertex_split`'s and `make_polygon`'s
// `repointTo*`, `split_face`'s `dropConsumedFaces`, `vertex_new`'s
// `clearVertexSelection` + `selectVertex`, `spikey`'s appended-face select,
// `thicken`'s `syncSelection`), and a private copy per file would be eight
// implementations of one mechanism — the shape `map_edit_undo.d`'s own header
// refuses. The bodies below are L2-b's verbatim; only the home moved.
//
// ---------------------------------------------------------------------------
// WHY DENSE AND NOT `Kind.SelectionDelta`, WHICH ALREADY EXISTS
// ---------------------------------------------------------------------------
// §L2.3's Marks ruling scheduled `Kind.SelectionDelta`'s first production
// publisher for this stage. Stage L2-b MEASURED it against the frozen oracle
// and it does not carry the plane: its restore re-selects through
// `Mesh.selectEdge`, which mints a FRESH order stamp off the counter, so the
// Select BIT came back and `edgeSelectionOrder` came back as 1 where the
// snapshot had 3. NO delta kind carries a selection-order stamp —
// `patchSelection` deliberately does not, and a unit gate in
// `l1_declined_census_test.d` asserts it does not. A migration that adopted it
// would restore less than the `MeshSnapshot` it replaces, and re-freezing the
// oracle to make that green is forbidden outright (§K.8.1).
//
// So the third `path` value, `dense-inline`, for the selection planes, next to
// a delta that owns the rest. That is a statement about the KIND's payload, not
// a preference, and it is the reason this module exists rather than a
// `recordSelectionDelta` call.
//
// ---------------------------------------------------------------------------
// WHY IT IS THE WHOLE SELECTION AND NOT ONE DOMAIN
// ---------------------------------------------------------------------------
// Also measured rather than assumed: `selection_product.repointToEdgeKeys`
// opens with `repointToNothing`, which clears ALL THREE domains — so a spin
// over an EDGE selection silently destroys the FACE selection too, and the
// second run of the oracle caught `faceMarks[7]`'s Select bit missing after
// the undo. `repointToFaces` and `repointToNothing` have the same opening.
// A per-domain capture would have to know which command clears what; this one
// does not.
//
// ---------------------------------------------------------------------------
// THE EDGE HALF IS KEYED BY ENDPOINTS, AND THAT IS NOT A REFINEMENT
// ---------------------------------------------------------------------------
// `SelectionSnapshot` is INDEX-keyed, and `MeshEditDelta.finalize`'s
// `rebuildEdges` gives the reverted mesh a FRESH edge index space — an edge
// index is a position in a derived array. So the index-keyed edge half can
// name the wrong edges, and every command here either splits an edge
// (`add_point`, `split_edge`), adds one (`make_polygon`, `spikey`, `thicken`)
// or moves one (`spin_edge`). The override re-resolves each pre-op edge by its
// two endpoints and re-applies its STAMP — unlike `delete.d`'s
// `restoreSelectedEdgeEnds`, a `selectEdge` loop, which restores the bit and
// mints a fresh rank.
module commands.mesh.selection_undo;

import mesh     : Mesh, edgeKey;
import snapshot : SelectionSnapshot;

/// The pre-op selection of all three domains, both order arrays' worth of
/// stamps and all three counters, with the edge half additionally keyed by
/// endpoints.
///
/// CAPTURED ON THE RECORDING ARM ONLY. The redo arm keeps the first capture
/// (a second one would image the POST-op selection), and the hatch's
/// `MeshSnapshot.restore` already puts every one of these planes back — a
/// second writer over a correct plane is how a restore starts disagreeing
/// with itself.
struct DenseSelectionUndo {
    private SelectionSnapshot sel_;
    private uint[]            edgeEnds_;      // flat [a, b, order] triples
    private int               edgeCounter_;

    /// True once `capture` has run. The command reads this to decide whether
    /// `restore` has anything to put back.
    bool filled() const { return sel_.filled; }

    /// Image the mesh's selection. Idempotent by CALLER contract, not by this
    /// method: calling it twice images the second state, which on a redo is
    /// the post-op one. Guard it with `if (ed.recording() && !undo.filled())`
    /// or with the batch's own recording bit, as every caller here does.
    void capture(ref Mesh m) {
        import std.array : uninitializedArray;
        sel_ = SelectionSnapshot.capture(m);

        // PRE-SIZED, with a counting pass in front of it, and never grown by
        // `~=`: an element-wise append is a runtime call per element that
        // `reserve` does not remove (task 2160). A whole-mesh edge selection
        // on a lane-sized mesh is hundreds of thousands of triples.
        size_t n = 0;
        foreach (ei; 0 .. m.edges.length) if (m.isEdgeSelected(ei)) ++n;
        edgeCounter_ = m.edgeSelectionOrderCounter;
        edgeEnds_    = uninitializedArray!(uint[])(n * 3);
        size_t w = 0;
        foreach (ei; 0 .. m.edges.length) {
            if (!m.isEdgeSelected(ei)) continue;
            edgeEnds_[w++] = m.edges[ei][0];
            edgeEnds_[w++] = m.edges[ei][1];
            edgeEnds_[w++] = ei < m.edgeSelectionOrder.length
                           ? cast(uint) m.edgeSelectionOrder[ei] : 0u;
        }
        assert(w == edgeEnds_.length,
            "DenseSelectionUndo.capture: the counting pass and the write pass "
          ~ "disagree");
    }

    /// Put the whole plane back, AFTER the delta replay has re-derived `edges`.
    ///
    /// ONE bulk `selectEdgesFrom` and then the stamps written directly: a
    /// per-edge `selectEdge` loop would publish a change per element — the task
    /// 1330 shape that makes a bulk path quadratic — and it would mint fresh
    /// stamps this method then has to overwrite anyway.
    void restore(ref Mesh m) {
        if (!sel_.filled) return;
        // All three domains, their stamps and their counters, index-keyed.
        sel_.restore(m);

        // …and then the ORDER ARRAYS WHOLESALE, because `SelectionSnapshot`
        // restores LESS of them than `MeshSnapshot` did and the frozen oracle
        // measures the difference. Its tail re-zeroes the stamp of every
        // element that is not selected; a stamp on an UNSELECTED element is a
        // state the mesh's own setters do not produce, but `MeshSnapshot`
        // copied the arrays whole and so put it back — `spin_edge`'s parity
        // cell froze `faceSelectionOrder [0,0,11,0,0,0,23,1,0]` against the
        // `[0,0,0,0,0,0,0,1,0]` the re-zero produces.
        //
        // The guard that tail exists for is KEPT, narrowed to the case it was
        // written for: an element the capture says was selected and the bulk
        // setter REFUSED (the Select ∧ Hide = ∅ invariant) must not keep a
        // stale rank. Everything else is restored verbatim, which is what "no
        // less than the snapshot" means here.
        m.vertexSelectionOrder = sel_.vertexSelectionOrder.dup;
        m.edgeSelectionOrder   = sel_.edgeSelectionOrder.dup;
        m.faceSelectionOrder   = sel_.faceSelectionOrder.dup;
        m.vertexSelectionOrder.length = m.vertices.length;
        m.edgeSelectionOrder.length   = m.edges.length;
        m.faceSelectionOrder.length   = m.faces.length;
        foreach (i; 0 .. m.vertexSelectionOrder.length)
            if (i < sel_.selectedVertices.length && sel_.selectedVertices[i]
                && !m.isVertexSelected(i)) m.vertexSelectionOrder[i] = 0;
        foreach (i; 0 .. m.faceSelectionOrder.length)
            if (i < sel_.selectedFaces.length && sel_.selectedFaces[i]
                && !m.isFaceSelected(i)) m.faceSelectionOrder[i] = 0;

        // …then the EDGE half again, by endpoints, because the index-keyed one
        // above may have named the wrong edges after `rebuildEdges`.
        bool[] want = new bool[](m.edges.length);
        uint[] slot = new uint[](m.edges.length);
        for (size_t k = 0; k + 2 < edgeEnds_.length; k += 3) {
            immutable uint ei = m.edgeIndexByKey(
                edgeKey(edgeEnds_[k], edgeEnds_[k + 1]));
            // A pre-op edge the reverted mesh does not have is SKIPPED, not
            // asserted on: `revert()` is also reached on the empty-delta arm,
            // where nothing was replayed and the mesh is whatever the forward
            // left. Losing one edge's bit there is strictly better than
            // aborting the process out of an undo.
            if (ei == ~0u || ei >= want.length) continue;
            want[ei] = true;
            slot[ei] = edgeEnds_[k + 2];
        }
        m.selectEdgesFrom(want);
        foreach (ei; 0 .. want.length)
            if (want[ei] && ei < m.edgeSelectionOrder.length)
                m.edgeSelectionOrder[ei] = cast(int) slot[ei];
        m.edgeSelectionOrderCounter = edgeCounter_;
    }
}
