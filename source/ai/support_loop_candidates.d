module ai.support_loop_candidates;

// AI Support-Loop Advisor — Phase A0 (task 0386): the geometric candidate
// generator. Detects sharp (high-dihedral) edges, groups them into
// topological edge-loop chains, proposes a support-loop operation (width /
// segments / kind) for each chain, featurizes it, and ranks the chains with
// a deterministic heuristic score. No ML/ONNX here — this is the "geometry
// GENERATES candidates" half of the ranker architecture used elsewhere in
// `source/ai/` (see `ai.element_candidates` / `ai.mode_candidates`); a later
// phase plugs an ONNX-scored rank in ADDITION to (or instead of) the
// heuristic below, exactly the way `ai.onnx_backend` sits behind
// `ai.advisor`'s heuristic fallback today. Pure D — must compile and be
// useful with `WithAI` undefined, same as the rest of `source/ai/`.
//
// Why `SupportLoopCandidate` is its own struct, not `ai.interaction.AiCandidate`:
// `AiCandidate` (see `ai.interaction`) is shaped for the existing
// element/handle/mode-tool-context ranker groups — a single screen/world
// position, a screen/world distance to the cursor, a small enum
// `elementKind`. A support-loop candidate is a different kind of thing: an
// ORDERED CHAIN of edges (not a point), with its own operation parameters
// (width, segments, kind) that a later "accept" step would feed straight
// into a bevel/inset command. Forcing it through `AiCandidate` would either
// drop the edge chain + operation params on the floor, or repurpose
// unrelated fields (`worldPosition` for "the loop's centroid"?) in a way
// that would confuse the existing element/handle consumers of that schema.
//
// The two schemas are still built on the SAME conventions so Phase B can
// extend `ai.ranker_schema` cleanly:
//   - a versioned, fixed-width `float[]` feature vector with a matching
//     `string[]` names function for introspection/training tooling
//     (mirrors `aiRankerCandidateFeatureNames` / `encodeAiRankerCandidate`);
//   - values normalized into ~[0, 1] via the same `clamp01`-style scale
//     constants (mirrors `aiRankerScreenDistanceScale` etc.);
//   - a `score` field playing the same role `AiAdvisorDecision.confidence`
//     plays for element/handle candidates — "how strongly is this
//     suggested", computed deterministically here, replaceable by an ONNX
//     score later without changing the candidate shape.
// Phase B's natural extension point: add
// `AiRankerCandidateGroup.supportLoop` to `ai.ranker_schema` alongside
// `handle` / `element` / `modeToolContext`, plus a
// `encodeSupportLoopRankerCandidate` that maps `SupportLoopCandidate.features`
// (already the right shape) into a padded `AiRankerFeatureBatch` row — no
// change needed here to support that.

import std.algorithm : max;
import std.conv : to;
import std.math : isFinite;

import mesh : Mesh, EdgeSharpness;
import math : Vec3;

enum int supportLoopFeatureSchemaVersion = 1;

// Normalization scales — same "divide-and-clamp-to-[0,1]" convention as
// ai.ranker_schema's aiRanker*Scale constants.
enum float supportLoopDihedralScaleDeg   = 180.0f;
enum float supportLoopEdgeCountScale     = 32.0f;
enum float supportLoopWorldLengthScale   = 10.0f;
enum float supportLoopValenceScale       = 8.0f;

/// Default fraction of the chain's mean edge length used as the proposed
/// support-loop width/offset (task guidance: ~5-10%).
enum float supportLoopDefaultWidthFraction = 0.08f;

/// Dihedral (degrees) at which the score's sharpness term saturates to 1.0.
/// A right-angle fold (90deg — the dihedral of an ordinary box/cube edge,
/// the single most common hard-surface feature) is already "as sharp as it
/// gets" for ranking purposes; scaling all the way to a 180deg degenerate
/// fold-back would under-score the common case (see the cube unittest).
enum float supportLoopSharpnessSaturationDeg = 90.0f;

/// Dihedral (degrees) at/above which a chain is proposed as `bevel` rather
/// than a plain `inset` — a strong enough crease that rounding the corner
/// (not just holding it) reads as the right default.
enum float supportLoopBevelDihedralDeg = 80.0f;

/// Dihedral (degrees) at/above which a second, centered loop is proposed
/// (`segments = 2`) in addition to the two flanking loops.
enum float supportLoopTwoSegmentDihedralDeg = 90.0f;

/// A chain is considered "already supported" when the narrowest adjacent
/// flanking strip (see `flankRatioForEdge`) is less than this fraction of
/// the sharp edge's own length — i.e. a thin parallel band already sits
/// right next to it, as a hand-placed support loop would leave behind.
enum float supportLoopAlreadySupportedRatio = 0.25f;

