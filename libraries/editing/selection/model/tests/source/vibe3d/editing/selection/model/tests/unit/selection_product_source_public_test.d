module vibe3d.editing.selection.model.tests.unit.selection_product_source_public_test;

import vibe3d.mesh.core.mesh : Mesh, edgeKey;
import vibe3d.editing.selection.model.selection_product;

// ---------------------------------------------------------------------------
// Mechanism unittests. The end-to-end LAW is pinned by three HTTP fixtures
// (`cmd_selection_product`, `edge_bevel_post_selection`,
// `loop_slice_post_selection`); what these add is the part a fixture cannot
// reach cheaply — that the verbs mean what their names say, one layer at a
// time, on a mesh small enough to read.
// ---------------------------------------------------------------------------
version (unittest) {
    import vibe3d.util.math.math : Vec3;

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
