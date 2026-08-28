// Module unittests for `mesh_analysis`, moved verbatim out of source/mesh_analysis.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_analysis_test;

import mesh : Mesh;
import math : Vec3;
import mesh : makeCube, makeGridPlane;
import std.conv : to;
import mesh_analysis;
// TASK 1903 Stage E1 — the three mutating fixes this file runs as the
// INDEPENDENT oracle for its detectors are free functions over
// `ref MeshEditBatch` now. The imports above are SELECTIVE, so mesh.d's
// `public import mesh_ops.cleanup;` does not reach here; name what is used.
import mesh : MeshEditBatch;
import mesh_ops.cleanup : kCleanupEditScope, unifyFaces, cleanDegenerateFaces,
                          fixFaceOrientation;

// UNRECORDED: these three calls exist to produce a MESH to compare against,
// not an op-log (see source/mesh_ops/cleanup.d's header).
private size_t unifyOnce(ref Mesh m) {
    auto ed = MeshEditBatch.unrecorded(m, kCleanupEditScope);
    const n = ed.unifyFaces();
    ed.close();
    return n;
}

private size_t cleanDegenerateOnce(ref Mesh m) {
    auto ed = MeshEditBatch.unrecorded(m, kCleanupEditScope);
    const n = ed.cleanDegenerateFaces();
    ed.close();
    return n;
}

private size_t fixOrientationOnce(ref Mesh m) {
    auto ed = MeshEditBatch.unrecorded(m, kCleanupEditScope);
    const n = ed.fixFaceOrientation();
    ed.close();
    return n;
}

unittest {
    // Coincident-vertex clusters, fidelity guard: a fixture with TWO
    // separate coincident groups (a 2-way pair and a 3-way triple), plus an
    // unrelated well-separated vertex. Detector reports both clusters with
    // the exact member sets; an INDEPENDENT (freshly-built) copy run
    // through the real mutating `weldCoincidentVertices` must, for each
    // detected cluster, end up with exactly ONE surviving vertex at that
    // cluster's position — checked by position (not by re-deriving remap),
    // so this does not just re-test the shared helper against itself.
    static Mesh buildFixture() {
        Mesh m;
        // Pair A: verts 0,1 coincident at (0,0,0). Triple B: verts 2,3,4
        // coincident at (5,0,0). Vert 5: unrelated, at (10,0,0). A triangle
        // ties every vertex into the face graph so none is orphaned.
        m.vertices = [
            Vec3(0, 0, 0), Vec3(0, 0, 0),
            Vec3(5, 0, 0), Vec3(5, 0, 0), Vec3(5, 0, 0),
            Vec3(10, 0, 0),
            Vec3(0, 1, 0), Vec3(5, 1, 0), Vec3(10, 1, 0),
        ];
        m.addFace([0u, 6u, 7u]);
        m.addFace([1u, 7u, 6u]);
        m.addFace([2u, 7u, 8u]);
        m.addFace([3u, 8u, 7u]);
        m.addFace([4u, 8u, 6u]);
        m.addFace([5u, 6u, 8u]);
        m.buildLoops();
        return m;
    }

    Mesh m1 = buildFixture();
    auto clusters = coincidentVertexClusters(m1);
    assert(clusters.length == 2, "expected exactly 2 coincident clusters, got " ~ clusters.length.to!string);

    bool[uint] flat;
    foreach (c; clusters) foreach (vi; c) flat[vi] = true;
    assert(flat.length == 5, "expected 5 total vertices across both clusters");
    foreach (vi; [0u, 1u, 2u, 3u, 4u]) assert(vi in flat, "vertex " ~ vi.to!string ~ " missing from a cluster");
    assert(5u !in flat, "unrelated vertex 5 must not appear in any cluster");

    // Independent fidelity check: fresh fixture, real mutation.
    Mesh m2 = buildFixture();
    size_t weldedCount = m2.weldCoincidentVertices();
    size_t expectedTouched = 0;
    foreach (c; clusters) expectedTouched += c.length - 1;
    assert(weldedCount == expectedTouched,
        "weldCoincidentVertices touched " ~ weldedCount.to!string ~
        ", detector implied " ~ expectedTouched.to!string);

    // Position-based SET check (independent of index bookkeeping and of
    // `computeWeldRemap` itself): `weldCoincidentVertices` remaps FACE
    // references to one representative but does NOT shrink `vertices` (the
    // followers remain as orphans — that is `compactUnreferenced`'s job, a
    // separate cleanup stage). So the observable "did the weld happen" fact
    // is REFERENCE count, not raw array occupancy: after the real weld,
    // exactly one vertex per cluster position is still REFERENCED by a
    // face; the unrelated vertex's reference count is untouched.
    auto referenced = m2.computeReferencedVertexMask();
    int referencedCountAt(const ref Mesh m, const bool[] referenced, Vec3 p) {
        int n = 0;
        foreach (i, v; m.vertices)
            if (referenced[i] && (v - p).length < 1e-6f) ++n;
        return n;
    }
    assert(referencedCountAt(m2, referenced, Vec3(0, 0, 0)) == 1);
    assert(referencedCountAt(m2, referenced, Vec3(5, 0, 0)) == 1);
    assert(referencedCountAt(m2, referenced, Vec3(10, 0, 0)) == 1);
}

