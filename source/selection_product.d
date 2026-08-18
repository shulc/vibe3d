module selection_product;

import mesh : Mesh, edgeKey;

// source/selection_product.d — "what does a command leave selected?"
//
// THE LAW, as measured (task 1180; dogfood ledger rows 2, 3 and 12, frozen in
// `tests/fixtures/cmd_selection_product.json`,
// `tests/fixtures/edge_bevel_post_selection.json` and
// `tests/fixtures/loop_slice_post_selection.json`):
//
//     After a command, the selection names the command's PRODUCT — the merged
//     face, the new face, the new diagonal, the new band, the new loop — and
//     the INPUT it consumed is gone from it.
//
// Why it is worth a module rather than five inlined clears. Its bite is not
// cosmetic: a modelling session is driven by "operate on whatever the last op
// left selected", so a command that leaves the WRONG thing selected diverges
// at the NEXT step, not at its own. The smallest reproduction is two spins of
// one edge in a row: we used to clear the edge selection after a spin, so the
// second spin had nothing to spin and refused. Re-selecting the product by
// coordinate between the two made it converge exactly — which is how the
// measurement localised the fault to the SELECTION and not to the spin
// arithmetic (`cmd_selection_product`'s `spin_reselect` control).
//
// WHAT "THE PRODUCT" IS, IS PER-COMMAND, and pretending otherwise would be a
// worse abstraction than none. The measurement does not support one uniform
// rule, and the disagreements are load-bearing:
//
//   * spin (edge input)     → the new DIAGONAL. No new vertices exist, and the
//                             reference selects none.
//   * merge (poly input)    → the merged FACE.
//   * make-polygon (VERTEX
//     input)                → the new FACE. The product is a dimension ABOVE
//                             the input, which is why this one alone promotes
//                             the selection TYPE (see the note on that below).
//   * vertex split (vertex
//     input)                → NOTHING. The reference clears and selects
//                             neither copy; `repointToNothing` is that answer
//                             spelled out, not an omission.
//   * edge bevel (edge
//     input)                → the new band, expressed ONE DIMENSION DOWN: its
//                             edges and their vertices, and NOT its faces
//                             (`repointToFaceBorder`).
//   * split face (VERTEX
//     input)                → nothing new is selected, and the SPLIT FACE's own
//                             selection does not survive onto its two halves —
//                             every other selected face is untouched
//                             (`dropConsumedFaces`). Two frozen cases pin that
//                             from opposite sides; see the note there.
//   * loop slice (poly
//     input)                → the sliced faces (which our kernel already
//                             selects) PLUS the new loop's edges and vertices,
//                             additively (`addNewLoopEdgesAndVerts`) — while
//                             the one-shot loop COMMANDS take the edges leg
//                             only (`addNewLoopEdges`), because the two
//                             captures of that operation disagree about the
//                             vertex layer. See the note on those two.
//
// So this module carries the MECHANISM — clear the right layers, select by a
// key that survives an index rebuild, do not disturb what the law leaves
// alone — and each command names its own product. The mechanism is here so a
// sixth command joins the family by choosing a verb, not by re-deriving which
// three arrays to clear in which order.
//
// ONE CAVEAT ABOUT THE VERTEX LAYER, stated because the captures disagree and
// the code silently encodes the choice. The row-12 capture (thin commands) and
// the 0476 capture (one-shot loop commands) each read what looks like ONE
// selection layer and report zero vertices; the row-2/3 capture (bevel, band
// loop slice) read all three and report the band's/loop's vertices alongside
// its edges. All are honoured verbatim — `repointToEdgeKeys` and
// `addNewLoopEdges` select no vertices, `repointToFaceBorder` and
// `addNewLoopEdgesAndVerts` do — because the fixtures DISCRIMINATE: add the
// spin diagonal's endpoints and `cmd_selection_product` reddens; drop the band's
// and `edge_bevel_post_selection` reddens. Both were run. If a thin-command
// capture is ever re-taken with a three-layer readback and reports endpoints
// too, this is the asymmetry to collapse — see `addNewLoopEdges` for the single
// measurement that would settle it.
//
// SELECTION TYPE. Re-pointing is a geometry SELECTION, so where it changes the
// element type it must go through the app's `promoteGeometryType` funnel (which
// touches the `SelType` ordering and re-derives `editMode` WITHOUT dropping the
// active tool) — never by writing `editMode`. That funnel is injected into the
// one command that needs it (`mesh.makePolygon`) exactly as `select.convert`
// takes it; this module deliberately does NOT reach for it, so that it stays
// pure mesh-selection mechanism with no app dependency.