/// Heuristic-score multiplier applied when a chain is already supported —
/// keeps the candidate visible (so a UI could still offer "add the second
/// flank" or "convert to crease") but pushes it well below any unsupported
/// chain of comparable sharpness/length.
enum float supportLoopAlreadySupportedPenalty = 0.15f;

/// How a suggested support loop would be realized.
enum SupportLoopKind {
    bevel,   // very sharp / substantial loop → bevel (rounds the edge)
    inset,   // moderate sharpness → a pair of flanking inset loops
    crease,  // already (partially) supported, or too marginal for geometry
             // → prefer an OSD crease weight instead of new geometry
}

/// One suggested support-loop target: a chain of sharp mesh edges that
/// Catmull-Clark subdivision would visibly round unless flanked by holding
/// geometry (or given a crease weight).
struct SupportLoopCandidate {
    string          id = "";
    uint[]          edgeLoop;           // ordered edge indices into mesh.edges[]
    float           width = 0.0f;       // suggested offset, world units
    int             segments = 1;       // 1 = two flanking loops; 2 = + a center loop
    SupportLoopKind kind = SupportLoopKind.inset;
    float           score = 0.0f;       // heuristic rank; higher = more strongly suggested
    bool            closed = false;     // chain forms a closed ring (no free ends)
    bool            alreadySupported = false;
    float[]         features;           // see supportLoopFeatureNames()
}

string[] supportLoopFeatureNames() {
    return [
        "loop.mean_dihedral_norm",
        "loop.min_dihedral_norm",
        "loop.edge_count_norm",
        "loop.world_length_norm",
        "loop.mean_edge_length_norm",
        "loop.junction_valence_norm",
        "loop.symmetry_hint",
        "loop.already_supported",
        "loop.closed_loop",
        "loop.kind_bevel",
        "loop.kind_inset",
        "loop.kind_crease",
    ];
}

/// Generate support-loop candidates for `mesh`. Deterministic: the same
/// mesh (same vertex/edge/face arrays) always yields the same candidates in
/// the same order with the same scores — no randomness, no hash-order
/// dependence (grouping/seeding always walks edges by increasing index).
///
/// Steps (see module doc comment for the overall design):
///  1. `mesh.computeEdgeSharpness` (shared with `MeshSmooth.lockSharp`)
///     marks every INTERIOR edge whose dihedral exceeds `dihedralThresholdDeg`.
///  2. Sharp edges are grouped into chains by walking the mesh's existing
///     quad edge-loop ring (`Mesh.walkEdgeLoop`) from each unvisited sharp
///     edge in both ring directions, truncating at the first non-sharp
///     edge OR the first edge already claimed by an earlier candidate (see
///     `buildSharpChain`'s doc comment for why the latter is needed on
///     irregular/extraordinary-vertex meshes like a cube) — i.e. we reuse
///     the topological loop walk, just truncated. A mesh with an isolated
///     sharp edge (no quad neighbor to continue the ring) yields a 1-edge
///     chain.
///  3. Each chain gets a proposed width/segments/kind and a feature vector.
///  4. A deterministic heuristic score ranks sharper / longer / thicker
///     (not-already-supported) chains above marginal or already-supported
///     ones.
SupportLoopCandidate[] generateSupportLoopCandidates(
    const ref Mesh mesh, float dihedralThresholdDeg = 30.0f) {
    immutable nEdges = mesh.edges.length;
    auto sharpness = mesh.computeEdgeSharpness(dihedralThresholdDeg);

    bool[] sharpMask = new bool[](nEdges);
    foreach (ei; 0 .. nEdges) sharpMask[ei] = sharpness[ei].sharp;

    // Per-vertex count of incident sharp edges — used for the
    // junction-valence feature (how "busy" a chain's free end is).
    uint[] sharpDegree = new uint[](mesh.vertices.length);
    foreach (ei; 0 .. nEdges) {
        if (!sharpMask[ei]) continue;
        auto e = mesh.edges[ei];
        if (e[0] < sharpDegree.length) sharpDegree[e[0]]++;
        if (e[1] < sharpDegree.length) sharpDegree[e[1]]++;
    }

    bool[] visited = new bool[](nEdges);
    SupportLoopCandidate[] result;

    foreach (ei; 0 .. nEdges) {
        if (!sharpMask[ei] || visited[ei]) continue;

        auto chainEdges = buildSharpChain(mesh, cast(uint)ei, sharpMask, visited);
        foreach (ce; chainEdges) if (ce < visited.length) visited[ce] = true;
        if (chainEdges.length == 0) continue; // defensive; ei is sharp so unreachable

        auto path = reconstructVertexPath(mesh, chainEdges);
        if (path.length < 2) continue;
        immutable closed = path[0] == path[$ - 1];

        float sumDihedral = 0.0f;
        float minDihedral = float.infinity;
        foreach (ce; chainEdges) {
            immutable a = sharpness[ce].angleDeg;
            sumDihedral += a;
            if (a < minDihedral) minDihedral = a;
        }
        immutable edgeCount = chainEdges.length;
        immutable meanDihedral = sumDihedral / cast(float)edgeCount;

        float worldLength = 0.0f;
        foreach (i; 0 .. path.length - 1)
            worldLength += (mesh.vertices[path[i + 1]] - mesh.vertices[path[i]]).length;
        immutable meanEdgeLength = worldLength / cast(float)edgeCount;

        immutable meanFlankRatio = meanFlankRatioForChain(mesh, chainEdges);
        immutable alreadySupported = meanFlankRatio.isFinite &&
            meanFlankRatio < supportLoopAlreadySupportedRatio;

        immutable junctionValence = closed
            ? 0u
            : max(sharpDegree[path[0]], sharpDegree[path[$ - 1]]);

        SupportLoopKind kind;
        if (alreadySupported)
            kind = SupportLoopKind.crease;
        else if (meanDihedral >= supportLoopBevelDihedralDeg && edgeCount >= 3)
            kind = SupportLoopKind.bevel;
        else
            kind = SupportLoopKind.inset;

        immutable width    = meanEdgeLength * supportLoopDefaultWidthFraction;
        immutable segments = meanDihedral >= supportLoopTwoSegmentDihedralDeg ? 2 : 1;
        immutable symHint  = chainCentroidNearMirrorPlane(mesh, path) ? 1.0f : 0.0f;

        SupportLoopCandidate cand;
        cand.id       = "supportloop:" ~ ei.to!string ~ ":" ~ edgeCount.to!string;
        cand.edgeLoop = chainEdges;
        cand.width    = width;
        cand.segments = segments;
        cand.kind     = kind;
        cand.closed   = closed;
        cand.alreadySupported = alreadySupported;
        cand.score = heuristicSupportLoopScore(
            meanDihedral, dihedralThresholdDeg, worldLength, edgeCount, alreadySupported);
        cand.features = encodeSupportLoopFeatures(
            meanDihedral, minDihedral, edgeCount, worldLength, meanEdgeLength,
            junctionValence, symHint, alreadySupported, closed, kind);

        result ~= cand;
    }

    return result;
}

