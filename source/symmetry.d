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
/// (matches MODO's "center vertex stays on the symmetry plane" rule).
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
