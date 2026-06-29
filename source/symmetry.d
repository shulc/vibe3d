module symmetry;

import std.algorithm : sort, max;
import std.math      : abs;

import math : Vec3, dot;
import mesh : Mesh;
import toolpipe.packets : SymmetryPacket;

// ---------------------------------------------------------------------------
// Symmetry — phase 7.6b math helpers and per-vertex pairing builder.
//
// The SymmetryStage owns the cache + lifecycle (`rebuildPairing` is called
// from `Stage.evaluate` whenever `Mesh.mutationVersion` or the plane has
// changed); tools and the headless `mesh.transform` consume the published
// `SymmetryPacket` and call `mirrorPosition` / `applySymmetryMirror` per
// frame.
// ---------------------------------------------------------------------------

/// Config-equality for two SymmetryPackets — compares only the user-facing
/// CONFIG fields (the ones SymmetryStage.snapshotConfigToPacket round-trips),
/// NOT the derived plane / pairing snapshot (planePoint / planeNormal / pairOf /
/// onPlane / vertSign, which evaluate() rebuilds from the config + live mesh).
/// Used by the transform wrapper's refire trigger (P-C) to detect a mid-run
/// symmetry-config change, mirroring falloffPacketsEqual.
bool symmetryPacketsEqual(const ref SymmetryPacket a, const ref SymmetryPacket b)
    pure nothrow @nogc @safe
{
    return a.enabled      == b.enabled
        && a.axisIndex    == b.axisIndex
        && a.offset       == b.offset
        && a.useWorkplane == b.useWorkplane
        && a.topology     == b.topology
        && a.epsilonWorld == b.epsilonWorld
        && a.baseSide     == b.baseSide;
}

/// Mirror a world-space point across the plane described by `sp`.
/// `sp.planeNormal` must be unit length (the stage normalises it).
/// `pos_mirror = pos - 2 * dot(pos - planePoint, normal) * normal`.
Vec3 mirrorPosition(const ref SymmetryPacket sp, Vec3 pos) pure nothrow @nogc @safe {
    float d = dot(pos - sp.planePoint, sp.planeNormal);
    return pos - sp.planeNormal * (2.0f * d);
}

/// Project a world-space point onto the plane described by `sp`. Used
/// for on-plane vertices when the user drags them with symmetry on — the
/// projection keeps them anchored to the plane instead of drifting off
/// (a "center vertex stays on the symmetry plane" rule).
Vec3 projectOnPlane(const ref SymmetryPacket sp, Vec3 pos) pure nothrow @nogc @safe {
    float d = dot(pos - sp.planePoint, sp.planeNormal);
    return pos - sp.planeNormal * d;
}

/// Is `pos` on the plane within `sp.epsilonWorld`?
bool isOnPlane(const ref SymmetryPacket sp, Vec3 pos) pure nothrow @nogc @safe {
    float d = dot(pos - sp.planePoint, sp.planeNormal);
    return abs(d) <= sp.epsilonWorld;
}

/// Per-vertex mirror lookup. Returns -1 when the vertex is on-plane,
/// unpaired, or out of range (callers should treat all of these as
/// "no mirror to drive").
int mirrorVertex(const ref SymmetryPacket sp, int vi) pure nothrow @nogc @safe {
    if (vi < 0 || vi >= cast(int)sp.pairOf.length) return -1;
    return sp.pairOf[vi];
}

/// Per-edge mirror lookup. Returns `~0u` (matches `Mesh.edgeIndex`'s
/// "no such edge" sentinel) when either endpoint is unpaired / on-
/// plane or the mirrored endpoints aren't connected by an edge in
/// the mesh. Self-mirror (both endpoints on the plane) is treated as
/// "no mirror" — the edge is already its own counterpart.
uint mirrorEdge(const ref Mesh m, const ref SymmetryPacket sp, uint ei)
{
    if (!sp.enabled || ei >= m.edges.length) return ~0u;
    if (sp.pairOf.length != m.vertices.length) return ~0u;
    uint a = m.edges[ei][0];
    uint b = m.edges[ei][1];
    int ma = sp.pairOf[a];
    int mb = sp.pairOf[b];
    // On-plane endpoints map to themselves: the user-visible "mirror
    // edge" of an edge with one endpoint on the plane is the same
    // edge if the other endpoint is also on-plane (the plane line
    // segment), otherwise the edge whose far endpoint is `pairOf[b]`.
    if (ma < 0 && sp.onPlane[a]) ma = cast(int)a;
    if (mb < 0 && sp.onPlane[b]) mb = cast(int)b;
    if (ma < 0 || mb < 0) return ~0u;
    if (ma == cast(int)a && mb == cast(int)b) return ~0u;       // self
    return m.edgeIndex(cast(uint)ma, cast(uint)mb);
}