unittest {
    // Degenerate faces, fidelity guard: TWO degenerate faces of DIFFERENT
    // kinds (a zero-Newell-area sliver, and a single-point collapse) among
    // healthy ones untouched by the pass (no index-dup collapse on the kept
    // faces — that "fixed but kept" path is exercised elsewhere and would
    // change a kept face's stored vertex list, which would break this
    // test's identity-based independent check below). Detector's set must
    // equal exactly the set the mutating cleanDegenerateFaces removes —
    // checked independently via before/after face-identity (sorted vertex
    // key), not by re-deriving isFaceDegenerate.
    static Mesh buildFixture() {
        Mesh m;
        m.vertices = [
            Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0), // 0-3: healthy quad verts
            Vec3(5, 0, 0), Vec3(6, 0, 0), Vec3(5.5f, 1, 0),             // 4-6: healthy triangle verts
            Vec3(9, 0, 0), Vec3(9, 0, 0), Vec3(9, 0, 0),                // 7-9: coincident positions -> zero-area sliver
        ];
        m.addFace([0u, 1u, 2u, 3u]);          // healthy quad — index 0
        m.addFace([4u, 5u, 6u]);              // healthy triangle, untouched — index 1
        m.addFace([7u, 8u, 9u]);              // distinct indices but coincident positions -> zero Newell area — index 2, DEGENERATE
        m.addFace([1u, 1u, 1u]);              // collapses to a single point -> <3 distinct -> DEGENERATE — index 3
        m.buildLoops();
        return m;
    }

    Mesh m1 = buildFixture();
    auto detected = degenerateFaceIndices(m1);
    assert(detected == [2u, 3u], "expected faces {2,3} degenerate, got " ~ detected.to!string);

    // Independent check: sorted-vertex-key survivor identity before/after.
    static immutable(uint)[] sortedKey(const(uint)[] f) {
        import std.algorithm.sorting : sort;
        auto k = f.dup;
        sort(k);
        return k.idup;
    }
    bool[uint] detectedSet;
    foreach (fi; detected) detectedSet[fi] = true;

    immutable(uint)[][] expectedSurvivors;
    foreach (fi; 0 .. m1.faces.length)
        if (cast(uint)fi !in detectedSet) expectedSurvivors ~= sortedKey(m1.faces[fi]);

    Mesh m2 = buildFixture();
    cleanDegenerateOnce(m2);
    immutable(uint)[][] actualSurvivors;
    foreach (fi; 0 .. m2.faces.length) actualSurvivors ~= sortedKey(m2.faces[fi]);

    assert(actualSurvivors == expectedSurvivors,
        "cleanDegenerateFaces survivor set != detector-implied survivor set");
}

