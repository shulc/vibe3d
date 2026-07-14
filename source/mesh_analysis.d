module mesh_analysis;

// AI Modeling Copilot — Phase 4 (task 0402, doc/ai_copilot_plan.md): the
// Cleanup / Topology / Retopo detector predicates. Every detector here is
// READ-ONLY (`const ref Mesh`), returns per-element LOCATIONS (vertex/edge/
// face index sets), and never mutates. Pure D, no `version(WithAI)` — must
// compile and be useful under BOTH `--config=modeling` and
// `--config=modeling-noai`.
//
// Fidelity approach (plan risk #2 — extraction drift): wherever the
// underlying mutating fix is cheap to split at the "decide vs apply"
// boundary, the DECISION itself now lives as a small `const` method on
// `Mesh` (`computeWeldRemap`, `computeReferencedVertexMask`,
// `computeDuplicateFaceMask`, `isFaceDegenerate`, `computeOrientationFlipMask`)
// and BOTH the mutating fix (`weldCoincidentVertices`, `compactUnreferenced`,
// `unifyFaces`, `cleanDegenerateFaces`, `fixFaceOrientation` — all in
// mesh.d) and the detectors below call the SAME code. This isn't just
// "tested to match" — a future edit to the shared method changes both sides
// identically, so the two literally cannot drift apart. `tests/` (and the
// unittests at the bottom of this file) additionally assert element-index
// SET equality (not just count) against a live, independently-run mutating
// pass on a multi-instance fixture, per the plan's opponent should-fix #5.
//
// Perf (plan risk #1): every detector that needs per-vertex degree or
// per-edge face-use-count reads it from `AnalyzeContext`, built ONCE per
// `ai.analysis.analyzeMesh` call in O(V + E + F) — never rebuilt per
// detector, never per element. No detector in this module is worse than
// O(V + E + F) (see the perf-smoke unittest at the bottom).

import mesh : Mesh;
import math : Vec3;

private float clamp01(float x) pure nothrow @safe @nogc {
    return x < 0.0f ? 0.0f : (x > 1.0f ? 1.0f : x);
}

// ===========================================================================
// Shared once-per-analyze context
// ===========================================================================

/// Shared, once-per-analyze scratch threaded through every Phase-4 detector
/// — avoids each detector rebuilding its own degree/adjacency arrays (plan
/// risk #1; this is the seam Phase 1's single SubdivReadiness detector did
/// not need, since `generateSupportLoopCandidates` builds its own small
/// per-vertex sharp-edge-degree array internally and nothing else in Phase 1
/// needed it shared).
struct AnalyzeContext {
    uint[] valence;           // per vertex (mesh.vertices[] index): incident-edge count
    uint[] edgeFaceUseCount;  // per edge (mesh.edges[] index): incident-face count, UNCAPPED
    bool[] boundaryVertex;    // per vertex: touches >=1 edge with face-use-count == 1
}

/// Build the shared context in O(V + E + F). Safe on an empty mesh (every
/// array comes back zero-length; no detector reading it will iterate).
AnalyzeContext buildAnalyzeContext(const ref Mesh mesh) {
    AnalyzeContext ctx;

    ctx.valence = new uint[](mesh.vertices.length);
    foreach (vi; 0 .. mesh.vertices.length)
        ctx.valence[vi] = mesh.vertexValence(cast(uint)vi);

    ctx.edgeFaceUseCount = mesh.edgeFaceUseCounts();

    ctx.boundaryVertex = new bool[](mesh.vertices.length);
    foreach (ei, cnt; ctx.edgeFaceUseCount) {
        if (cnt != 1) continue;
        auto e = mesh.edges[ei];
        if (e[0] < ctx.boundaryVertex.length) ctx.boundaryVertex[e[0]] = true;
        if (e[1] < ctx.boundaryVertex.length) ctx.boundaryVertex[e[1]] = true;
    }

    return ctx;
}

// ===========================================================================
// Cleanup detectors
// ===========================================================================

