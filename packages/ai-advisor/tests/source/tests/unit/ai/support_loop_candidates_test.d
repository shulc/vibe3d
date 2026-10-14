// Module unittests for `ai.support_loop_candidates`, moved verbatim out of source/ai/support_loop_candidates.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai.support_loop_candidates_test;

import std.algorithm : max;
import std.conv : to;
import std.math : isFinite;
import mesh : Mesh, EdgeSharpness;
import math : Vec3;
import mesh : makeCube;
import ai.support_loop_candidates;

unittest {
    // Feature-vector shape stays in lockstep with the names table.
    auto names = supportLoopFeatureNames();
    auto v = encodeSupportLoopFeatures(90.0f, 90.0f, 4, 4.0f, 1.0f, 0, 1.0f,
                                       false, true, SupportLoopKind.bevel);
    assert(v.length == names.length);
}

unittest {
    // Cube: every edge is a 90deg dihedral → all 12 edges should end up
    // covered by candidates, grouped into loops (not one 12-edge blob),
    // every candidate scored high and none already-supported.
    auto m = makeCube();
    auto candidates = generateSupportLoopCandidates(m, 30.0f);

    assert(candidates.length > 1,
           "cube's sharp edges should form more than one loop candidate");

    size_t totalEdges = 0;
    bool[uint] coveredEdges;
    foreach (ref c; candidates) {
        assert(c.edgeLoop.length > 0);
        assert(c.edgeLoop.length <= m.edges.length);
        assert(!c.alreadySupported);
        assert(c.score > 0.5f,
               "cube edges are maximally sharp; score should be high");
        foreach (ei; c.edgeLoop) {
            assert(ei !in coveredEdges, "an edge should belong to exactly one candidate");
            coveredEdges[ei] = true;
        }
        totalEdges += c.edgeLoop.length;
    }
    assert(totalEdges == 12, "all 12 cube edges should be covered");
    assert(coveredEdges.length == 12);

    // Determinism: re-running on the same mesh gives identical results.
    auto again = generateSupportLoopCandidates(m, 30.0f);
    assert(again.length == candidates.length);
    foreach (i; 0 .. candidates.length) {
        assert(again[i].id == candidates[i].id);
        assert(again[i].edgeLoop == candidates[i].edgeLoop);
        assert(again[i].score == candidates[i].score);
        assert(again[i].kind == candidates[i].kind);
    }
}

unittest {
    // A flat grid: every interior edge is between two coplanar quads
    // (dihedral ~0deg) — nothing should clear a 30deg threshold, so the
    // generator must not spam suggestions on a smooth/flat surface.
    Mesh m;
    // 3x3 grid of verts (2x2 quads) in the XZ plane.
    foreach (row; 0 .. 3)
        foreach (col; 0 .. 3)
            m.vertices ~= Vec3(cast(float)col, 0.0f, cast(float)row);
    uint idx(int col, int row) { return cast(uint)(row * 3 + col); }
    foreach (row; 0 .. 2)
        foreach (col; 0 .. 2)
            m.addFace([idx(col, row), idx(col + 1, row),
                       idx(col + 1, row + 1), idx(col, row + 1)]);
    m.buildLoops();

    auto candidates = generateSupportLoopCandidates(m, 30.0f);
    assert(candidates.length == 0,
           "a flat grid has no sharp edges; expected no candidates");
}

unittest {
    // Two isolated "hinge" islands, each two quad wings meeting at a 90deg
    // ridge edge (same physical dihedral as a cube corner). Tent B's wing1
    // is pre-split into a thin strip flanking the ridge (simulating a
    // hand-placed support loop on one side) plus the remaining face; tent
    // A is left untouched. The two islands share no vertices, so splitting
    // tent B cannot disturb tent A's topology.
    //
    //   tent A:  a0=(0,0,0) b0=(0,1,0)  (ridge)      tent B:  a1=(5,0,0) b1=(5,1,0)  (ridge)
    //            c0=(1,0,0) d0=(1,1,0)  (wing1 far)           c1=(6,0,0) d1=(6,1,0)  (wing1 far)
    //            e0=(0,0,1) f0=(0,1,1)  (wing2 far)           e1=(5,0,1) f1=(5,1,1)  (wing2 far)
    //                                                          c1s=(5.05,0,0) d1s=(5.05,1,0) (thin-strip far edge)
    Mesh m;
    m.vertices = [
        Vec3(0.0f, 0.0f, 0.0f), Vec3(0.0f, 1.0f, 0.0f),   // 0 a0, 1 b0
        Vec3(1.0f, 0.0f, 0.0f), Vec3(1.0f, 1.0f, 0.0f),   // 2 c0, 3 d0
        Vec3(0.0f, 0.0f, 1.0f), Vec3(0.0f, 1.0f, 1.0f),   // 4 e0, 5 f0
        Vec3(5.0f, 0.0f, 0.0f), Vec3(5.0f, 1.0f, 0.0f),   // 6 a1, 7 b1
        Vec3(6.0f, 0.0f, 0.0f), Vec3(6.0f, 1.0f, 0.0f),   // 8 c1, 9 d1
        Vec3(5.0f, 0.0f, 1.0f), Vec3(5.0f, 1.0f, 1.0f),   // 10 e1, 11 f1
        Vec3(5.05f, 0.0f, 0.0f), Vec3(5.05f, 1.0f, 0.0f), // 12 c1s, 13 d1s
    ];
    m.addFace([0, 1, 3, 2]);     // tent A wing1
    m.addFace([1, 0, 4, 5]);     // tent A wing2
    m.addFace([6, 7, 13, 12]);   // tent B wing1 — thin strip flanking the ridge
    m.addFace([12, 13, 9, 8]);   // tent B wing1 — remainder
    m.addFace([7, 6, 10, 11]);   // tent B wing2
    m.buildLoops();

    auto candidates = generateSupportLoopCandidates(m, 30.0f);
    assert(candidates.length == 2, "two disjoint ridges should yield two candidates");

    uint ridgeA = m.edgeIndex(0, 1);
    uint ridgeB = m.edgeIndex(6, 7);
    assert(ridgeA != ~0u && ridgeB != ~0u);

    SupportLoopCandidate* candA, candB;
    foreach (ref c; candidates) {
        assert(c.edgeLoop.length == 1, "an isolated hinge ridge has no quad ring to extend into");
        if (c.edgeLoop[0] == ridgeA) candA = &c;
        else if (c.edgeLoop[0] == ridgeB) candB = &c;
    }
    assert(candA !is null && candB !is null);

    assert(!candA.alreadySupported, "tent A's ridge has no nearby flanking strip");
    assert(candB.alreadySupported, "tent B's ridge has a thin flank on one side");
    assert(candB.kind == SupportLoopKind.crease);
    assert(candB.score < candA.score,
           "the already-supported ridge should score below the untouched one");
    // Same physical dihedral (90deg) either way — the divergence is purely
    // the already-supported penalty, not a difference in sharpness.
    assert(candA.features[0] == candB.features[0]);
}