/// Per-face mirror lookup. Returns `~0u` when no face has a matching
/// mirrored vertex set, or when the face is its own mirror (all
/// vertices on-plane).
///
/// Search strategy: build the mirrored vertex SET (order doesn't
/// matter — the mirrored face winds backwards), then linear-scan
/// `mesh.faces` for a face with the same vertex set. O(F * V_per_face)
/// per query; fine for editor-sized meshes (cube = 6 faces). When
/// large meshes start showing up the consumer should switch to a
/// hash-keyed lookup.
uint mirrorFace(const ref Mesh m, const ref SymmetryPacket sp, uint fi)
{
    if (!sp.enabled || fi >= m.faces.length) return ~0u;
    if (sp.pairOf.length != m.vertices.length) return ~0u;

    const(uint)[] face = m.faces[fi];
    if (face.length == 0) return ~0u;

    auto mirrored = new uint[](face.length);
    bool allOnPlane = true;
    foreach (i, v; face) {
        int mv = sp.pairOf[v];
        if (mv < 0 && sp.onPlane[v]) {
            mv = cast(int)v;            // on-plane vert is its own mirror
        } else if (mv < 0) {
            return ~0u;                  // unpaired vert → no mirror face
        } else {
            allOnPlane = false;
        }
        mirrored[i] = cast(uint)mv;
    }
    if (allOnPlane) return ~0u;          // face IS its own mirror

    // Compare sorted vert sets. The mirrored face winds backwards
    // (orientation flips across a plane), but the SET of verts is
    // what identifies the face in vibe3d's data structure.
    auto sortedMirror = mirrored.dup;
    import std.algorithm : sort;
    sort(sortedMirror);

    foreach (gi; 0 .. m.faces.length) {
        if (m.faces[gi].length != mirrored.length) continue;
        auto sortedG = m.faces[gi].dup;
        sort(sortedG);
        bool match = true;
        foreach (k; 0 .. sortedG.length) {
            if (sortedG[k] != sortedMirror[k]) { match = false; break; }
        }
        if (match) return cast(uint)gi;
    }
    return ~0u;
}

/// Build the per-vertex pairing table for `mesh` under the plane in
/// `sp` (uses `sp.planePoint`, `sp.planeNormal`, `sp.epsilonWorld`,
/// `sp.axisIndex`). Writes results into `outPairOf`, `outOnPlane`, and
/// `outVertSign` (allocated to `mesh.vertices.length` if shorter).
///
/// Algorithm (O(n log n)):
///   1. Walk every vertex `i`, compute `mirror[i] = mirrorPosition(v[i])`
///      and `outVertSign[i] = sign(dot(v[i] - planePoint, planeNormal))`.
///   2. Build an index `idx[]` of all vertices sorted by their dominant-
///      axis coordinate.
///   3. For each `i`, binary-search `idx[]` for the range of vertices
///      whose dominant coord lies within `epsilon` of `mirror[i]`'s, then
///      linear-scan that window for a 3D match within `epsilon`.
///   4. On-plane vertices (within `epsilon` of the plane) are tagged in
///      `outOnPlane[]`; their mirror is themselves so `outPairOf[i] = -1`.
///
/// Axis-aligned planes get the cheapest search axis automatically — the
/// dominant axis of `planeNormal` is the axis the mirror MOST changes,
/// so it has the highest discrimination power. For arbitrary axes the
/// algorithm still works (it just picks one orthogonal axis as the sort
/// key); the v1 stage only emits axis-aligned planes anyway.
void rebuildPairing(const ref Mesh mesh, const ref SymmetryPacket sp,
                    ref int[] outPairOf, ref bool[] outOnPlane,
                    ref int[] outVertSign)
{
    size_t n = mesh.vertices.length;
    if (outPairOf.length   != n) outPairOf.length   = n;
    if (outOnPlane.length  != n) outOnPlane.length  = n;
    if (outVertSign.length != n) outVertSign.length = n;

    if (n == 0) return;

    // Pre-compute mirror positions + on-plane flags + per-vertex side.
    // `vertSign` is captured here (pre-translate) so consumers like
    // `applySymmetryMirror` keep a stable view of which side each
    // vertex started on — even if a perpendicular translate would
    // push a selected vertex across the plane mid-operation.
    auto mirrored = new Vec3[](n);
    foreach (i; 0 .. n) {
        mirrored[i]  = mirrorPosition(sp, mesh.vertices[i]);
        outOnPlane[i] = isOnPlane(sp, mesh.vertices[i]);
        outPairOf[i]  = -1;
        float d = dot(mesh.vertices[i] - sp.planePoint, sp.planeNormal);
        if (abs(d) <= sp.epsilonWorld) outVertSign[i] = 0;
        else                           outVertSign[i] = d > 0 ? +1 : -1;
    }

    // Pick the search axis: the dominant component of `planeNormal`.
    // For an axis-aligned plane (normal == ±X/±Y/±Z) this is exact; for
    // arbitrary planes it's a heuristic that still narrows the candidate
    // window enough to stay below O(n).
    int sortAxis = dominantAxis(sp.planeNormal);

    // idx sorted by sortAxis coord. We sort vertex INDICES, not the
    // verts themselves, so the per-axis lookup that follows is a clean
    // index → coord lookup.
    auto idx = new int[](n);
    foreach (i; 0 .. n) idx[i] = cast(int)i;
    sort!((a, b) => axisCoord(mesh.vertices[a], sortAxis)
                 <  axisCoord(mesh.vertices[b], sortAxis))(idx);

    // For binary search we need a parallel coord array.
    auto sortedCoords = new float[](n);
    foreach (k; 0 .. n)
        sortedCoords[k] = axisCoord(mesh.vertices[idx[k]], sortAxis);

    float eps = sp.epsilonWorld;
    foreach (i; 0 .. n) {
        if (outOnPlane[i]) continue;   // own mirror; pairOf[i] stays -1

        float target = axisCoord(mirrored[i], sortAxis);
        // Binary-search the left + right bounds of [target - eps,
        // target + eps] in sortedCoords. Phobos' `std.range.assumeSorted`
        // would do this in one call; the open-coded loop avoids dragging
        // another import + a closure into a hot path.
        size_t lo = lowerBound(sortedCoords, target - eps);
        size_t hi = upperBound(sortedCoords, target + eps);

        int best = -1;
        float bestDist = eps * eps;        // squared (cheap compare)
        for (size_t k = lo; k < hi; ++k) {
            int j = idx[k];
            if (j == cast(int)i) continue; // can't pair to self off-plane
            Vec3 d = mesh.vertices[j] - mirrored[i];
            float d2 = d.x * d.x + d.y * d.y + d.z * d.z;
            if (d2 <= bestDist) {
                bestDist = d2;
                best     = j;
            }
        }
        outPairOf[i] = best;
    }
}