/// Coincident-vertex clusters: groups of >= 2 vertices `Mesh.weldCoincidentVertices`
/// would merge into one, grouped by shared representative (see
/// `Mesh.computeWeldRemap`'s doc comment — no multi-hop chains form, so
/// grouping by `remap[]` value alone recovers exact clusters). Deterministic:
/// ascending by representative vertex index; each cluster lists its
/// representative first, then followers in ascending index order.
// NOTE (review S1): the default `epsSq = 1e-12` (1e-6 linear) is deliberately
// TIGHTER than the suggested `mesh.cleanup` op's `CleanupOptions.weldEpsSq = 1e-10`
// (1e-5 linear) — the detector surfaces only clearly-coincident vertices, a strict
// subset of what cleanup would weld, so a Finding is never a marginal false
// positive. Callers wanting cleanup-parity can pass `1e-10` explicitly.
uint[][] coincidentVertexClusters(const ref Mesh mesh, double epsSq = 1e-12) {
    auto remap = mesh.computeWeldRemap(epsSq);
    if (remap.length == 0) return [];

    uint[][] byRoot = new uint[][](remap.length);
    foreach (i; 0 .. remap.length)
        byRoot[cast(uint)remap[i]] ~= cast(uint)i;

    uint[][] result;
    foreach (members; byRoot)
        if (members.length >= 2) result ~= members;
    return result;
}

/// Zero-area / degenerate face indices — faces `Mesh.cleanDegenerateFaces`
/// would DROP entirely (fewer than 3 distinct vertices after
/// consecutive-duplicate collapse, or a near-zero Newell-normal area).
/// Ascending face-index order.
uint[] degenerateFaceIndices(const ref Mesh mesh) {
    uint[] result;
    foreach (fi; 0 .. mesh.faces.length)
        if (mesh.isFaceDegenerate(cast(uint)fi)) result ~= cast(uint)fi;
    return result;
}

/// Duplicate-face indices — later occurrences of an already-seen unordered
/// vertex set, exactly what `Mesh.unifyFaces` would remove. Ascending
/// face-index order (the FIRST occurrence of a repeated vertex set is never
/// included — it is the one `unifyFaces` keeps).
uint[] duplicateFaceIndices(const ref Mesh mesh) {
    auto mask = mesh.computeDuplicateFaceMask();
    uint[] result;
    foreach (fi, m; mask)
        if (m) result ~= cast(uint)fi;
    return result;
}

/// Orphan (unreferenced) vertex indices — vertices no face touches, exactly
/// what `Mesh.compactUnreferenced` would remove. Ascending vertex-index order.
uint[] orphanVertexIndices(const ref Mesh mesh) {
    auto referenced = mesh.computeReferencedVertexMask();
    uint[] result;
    foreach (vi, r; referenced)
        if (!r) result ~= cast(uint)vi;
    return result;
}

// ===========================================================================
// Topology / manifold detectors
// ===========================================================================

/// Face indices whose winding is inconsistent with their manifold-adjacent
/// neighbors — exactly the set `Mesh.fixFaceOrientation` would flip.
/// Ascending face-index order. PRECONDITION: mesh loops must already be
/// built (see `Mesh.computeOrientationFlipMask`'s doc comment).
uint[] inconsistentWindingFaces(const ref Mesh mesh) {
    // false = analyze the WHOLE mesh (review S2): a read-only analyze must not
    // silently skip winding problems in unselected components when the artist
    // happens to have a selection active at analyze time.
    auto flipMask = mesh.computeOrientationFlipMask(false);
    uint[] result;
    foreach (fi, f; flipMask)
        if (f) result ~= cast(uint)fi;
    return result;
}

/// Non-manifold edge indices — edges shared by 3 or more faces. Uses the
/// FULL per-edge face-use count in `ctx` (plan risk #3: `Mesh.buildEdgeFaces`'s
/// `int[2]` slots cannot witness a 3rd+ incident face, so that helper must
/// NOT be used here). Ascending edge-index order.
uint[] nonManifoldEdgeIndices(const ref AnalyzeContext ctx) {
    uint[] result;
    foreach (ei, cnt; ctx.edgeFaceUseCount)
        if (cnt > 2) result ~= cast(uint)ei;
    return result;
}