unittest {
    // Duplicate faces, fidelity guard: TWO duplicate faces (a straight
    // repeat and a reversed-winding repeat of the same vertex set) among
    // distinct ones. Detector's set must equal exactly what unifyFaces
    // removes — checked independently via positional survivor comparison
    // (unifyFaces/deleteFacesByMask preserves the relative order of kept
    // faces).
    static Mesh buildFixture() {
        Mesh m;
        m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
                       Vec3(0, 0, 2), Vec3(1, 0, 2), Vec3(1, 1, 2)];
        m.addFace([0u, 1u, 2u, 3u]);   // 0: original quad
        m.addFace([4u, 5u, 6u]);       // 1: distinct triangle
        m.addFace([0u, 1u, 2u, 3u]);   // 2: exact duplicate of 0
        m.addFace([3u, 2u, 1u, 0u]);   // 3: reversed-winding duplicate of 0 (same unordered set)
        m.buildLoops();
        return m;
    }

    Mesh m1 = buildFixture();
    auto detected = duplicateFaceIndices(m1);
    assert(detected == [2u, 3u], "expected faces {2,3} duplicate, got " ~ detected.to!string);

    bool[uint] detectedSet;
    foreach (fi; detected) detectedSet[fi] = true;
    uint[][] expectedSurvivors;
    foreach (fi; 0 .. m1.faces.length)
        if (cast(uint)fi !in detectedSet) expectedSurvivors ~= m1.faces[fi][].dup;

    Mesh m2 = buildFixture();
    unifyOnce(m2);
    uint[][] actualSurvivors;
    foreach (fi; 0 .. m2.faces.length) actualSurvivors ~= m2.faces[fi][].dup;

    assert(actualSurvivors == expectedSurvivors,
        "unifyFaces survivor sequence != detector-implied survivor sequence");
}

unittest {
    // Orphan vertices, fidelity guard: TWO unreferenced vertices among
    // referenced ones. Detector's set must equal exactly what
    // compactUnreferenced removes — checked independently via ordered
    // position-sequence comparison (compactUnreferenced builds newVerts in
    // ascending original-index order).
    static Mesh buildFixture() {
        Mesh m;
        m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0),  // 0,1,2: referenced
                      Vec3(9, 9, 9),                                 // 3: orphan
                      Vec3(0, 1, 0),                                 // 4: referenced
                      Vec3(-9, -9, -9)];                             // 5: orphan
        m.addFace([0u, 1u, 2u]);
        m.addFace([0u, 2u, 4u]);
        m.buildLoops();
        return m;
    }

    Mesh m1 = buildFixture();
    auto detected = orphanVertexIndices(m1);
    assert(detected == [3u, 5u], "expected vertices {3,5} orphaned, got " ~ detected.to!string);

    bool[uint] detectedSet;
    foreach (vi; detected) detectedSet[vi] = true;
    Vec3[] expectedSurvivors;
    foreach (vi; 0 .. m1.vertices.length)
        if (cast(uint)vi !in detectedSet) expectedSurvivors ~= m1.vertices[vi];

    Mesh m2 = buildFixture();
    m2.compactUnreferenced();
    assert(m2.vertices == expectedSurvivors,
        "compactUnreferenced survivor sequence != detector-implied survivor sequence");
}

unittest {
    // Inconsistent winding, fidelity guard: two adjacent quads sharing an
    // edge, deliberately wound so the SECOND one traverses the shared edge
    // in the SAME direction as the first (the exact corruption
    // fixFaceOrientation heals). Detector's flagged set must equal exactly
    // the set of faces whose `faces[fi]` array actually changes after a
    // real fixFaceOrientation() run on an independent copy — a face-index
    // -level check (fixFaceOrientation never adds/removes/reorders face
    // slots).
    static Mesh buildFixture() {
        Mesh m;
        m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
                       Vec3(2, 0, 0), Vec3(2, 1, 0)];
        m.addFace([0u, 1u, 2u, 3u]);   // face 0: CCW, shares edge (1,2) with face 1
        m.addFace([1u, 2u, 5u, 4u]);   // face 1: traverses (1,2) SAME direction as face 0 -> inconsistent
        m.buildLoops();
        return m;
    }

    Mesh m1 = buildFixture();
    auto detected = inconsistentWindingFaces(m1);
    assert(detected.length == 1, "expected exactly 1 face flagged, got " ~ detected.length.to!string);

    Mesh m2 = buildFixture();
    fixOrientationOnce(m2);
    bool[] changed = new bool[](m1.faces.length);
    foreach (fi; 0 .. m1.faces.length)
        changed[fi] = (m1.faces[fi][] != m2.faces[fi][]);

    bool[uint] detectedSet;
    foreach (fi; detected) detectedSet[fi] = true;
    foreach (fi; 0 .. m1.faces.length) {
        immutable bool isDetected = (cast(uint)fi in detectedSet) !is null;
        assert(isDetected == changed[fi],
               "face " ~ fi.to!string ~ " changed=" ~ changed[fi].to!string ~
               " but detector flag=" ~ isDetected.to!string);
    }
}