/// Select nothing: the answer for a command whose product is not addressable
/// (a vertex split's two coincident copies — the reference selects neither).
/// Clears all three layers; the element TYPE is untouched.
void repointToNothing(Mesh* m) {
    m.syncSelection();
    m.clearVertexSelection();
    m.clearEdgeSelection();
    m.clearFaceSelection();
}

/// Re-point at `product` FACES, exclusively: every layer is cleared first, so
/// the input the command consumed cannot survive in another layer.
void repointToFaces(Mesh* m, scope const(uint)[] product) {
    repointToNothing(m);
    foreach (fi; product)
        if (fi < m.faces.length) m.selectFace(cast(int) fi);
}

/// Drop the given faces from the selection and touch NOTHING else — the shape
/// of "the input it consumed is gone" for a command whose kernel hands its
/// selection bit down to the faces that REPLACED the consumed one.
///
/// `mesh.splitFace` is that command. `rebuildFacesWithChordSplits` copies the
/// split face's Select bit onto BOTH halves, so a split whose target happened
/// to be selected left two selected polygons behind. The reference leaves
/// neither.
///
/// TWO FROZEN CASES PIN THIS FROM BOTH SIDES, and the pair is why this is a
/// scalpel and not `repointToNothing`:
///   * `poly_split_parity.json` / `split_hex_after_merge` — merge (which now
///     leaves the merged face selected), then split THAT face: 0 polygons
///     selected afterwards. Carry the bit down and you get 2.
///   * `material_inheritance_parity.json` / `mat_two_then_split` — select the
///     FAR face, then split the NEAR one: the far face is still selected
///     afterwards. Clear the whole polygon layer and you get 0.
/// So neither "carry it down" nor "clear everything" is the law; "the consumed
/// face's own selection does not survive it" is, and it is the only rule that
/// satisfies both. The second case also settles a question the first one alone
/// could not: a geometry SELECT in another element mode does NOT clear the
/// polygon layer in the reference, so this belongs in the command and not in
/// the selection machinery.
void dropConsumedFaces(Mesh* m, scope const(uint)[] consumed) {
    m.syncSelection();
    foreach (fi; consumed)
        if (fi < m.faces.length) m.deselectFace(cast(int) fi);
}

/// Re-point at product EDGES named by canonical endpoint KEYS, exclusively.
///
/// Keys, not indices, because every kernel in this family rebuilds `edges[]`
/// (and therefore every edge index) before the caller gets control back — a
/// spin does it once per spun edge, so an index collected during the loop is
/// already stale by the next iteration. A key whose edge no longer exists
/// (a later spin consumed an earlier product) is skipped, not asserted on.
void repointToEdgeKeys(Mesh* m, scope const(ulong)[] keys) {
    repointToNothing(m);
    foreach (k; keys) {
        immutable uint ei = m.edgeIndexByKey(k);
        if (ei != ~0u) m.selectEdge(cast(int) ei);
    }
}

/// Re-point at the EDGES and VERTICES of the `product` faces, exclusively —
/// the product expressed one dimension DOWN, and the shape an edge bevel
/// leaves behind: the band's 10 edges and the 8 vertices they span, with the
/// band's own 3 faces NOT selected.
///
/// Every edge of a bevel band is new (all four corners of a chamfer quad are
/// slid copies), so "the border of the product faces" and "the new edges" name
/// the same set here; the former is used because it is the one the kernel can
/// hand over without a second pass.
void repointToFaceBorder(Mesh* m, scope const(uint)[] product) {
    m.syncSelection();
    // Read the rings BEFORE clearing: `product` is a face-index list, and the
    // clears below do not move faces, but collecting first keeps this honest
    // if a future caller passes indices derived from the selection itself.
    bool[] wantVert;
    wantVert.length = m.vertices.length;
    ulong[] wantEdge;
    foreach (fi; product) {
        if (fi >= m.faces.length) continue;
        const ring = m.faces[fi];
        foreach (c; 0 .. ring.length) {
            immutable uint a = ring[c];
            immutable uint b = ring[(c + 1) % ring.length];
            if (a < wantVert.length) wantVert[a] = true;
            if (b < wantVert.length) wantVert[b] = true;
            wantEdge ~= edgeKey(a, b);
        }
    }
    repointToNothing(m);
    foreach (vi; 0 .. wantVert.length)
        if (wantVert[vi]) m.selectVertex(cast(int) vi);
    foreach (k; wantEdge) {
        immutable uint ei = m.edgeIndexByKey(k);
        if (ei != ~0u) m.selectEdge(cast(int) ei);
    }
}