/// Naked boundary loops, each expressed as an ORDERED edge-index chain
/// (converted from `Mesh.boundaryLoops`'s vertex chains via `edgeIndexMap`).
/// One entry per open loop/hole; [] for a closed mesh.
uint[][] nakedBoundaryLoopEdges(const ref Mesh mesh) {
    auto vertLoops = mesh.boundaryLoops();
    uint[][] result;
    result.reserve(vertLoops.length);
    foreach (loop; vertLoops)
        result ~= boundaryLoopToEdgeIndices(mesh, loop);
    return result;
}

private uint[] boundaryLoopToEdgeIndices(const ref Mesh mesh, const(uint)[] loopVerts) {
    uint[] result;
    result.reserve(loopVerts.length);
    foreach (i; 0 .. loopVerts.length) {
        uint a = loopVerts[i];
        uint b = loopVerts[(i + 1) % loopVerts.length];
        ulong key = a < b ? (cast(ulong)a << 32) | b : (cast(ulong)b << 32) | a;
        if (auto p = key in mesh.edgeIndexMap) result ~= *p;
    }
    return result;
}

// ===========================================================================
// Retopo detectors — `vibe3d-original` heuristic (no reference analog; see
// the plan's provenance section). Hotspots = connected clusters of faces
// that are tri/n-gon, touch a non-quad-valence interior vertex ("pole"), or
// are thin/sliver (low edge-length aspect ratio) — the standard hand-surface
// "this area needs retopo attention" signals.
// ===========================================================================

/// Aspect ratio below which a face is flagged as thin/sliver: shortest edge
/// / longest edge. 0.15 ~= a face roughly 6.7x longer than it is wide.
enum float thinFaceAspectRatioThreshold = 0.15f;

/// A face's arity classification against an all-quad target topology.
enum FaceArityKind { Tri, Quad, Ngon }

FaceArityKind faceArityKind(size_t arity) pure nothrow @safe @nogc {
    if (arity == 3) return FaceArityKind.Tri;
    if (arity == 4) return FaceArityKind.Quad;
    return FaceArityKind.Ngon;
}

bool isTriArity(size_t arity)  pure nothrow @safe @nogc { return arity == 3; }
bool isQuadArity(size_t arity) pure nothrow @safe @nogc { return arity == 4; }
bool isNgonArity(size_t arity) pure nothrow @safe @nogc { return arity >= 5; }

/// True when face `fi`'s shortest-to-longest edge-length ratio is below
/// `thinFaceAspectRatioThreshold`. A face with any zero-length edge (already
/// a Cleanup-category defect) is never flagged here — that is
/// `degenerateFaceIndices`'s job, not Retopo's.
bool isFaceThin(const ref Mesh mesh, uint fi) {
    auto face = mesh.faces[fi];
    if (face.length < 3) return false;
    float minLen = float.max;
    float maxLen = 0.0f;
    foreach (k; 0 .. face.length) {
        Vec3 a = mesh.vertices[face[k]];
        Vec3 b = mesh.vertices[face[(k + 1) % face.length]];
        float len = (a - b).length;
        if (len < minLen) minLen = len;
        if (len > maxLen) maxLen = len;
    }
    // A face with ANY ~zero-length edge is degenerate (Cleanup's concern),
    // not "thin" — skip on either bound so it isn't double-reported (review nit).
    if (maxLen < 1e-9f || minLen < 1e-9f) return false;
    return (minLen / maxLen) < thinFaceAspectRatioThreshold;
}