unittest {
    // Non-manifold edges: a "book" of 3 faces all sharing one central edge
    // (use-count 3) among ordinary manifold edges (use-count <= 2).
    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(0, 1, 0),              // shared edge 0-1
                  Vec3(1, 0, 0), Vec3(1, 1, 0),
                  Vec3(-1, 0.3, 0.3), Vec3(-1, 0.7, 0.3),
                  Vec3(0.3, -1, -0.3), Vec3(0.7, -1, -0.3)];
    m.addFace([0u, 1u, 3u, 2u]);
    m.addFace([1u, 0u, 4u, 5u]);
    m.addFace([0u, 1u, 7u, 6u]);
    m.buildLoops();

    auto ctx = buildAnalyzeContext(m);
    auto nm = nonManifoldEdgeIndices(ctx);
    assert(nm.length == 1, "expected exactly 1 non-manifold edge, got " ~ nm.length.to!string);
    uint ei = nm[0];
    auto e = m.edges[ei];
    bool isBookEdge = (e[0] == 0 && e[1] == 1) || (e[0] == 1 && e[1] == 0);
    assert(isBookEdge, "the flagged edge must be the shared 0-1 edge");
    assert(ctx.edgeFaceUseCount[ei] == 3);
}

unittest {
    // Naked boundary: a single open quad (no faces) has one 4-edge boundary loop.
    Mesh m = makeGridPlane(2); // 2x2 grid of quads, open on all 4 sides
    auto loops = nakedBoundaryLoopEdges(m);
    assert(loops.length == 1, "a 2x2 open grid should have exactly one boundary loop");
    assert(loops[0].length == 8, "the 2x2 grid's outer boundary has 8 edges, got " ~ loops[0].length.to!string);

    // A closed cube has no boundary at all.
    auto cube = makeCube();
    assert(nakedBoundaryLoopEdges(cube).length == 0, "a closed cube must have zero boundary loops");
}

unittest {
    // Retopo hotspot: an all-quad grid (clean) has zero hotspot clusters;
    // poking one triangle into it creates exactly one hotspot cluster
    // containing that triangle (and possibly its immediate quad neighbors,
    // since the triangle's apex vertex now has non-4 valence too).
    auto clean = makeGridPlane(4);
    auto ctxClean = buildAnalyzeContext(clean);
    assert(retopoHotspotClusters(clean, ctxClean).length == 0,
        "a clean all-quad grid should have zero retopo hotspots");

    // Split one face of a fresh grid into two triangles.
    auto dirty = makeGridPlane(4);
    auto f0 = dirty.faces[0][].dup;
    assert(f0.length == 4);
    bool[] mask = new bool[](dirty.faces.length);
    mask[0] = true;
    dirty.deleteFacesByMask(mask);
    dirty.addFace([f0[0], f0[1], f0[2]]);
    dirty.addFace([f0[0], f0[2], f0[3]]);
    dirty.buildLoops();

    auto ctxDirty = buildAnalyzeContext(dirty);
    auto clusters = retopoHotspotClusters(dirty, ctxDirty);
    assert(clusters.length >= 1, "expected at least one hotspot cluster after introducing triangles");
    bool[uint] flat;
    foreach (c; clusters) foreach (fi; c) flat[fi] = true;
    // The two new triangle face indices are the last two faces appended.
    uint tri0 = cast(uint)(dirty.faces.length - 2);
    uint tri1 = cast(uint)(dirty.faces.length - 1);
    assert(tri0 in flat && tri1 in flat, "both introduced triangles must be part of a hotspot cluster");
}

unittest {
    // Perf smoke (plan risk #1): a ~100k-face all-quad grid must build the
    // context and run every Phase-4 detector well under a second, with no
    // detector allocating anything worse than O(V+E+F). 316x316 quads ~=
    // 99,856 faces.
    import std.datetime.stopwatch : StopWatch, AutoStart;

    auto big = makeGridPlane(316);
    assert(big.faces.length >= 90_000, "fixture too small for a meaningful perf smoke: " ~ big.faces.length.to!string);

    auto sw = StopWatch(AutoStart.yes);
    auto ctx = buildAnalyzeContext(big);
    auto coincident = coincidentVertexClusters(big);
    auto degenerate  = degenerateFaceIndices(big);
    auto duplicate   = duplicateFaceIndices(big);
    auto orphan      = orphanVertexIndices(big);
    auto winding     = inconsistentWindingFaces(big);
    auto nonManifold = nonManifoldEdgeIndices(ctx);
    auto boundary    = nakedBoundaryLoopEdges(big);
    auto hotspots    = retopoHotspotClusters(big, ctx);
    sw.stop();

    assert(coincident.length == 0);
    assert(degenerate.length == 0);
    assert(duplicate.length == 0);
    assert(orphan.length == 0);
    assert(winding.length == 0);
    assert(nonManifold.length == 0);
    assert(boundary.length == 1);
    assert(hotspots.length == 0, "a clean all-quad grid interior should have zero hotspots (only its rim, which isFaceThin/arity/pole would need to flag, does not for a regular grid)");

    immutable msecs = sw.peek.total!"msecs";
    assert(msecs < 1000, "Phase-4 detector sweep over a ~100k-face mesh took " ~ msecs.to!string ~ "ms, expected < 1000ms");
}

