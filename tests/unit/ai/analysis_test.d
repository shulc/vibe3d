// Module unittests for `ai.analysis`, moved verbatim out of source/ai/analysis.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai.analysis_test;

import std.algorithm : sort, min, max;
import std.array     : appender;
import std.conv      : to;
import std.json      : JSONValue;
import std.math      : isFinite;
import mesh : Mesh;
import ai.support_loop_candidates : SupportLoopCandidate,
    generateSupportLoopCandidates;
import mesh_analysis : AnalyzeContext, buildAnalyzeContext,
    coincidentVertexClusters, degenerateFaceIndices, duplicateFaceIndices,
    orphanVertexIndices, inconsistentWindingFaces, nonManifoldEdgeIndices,
    nakedBoundaryLoopEdges, retopoHotspotClusters;
import mesh : makeCube;
import math : Vec3;
import ai.analysis;

unittest {
    // Cube: SubdivReadiness must surface at least one finding whose edges
    // group (a subset of) the cube's 12 sharp edges.
    auto m = makeCube();
    auto findings = analyzeMesh(m);

    assert(findings.length >= 1, "cube should yield at least one SubdivReadiness finding");

    bool[uint] coveredEdges;
    foreach (ref f; findings) {
        assert(f.category == FindingCategory.SubdivReadiness);
        assert(f.suggestedOp == "loop.slice");
        assert(f.edges.length > 0, "a SubdivReadiness finding should carry a non-empty edge set");
        foreach (ei; f.edges) coveredEdges[ei] = true;
    }
    assert(coveredEdges.length > 0);
    foreach (ei; coveredEdges.byKey)
        assert(ei < m.edges.length, "finding edge index must be a valid mesh edge");
}

unittest {
    // A flat grid has no sharp edges (dihedral 0 everywhere) — analyzeMesh
    // must not crash and must not spam SubdivReadiness suggestions on a
    // smooth surface. It DOES legitimately surface a Phase-4 Topology
    // naked-boundary finding, since `makeGridPlane` is an OPEN rim — that is
    // a correct finding, not a false positive, so this only asserts on the
    // category this test actually cares about.
    import mesh : makeGridPlane;
    auto m = makeGridPlane(4);
    auto findings = analyzeMesh(m);
    foreach (ref f; findings)
        assert(f.category != FindingCategory.SubdivReadiness,
            "a flat grid must not surface a SubdivReadiness finding");
}

unittest {
    // Empty mesh: no vertices/edges at all must not crash.
    Mesh m;
    auto findings = analyzeMesh(m);
    assert(findings.length == 0);
}

unittest {
    // Determinism: analyzing the same mesh twice yields identical findings
    // in the same order with the same scores.
    auto m = makeCube();
    auto a = analyzeMesh(m);
    auto b = analyzeMesh(m);
    assert(a.length == b.length);
    foreach (i; 0 .. a.length) {
        assert(a[i].id == b[i].id);
        assert(a[i].edges == b[i].edges);
        assert(a[i].score == b[i].score);
        assert(a[i].category == b[i].category);
        assert(a[i].severity == b[i].severity);
    }
}

unittest {
    // findingsToJson: valid JSON array; each object carries the expected
    // key set and round-trips the id/category/severity/score/edges.
    import std.json : parseJSON, JSONType;

    auto m = makeCube();
    auto findings = analyzeMesh(m);
    assert(findings.length >= 1);

    auto json = findingsToJson(findings);
    auto parsed = parseJSON(json);
    assert(parsed.type == JSONType.array);
    assert(parsed.array.length == findings.length);

    auto first = parsed.array[0];
    assert(first["id"].str == findings[0].id);
    assert(first["category"].str == findingCategoryId(findings[0].category));
    assert(first["severity"].str == findingSeverityId(findings[0].severity));
    assert(first["message"].str == findings[0].message);
    assert(first["suggestedOp"].str == findings[0].suggestedOp);
    assert(first["edges"].array.length == findings[0].edges.length);
    assert(first["features"].array.length == findings[0].features.length);
    assert(first["verts"].array.length == 0);
    assert(first["faces"].array.length == 0);
}

unittest {
    // MAX_FINDINGS_PER_CATEGORY / maxFindingsPerCategory clamp: a mesh with
    // many disjoint sharp-edge islands, requested with a huge (or zero/
    // negative) cap, never exceeds the kernel ceiling and never crashes on
    // a degenerate option value.
    Mesh m;
    // 40 disjoint "hinge" islands (two quad wings meeting at a 90deg ridge
    // edge each — same shape as the isolated-hinge case proven in
    // ai.support_loop_candidates's unittest), far apart so no edge-loop walk
    // crosses islands and each yields exactly one 1-edge candidate.
    foreach (i; 0 .. 40) {
        immutable float x = cast(float)i * 10.0f;
        immutable uint baseIdx = cast(uint)m.vertices.length;
        m.vertices ~= [
            Vec3(x, 0.0f, 0.0f), Vec3(x, 1.0f, 0.0f),   // ridge
            Vec3(x + 1.0f, 0.0f, 0.0f), Vec3(x + 1.0f, 1.0f, 0.0f), // wing1 far
            Vec3(x, 0.0f, 1.0f), Vec3(x, 1.0f, 1.0f),   // wing2 far
        ];
        m.addFace([baseIdx, baseIdx + 1, baseIdx + 3, baseIdx + 2]);
        m.addFace([baseIdx + 1, baseIdx, baseIdx + 4, baseIdx + 5]);
    }
    m.buildLoops();

    AnalyzeOptions huge;
    huge.maxFindingsPerCategory = int.max;
    auto findingsHuge = analyzeMesh(m, huge);
    assert(findingsHuge.length <= MAX_FINDINGS_PER_CATEGORY,
           "kernel cap must bound findings regardless of a huge caller-requested cap");

    AnalyzeOptions zero;
    zero.maxFindingsPerCategory = 0;
    auto findingsZero = analyzeMesh(m, zero);
    assert(findingsZero.length >= 1,
           "a non-positive cap must be floored to at least 1, not yield zero findings outright");

    AnalyzeOptions negative;
    negative.maxFindingsPerCategory = -5;
    auto findingsNeg = analyzeMesh(m, negative);
    assert(findingsNeg.length == findingsZero.length);
}