private int dominantAxis(Vec3 n) pure nothrow @nogc @safe {
    float ax = abs(n.x), ay = abs(n.y), az = abs(n.z);
    if (ax >= ay && ax >= az) return 0;
    if (ay >= ax && ay >= az) return 1;
    return 2;
}

private float axisCoord(Vec3 v, int axis) pure nothrow @nogc @safe {
    return axis == 0 ? v.x : (axis == 1 ? v.y : v.z);
}

// Smallest k with sortedCoords[k] >= target. Returns sortedCoords.length
// when target is larger than every element.
private size_t lowerBound(const float[] sortedCoords, float target) pure nothrow @nogc @safe {
    size_t lo = 0, hi = sortedCoords.length;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (sortedCoords[mid] < target) lo = mid + 1;
        else                            hi = mid;
    }
    return lo;
}

// Smallest k with sortedCoords[k] > target.
private size_t upperBound(const float[] sortedCoords, float target) pure nothrow @nogc @safe {
    size_t lo = 0, hi = sortedCoords.length;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (sortedCoords[mid] <= target) lo = mid + 1;
        else                             hi = mid;
    }
    return lo;
}

// ---------------------------------------------------------------------------
// applySymmetryMirror — copy mirrored positions from each selected
// vertex `vi` into its mirror `mi`, then snap any on-plane selected
// vertex back onto the plane.
//
// Convention: `selected[]` is a per-vertex bool mask of "verts the
// caller already moved". For each such `vi`:
//   • if `onPlane[vi]`: project `mesh.vertices[vi]` back onto the plane.
//   • else if `pairOf[vi] = mi` and `mi != vi`: set
//     `mesh.vertices[mi] = mirrorPosition(mesh.vertices[vi])`.
//
// `outAlsoTouched` is OR-ed with `mi` for each mirror write — callers
// use it to extend GPU upload / undo snapshot sets to cover the verts
// the mirror pass touched. Caller MUST size it to `mesh.vertices.length`
// before the call.
//
// **BaseSide drive rule.** When both `vi` and its mirror `mi` are in
// `selected[]` (the user picked both sides — e.g. via 7.6c's symmetric
// auto-add, or by shift-click), the side matching `sp.baseSide`
// (`-1`/`+1`) drives. The non-base side is skipped on its own
// iteration so its mirror write happens exactly once and from the
// user-anchored side. This matters when a perpendicular translate
// would otherwise push the lower-index vertex across the plane and
// flip the implicit drive direction.
//
// For lone-selected verts (mirror is NOT in `selected[]`), `vi`
// always drives — there's no ambiguity.
// ---------------------------------------------------------------------------
void applySymmetryMirror(Mesh* mesh, const ref SymmetryPacket sp,
                         const(bool)[] selected,
                         bool[] outAlsoTouched)
{
    if (!sp.enabled) return;
    if (sp.pairOf.length != mesh.vertices.length) return;
    foreach (i; 0 .. mesh.vertices.length) {
        if (i >= selected.length || !selected[i]) continue;
        if (sp.onPlane[i]) {
            mesh.vertices[i] = projectOnPlane(sp, mesh.vertices[i]);
            continue;
        }
        int mi = sp.pairOf[i];
        if (mi < 0 || mi == cast(int)i) continue;
        bool mirrorAlsoSelected =
            (mi < cast(int)selected.length) && selected[mi];
        if (mirrorAlsoSelected) {
            // Both sides selected — only the base-side vertex drives.
            // `vertSign[i]` is the PRE-translate side, so the rule
            // stays stable through a perpendicular drag that crosses
            // the plane.
            int iSign = (i < sp.vertSign.length) ? sp.vertSign[i] : 0;
            if (iSign != sp.baseSide) continue;
        }
        mesh.vertices[mi] = mirrorPosition(sp, mesh.vertices[i]);
        if (mi < cast(int)outAlsoTouched.length)
            outAlsoTouched[mi] = true;
    }
}

// ---------------------------------------------------------------------------
// mirrorDirection — reflect a direction vector (not a point) across the plane.
// The planePoint term from mirrorPosition drops out:
//   mirrorDirection(sp, d) = d − n·2·dot(d,n)
// ---------------------------------------------------------------------------

/// Reflect direction `dir` across the plane described by `sp`.
/// Unlike mirrorPosition this reflects a displacement vector, not a point, so
/// the planePoint offset is not involved. Used by the delta-mirror apply to
/// copy the driver's edit displacement to the partner in the mirrored direction.
Vec3 mirrorDirection(const ref SymmetryPacket sp, Vec3 dir) pure nothrow @nogc @safe {
    return dir - sp.planeNormal * (2.0f * dot(dir, sp.planeNormal));
}

// ---------------------------------------------------------------------------
// applySymmetryMirrorDelta — delta-mirror apply for topological symmetry.
//
// Identical structure to applySymmetryMirror (same guards, same baseSide
// rule, same on-plane projection) but writes:
//   mesh.vertices[mi] = baseline[mi] + mirrorDirection(sp, driver_delta)
// instead of the absolute position-copy in applySymmetryMirror.
//
// This preserves the partner's pre-existing deformation (baseline[mi]) and
// mirrors only the edit delta, so a deformed-base mesh stays deformed while
// the edit is reflected symmetrically.
//
// Equivalence: on a spatially-symmetric base (baseline[mi] == mirrorPosition(
// sp, baseline[i])), the two functions are float-exact-identical (see the
// proof in doc/topological_symmetry_plan.md Risk 1).
// ---------------------------------------------------------------------------

