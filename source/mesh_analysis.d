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

import mesh : Mesh, edgeKey;
// Task 1903 Stage E1 moved the three hygiene/topology detectors this module
// shares with the mutating fixes out of `struct Mesh` and into free functions
// over `ref const(Mesh)` (`source/mesh_ops/cleanup.d`). The call sites below
// are unchanged — UFCS keeps `mesh.isFaceDegenerate(fi)` verbatim — but the
// import above is SELECTIVE, and a selective import does not carry the
// `public import mesh_ops.cleanup;` mesh.d re-exports them through. So the
// three names are listed here explicitly, which is also the honest statement
// of where the shared decision code now lives.
import mesh_ops.cleanup : computeDuplicateFaceMask, isFaceDegenerate,
                          computeOrientationFlipMask;
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

/// Zero-area / degenerate face indices — faces `cleanDegenerateFaces`
/// (source/mesh_ops/cleanup.d) would DROP entirely (fewer than 3 distinct vertices after
/// consecutive-duplicate collapse, or a near-zero Newell-normal area).
/// Ascending face-index order.
uint[] degenerateFaceIndices(const ref Mesh mesh) {
    uint[] result;
    foreach (fi; 0 .. mesh.faces.length)
        if (mesh.isFaceDegenerate(cast(uint)fi)) result ~= cast(uint)fi;
    return result;
}

/// Duplicate-face indices — later occurrences of an already-seen unordered
/// vertex set, exactly what `unifyFaces` (source/mesh_ops/cleanup.d) would
/// remove. Ascending
/// face-index order (the FIRST occurrence of a repeated vertex set is never
/// included — it is the one `unifyFaces` keeps).
uint[] duplicateFaceIndices(const ref Mesh mesh) {
    auto mask = mesh.computeDuplicateFaceMask();
    uint[] result;
    foreach (fi, m; mask)
        if (m) result ~= cast(uint)fi;
    return result;
}

/// Orphan vertex indices — vertices touched by neither a face nor a live
/// authored edge, exactly what `Mesh.compactUnreferenced` would remove.
/// Ascending vertex-index order.
uint[] orphanVertexIndices(const ref Mesh mesh) {
    auto referenced = mesh.computeReferencedVertexMask();
    foreach (ref e; mesh.edges)
        if (edgeKey(e[0], e[1]) in mesh.wireEdgeKeys) {
            if (e[0] < referenced.length) referenced[e[0]] = true;
            if (e[1] < referenced.length) referenced[e[1]] = true;
        }
    uint[] result;
    foreach (vi, r; referenced)
        if (!r) result ~= cast(uint)vi;
    return result;
}

// ===========================================================================
// Topology / manifold detectors
// ===========================================================================

/// Face indices whose winding is inconsistent with their manifold-adjacent
/// neighbors — exactly the set `fixFaceOrientation`
/// (source/mesh_ops/cleanup.d) would flip. Ascending face-index order.
/// PRECONDITION: mesh loops must already be built (see
/// `computeOrientationFlipMask`'s doc comment, same file).
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
    // Settled-mesh precondition (debug-only, stripped from release builds —
    // task 0724 / audit-4 M6). This entry point is `const ref`, so it CANNOT
    // rebuild what it needs; a caller that hands it an unsettled mesh gets a
    // silently SHORT answer, not an error — `boundaryLoopToEdgeIndices` drops
    // every pair the map fails to resolve, so a null/stale map turns a real
    // hole into "no boundary loops". The `const` reader that legitimately
    // tolerates an unbuilt map returns a sentinel instead of asserting (see
    // `constraint.nearestFaceEdge`); this one has no sentinel to return.
    // TASK 0833 — demonstrated live: tests/unit/mesh_analysis_test.d builds an
    // importer-shaped mesh (`addFaceFast`, no terminal buildLoops) and requires
    // this to throw, then requires the same call to succeed after buildLoops().
    // Deleting this line turns that block red.
    mesh.assertEdgeMapValid();
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