float heuristicSupportLoopScore(float meanDihedralDeg, float thresholdDeg,
                                float worldLength, size_t edgeCount,
                                bool alreadySupported) {
    immutable sharpnessTerm = clamp01(
        (meanDihedralDeg - thresholdDeg) /
        max(1.0f, supportLoopSharpnessSaturationDeg - thresholdDeg));
    immutable lengthTerm = clamp01(worldLength / supportLoopWorldLengthScale);
    immutable countTerm  = clamp01(cast(float)edgeCount / supportLoopEdgeCountScale);
    immutable base = clamp01(0.5f * sharpnessTerm + 0.3f * lengthTerm + 0.2f * countTerm);
    return alreadySupported ? base * supportLoopAlreadySupportedPenalty : base;
}

float[] encodeSupportLoopFeatures(float meanDihedralDeg, float minDihedralDeg,
                                  size_t edgeCount, float worldLength,
                                  float meanEdgeLength, uint junctionValence,
                                  float symmetryHint, bool alreadySupported,
                                  bool closed, SupportLoopKind kind) {
    auto v = new float[](supportLoopFeatureNames().length);
    size_t i = 0;
    v[i++] = clamp01(meanDihedralDeg / supportLoopDihedralScaleDeg);
    v[i++] = clamp01(minDihedralDeg.isFinite ? minDihedralDeg / supportLoopDihedralScaleDeg : 0.0f);
    v[i++] = clamp01(cast(float)edgeCount / supportLoopEdgeCountScale);
    v[i++] = clamp01(worldLength / supportLoopWorldLengthScale);
    v[i++] = clamp01(meanEdgeLength / supportLoopWorldLengthScale);
    v[i++] = clamp01(cast(float)junctionValence / supportLoopValenceScale);
    v[i++] = clamp01(symmetryHint);
    v[i++] = alreadySupported ? 1.0f : 0.0f;
    v[i++] = closed ? 1.0f : 0.0f;
    v[i++] = kind == SupportLoopKind.bevel  ? 1.0f : 0.0f;
    v[i++] = kind == SupportLoopKind.inset  ? 1.0f : 0.0f;
    v[i++] = kind == SupportLoopKind.crease ? 1.0f : 0.0f;
    assert(i == v.length);
    return v;
}