/// ADDITIVELY select the EDGES of the loop a slice just inserted: every edge
/// BOTH of whose endpoints is a vertex the cut appended (index >=
/// `firstNewVert`, captured immediately before the cut).
///
/// This is the rule task 0476 measured for the ONE-SHOT loop commands
/// (`mesh.addLoop` / `mesh.loopSlice`): it names the loop's transverse edges
/// plus, for a multi-loop cut, the along-rail segments between consecutive loop
/// midpoints (count 1 -> 4 edges; count 3 -> 12 transverse + 8 along-rail).
///
/// TWO SPELLINGS, ONE OPERATION — and the second one is below, deliberately.
/// The 0476 capture states, as a positive claim, that the reference leaves the
/// loop's EDGES and NO VERTICES selected (`tests/test_loop_slice.d` case 7
/// asserts `selectedVertices.length == 0` in those words). The row-3 capture of
/// the same family — a band slice driven through the interactive tool —
/// measured all three layers and found the loop's 10 VERTICES held alongside
/// its 9 edges (`tests/fixtures/loop_slice_post_selection.json`).
///
/// Those two cannot both be the whole truth, and task 1180 did not have the
/// evidence to pick: the likeliest explanation is that the 0476 probe read only
/// the ACTIVE selection layer (its own note records "active selmode = edge"),
/// so its zero is "nobody looked" rather than "nothing selected" — but that is
/// a hypothesis, and the alternative, that the one-shot command and the band
/// tool genuinely differ, is not excluded. So each site keeps the law its own
/// capture measured, and the disagreement is written down here instead of being
/// averaged away. RESOLVING IT NEEDS ONE MEASUREMENT: drive `mesh.addLoop` in
/// the reference with a three-layer selection readback. If the vertices are
/// there, delete this function and let both callers use the one below.
void addNewLoopEdges(Mesh* m, uint firstNewVert) {
    m.syncSelection();
    foreach (ei, e; m.edges)
        if (e[0] >= firstNewVert && e[1] >= firstNewVert)
            m.selectEdge(cast(int) ei);
}

/// ADDITIVELY select the loop a slice just inserted, EDGES AND VERTICES — the
/// law the row-3 capture measured for the interactive Loop Slice tool (see the
/// conflict note above for why this is not simply the same function).
///
/// Additive on purpose: the slice's product spans two dimensions at once and
/// the reference holds both — the sliced FACES (which the tool selects itself,
/// under its own "select new" switch) and the new loop's edges and vertices.
/// Clearing here would throw the face half away.
void addNewLoopEdgesAndVerts(Mesh* m, uint firstNewVert) {
    addNewLoopEdges(m, firstNewVert);
    foreach (vi; firstNewVert .. m.vertices.length)
        m.selectVertex(cast(int) vi);
}

// ---------------------------------------------------------------------------
// Mechanism unittests. The end-to-end LAW is pinned by three HTTP fixtures
// (`cmd_selection_product`, `edge_bevel_post_selection`,
// `loop_slice_post_selection`); what these add is the part a fixture cannot
// reach cheaply — that the verbs mean what their names say, one layer at a
// time, on a mesh small enough to read.
// ---------------------------------------------------------------------------
version (unittest) {
    import math : Vec3;

    /// Two quads sharing the edge 1-4, on the XZ plane. Same plate the
    /// selection-product fixtures use, built here without an app.
    private Mesh twoQuadPlate() {
        Mesh m;
        foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0),
                     Vec3(0, 0, 1), Vec3(1, 0, 1), Vec3(2, 0, 1)])
            m.addVertex(p);
        m.addFace([0u, 1u, 4u, 3u]);
        m.addFace([1u, 2u, 5u, 4u]);
        m.buildLoops();
        m.resetSelection();
        return m;
    }
}