/// Delta-mirror apply. For each selected driver vertex `i`:
///   - on-plane:  project mesh.vertices[i] onto the plane.
///   - off-plane: mesh.vertices[mi] = baseline[mi] + mirrorDirection(sp, delta)
///                where delta = mesh.vertices[i] − baseline[i].
/// `baseline` must be mesh-length (same sizing contract as `outAlsoTouched`).
/// No-ops safely when lengths don't match.
void applySymmetryMirrorDelta(Mesh* mesh, const ref SymmetryPacket sp,
                              const(Vec3)[] baseline,
                              const(bool)[] selected,
                              bool[] outAlsoTouched)
{
    if (!sp.enabled) return;
    if (sp.pairOf.length != mesh.vertices.length) return;
    if (baseline.length  != mesh.vertices.length) return;
    foreach (i; 0 .. mesh.vertices.length) {
        if (i >= selected.length || !selected[i]) continue;
        if (sp.onPlane[i]) {
            mesh.vertices[i] = projectOnPlane(sp, mesh.vertices[i]);
            continue;
        }
        int mi = sp.pairOf[i];
        if (mi < 0 || mi == cast(int)i) continue;
        bool mirrorAlsoSelected =
            (mi < cast(int)selected.length) && selected[mi];
        if (mirrorAlsoSelected) {
            int iSign = (i < sp.vertSign.length) ? sp.vertSign[i] : 0;
            if (iSign != sp.baseSide) continue;
        }
        Vec3 delta = mesh.vertices[i] - baseline[i];
        mesh.vertices[mi] = baseline[mi] + mirrorDirection(sp, delta);
        if (mi < cast(int)outAlsoTouched.length)
            outAlsoTouched[mi] = true;
    }
}

// ---------------------------------------------------------------------------
// isBoundaryVertexMesh — boundary check derived from loop/twin adjacency,
// matching the VertexNeighborRange open-fan detection exactly.
// ---------------------------------------------------------------------------

/// True when vertex `vi` is incident to a boundary edge (twin == ~0u),
/// meaning its fan is OPEN. Uses the same twin(prev(cur)) walk that
/// VertexNeighborRange uses — guarantees the OPEN/CYCLIC classification
/// agrees with the materialized neighbor array.
private bool isBoundaryVertexMesh(const ref Mesh mesh, uint vi) pure nothrow @nogc {
    if (vi >= mesh.vertLoop.length) return false;
    uint startLi = mesh.vertLoop[vi];
    if (startLi == ~0u) return false;
    uint cur = startLi;
    enum uint MAX_STEPS = 1024;
    for (uint steps = 0; steps < MAX_STEPS; ++steps) {
        uint prevLi   = mesh.loops[cur].prev;
        uint twinPrev = mesh.loops[prevLi].twin;
        if (twinPrev == ~0u) return true;   // boundary edge → OPEN fan
        cur = twinPrev;
        if (cur == startLi) return false;   // full circle → CYCLIC fan
    }
    return true;   // MAX_STEPS exceeded = non-manifold; treat as OPEN
}

// ---------------------------------------------------------------------------
// rebuildPairingTopological — connectivity-based pairing.
//
// Seeds from seam (on-plane) vertices that have a seam-edge neighbor, then
// walks the mesh connectivity via a BFS lock-step matching rule:
//   • CYCLIC fans: reversed modular wrap (orientation flip across the plane).
//   • OPEN fans:   reversed linear sequence (no modular wrap).
// Reference slot (the first anchored neighbor shared by both sides) anchors
// the reversal deterministically. On any valence/kind/consistency/side
// mismatch the expansion is abandoned; unpaired vertices stay pairOf = -1
// (safe degradation = no mirror for that vertex, identical to the spatial
// builder's "no candidate" outcome).
//
// Same output-sizing contract as rebuildPairing: allocates outPairOf /
// outOnPlane / outVertSign to mesh.vertices.length.
//
// Precondition: seam vertices lie on the plane within sp.epsilonWorld AND
// are connected to other seam vertices. A mesh with no such vertices
// produces an all-(-1) pairing (safe degradation).
// ---------------------------------------------------------------------------