// ---------------------------------------------------------------------
// Chain construction
// ---------------------------------------------------------------------

/// Build the maximal sharp-only chain through `startEdge` by walking the
/// mesh's existing quad edge-loop ring (`Mesh.walkEdgeLoop`) in BOTH
/// directions (once per adjacent face of `startEdge`) and keeping only the
/// contiguous sharp prefix of each walk. Reuses the topological ring
/// traversal rather than reimplementing quad-hopping; the truncation
/// conditions ("stop at the first non-sharp edge, or the first edge already
/// claimed by an earlier candidate") are new.
///
/// The `claimed` truncation matters on irregular (non-grid) quad meshes —
/// e.g. a cube's corners are valence-3, an extraordinary vertex for a quad
/// mesh, so `walkEdgeLoop`'s "opposite edge of the next face" rule does not
/// partition a cube's 12 edges into clean disjoint 4-edge rings the way it
/// would on a regular grid: two different seed edges' walks can converge on
/// the same territory. Stopping at an already-`claimed` edge keeps every
/// edge in exactly one candidate regardless of processing order, at the
/// cost of chain shape depending on which edge happened to seed first —
/// acceptable for a first-pass heuristic generator (still fully
/// deterministic for a fixed mesh, since seeding always walks edges by
/// increasing index).
///
/// For a uniformly-sharp closed ring on a regular grid, the first
/// direction's walk already returns the whole closed cycle (`walkEdgeLoop`
/// stops on revisiting its start key), so the second direction contributes
/// nothing new — handled by the `seen` de-dup below, not by special-casing
/// closed vs. open chains.
private uint[] buildSharpChain(const ref Mesh mesh, uint startEdge,
                               const(bool)[] sharpMask, const(bool)[] claimed) {
    uint[] chain;
    bool[uint] seen;

    void addSharpPrefix(const(int)[] ring) {
        foreach (e; ring) {
            if (e < 0) break;
            immutable ue = cast(uint)e;
            if (ue >= sharpMask.length || !sharpMask[ue]) break; // left the sharp region
            if (ue in seen) continue;                            // ring closed on itself
            if (ue < claimed.length && claimed[ue]) break;        // another candidate's turf
            chain ~= ue;
            seen[ue] = true;
        }
    }

    int faceA = -1, faceB = -1;
    foreach (fi; mesh.facesAroundEdge(startEdge)) {
        if (faceA < 0) faceA = cast(int)fi;
        else if (faceB < 0) faceB = cast(int)fi;
    }
    if (faceA >= 0) addSharpPrefix(mesh.walkEdgeLoop(cast(int)startEdge, faceA));
    if (faceB >= 0) addSharpPrefix(mesh.walkEdgeLoop(cast(int)startEdge, faceB));
    return chain;
}

/// Reconstruct the ordered vertex path through a chain of edges (each
/// consecutive pair sharing exactly one vertex). For a closed chain the
/// first and last vertex are equal. Returns `[]` for an empty chain.
private uint[] reconstructVertexPath(const ref Mesh mesh, const(uint)[] chainEdges) {
    if (chainEdges.length == 0) return [];
    if (chainEdges.length == 1) {
        auto e = mesh.edges[chainEdges[0]];
        return [e[0], e[1]];
    }
    auto e0 = mesh.edges[chainEdges[0]];
    auto e1 = mesh.edges[chainEdges[1]];
    immutable start = (e0[0] == e1[0] || e0[0] == e1[1]) ? e0[1] : e0[0];

    uint[] path = [start];
    uint cur = start;
    foreach (ei; chainEdges) {
        auto e = mesh.edges[ei];
        uint next;
        if (e[0] == cur) next = e[1];
        else if (e[1] == cur) next = e[0];
        else return path; // malformed chain (shouldn't happen); bail with what we built
        path ~= next;
        cur = next;
    }
    return path;
}

// ---------------------------------------------------------------------
// "Already supported?" — thin flanking-strip detection
// ---------------------------------------------------------------------