// ---------------------------------------------------------------------------
// Task 0833 — the settled-mesh precondition on `nakedBoundaryLoopEdges` is
// LIVE, i.e. it CAN fail.
//
// Task 0724 rolled the precondition out and measured that no CALLER can trip
// it today: every mutator that leaves `edgeIndexMap` stale ends in a terminal
// `buildLoops()` before any reader runs. That measurement says the invariant
// holds by call ORDER, and a check that cannot fail is indistinguishable from
// one that is absent — so this block constructs the stale read the callers
// never produce, through the public API only.
//
// The legal sequence: `addFaceFast` is the importers' own append primitive
// (io/scene_ir.d, io/native.d, remesh) — it fills `edges` from the CALLER's
// scratch lookup and deliberately defers the canonical map to a terminal
// `buildLoops()`, marking `edgeMapState_` Stale meanwhile. Nothing here pokes
// a private field or fakes a state the product cannot reach.
//
// The failure this stands in for is silent, which is why the site asserts
// rather than returning a sentinel: `boundaryLoopToEdgeIndices` DROPS every
// endpoint pair the map fails to resolve, so a stale/never-built map turns a
// real hole into "no boundary loops" — a short answer, not an error.
//
// Wrapped in `debug` because `assertEdgeMapValid` is a `debug assert`: under
// `-release` there is nothing to throw, so this proves the guard is live in
// the builds that CARRY it (dub test / dub build), NOT that the shipped
// release binary refuses a stale read. It does not.
// ---------------------------------------------------------------------------
unittest {
    debug {
        import core.exception : AssertError;
        import std.exception  : assertThrown;

        Mesh m;
        uint[ulong] scratch;
        m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1), Vec3(0, 0, 1)];
        m.addFaceFast(scratch, [0u, 1u, 2u, 3u]);
        assert(m.edges.length == 4,
            "setup: addFaceFast must still append the quad's four edges");
        assert(!m.edgeMapUsable(),
            "setup: addFaceFast defers the canonical map, so it must read unusable");

        assertThrown!AssertError(nakedBoundaryLoopEdges(m),
            "nakedBoundaryLoopEdges must refuse a mesh whose edgeIndexMap was "
            ~ "never rebuilt -- if this stops throwing, the precondition has "
            ~ "become decoration");

        // ...and the SAME call is fine once the caller settles the mesh, so the
        // assert discriminates between two states rather than refusing the
        // reader outright. The quad's four boundary edges all resolve, which is
        // exactly what a stale map would have silently dropped.
        m.buildLoops();
        assert(m.edgeMapUsable(), "setup: buildLoops must restore the map");
        auto loops = nakedBoundaryLoopEdges(m);
        assert(loops.length == 1,
            "a lone quad has exactly one naked boundary loop, got "
            ~ loops.length.to!string);
        assert(loops[0].length == 4,
            "the loop must resolve all four edges through the rebuilt map, got "
            ~ loops[0].length.to!string);
    }
}