/// Build the per-vertex pairing table from mesh connectivity.
/// Produces the same output triple (pairOf, onPlane, vertSign) as
/// rebuildPairing, derived from winding-order fan matching rather than
/// spatial proximity.
void rebuildPairingTopological(const ref Mesh mesh, const ref SymmetryPacket sp,
                               ref int[] outPairOf, ref bool[] outOnPlane,
                               ref int[] outVertSign)
{
    size_t n = mesh.vertices.length;
    if (outPairOf.length   != n) outPairOf.length   = n;
    if (outOnPlane.length  != n) outOnPlane.length  = n;
    if (outVertSign.length != n) outVertSign.length = n;
    if (n == 0) return;

    // Seam + side classification — identical to rebuildPairing so semantics match.
    outPairOf[] = -1;
    foreach (i; 0 .. n) {
        float d = dot(mesh.vertices[i] - sp.planePoint, sp.planeNormal);
        outOnPlane[i]  = (abs(d) <= sp.epsilonWorld);
        outVertSign[i] = (abs(d) <= sp.epsilonWorld) ? 0 : (d > 0 ? +1 : -1);
    }

    // BFS state. Both queues advance in lock-step (queueA[i] = driver,
    // queueB[i] = partner). visited[] tracks pushed DRIVER vertices to
    // prevent re-pushing the same pair from multiple neighbor routes.
    bool[]  visited = new bool[](n);
    uint[]  queueA, queueB;
    size_t  qHead = 0;

    // Seed: seam vertices with at least one seam-edge neighbor, ascending index.
    // A seam vertex with no seam-edge neighbor provides no rotational anchor
    // (0.D.2) and is skipped; its off-plane neighbors may still be reached
    // from a neighboring seed.
    foreach (c; 0 .. n) {
        if (!outOnPlane[c]) continue;
        bool hasSeamNb = false;
        foreach (nb; mesh.verticesAroundVertex(cast(uint)c)) {
            if (outOnPlane[nb] && mesh.edgeIndex(cast(uint)c, nb) != ~0u) {
                hasSeamNb = true;
                break;
            }
        }
        if (!hasSeamNb) continue;
        queueA ~= cast(uint)c;
        queueB ~= cast(uint)c;
        visited[c] = true;
    }

    while (qHead < queueA.length) {
        uint a = queueA[qHead];
        uint b = queueB[qHead];
        ++qHead;

        // Materialize neighbor arrays.
        uint[] Na, Nb;
        foreach (nb; mesh.verticesAroundVertex(a)) Na ~= nb;
        if (a == b) {
            Nb = Na;   // self-pair: same vertex, same fan
        } else {
            foreach (nb; mesh.verticesAroundVertex(b)) Nb ~= nb;
        }

        bool openA = isBoundaryVertexMesh(mesh, a);
        bool openB = (a == b) ? openA : isBoundaryVertexMesh(mesh, b);
        int  d     = cast(int)Na.length;
        int  e     = cast(int)Nb.length;

        // Valence / fan-kind gates (0.F.1).
        if (d != e || d == 0) continue;
        if (openA != openB) continue;

        // Find reference slot: first anchored neighbor of `a` whose partner
        // is a member of `Nb`. "Anchored" = onPlane OR already paired.
        int  ra = -1, rb = -1;
        foreach (k; 0 .. d) {
            uint na = Na[k];
            bool anchored = outOnPlane[na] || outPairOf[na] >= 0;
            if (!anchored) continue;
            uint partnerNa = outOnPlane[na] ? na : cast(uint)outPairOf[na];
            // Linear scan of Nb for partnerNa.
            int rbCand = -1;
            foreach (m; 0 .. e) {
                if (Nb[m] == partnerNa) { rbCand = m; break; }
            }
            if (rbCand < 0) continue;
            ra = k; rb = rbCand;
            break;
        }
        if (ra < 0) continue;   // no reference → abandon expansion (0.F.2)

        // Open-fan consistency gate (0.F.2): the clean reversal must pin the
        // reference — ra + rb == d − 1.
        if (openA && (ra + rb != d - 1)) continue;

        if (!openA) {
            // CYCLIC fans: reversed modular walk (k = 1 .. d−1).
            foreach (k; 1 .. d) {
                uint na  = Na[(ra + k) % d];
                uint nb_ = Nb[((rb - k) % e + e) % e];
                if (outOnPlane[na]) continue;
                if (outPairOf[na] >= 0) continue;              // na already settled
                if (na == nb_) continue;                        // degenerate (0.F.6)
                if (outOnPlane[nb_]) continue;                  // partner-side seam (0.F.4)
                if (outPairOf[nb_] >= 0 && outPairOf[nb_] != cast(int)na) continue; // conflict (0.F.5)
                if (outVertSign[nb_] != -outVertSign[na]) continue;   // side mismatch (0.F.3)
                outPairOf[na]  = cast(int)nb_;
                outPairOf[nb_] = cast(int)na;
                if (!visited[na]) { queueA ~= na; queueB ~= nb_; visited[na] = true; }
            }
        } else {
            // OPEN fans: reversed linear (j = 0 .. d−1, partner slot d−1−j).
            foreach (j; 0 .. d) {
                if (j == ra) continue;                          // reference slot, skip
                uint na  = Na[j];
                uint nb_ = Nb[d - 1 - j];
                if (outOnPlane[na]) continue;
                if (outPairOf[na] >= 0) continue;
                if (na == nb_) continue;
                if (outOnPlane[nb_]) continue;
                if (outPairOf[nb_] >= 0 && outPairOf[nb_] != cast(int)na) continue;
                if (outVertSign[nb_] != -outVertSign[na]) continue;
                outPairOf[na]  = cast(int)nb_;
                outPairOf[nb_] = cast(int)na;
                if (!visited[na]) { queueA ~= na; queueB ~= nb_; visited[na] = true; }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Unittests — run only under `dub test --config=modeling`, NOT `run_test.d`
// (the HTTP suite static-lib path never compiles this module standalone).
// ---------------------------------------------------------------------------

version (unittest) {
    import std.conv : to;

    // Build a minimal two-quad mesh sharing a seam edge on X=0.
    // Vertex layout (matches the plan's Phase 0.G worked example):
    //   0: c0 = (0, 0, 0)      — seam
    //   1: c1 = (0, 1, 0)      — seam
    //   2: A  = (2.0, 0.5, 0)  — +X driver (deformed off its spatial-mirror position)
    //   3: B  = (1.5, 1.2, 0)  — +X top
    //   4: D  = (-0.8,-0.3,0)  — -X partner of A (independently deformed)
    //   5: C  = (-1.1, 1.3,0)  — -X partner of B
    // Face 0 (+X quad): [c0, A, B, c1] = [0, 2, 3, 1]
    // Face 1 (-X quad): [c0, c1, C, D] = [0, 1, 5, 4]
    // Spatial mirror of A=(2.0,0.5,0) is (-2.0,0.5,0) — no vertex within any
    // reasonable epsilon of that point, so the spatial builder leaves A unpaired.
    private Mesh makeDeformedTwoQuadMesh() {
        Mesh m;
        m.addVertex(Vec3( 0.0f,  0.0f, 0.0f));   // 0: c0
        m.addVertex(Vec3( 0.0f,  1.0f, 0.0f));   // 1: c1
        m.addVertex(Vec3( 2.0f,  0.5f, 0.0f));   // 2: A (+X)
        m.addVertex(Vec3( 1.5f,  1.2f, 0.0f));   // 3: B (+X)
        m.addVertex(Vec3(-0.8f, -0.3f, 0.0f));   // 4: D (-X)
        m.addVertex(Vec3(-1.1f,  1.3f, 0.0f));   // 5: C (-X)
        m.addFace([0u, 2u, 3u, 1u]);              // +X quad: c0, A, B, c1
        m.addFace([0u, 1u, 5u, 4u]);              // -X quad: c0, c1, C, D
        m.buildLoops();
        return m;
    }

    // Helper: build an X-axis SymmetryPacket (plane X=0).
    private SymmetryPacket xPlanePacket(float eps = 1e-4f) {
        SymmetryPacket sp;
        sp.enabled      = true;
        sp.topology     = true;
        sp.axisIndex    = 0;
        sp.planeNormal  = Vec3(1, 0, 0);
        sp.planePoint   = Vec3(0, 0, 0);
        sp.epsilonWorld = eps;
        sp.baseSide     = +1;
        return sp;
    }
}

unittest { // mirrorDirection: X-plane negates only X component of dir
    import std.math : isClose;
    auto sp = xPlanePacket();
    auto d  = Vec3(3.0f, 4.0f, 5.0f);
    auto r  = mirrorDirection(sp, d);
    assert(isClose(r.x, -3.0f, 1e-6f), "mirrorDirection X expected -3, got " ~ r.x.to!string);
    assert(isClose(r.y,  4.0f, 1e-6f), "mirrorDirection Y unchanged, got "   ~ r.y.to!string);
    assert(isClose(r.z,  5.0f, 1e-6f), "mirrorDirection Z unchanged, got "   ~ r.z.to!string);

    // Non-axis-aligned direction: Z-plane (normal +Z).
    SymmetryPacket spZ;
    spZ.planeNormal = Vec3(0, 0, 1);
    spZ.planePoint  = Vec3(0, 0, 0);
    auto d2 = Vec3(1.0f, 2.0f, 3.0f);
    auto r2 = mirrorDirection(spZ, d2);
    assert(isClose(r2.x,  1.0f, 1e-6f));
    assert(isClose(r2.y,  2.0f, 1e-6f));
    assert(isClose(r2.z, -3.0f, 1e-6f));
}

unittest { // rebuildPairingTopological: pairs connectivity partners regardless of deformed positions
    import std.conv : to;
    auto m  = makeDeformedTwoQuadMesh();
    auto sp = xPlanePacket();

    int[]  pairOf; bool[] onPlane; int[] vertSign;
    rebuildPairingTopological(m, sp, pairOf, onPlane, vertSign);

    assert(pairOf.length == 6);
    // Seam vertices: on-plane, pairOf = -1.
    assert(onPlane[0] && pairOf[0] == -1, "c0 should be on-plane/unpaired");
    assert(onPlane[1] && pairOf[1] == -1, "c1 should be on-plane/unpaired");
    // Connectivity pairs: A(2)↔D(4), B(3)↔C(5).
    assert(pairOf[2] == 4, "A should pair with D; got " ~ pairOf[2].to!string);
    assert(pairOf[4] == 2, "D should pair with A; got " ~ pairOf[4].to!string);
    assert(pairOf[3] == 5, "B should pair with C; got " ~ pairOf[3].to!string);
    assert(pairOf[5] == 3, "C should pair with B; got " ~ pairOf[5].to!string);
    // vertSign
    assert(vertSign[2] == +1 && vertSign[3] == +1, "+X verts should have vertSign +1");
    assert(vertSign[4] == -1 && vertSign[5] == -1, "-X verts should have vertSign -1");
}

unittest { // rebuildPairing (spatial) fails to pair the deformed mesh — the discriminator
    import std.conv : to;
    auto m  = makeDeformedTwoQuadMesh();
    auto sp = xPlanePacket();

    int[]  pairOf; bool[] onPlane; int[] vertSign;
    rebuildPairing(m, sp, pairOf, onPlane, vertSign);

    // No off-plane vertex has a spatial mirror within epsilon (deformed positions).
    assert(pairOf[2] == -1, "spatial should NOT pair A on deformed mesh");
    assert(pairOf[3] == -1, "spatial should NOT pair B");
    assert(pairOf[4] == -1, "spatial should NOT pair D");
    assert(pairOf[5] == -1, "spatial should NOT pair C");
}

unittest { // applySymmetryMirrorDelta: deformed base — partner gets delta, not absolute mirror
    import std.math : isClose, fabs;
    import std.conv : to;

    auto m  = makeDeformedTwoQuadMesh();
    auto sp = xPlanePacket();

    // Build topological pair table.
    rebuildPairingTopological(m, sp, sp.pairOf, sp.onPlane, sp.vertSign);

    // Baseline = pre-transform positions.
    auto baseline = m.vertices.dup;

    // Simulate translating A (vertex 2) by delta = (0.5, 0.3, 0.1).
    Vec3 delta = Vec3(0.5f, 0.3f, 0.1f);
    m.vertices[2] = baseline[2] + delta;

    // Drive mirror with selected = [A only].
    bool[] sel = new bool[](6);
    sel[2] = true;
    bool[] touched = new bool[](6);

    applySymmetryMirrorDelta(&m, sp, baseline, sel, touched);

    // D (vertex 4) should move by mirrorDirection(delta) from its own base.
    Vec3 expectedD = baseline[4] + mirrorDirection(sp, delta);
    assert(isClose(m.vertices[4].x, expectedD.x, 1e-5f),
        "D.x expected " ~ expectedD.x.to!string ~ " got " ~ m.vertices[4].x.to!string);
    assert(isClose(m.vertices[4].y, expectedD.y, 1e-5f),
        "D.y expected " ~ expectedD.y.to!string ~ " got " ~ m.vertices[4].y.to!string);
    assert(isClose(m.vertices[4].z, expectedD.z, 1e-5f),
        "D.z expected " ~ expectedD.z.to!string ~ " got " ~ m.vertices[4].z.to!string);

    // Discriminator: NOT the absolute mirror of the driver's final position.
    Vec3 absWrong = mirrorPosition(sp, m.vertices[2]);
    assert(fabs(m.vertices[4].x - absWrong.x) > 0.1f ||
           fabs(m.vertices[4].y - absWrong.y) > 0.1f ||
           fabs(m.vertices[4].z - absWrong.z) > 0.1f,
        "delta-mirror must differ from absolute-mirror on deformed base");
    assert(touched[4], "D should be in outAlsoTouched");
}

unittest { // equivalence: on symmetric base, delta-mirror == absolute-mirror (float-exact for axis-aligned)
    import std.math : isClose;
    import std.conv : to;

    // Symmetric mesh: A at (+0.5, 0.7, 0.3) and D at (-0.5, 0.7, 0.3) = spatial mirror of A.
    Mesh m;
    m.addVertex(Vec3(0.0f,  0.0f, 0.0f));   // 0: c0
    m.addVertex(Vec3(0.0f,  1.0f, 0.0f));   // 1: c1
    m.addVertex(Vec3(0.5f,  0.7f, 0.3f));   // 2: A  (+X)
    m.addVertex(Vec3(0.5f,  1.5f, 0.3f));   // 3: B  (+X)
    m.addVertex(Vec3(-0.5f, 0.7f, 0.3f));   // 4: D  (-X, exact spatial mirror of A)
    m.addVertex(Vec3(-0.5f, 1.5f, 0.3f));   // 5: C  (-X, exact spatial mirror of B)
    m.addFace([0u, 2u, 3u, 1u]);
    m.addFace([0u, 1u, 5u, 4u]);
    m.buildLoops();

    auto sp = xPlanePacket(1e-3f);  // wider eps to pair the symmetric verts
    rebuildPairing(m, sp, sp.pairOf, sp.onPlane, sp.vertSign);
    // Spatial should pair A(2)↔D(4) and B(3)↔C(5) on the symmetric mesh.
    assert(sp.pairOf[2] == 4, "symmetric mesh spatial pair A↔D expected");

    auto baseline = m.vertices.dup;
    Vec3 delta = Vec3(0.2f, 0.15f, 0.05f);
    m.vertices[2] = baseline[2] + delta;

    bool[] sel = new bool[](6); sel[2] = true;
    bool[] touched = new bool[](6);

    applySymmetryMirrorDelta(&m, sp, baseline, sel, touched);
    Vec3 deltaResult = m.vertices[4];

    // Reset D and apply absolute-mirror.
    m.vertices[4] = baseline[4];
    bool[] touched2 = new bool[](6);
    bool[] sel2 = sel.dup;
    applySymmetryMirror(&m, sp, sel2, touched2);
    Vec3 absResult = m.vertices[4];

    assert(isClose(deltaResult.x, absResult.x, 1e-5f),
        "equivalence X: delta=" ~ deltaResult.x.to!string ~ " abs=" ~ absResult.x.to!string);
    assert(isClose(deltaResult.y, absResult.y, 1e-5f),
        "equivalence Y: delta=" ~ deltaResult.y.to!string ~ " abs=" ~ absResult.y.to!string);
    assert(isClose(deltaResult.z, absResult.z, 1e-5f),
        "equivalence Z: delta=" ~ deltaResult.z.to!string ~ " abs=" ~ absResult.z.to!string);
}

unittest { // rebuildPairingTopological: CYCLIC fan branch — closed mesh, no boundary edges
    import std.conv : to;

    // Build a closed square tube straddling X=0 (homeomorphic to a sphere —
    // every edge has a twin, so every fan is CYCLIC).
    //
    // Vertex layout:
    //   seam ring  (X=0): v0=(0,0,0)  v1=(0,1,0)  v2=(0,1,1)  v3=(0,0,1)
    //   +X cap ring:      v4=(1,0,0)  v5=(1,1,0)  v6=(1,1,1)  v7=(1,0,1)
    //   -X cap ring:      v8=(-1,0,0) v9=(-1,1,0) v10=(-1,1,1) v11=(-1,0,1)
    //
    // v8..v11 are the exact spatial mirrors of v4..v7 (clean expected pairing).
    //
    // 10 quad faces form the closed manifold:
    //   +X cap [5,4,7,6], -X cap [8,9,10,11],
    //   four +X-side quads, four -X-side quads.
    // Seam edges are shared between one +X-side and one -X-side quad,
    // wound in opposite directions — verified to be a valid 2-manifold.

    Mesh m;
    // seam (X=0)
    m.addVertex(Vec3( 0.0f, 0.0f, 0.0f));  //  0
    m.addVertex(Vec3( 0.0f, 1.0f, 0.0f));  //  1
    m.addVertex(Vec3( 0.0f, 1.0f, 1.0f));  //  2
    m.addVertex(Vec3( 0.0f, 0.0f, 1.0f));  //  3
    // +X side (mirrors of 8,9,10,11)
    m.addVertex(Vec3( 1.0f, 0.0f, 0.0f));  //  4
    m.addVertex(Vec3( 1.0f, 1.0f, 0.0f));  //  5
    m.addVertex(Vec3( 1.0f, 1.0f, 1.0f));  //  6
    m.addVertex(Vec3( 1.0f, 0.0f, 1.0f));  //  7
    // -X side (mirrors of 4,5,6,7)
    m.addVertex(Vec3(-1.0f, 0.0f, 0.0f));  //  8
    m.addVertex(Vec3(-1.0f, 1.0f, 0.0f));  //  9
    m.addVertex(Vec3(-1.0f, 1.0f, 1.0f));  // 10
    m.addVertex(Vec3(-1.0f, 0.0f, 1.0f));  // 11

    // Faces — winding verified: every shared edge is traversed in opposite
    // directions by its two incident faces (valid closed 2-manifold).
    m.addFace([5u, 4u, 7u, 6u]);         // +X cap
    m.addFace([8u, 9u, 10u, 11u]);       // -X cap
    m.addFace([0u, 4u, 5u, 1u]);         // bottom +X
    m.addFace([1u, 5u, 6u, 2u]);         // front  +X
    m.addFace([2u, 6u, 7u, 3u]);         // top    +X
    m.addFace([3u, 7u, 4u, 0u]);         // back   +X
    m.addFace([0u, 1u, 9u, 8u]);         // bottom -X
    m.addFace([1u, 2u, 10u, 9u]);        // front  -X
    m.addFace([2u, 3u, 11u, 10u]);       // top    -X
    m.addFace([3u, 0u, 8u, 11u]);        // back   -X
    m.buildLoops();

    // Every vertex must have a CYCLIC fan — this confirms the !openA branch
    // in rebuildPairingTopological is exercised by the test below.
    foreach (vi; 0u .. 12u)
        assert(!isBoundaryVertexMesh(m, vi),
            "vertex " ~ vi.to!string
            ~ " should be CYCLIC (no boundary edge), got OPEN");

    auto sp = xPlanePacket(1e-4f);
    int[]  pairOf; bool[] onPlane; int[] vertSign;
    rebuildPairingTopological(m, sp, pairOf, onPlane, vertSign);

    assert(pairOf.length == 12);

    // Seam vertices: on-plane, pairOf = -1.
    foreach (vi; 0 .. 4)
        assert(onPlane[vi] && pairOf[vi] == -1,
            "seam v" ~ vi.to!string ~ " should be on-plane/unpaired; got onPlane="
            ~ onPlane[vi].to!string ~ " pairOf=" ~ pairOf[vi].to!string);

    // Off-plane vertices: +X ↔ -X mirror pairs.
    assert(pairOf[4]  ==  8, "v4  ↔ v8  expected; got " ~ pairOf[4].to!string);
    assert(pairOf[8]  ==  4, "v8  ↔ v4  expected; got " ~ pairOf[8].to!string);
    assert(pairOf[5]  ==  9, "v5  ↔ v9  expected; got " ~ pairOf[5].to!string);
    assert(pairOf[9]  ==  5, "v9  ↔ v5  expected; got " ~ pairOf[9].to!string);
    assert(pairOf[6]  == 10, "v6  ↔ v10 expected; got " ~ pairOf[6].to!string);
    assert(pairOf[10] ==  6, "v10 ↔ v6  expected; got " ~ pairOf[10].to!string);
    assert(pairOf[7]  == 11, "v7  ↔ v11 expected; got " ~ pairOf[7].to!string);
    assert(pairOf[11] ==  7, "v11 ↔ v7  expected; got " ~ pairOf[11].to!string);

    // vertSign: +X = +1, -X = -1, seam = 0.
    assert(vertSign[4] == +1 && vertSign[5] == +1
        && vertSign[6] == +1 && vertSign[7] == +1,
        "+X verts should have vertSign +1");
    assert(vertSign[8] == -1 && vertSign[9] == -1
        && vertSign[10] == -1 && vertSign[11] == -1,
        "-X verts should have vertSign -1");
}

unittest { // disconnected precondition: topological yields no pairs, spatial does pair
    import std.conv : to;

    // Two separate quad islands at X=±0.5, no shared seam vertex.
    Mesh m;
    m.addVertex(Vec3(-0.5f, -0.5f, 0.0f));  // 0
    m.addVertex(Vec3(-0.5f,  0.5f, 0.0f));  // 1
    m.addVertex(Vec3(-0.5f, -0.5f, 1.0f));  // 2
    m.addVertex(Vec3(-0.5f,  0.5f, 1.0f));  // 3
    m.addVertex(Vec3( 0.5f, -0.5f, 0.0f));  // 4
    m.addVertex(Vec3( 0.5f,  0.5f, 0.0f));  // 5
    m.addVertex(Vec3( 0.5f, -0.5f, 1.0f));  // 6
    m.addVertex(Vec3( 0.5f,  0.5f, 1.0f));  // 7
    m.addFace([0u, 1u, 3u, 2u]);  // -X quad
    m.addFace([4u, 6u, 7u, 5u]);  // +X quad
    m.buildLoops();

    auto sp = xPlanePacket(0.6f);  // eps wide enough to reach ±0.5 for spatial

    int[] tPairOf; bool[] tOnPlane; int[] tVertSign;
    rebuildPairingTopological(m, sp, tPairOf, tOnPlane, tVertSign);
    // No seam vertices → all pairOf = -1.
    foreach (i; 0 .. 8)
        assert(tPairOf[i] == -1,
            "topological: disconnected mesh should have no pairs; pairOf["
            ~ i.to!string ~ "]=" ~ tPairOf[i].to!string);

    // Spatial with a tighter eps (0.1f) so the ±0.5 verts are NOT swallowed
    // into the plane and CAN be paired across it (mirrored distance = 0).
    auto spSpatial = xPlanePacket(0.1f);
    int[] sPairOf; bool[] sOnPlane; int[] sVertSign;
    rebuildPairing(m, spSpatial, sPairOf, sOnPlane, sVertSign);
    // Spatial should pair the two islands by position.
    bool anyPaired = false;
    foreach (i; 0 .. 8) if (sPairOf[i] >= 0) { anyPaired = true; break; }
    assert(anyPaired, "spatial: disconnected mirrored mesh should have pairs");
}

