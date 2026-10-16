module symmetry;
static import spatial = vibe3d.util.spatial.spatial;

import std.algorithm : sort, max;
import std.math      : abs;

import math : Vec3, dot;
public import vibe3d.util.spatial.symmetry_plane : symmetrySide;
static import math;
import mesh : Mesh;
import vibe3d.editing.contracts.editmode : EditMode;
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
    // One compiler-owned comparison over the config sub-struct. The
    // seven-way conjunction this replaces silently ignored any newly added
    // config field until a separate edit remembered to extend it.
    return a.config == b.config;
}

/// Mirror equality: the config plus the resolved plane (planePoint /
/// planeNormal). A latch that resolves its own plane (the pen's work-plane
/// mirror) compares with this, not with the config-only test above.
bool symmetryMirrorsEqual(const ref SymmetryPacket a, const ref SymmetryPacket b)
    pure nothrow @nogc @safe
{
    return symmetryPacketsEqual(a, b) && a.planePoint == b.planePoint &&
        a.planeNormal == b.planeNormal;
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

/// ditto, against the packet's plane.
int symmetrySide(const ref SymmetryPacket sp, Vec3 p, float eps) pure nothrow @nogc @safe {
    return symmetrySide(sp.planePoint, sp.planeNormal, p, eps);
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

/// The mirror of a point on edge (v0, v1) at a parameter `t`: the edge
/// (m0, m1) = (pairOf[v0], pairOf[v1]) at the SAME `t`, since the pairing maps
/// each endpoint to its own image (an on-plane endpoint maps to itself). False —
/// no mirror point — when symmetry is off or has no axis, the pairing is not for
/// this mesh, an endpoint is unpaired off the plane, the images are not joined
/// by an edge, or the edge is its own mirror. Used by Edge Slice's mirrored chain
/// (task 7114; measured law: the cut is mirrored from either side).
bool mirrorEdgePoint(const ref Mesh m, const ref SymmetryPacket sp, uint v0, uint v1,
                     out uint m0, out uint m1)
{
    m0 = m1 = ~0u;
    if (!sp.enabled || sp.axisIndex < 0) return false;
    if (sp.pairOf.length != m.vertices.length) return false;
    if (v0 >= m.vertices.length || v1 >= m.vertices.length) return false;
    int a = sp.pairOf[v0], b = sp.pairOf[v1];
    // An on-plane endpoint is its own image, as in `mirrorEdge` (the captured
    // law mirrors every split and cut: C1-sym-own, gap row 290).
    if (a < 0 && v0 < sp.onPlane.length && sp.onPlane[v0]) a = cast(int)v0;
    if (b < 0 && v1 < sp.onPlane.length && sp.onPlane[v1]) b = cast(int)v1;
    if (a < 0 || b < 0) return false;
    if ((a == v0 && b == v1) || (a == v1 && b == v0)) return false;   // self
    if (m.edgeIndex(cast(uint)a, cast(uint)b) == ~0u) return false;
    m0 = cast(uint)a;
    m1 = cast(uint)b;
    return true;
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

/// The mirror partner of one element of kind `k` (task 7144, law gap 315):
/// a vertex through `pairOf`, an edge through `mirrorEdge`, a face through
/// `mirrorFace`; `~0u` when there is none. THE ONE place a partner joins a
/// selection: only POINTER gestures call it (click / paint / region pick in
/// `symmetry_pick.d`, the double-click loop in `input_router.d`, the Element
/// Move pick in `xfrm_transform.d`); script and command doors never pair.
/// Pinned by the census in tests/unit/symmetry_test.d.
uint mirrorElement(const ref Mesh m, const ref SymmetryPacket sp, EditMode k, uint idx) {
    if (!sp.enabled) return ~0u;
    final switch (k) {
        case EditMode.Vertices: {
            if (sp.pairOf.length != m.vertices.length || idx >= sp.pairOf.length) return ~0u;
            immutable int mi = sp.pairOf[idx];
            return (mi < 0 || mi == cast(int)idx) ? ~0u : cast(uint)mi;
        }
        case EditMode.Edges: {
            immutable uint me = mirrorEdge(m, sp, idx);
            return me == idx ? ~0u : me;
        }
        case EditMode.Polygons: {
            immutable uint mf = mirrorFace(m, sp, idx);
            return mf == idx ? ~0u : mf;
        }
    }
}

// ---------------------------------------------------------------------------
// THE AUTHORING FRAME (task 7144; captured law gap rows 316/317/328,
// toolcards/symmetry_selection, doc/measured_laws.md §24a). Every operand
// vertex is computed in ONE frame: on the authoring side A it takes the
// transform K itself, off A it takes M·K(M·p) — the WHOLE affine conjugated,
// pivot included (Cj-affine: a rotation about c becomes the mirrored rotation
// about M·c). A vertex ON the plane is never "off". The caller computes the
// vertex weight BEFORE `authored`, from the vertex's own ORIGINAL position:
// the weight is its own (C-fall), only the point is conjugated.
// ---------------------------------------------------------------------------

/// True iff vertex `vi` lies on the side opposite the authoring side A.
bool offAuthoringSide(const ref SymmetryPacket sp, size_t vi) pure nothrow @nogc @safe {
    return sp.enabled && vi < sp.vertSign.length && sp.vertSign[vi] == -sp.authoringSide;
}

/// The vertex whose per-vertex FRAME (ACEN.Local cluster pivot, axes or
/// matrix) a kernel reads for vertex `vi`: `vi` itself on A, its pair partner
/// off A. Off A the kernel evaluates the MIRROR IMAGE of the point, and that
/// image lies in the partner's cluster — reading `vi`'s own cluster frame
/// there would mirror a frame that is already a mirror, i.e. twice (review of
/// task 7144). No partner: `vi`.
size_t frameSource(const ref SymmetryPacket sp, size_t vi) pure nothrow @nogc @safe {
    if (!offAuthoringSide(sp, vi) || vi >= sp.pairOf.length) return vi;
    immutable int mi = sp.pairOf[vi];
    return mi < 0 ? vi : cast(size_t)mi;
}

/// The one authoring-frame evaluation: `kernel(p)` on A, `M·kernel(M·p)` off A.
///
/// Forced inline (task 8170): it runs once per vertex per drag step, and as an
/// out-of-line call the `Vec3` crossing its ABI boundary was spilled as two
/// 4-byte stores and reloaded as one 8-byte load (a store-forwarding stall),
/// on top of an indirect call to `kernel`. Inlined, the caller's delegate
/// literal is a known function and is inlined too; the float operations and
/// their order are unchanged.
pragma(inline, true)
Vec3 authored(K)(const ref SymmetryPacket sp, size_t vi, Vec3 p, scope K kernel) {
    if (!offAuthoringSide(sp, vi)) return kernel(p);
    return mirrorPosition(sp, kernel(mirrorPosition(sp, p)));
}

// ---------------------------------------------------------------------------
// THE PAIR WRITE RULE (task 7144; gap rows 73/316/318, C-plane P-proj). ONE
// rule, walked by `walkMirrorPairs` for the four mirror passes, in this order:
//   1. an on-plane operand vertex is projected back onto the plane;
//   2. a vertex whose visible partner is ALSO in the operand: the member on
//      `sp.baseSide` (the live stage keeps +1; Symmetrize passes its own
//      side) keeps its own result and its partner is written as its exact
//      mirror — the pair's weight and result are its +X member's; the other
//      member yields (the copy overwrites it);
//   3. otherwise the vertex keeps its own result — the kernel already put it
//      in the authoring frame, and a partner OUTSIDE the operand is never
//      written (gap 316). A hidden partner counts as outside (task 0613 R3:
//      it must not win the drive nor be written).
// ---------------------------------------------------------------------------

/// Is vertex `i`'s pair partner hidden? Computed once per vertex by each
/// mirror pass and handed to `mirrorStepFor` (task 0613 R3's guard).
bool partnerHidden(const ref Mesh mesh, const ref SymmetryPacket sp, size_t i) {
    immutable int pi = i < sp.pairOf.length ? sp.pairOf[i] : -1;
    return pi >= 0 && mesh.isVertexHidden(pi);
}

/// A weld `[keep, gone]` under symmetry (task 9438, K-W2/K-W2b): the partners weld too
/// unless either is hidden (W2f); `gone` meeting its own partner fuses with it at their
/// midpoint, on the plane, `gone` surviving (KW2_M, KW2_MDW). `sp` null or unsized: as is.
uint[2][] symmetricWeldPairs(ref Mesh mesh, const(SymmetryPacket)* sp, uint keep, uint gone) {
    if (sp is null || sp.pairOf.length != mesh.vertices.length) return [[keep, gone]];
    const int pk = sp.pairOf[keep], pg = sp.pairOf[gone];
    if (pk == cast(int)gone) {
        mesh.vertices[gone] = (mesh.vertices[gone] + mesh.vertices[keep]) * 0.5f;
        return [[gone, keep]];
    }
    if (pk >= 0 && pg >= 0 && !mesh.isVertexHidden(pk) && !mesh.isVertexHidden(pg))
        return [[keep, gone], [cast(uint)pk, cast(uint)pg]];
    return [[keep, gone]];
}

enum SelfStep : ubyte { own, project, yield }

struct MirrorStep {
    SelfStep self;
    bool     copyToPartner;
    int      partner = -1;
}

MirrorStep mirrorStepFor(const ref SymmetryPacket sp, const(bool)[] operand,
                         size_t i, bool partnerHidden) pure nothrow @nogc @safe
{
    MirrorStep st;
    if (i < sp.onPlane.length && sp.onPlane[i]) { st.self = SelfStep.project; return st; }
    immutable int mi = i < sp.pairOf.length ? sp.pairOf[i] : -1;
    if (mi >= 0 && mi != cast(int)i && !partnerHidden
        && mi < cast(int)operand.length && operand[mi]) {
        st.partner = mi;
        immutable int iSign = i < sp.vertSign.length ? sp.vertSign[i] : 0;
        if (iSign == sp.baseSide) { st.self = SelfStep.own; st.copyToPartner = true; }
        else                      st.self = SelfStep.yield;
        return st;
    }
    st.self = SelfStep.own;
    return st;
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
        mirrored[i]    = mirrorPosition(sp, mesh.vertices[i]);
        outVertSign[i] = symmetrySide(sp, mesh.vertices[i], sp.epsilonWorld);
        outOnPlane[i]  = outVertSign[i] == 0;
        outPairOf[i]   = -1;
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
// walkMirrorPairs — THE mirror walker: the pair write rule over the operand
// `selected[]`, with the client's storage: `read(i)` / `write(i, p)` a vertex's
// position, `mirrored(i, mi, p)` partner mi's from driver i at `p`. Partners
// written are OR-ed into `outAlsoTouched`. Templated: it runs per vertex on a drag.
// ---------------------------------------------------------------------------
void walkMirrorPairs(alias read, alias write, alias mirrored)(
    Mesh* mesh, const ref SymmetryPacket sp, const(bool)[] selected, bool[] outAlsoTouched)
{
    if (!sp.enabled || sp.pairOf.length != mesh.vertices.length) return;
    foreach (i; 0 .. mesh.vertices.length) {
        if (i >= selected.length || !selected[i]) continue;
        immutable MirrorStep st = mirrorStepFor(sp, selected, i, partnerHidden(*mesh, sp, i));
        if (st.self == SelfStep.project) {
            write(i, projectOnPlane(sp, read(i)));
            continue;
        }
        if (!st.copyToPartner) continue;
        write(st.partner, mirrored(i, st.partner, read(i)));
        if (st.partner < cast(int)outAlsoTouched.length)
            outAlsoTouched[st.partner] = true;
    }
}

/// The plain walk: positions in `mesh.vertices`, the partner an exact mirror.
void applySymmetryMirror(Mesh* mesh, const ref SymmetryPacket sp,
                         const(bool)[] selected, bool[] outAlsoTouched)
{
    walkMirrorPairs!(i => mesh.vertices[i], (i, p) { mesh.vertices[i] = p; },
                     (i, mi, p) => mirrorPosition(sp, p))(mesh, sp, selected, outAlsoTouched);
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

/// Delta-mirror apply (topological symmetry): the partner keeps its own
/// pre-existing deformation and takes the mirrored EDIT,
/// `baseline[mi] + mirrorDirection(sp, vertices[i] − baseline[i])` (on a
/// symmetric base float-identical to the plain walk, doc/topological_symmetry_plan.md
/// Risk 1). `baseline` must be mesh-length; no-ops safely when lengths differ.
void applySymmetryMirrorDelta(Mesh* mesh, const ref SymmetryPacket sp,
                              const(Vec3)[] baseline,
                              const(bool)[] selected,
                              bool[] outAlsoTouched)
{
    if (baseline.length != mesh.vertices.length) return;
    walkMirrorPairs!(i => mesh.vertices[i], (i, p) { mesh.vertices[i] = p; },
                     (i, mi, p) => mirroredEdit(sp, baseline, i, mi, p))(mesh, sp, selected, outAlsoTouched);
}

/// The delta rule's partner: `base[mi]` plus the driver's edit `p − base[i]` reflected.
Vec3 mirroredEdit(const ref SymmetryPacket sp, const(Vec3)[] base, size_t i, size_t mi, Vec3 p)
    pure nothrow @nogc @safe {
    return base[mi] + mirrorDirection(sp, p - base[i]);
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
        outVertSign[i] = symmetrySide(sp, mesh.vertices[i], sp.epsilonWorld);
        outOnPlane[i]  = outVertSign[i] == 0;
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

        // Task 0447: this pairing matches mirror partners by fan SLOT NUMBER
        // (the reversed modular / linear walks below). A vertex whose fan is
        // not `vertexFanOrdered` (rests on a same-direction shared edge —
        // inconsistent winding) has no meaningful slot order, so `Na`/`Nb`
        // (from verticesAroundVertex, CSR-backed and arbitrarily ordered
        // there) would pair the wrong partners. Abandon this expansion —
        // the affected vertices simply stay pairOf = -1 (safe degradation,
        // identical to the "no reference slot" outcome below). This is the
        // silent-corruption consumer §3.1 warns about, so it declines
        // explicitly rather than writing a wrong mirror pair.
        if (!mesh.vertexFanOrdered(a) || !mesh.vertexFanOrdered(b)) continue;

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













// 9504: one corner-ordered move producer. Optional captured partner positions
// carry a vertex snap's held lag; ordinary/edge writes use exact reflection.
void writeMovePositions(ref Mesh mesh, const(SymmetryPacket)* sp,
        const(uint)[] vertices, const(Vec3)[] points,
        const(Vec3)[] partners = null) {
    foreach(i,vi;vertices) {
        mesh.vertices[vi]=points[i];
        const pi=sp !is null && sp.pairOf.length==mesh.vertices.length ? sp.pairOf[vi] : -1;
        if(pi>=0 && !mesh.isVertexHidden(pi))
            mesh.vertices[pi]=i<partners.length ? partners[i] : mirrorPosition(*sp,points[i]);
    }
}

// 9504: own-partner hit uses the current reflected point, then the existing
// symmetric weld owns absorption on the plane. The query retains client reach.
bool moveMirrorCenter(const ref SymmetryPacket sp,uint source,Vec3 point,
        spatial.ModelSpace space,const ref spatial.Viewport view,float reach,ref Vec3 center) {
    import vibe3d.util.spatial.spatial : projectToWindowFull;
    if(source>=sp.pairOf.length || sp.pairOf[source]<0) return false;
    float ax,ay,az,bx,by,bz;
    if(!projectToWindowFull(space.toWorldPoint(point),view,ax,ay,az)
        || !projectToWindowFull(space.toWorldPoint(mirrorPosition(sp,point)),view,bx,by,bz)) return false;
    if((ax-bx)*(ax-bx)+(ay-by)*(ay-by)>reach*reach) return false;
    center=projectOnPlane(sp,point);
    return true;
}

version (unittest) {
    import std.conv : to;
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