/// Given a quad face `fi` and the endpoints (`u`, `v`) of one of its edges
/// (in either order), return the two "flank" vertices — the face corners
/// adjacent to `u` and `v` respectively that are NOT part of the u-v edge.
/// For a well-formed quad strip these define the local "width" of the
/// strip on this face's side of the edge.
private bool quadFlank(const ref Mesh mesh, uint fi, uint u, uint v,
                       out uint flankAtU, out uint flankAtV) {
    if (fi >= mesh.faces.length) return false;
    const face = mesh.faces[fi];
    if (face.length != 4) return false;

    int j = -1;
    foreach (k; 0 .. 4) {
        if ((face[k] == u && face[(k + 1) % 4] == v) ||
            (face[k] == v && face[(k + 1) % 4] == u)) { j = k; break; }
    }
    if (j < 0) return false;

    immutable a = face[j];
    immutable d = face[(j + 3) % 4]; // adjacent to a via edge d-a
    immutable c = face[(j + 2) % 4]; // adjacent to b via edge b-c
    if (a == u) { flankAtU = d; flankAtV = c; }
    else        { flankAtU = c; flankAtV = d; }
    return true;
}

/// For one sharp edge, the narrowest adjacent flanking-strip width divided
/// by the edge's own length — small when a thin parallel band (a
/// hand-placed support loop, or a prior partial bevel) already sits right
/// next to it. Returns `float.infinity` when no quad flank is available.
private float flankRatioForEdge(const ref Mesh mesh, uint ei) {
    auto e = mesh.edges[ei];
    immutable edgeLen = (mesh.vertices[e[1]] - mesh.vertices[e[0]]).length;
    if (edgeLen < 1e-9f) return float.infinity;

    float minFlank = float.infinity;
    foreach (fi; mesh.facesAroundEdge(ei)) {
        uint flankU, flankV;
        if (!quadFlank(mesh, fi, e[0], e[1], flankU, flankV)) continue;
        immutable side = 0.5f * (
            (mesh.vertices[flankU] - mesh.vertices[e[0]]).length +
            (mesh.vertices[flankV] - mesh.vertices[e[1]]).length);
        if (side < minFlank) minFlank = side;
    }
    return minFlank.isFinite ? minFlank / edgeLen : float.infinity;
}

/// Mean `flankRatioForEdge` over a chain; `float.infinity` if no edge in the
/// chain has a usable quad flank (e.g. non-quad faces).
private float meanFlankRatioForChain(const ref Mesh mesh, const(uint)[] chainEdges) {
    float sum = 0.0f;
    int count = 0;
    foreach (ei; chainEdges) {
        immutable r = flankRatioForEdge(mesh, ei);
        if (!r.isFinite) continue;
        sum += r;
        count++;
    }
    return count > 0 ? sum / cast(float)count : float.infinity;
}

// ---------------------------------------------------------------------
// Symmetry hint
// ---------------------------------------------------------------------

/// Cheap symmetry signal: does the chain's centroid sit close to a
/// cardinal plane through the mesh's own bounding-box center? Rings that
/// straddle a mirror plane (or sit exactly on one) usually have a mirrored
/// counterpart elsewhere in the candidate list — useful later for
/// symmetry-aware application, without a full mesh-wide symmetry detector.
private bool chainCentroidNearMirrorPlane(const ref Mesh mesh, const(uint)[] path) {
    if (path.length == 0 || mesh.vertices.length == 0) return false;

    Vec3 lo = mesh.vertices[0], hi = mesh.vertices[0];
    foreach (v; mesh.vertices) {
        if (v.x < lo.x) lo.x = v.x; if (v.x > hi.x) hi.x = v.x;
        if (v.y < lo.y) lo.y = v.y; if (v.y > hi.y) hi.y = v.y;
        if (v.z < lo.z) lo.z = v.z; if (v.z > hi.z) hi.z = v.z;
    }
    immutable cx = (lo.x + hi.x) * 0.5f, cy = (lo.y + hi.y) * 0.5f, cz = (lo.z + hi.z) * 0.5f;
    immutable ex = hi.x - lo.x, ey = hi.y - lo.y, ez = hi.z - lo.z;

    Vec3 centroid = Vec3(0, 0, 0);
    foreach (vi; path) centroid = centroid + mesh.vertices[vi];
    centroid = centroid * (1.0f / cast(float)path.length);

    enum float tol = 0.02f;
    if (ex > 1e-6f && absf(centroid.x - cx) / ex < tol) return true;
    if (ey > 1e-6f && absf(centroid.y - cy) / ey < tol) return true;
    if (ez > 1e-6f && absf(centroid.z - cz) / ez < tol) return true;
    return false;
}

private float absf(float v) { return v < 0.0f ? -v : v; }

private float clamp01(float value) {
    if (!value.isFinite || value < 0.0f) return 0.0f;
    if (value > 1.0f) return 1.0f;
    return value;
}

// =======================================================================
// Unit tests
// =======================================================================

version(unittest) {
    import mesh : makeCube;
}
