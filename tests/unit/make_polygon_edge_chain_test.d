// make_polygon_edge_chain_test — task 7132 (wave bugfix S11 item 16).
//
// `edgeChainWalk` turns the edge selection into the ring Make Polygon hands
// the kernel. The live witness (`tests/test_make_polygon_edges_key.d`)
// compares the new polygon CYCLICALLY after the kernel's neighbour vote, so
// it cannot see the walk's start, its direction, a duplicated closing
// vertex (the kernel collapses it) or which guard refused: those are pinned
// here, on the walk itself, with exact rings.
//
// Every refusal cell is built so that exactly ONE guard can refuse it; the
// comment on each names the guard and what the walk would answer without it.
module tests.unit.make_polygon_edge_chain_test;

import std.format : format;

import mesh;
import math : Vec3;
import commands.mesh.make_polygon : edgeChainWalk;

private Mesh build(size_t nVerts, uint[][] faces)
{
    Mesh m;
    foreach (i; 0 .. nVerts) m.addVertex(Vec3(cast(float) i, 0, 0));
    foreach (f; faces) m.addFace(f.dup);
    m.syncSelection();
    return m;
}

/// Select the given unordered vertex pairs as edges, IN THIS ORDER.
private void selectPairs(ref Mesh m, uint[2][] pairs)
{
    foreach (p; pairs) {
        int hit = -1;
        foreach (i, e; m.edges)
            if ((e[0] == p[0] && e[1] == p[1]) || (e[0] == p[1] && e[1] == p[0]))
                hit = cast(int) i;
        assert(hit >= 0, format("fixture: edge %s not in the mesh", p));
        m.selectEdge(hit);
    }
}

// Closed loop: starts at the FIRST SELECTED edge, runs from its STORED v0 to
// v1, and does not repeat the start vertex at the end.
unittest
{
    auto m = build(4, [[0u, 1, 2, 3]]);
    assert(m.edges.length == 4, "population floor: quad has 4 edges");
    selectPairs(m, [[2, 3], [0, 1], [1, 2], [3, 0]]);
    auto w = edgeChainWalk(m);
    assert(w == [2u, 3, 0, 1],
        format("closed loop does not start at the first selected edge's v0: %s", w));

    // Stored direction, not the pair as typed: [0,3] is stored [3,0].
    auto m2 = build(4, [[0u, 1, 2, 3]]);
    selectPairs(m2, [[0, 3], [1, 2], [2, 3], [0, 1]]);
    auto w2 = edgeChainWalk(m2);
    assert(w2 == [3u, 0, 1, 2],
        format("closed loop does not follow the stored edge direction: %s", w2));
}

// Open chain: starts at the END whose edge was selected first, walks to the
// other end, and answers every vertex once.
unittest
{
    auto m = build(4, [[0u, 1, 2, 3]]);
    selectPairs(m, [[1, 2], [2, 3], [0, 1]]);   // end 3's edge is 2nd, end 0's 3rd
    auto w = edgeChainWalk(m);
    assert(w == [3u, 2, 1, 0],
        format("open chain does not start at the first-selected end: %s", w));

    auto m2 = build(4, [[0u, 1, 2, 3]]);
    selectPairs(m2, [[0, 1], [2, 3], [1, 2]]);  // end 0's edge is 1st
    auto w2 = edgeChainWalk(m2);
    assert(w2 == [0u, 1, 2, 3],
        format("open chain does not start at the first-selected end: %s", w2));

    // A single edge answers its two vertices; `evaluate` refuses rings < 3.
    auto m3 = build(4, [[0u, 1, 2, 3]]);
    selectPairs(m3, [[1, 2]]);
    assert(edgeChainWalk(m3) == [1u, 2], "single edge is not answered as its two vertices");
}

// Refusals.
unittest
{
    size_t refused;

    // Degree > 2 at a vertex the walk reaches mid-ring (a bowtie of two
    // triangles sharing vertex 0, entered from edge 1-2 and ordered so the
    // walk turns into the second triangle at 0). Only the degree guard sees
    // this: every edge gets used, so without it the walk answers
    // [1,2,0,3,4,0,3].
    auto bow = build(5, [[0u, 1, 2], [0u, 3, 4]]);
    selectPairs(bow, [[1, 2], [0, 3], [2, 0], [3, 4], [4, 0], [0, 1]]);
    assert(edgeChainWalk(bow) is null, "a vertex of degree 4 was walked through");
    ++refused;

    // Two components, both closed (no ends at all): only the used-edge count
    // sees this; without it the walk answers the first loop, [0,1,2,3].
    auto two = build(8, [[0u, 1, 2, 3], [4u, 5, 6, 7]]);
    selectPairs(two, [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4]]);
    assert(edgeChainWalk(two) is null, "two disjoint loops were walked as one");
    ++refused;

    // Two open components (four ends) — the same count guard.
    auto pair = build(4, [[0u, 1, 2, 3]]);
    selectPairs(pair, [[0, 1], [2, 3]]);
    assert(edgeChainWalk(pair) is null, "two disjoint edges were walked as one");
    ++refused;

    // Nothing selected (a caller that skipped its own gate): empty, not a
    // read of sel[0].
    auto none = build(4, [[0u, 1, 2, 3]]);
    assert(edgeChainWalk(none) is null, "an empty edge selection was walked");
    ++refused;

    assert(refused == 4);
}