/// True when vertex `vi` is a "pole" — an INTERIOR vertex (never a boundary
/// vertex; boundary valence legitimately differs from 4 for an ordinary
/// open-mesh rim) whose valence is not 4, i.e. an extraordinary vertex for
/// an all-quad target topology. General-purpose (no reference/reason to
/// exclude the common valence-3 case) — see `isRetopoHighValencePole` for
/// the narrower predicate the Retopo hotspot detector actually uses.
bool isPoleVertex(const ref AnalyzeContext ctx, uint vi) {
    if (vi >= ctx.valence.length) return false;
    if (vi < ctx.boundaryVertex.length && ctx.boundaryVertex[vi]) return false;
    return ctx.valence[vi] != 4;
}

/// Valence at/above which an interior vertex counts as a Retopo hotspot
/// "high-valence pole" (plan wording: "clusters of tris/n-gons +
/// HIGH-VALENCE poles"). Deliberately narrower than `isPoleVertex`'s general
/// valence != 4: a plain valence-3 vertex is the ORDINARY corner of any
/// box/cube-like primitive (see e.g. `mesh.makeCube` — every corner is
/// valence-3, interior since a closed solid has no boundary edges at all)
/// and must NOT read as a retopo problem; a >=5-valence hub is the actual
/// hard-surface/organic-topology pinch-point that visibly artifacts under
/// subdivision.
enum uint retopoHighPoleValence = 5;

bool isRetopoHighValencePole(const ref AnalyzeContext ctx, uint vi) {
    if (vi >= ctx.valence.length) return false;
    if (vi < ctx.boundaryVertex.length && ctx.boundaryVertex[vi]) return false;
    return ctx.valence[vi] >= retopoHighPoleValence;
}

/// Per-face "is this a retopo problem spot" predicate: non-quad arity, a
/// thin/sliver shape, or touching an interior high-valence pole vertex.
private bool isRetopoProblemFace(const ref Mesh mesh, const ref AnalyzeContext ctx, uint fi) {
    auto face = mesh.faces[fi];
    if (!isQuadArity(face.length)) return true;
    if (isFaceThin(mesh, fi)) return true;
    foreach (vid; face)
        if (isRetopoHighValencePole(ctx, vid)) return true;
    return false;
}

/// All faces flagged as a retopo problem spot (unclustered), ascending
/// face-index order. Exposed mainly for testing; `retopoHotspotClusters`
/// groups these into connected components for findings.
uint[] retopoProblemFaces(const ref Mesh mesh, const ref AnalyzeContext ctx) {
    uint[] result;
    foreach (fi; 0 .. mesh.faces.length)
        if (isRetopoProblemFace(mesh, ctx, cast(uint)fi)) result ~= cast(uint)fi;
    return result;
}

/// Connected clusters (edge-adjacency BFS, via `Mesh.adjacentFaces`) of
/// retopo-problem faces — one Finding per spatially-coherent hotspot instead
/// of one per triangle. O(F) total: each face is visited at most once.
uint[][] retopoHotspotClusters(const ref Mesh mesh, const ref AnalyzeContext ctx) {
    auto problemFaces = retopoProblemFaces(mesh, ctx);
    if (problemFaces.length == 0) return [];

    bool[] isProblem = new bool[](mesh.faces.length);
    foreach (fi; problemFaces) isProblem[fi] = true;

    bool[] visited = new bool[](mesh.faces.length);
    uint[][] clusters;
    foreach (seed; problemFaces) {
        if (visited[seed]) continue;
        uint[] comp;
        uint[] queue;
        queue ~= seed;
        visited[seed] = true;
        size_t qi = 0;
        while (qi < queue.length) {
            uint fi = queue[qi++];
            comp ~= fi;
            foreach (nfi; mesh.adjacentFaces(fi)) {
                if (nfi < isProblem.length && isProblem[nfi] && !visited[nfi]) {
                    visited[nfi] = true;
                    queue ~= nfi;
                }
            }
        }
        clusters ~= comp;
    }
    return clusters;
}

// =======================================================================
// Unit tests
// =======================================================================

version(unittest) {
    import mesh : makeCube, makeGridPlane;
    import std.conv : to;
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
    m2.cleanDegenerateFaces();
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
    m2.unifyFaces();
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
    m2.fixFaceOrientation();
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