unittest { // re-pointing is EXCLUSIVE: nothing of the input survives in any layer
    auto m = twoQuadPlate();
    m.selectVertex(0);
    m.selectEdge(cast(int) m.edgeIndex(1, 4));
    m.selectFace(0);

    repointToFaces(&m, [1u]);

    assert(m.isFaceSelected(1) && !m.isFaceSelected(0),
        "repointToFaces must select the product face and only it");
    foreach (vi; 0 .. m.vertices.length)
        assert(!m.isVertexSelected(vi),
            "repointToFaces must clear the VERTEX layer too — the input a "
          ~ "command consumed must not survive in another layer");
    foreach (ei; 0 .. m.edges.length)
        assert(!m.isEdgeSelected(ei), "repointToFaces must clear the EDGE layer");
}

unittest { // edge KEYS, and a key whose edge is gone is skipped, not fatal
    auto m = twoQuadPlate();
    m.selectFace(0);

    immutable ulong live  = edgeKey(1, 4);
    immutable ulong ghost = edgeKey(0, 2);   // no such edge on this plate
    assert(m.edgeIndexByKey(ghost) == ~0u, "setup: 0-2 must not be an edge");

    repointToEdgeKeys(&m, [live, ghost]);

    size_t nSel = 0;
    foreach (ei; 0 .. m.edges.length) if (m.isEdgeSelected(ei)) ++nSel;
    assert(nSel == 1, "exactly the one live product edge must be selected");
    assert(m.isEdgeSelected(m.edgeIndexByKey(live)), "…and it must be that one");
    assert(!m.isFaceSelected(0), "the consumed face selection must be gone");
}

unittest { // the bevel shape: a product face's BORDER, and not the face itself
    auto m = twoQuadPlate();

    repointToFaceBorder(&m, [0u]);   // quad 0-1-4-3

    foreach (fi; 0 .. m.faces.length)
        assert(!m.isFaceSelected(fi),
            "repointToFaceBorder must leave NO face selected — that is the "
          ~ "whole difference from repointToFaces, and it is what ledger row 2 "
          ~ "measured");
    foreach (vi; [0, 1, 3, 4])
        assert(m.isVertexSelected(vi), "quad 0's corners must be selected");
    foreach (vi; [2, 5])
        assert(!m.isVertexSelected(vi), "the other quad's corners must not be");
    foreach (ei; 0 .. m.edges.length) {
        immutable bool ofQuad0 =
            (m.edges[ei][0] != 2 && m.edges[ei][1] != 2) &&
            (m.edges[ei][0] != 5 && m.edges[ei][1] != 5);
        assert(m.isEdgeSelected(ei) == ofQuad0,
            "exactly quad 0's four edges must be selected");
    }
}

unittest { // the two loop verbs differ in the VERTEX layer, and ONLY there
    // They exist as a pair because two captures of one operation disagree
    // about that layer (see addNewLoopEdges). Fold them together and this
    // fails — which is the point: the difference is a recorded measurement,
    // not an accident waiting to be tidied up.
    auto a = twoQuadPlate();
    addNewLoopEdges(&a, 3);            // pretend verts 3,4,5 are the new ones
    auto b = twoQuadPlate();
    addNewLoopEdgesAndVerts(&b, 3);

    foreach (ei; 0 .. a.edges.length)
        assert(a.isEdgeSelected(ei) == b.isEdgeSelected(ei),
            "the two verbs must agree edge-for-edge");
    size_t nEdges = 0;
    foreach (ei; 0 .. a.edges.length) if (a.isEdgeSelected(ei)) ++nEdges;
    assert(nEdges == 2, "3-4 and 4-5 are the only edges with BOTH ends new");

    foreach (vi; 0 .. a.vertices.length)
        assert(!a.isVertexSelected(vi),
            "addNewLoopEdges must touch no vertex (task 0476's measured law)");
    foreach (vi; 0 .. b.vertices.length)
        assert(b.isVertexSelected(vi) == (vi >= 3),
            "addNewLoopEdgesAndVerts must select exactly the new vertices "
          ~ "(ledger row 3's measured law)");
}