// ---------------------------------------------------------------------------
// Task 2561 (follow-up to 1909's fixFaceOrientation stand) --
// `inconsistentWindingFaces`'s only precondition-carrying dependency,
// `mesh_ops.cleanup.computeOrientationFlipMask`, read `m.loops`/`m.faceLoop`
// directly with NO guard and no way to self-heal (its own doc comment: "Does
// NOT call buildLoops() itself -- that would require a non-const receiver").
// Unlike `fixFaceOrientation`, whose only caller is itself (closes the gap
// with its own internal `buildLoops()`), `inconsistentWindingFaces`'s only
// external caller is a REAL, LIVE, SINGULAR one -- `ai.analysis.analyzeMesh`'s
// Topology category, reached from `/api/ai/analyze` -- and until this task it
// carried no guard at all, unlike its own neighbor detector two blocks above
// this one, `nakedBoundaryLoopEdges` (task 0833's `assertEdgeMapValid()`
// witness, immediately above).
//
// The guard added (`source/mesh_ops/cleanup.d`, top of the two-parameter
// `computeOrientationFlipMask` overload -- the only real implementation, the
// one-parameter overload delegates to it) is `m.assertLoopsValid()`, which is
// `structVersion`-keyed. MEASURED before writing it (`source/mesh.d`'s
// `structVersion` doc comment): this closes a CRUDER class than the one 1909
// demonstrated for the mutating twin -- a structural edit through a REAL
// mutator (here, `rebuildEdgesFromFaces()`) that bumps `structVersion`
// without a following `buildLoops()`. It does NOT close 1909's own class (a
// direct `faces[fi] = ...` element write, which moves neither `structVersion`
// nor `loopsStamp`) -- see the task card (`doc/tasks/*/2561-...md`) for the
// measurement and the reasoning for stopping here rather than changing
// `inconsistentWindingFaces` to a non-`const` receiver.
//
// Not a cube -- two open triangles sharing edge (0,2), same shape 1909's
// `openTriPairStand_` uses: a closed solid makes every candidate orientation
// rule agree, which is how the parent gap survived undetected in the first
// place.
// ---------------------------------------------------------------------------
unittest {
    debug {
        import core.exception : AssertError;
        import std.exception  : assertThrown;

        static Mesh openTriPairStand2561_() {
            Mesh m;
            m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)];
            // Two triangles sharing edge (0,2), consistently wound: face 0
            // traverses the shared edge 2->0, face 1 traverses it 0->2 --
            // opposite directions (the healthy invariant).
            m.faces = [[0u, 1u, 2u], [0u, 2u, 3u]];
            m.rebuildEdgesFromFaces();
            m.buildLoops();
            m.resetSelection();
            return m;
        }

        // Ground truth: corrupt face 1's winding (reverse [0,2,3] -> [3,2,0],
        // which makes both faces traverse the shared edge (0,2) in the SAME
        // direction -- the corruption signature), resync loops, THEN read.
        Mesh control = openTriPairStand2561_();
        control.faces[1] = [3u, 2u, 0u];
        control.buildLoops();
        auto controlWinding = inconsistentWindingFaces(control);
        assert(controlWinding.length == 1,
            "sanity: the corrupted stand must name exactly one inconsistent "
            ~ "face once resynced -- the rig discriminates nothing otherwise, got "
            ~ controlWinding.length.to!string);

        // Subject: the IDENTICAL corruption, but resync `structVersion`
        // through a REAL structural primitive -- `rebuildEdgesFromFaces()`
        // -- WITHOUT a following `buildLoops()`. Unlike a bare
        // `faces[fi] = ...` write (1909's own rig, which `structVersion`
        // never sees at all), `rebuildEdgesFromFaces()` DOES bump
        // `structVersion`, so `loopsValid()` correctly reads false here --
        // this is exactly the class the new guard is built to catch.
        Mesh subject = openTriPairStand2561_();
        subject.faces[1] = [3u, 2u, 0u];
        subject.rebuildEdgesFromFaces();
        assert(!subject.loopsValid(),
            "setup sanity: rebuildEdgesFromFaces() must leave loops stale "
            ~ "relative to the bumped structVersion -- if this reads true the "
            ~ "rig proves nothing about the guard");

        assertThrown!AssertError(inconsistentWindingFaces(subject),
            "inconsistentWindingFaces must refuse a mesh whose loops are "
            ~ "stale relative to structVersion -- if this stops throwing, "
            ~ "computeOrientationFlipMask's assertLoopsValid() guard has "
            ~ "been removed or the precondition has become decoration");

        // ...and the SAME call succeeds, and matches the freshly-resynced
        // control, once the caller resyncs loops itself.
        subject.buildLoops();
        assert(subject.loopsValid(), "setup: buildLoops() must restore validity");
        auto subjectWinding = inconsistentWindingFaces(subject);
        assert(subjectWinding == controlWinding,
            "once resynced, the subject must name the identical inconsistent "
            ~ "face(s) as the freshly-resynced control");
    }
}
