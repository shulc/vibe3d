module mesh_ops.poly_bevel;

// ---------------------------------------------------------------------------
// MeshPolyBevelOps — the POLYGON bevel family: poly.bevel (bevelFacesByMask),
// poly.inset (insetFacesByMask) and poly.spike (spikeFacesByMask), with the
// corner/normal helpers they share (insetCorner, insetCornerCentroid,
// maxSafeUniformInset, cornerNormalAt, aveNormal) and the group-boundary
// contour pair (findGroupBoundaryContour, boundaryContourInset). Mixed into
// struct Mesh (source/mesh.d) via `mixin MeshPolyBevelOps;`.
//
// Split out of mesh.d (task 0717, audit 0678 §2B-M4). M4's finding was that
// "bevel" lived in two homes — edge/vertex bevel in mesh_ops/, polygon bevel
// in the middle of mesh.d — and that this is a search trap. Both homes are
// now in mesh_ops/, and the edge one is named edge_bevel.d.
//
// Verbatim cut/paste, no dedent: a mixin template's members already sit at
// the struct members' indent. The six unittest blocks come with it and stay
// INSIDE the mixin, because three of them read `insetCorner` /
// `boundaryContourInset`, which are private. A mixin body — unittest blocks
// included — is looked up in the INSTANTIATION scope, so those reads keep
// working with nothing widened; the same rule is why `buildRawMesh` (a
// `version (unittest) private` free function that mesh.d's own T-S1 fixtures
// also use, so it cannot follow) still resolves from the blocks below.
// ---------------------------------------------------------------------------
import mesh;
import math;

mixin template MeshPolyBevelOps() {

    // Per-corner inset helper: given the origPos ring and corner index i,
    // return the inset position using the perpendicular-offset meeting
    // formula (offsetMeet from math.d). ePrev/eNext are unit directions from
    // origPos[i] toward the previous and next corners respectively.
    private Vec3 insetCorner(const Vec3[] origPos, int i, Vec3 n, float inset) {
        const int  N     = cast(int)origPos.length;
        const int  prevI = (i + N - 1) % N;
        const int  nextI = (i + 1)     % N;
        const Vec3 ePrev = safeNormalize(origPos[prevI] - origPos[i]);
        const Vec3 eNext = safeNormalize(origPos[nextI] - origPos[i]);
        return offsetMeet(origPos[i], ePrev, eNext, n, inset, inset);
    }

    // Per-corner constant-distance-toward-centroid helper for
    // insetFacesByMask (poly.inset). Deliberately SEPARATE from insetCorner/
    // offsetMeet above (used by bevelFacesByMask / poly.bevel's per-edge
    // perpendicular-offset miter law) — task 0359's toolcard capture showed
    // poly.inset uses a DIFFERENT per-vertex law (a constant absolute
    // displacement toward the polygon centroid, NOT a per-edge miter
    // offset), so sharing insetCorner would have silently changed
    // poly.bevel's already-verified geometry.
    //
    // Reference-captured law (toolcard `behavior.per_vertex_law` /
    // `sign_law`): each new boundary vertex sits at `orig` moved toward the
    // polygon centroid by an ABSOLUTE distance of exactly `inset` world
    // units. Positive inset shrinks (toward centroid); negative grows
    // (moves away — the duplicate scales larger), which falls out of this
    // formula automatically via the signed `inset` multiply.
    //
    // OPEN AMBIGUITY (documented in the toolcard, not resolved by capture):
    // the only parity case captured is a perfect square, where "move by a
    // constant absolute distance" and "scale proportionally toward the
    // centroid" are numerically indistinguishable (every corner starts
    // equidistant from the centroid). This implementation picks the
    // constant-distance law per the captured wording; unverified on a
    // non-regular (asymmetric) selected polygon.
    private Vec3 insetCornerCentroid(Vec3 orig, Vec3 centroid, float inset) {
        Vec3 toCenter = centroid - orig;
        const float len = toCenter.length;
        if (len < 1e-9f) return orig;   // corner already at the centroid — no direction to move
        return orig + (toCenter / len) * inset;
    }

    /// Per-face polygon inset: for each face flagged true in `mask`, move
    /// each corner toward the polygon centroid by an absolute distance of
    /// `inset` world units (see insetCornerCentroid) and bridge the original
    /// boundary to the new inner boundary with N ring quads. The original
    /// face slot is replaced by the inner face so its selection mark is
    /// preserved.
    ///
    /// `inset == 0` is NOT a no-op (reference-matched, task 0359): it still
    /// performs the full topology split, landing the new corners exactly on
    /// the original ones (a degenerate zero-width ring) — the reference tool
    /// does not skip the split at its default value either.
    ///
    /// Returns the number of faces processed (0 only when `mask` selects no
    /// face, e.g. an empty/undersized mask).
    size_t insetFacesByMask(const bool[] maskIn, float inset) {
        const mask = maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        size_t processed = 0;
        const size_t nFaces = faces.length; // snapshot before appending ring quads
        foreach (fi; 0 .. nFaces) {
            if (fi >= mask.length || !mask[fi]) continue;
            const uint[] origFaceVerts = faces[fi].dup;
            const int    N             = cast(int)origFaceVerts.length;
            if (N < 3) continue;
            // Build per-corner position slice.
            Vec3[] origPos = new Vec3[](N);
            foreach (i; 0 .. N) origPos[i] = vertices[origFaceVerts[i]];
            // Polygon centroid (plain average of corners — matches the
            // reference's "toward the centroid" wording; N-gon area-weighted
            // centroids are not what was captured).
            Vec3 centroid = Vec3(0, 0, 0);
            foreach (p; origPos) centroid = centroid + p;
            centroid = centroid * (1.0f / cast(float)N);
            // Add one inset vertex per corner.
            uint[] newVerts = new uint[](N);
            foreach (i; 0 .. N)
                newVerts[i] = addVertex(insetCornerCentroid(origPos[i], centroid, inset));
            // Replace the original face with the inner (inset) face.
            // The face slot index is unchanged, so faceMarks[fi] (select mark
            // AND subpatch mark) carries over to the inner face automatically.
            faces[fi] = newVerts.dup;
            // Task 0389: read the source face's Subpatch bit BEFORE the ring
            // quads below grow `faceMarks` (addFace does not grow it itself —
            // `fi`'s own bit is unaffected by the in-place replace above).
            immutable bool srcSub  = isFaceSubpatch(fi);
            immutable size_t ringStart = faces.length;
            // Emit N ring quads bridging original boundary to inner boundary.
            foreach (i; 0 .. N) {
                const int next = (i + 1) % N;
                addFace([origFaceVerts[i], origFaceVerts[next],
                         newVerts[next],   newVerts[i]]);
            }
            // Ring quads inherit Subpatch from the inset source face.
            resizeSubpatch();
            foreach (rfi; ringStart .. faces.length) setFaceSubpatch(rfi, srcSub);
            ++processed;
        }
        if (processed == 0) return 0;
        rebuildEdges();
        buildLoops();
        syncSelection();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return processed;
    }

    // Per-face safe upper bound for a uniform (all-corners-equal-inset)
    // polygon inset. Mirrors the "does NOT overshoot and self-intersect"
    // guard the edge-extrude face-aware inset already applies (mesh.d
    // ~2520), generalized from "clamp to the far vertex of an edge" to
    // "clamp to the point where a ring edge would collapse to zero
    // length": `probe[i]` is each corner's per-unit-inset offset direction
    // (`insetCorner(...,1)` — offsetMeet is affine in its width args, so
    // the offset at any `inset` is `origPos[i] + probe[i]*inset` exactly).
    // Ring edge (i, i+1)'s length is therefore an affine function of
    // `inset` that reaches zero at
    //     t = edgeLen / -dot(probe[next] - probe[i], edgeDir)
    // The smallest positive such `t` across all ring edges is the largest
    // inset that keeps every edge non-negative-length; beyond it the ring
    // folds back on itself (self-intersects, corners overshoot past their
    // neighbours). Returns +infinity when no edge would ever collapse.
    private float maxSafeUniformInset(const Vec3[] origPos, const Vec3[] probe) {
        const int N = cast(int)origPos.length;
        float safe = float.infinity;
        foreach (i; 0 .. N) {
            const int next = (i + 1) % N;
            Vec3 edge = origPos[next] - origPos[i];
            const float edgeLen = edge.length;
            if (edgeLen < 1e-9f) continue;
            Vec3 edgeDir = edge / edgeLen;
            Vec3 p = probe[next] - probe[i];
            const float denom = -dot(p, edgeDir);
            if (denom > 1e-9f) {
                const float t = edgeLen / denom;
                if (t < safe) safe = t;
            }
        }
        return safe;
    }

    /// Per-corner unit normal at vertex `v` within face `fi`: the cross
    /// product of the face's OWN two edges meeting at that corner
    /// (`cross(next-cur, prev-cur)`), NOT `faceNormal()`'s whole-face
    /// Newell average. Identical to `faceNormal()` for a planar face (any
    /// corner of a flat polygon shares the same normal direction), but
    /// diverges on a non-planar n-gon — task 0458's recovered
    /// the reference's group-average-normal law is only bit-exact against this
    /// PER-CORNER form (rr/gdb + geometry, `toolcards/poly.bevel/
    /// findings.md` §1: the reference's per-corner vertex normal). Returns (0,1,0)
    /// for a degenerate/tiny corner (matches `faceNormal`'s own fallback).
    private Vec3 cornerNormalAt(uint fi, uint v) const {
        const uint[] f = faces[fi];
        const int N = cast(int)f.length;
        int k = -1;
        foreach (i; 0 .. N) if (f[i] == v) { k = i; break; }
        assert(k >= 0, "cornerNormalAt: vertex not incident to face");
        const Vec3 prevV = vertices[f[(k + N - 1) % N]];
        const Vec3 curV  = vertices[f[k]];
        const Vec3 nextV = vertices[f[(k + 1) % N]];
        Vec3 n = cross(nextV - curV, prevV - curV);
        float len = n.length;
        return len > 1e-9f ? n * (1.0f / len) : Vec3(0, 1, 0);
    }

    /// `AVE_N(v) = k·N/|N|²` (task 0458, the reference's group-average-normal recovered
    /// via rr/gdb — `toolcards/poly.bevel/findings.md` §1): `nSum` = Σ of
    /// the `count` incident selected-face CORNER unit normals (see
    /// `cornerNormalAt`), amplified by their own count and re-normalized
    /// against their squared magnitude. Reduces to the naive `Σ(unit
    /// normal)` EXACTLY when the `count` corner normals are mutually
    /// ORTHOGONAL (there `|N|²==count`) — every group fixture before 0458
    /// happened to be an axis-aligned cube corner, so the naive sum
    /// (`vibe3d-bug`, pre-0458) passed every prior test: a symmetry trap,
    /// not correctness (the same class as 0453). Falls back to the raw
    /// (un-amplified) sum when `|N|²` is too small to safely invert — a
    /// degenerate selection (near-antiparallel corner normals) no known
    /// case exercises; returning the un-scaled sum avoids a NaN/Inf blowup
    /// rather than asserting.
    private static Vec3 aveNormal(Vec3 nSum, uint count) {
        immutable float mag2 = dot(nSum, nSum);
        if (mag2 < 1e-12f) return nSum;
        return nSum * (cast(float)count / mag2);
    }

    /// Locates vertex `v`'s two GROUP-BOUNDARY-CONTOUR edges — the outer
    /// silhouette of the selected-face region at `v`, task 0458
    /// findings.md §1/§5's `e_a`/`e_b` — for the recovered `bevGenInset`
    /// mitered-corner offset (`boundaryContourInset` below). Any THIRD
    /// edge incident to `v` that is INTERNAL (shared by two selected
    /// faces — e.g. G2's spoke to the fully-enclosed apex, or G3's two
    /// spokes to its other interior neighbors) is excluded entirely, per
    /// the reference's construction. `eB` is the boundary neighbor
    /// reached via each incident selected face's PREVIOUS-index direction
    /// (`f[k-1]`), `eA` via its NEXT-index direction (`f[k+1]`) — this
    /// pairing (not its mirror) is the one empirically confirmed
    /// bit-exact against the G2-ring/G3-partial dump-oracles (the
    /// mirrored pairing negates the mitered offset, since `U` — and hence
    /// the sign of `boundaryInset` — is built from `eB` alone). Returns
    /// false unless exactly one of each is found, the only topology (two
    /// group-boundary edges at `v`) this construction covers.
    private bool findGroupBoundaryContour(uint v, const bool[] mask,
            bool[ulong] internalEdgeSet, out uint eA, out uint eB) const {
        bool foundA = false, foundB = false;
        foreach (fi; facesAroundVertex(v)) {
            if (fi >= mask.length || !mask[fi]) continue;
            const uint[] f = faces[fi];
            immutable int N = cast(int)f.length;
            int k = -1;
            foreach (i; 0 .. N) if (f[i] == v) { k = i; break; }
            if (k < 0) continue;
            immutable uint nxt = f[(k + 1) % N];
            immutable uint prv = f[(k + N - 1) % N];
            if (auto ip = edgeKey(v, nxt) in internalEdgeSet) {
                if (!*ip) { eA = nxt; foundA = true; }
            }
            if (auto ip = edgeKey(v, prv) in internalEdgeSet) {
                if (!*ip) { eB = prv; foundB = true; }
            }
        }
        return foundA && foundB;
    }

    /// Recovered `bevGenInset` mitered-corner offset (task 0458
    /// findings.md §1/§5, rr/gdb-traced): `boundaryInset = D · inset /
    /// (D·U)`, a textbook mitered-polygon-corner offset generalized off
    /// the true per-vertex shift normal `aveN` (`AVE_N`) instead of a flat
    /// 2D plane. `D = unit(perp(eaVec,aveN)) + unit(perp(ebVec,aveN))` is
    /// the tangent-plane (⟂ `aveN`) bisector sum of the two
    /// group-boundary-contour edges; `U = unit(cross(ebVec,aveN))` is the
    /// tangent-plane perpendicular of `ebVec`; `perp(e,n) = e −
    /// (e·n/n·n)·n` projects an edge vector into the plane ⟂ `n`. Returns
    /// false (and leaves `result` zeroed) when `|D·U|` is below `GATE_EPS`
    /// — a genuine 0/0 singularity in the formula, NOT a code bug, that
    /// occurs exactly when `eaVec`/`ebVec` project anti-parallel onto the
    /// tangent plane: G1's coplanar ridge-tent measures `D·U` at machine
    /// epsilon (both its boundary-contour edges and `aveN` are coplanar),
    /// while G2-ring/G3-partial measure `|D·U|` in `[0.368, 0.974]` on
    /// their dump-oracles — a clean separation (task 0458, verified
    /// against all three case families before wiring this gate). The
    /// caller falls back to the existing 3-plane-meet law in that case.
    private static bool boundaryContourInset(Vec3 eaVec, Vec3 ebVec,
            Vec3 aveN, float inset, out Vec3 result) {
        import std.math : abs;
        static Vec3 perp(Vec3 e, Vec3 n) {
            immutable float nn = dot(n, n);
            return nn > 1e-12f ? e - n * (dot(e, n) / nn) : e;
        }
        // NIT (task 0467, reviewer follow-up): gate the U-degeneracy at its
        // SOURCE. When `ebVec` is parallel to `aveN`, `cross(ebVec,aveN)`
        // collapses to ~0 and `safeNormalize` would fabricate a finite bogus
        // (0,1,0) for both `U` and `perp(ebVec,aveN)` — yielding a
        // finite-but-meaningless miter that the downstream `|D·U|` gate can
        // MISS (D·U stays non-tiny because it is built from the fake
        // directions). Test the true sine of the eb/aveN angle directly
        // (`|cross(ebVec,aveN)| / (|ebVec|·|aveN|)`) so `e_b ∥ aveN` falls to
        // the caller's 3-plane / per-face fallback instead of returning
        // bogus geometry. This is strictly ADDITIVE to the existing `|D·U|`
        // gate (which still catches G1's coplanar-ridge `D→0` anti-parallel
        // case, where `ebVec` is NOT parallel to `aveN`).
        immutable Vec3  crossEbN = cross(ebVec, aveN);
        immutable float ebLen  = ebVec.length;
        immutable float aveLen = aveN.length;
        enum float SIN_EPS = 1e-4f;
        if (ebLen < 1e-9f || aveLen < 1e-9f ||
            crossEbN.length < SIN_EPS * ebLen * aveLen) {
            result = Vec3(0, 0, 0); return false;
        }
        immutable Vec3 D = safeNormalize(perp(eaVec, aveN)) + safeNormalize(perp(ebVec, aveN));
        immutable Vec3 U = safeNormalize(crossEbN);
        immutable float dDotU = dot(D, U);
        enum float GATE_EPS = 1e-4f;
        if (abs(dDotU) < GATE_EPS) { result = Vec3(0, 0, 0); return false; }
        result = D * (inset / dDotU);
        return true;
    }

    unittest { // boundaryContourInset degeneracy gate (task 0467 reviewer NIT):
               // when e_b is PARALLEL to aveN the U-direction is undefined and
               // safeNormalize would fabricate a bogus finite (0,1,0); the
               // source-level |cross(e_b,aveN)| gate must reject it (return
               // false) so the caller falls back — NOT return bogus geometry.
        Vec3 res;
        // e_b ∥ aveN (both along +Y, different magnitudes): must gate out.
        assert(!Mesh.boundaryContourInset(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,2,0), 0.1f, res),
            "e_b ∥ aveN must fall to the fallback (degenerate U)");
        // Anti-parallel projection (G1-style D→0): D sums to ~zero, |D·U| gate.
        assert(!Mesh.boundaryContourInset(Vec3(1,0,0), Vec3(-1,0,0), Vec3(0,0,1), 0.1f, res),
            "anti-parallel tangent-plane edges (D→0) must fall to the fallback");
        // A well-conditioned 90° corner in a plane returns a finite miter.
        assert(Mesh.boundaryContourInset(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1), 0.1f, res),
            "a well-conditioned corner should yield a finite mitered offset");
    }

    /// Polygon bevel: for each selected face, inset each corner by `inset`
    /// AND displace the inset cap by `+faceNormal*shift` along the face normal,
    /// bridging the original boundary to the offset cap with N ring quads.
    /// Produces ONE slanted ring (not inset∘extrude, which would produce two rings).
    /// inset=0, shift>0 degenerates to a one-ring face-extrude along the normal.
    /// Returns 0 (no-op) when |inset|<1e-6 AND |shift|<1e-6.
    ///
    /// Overshoot guard: a positive `inset` is clamped per-face to
    /// `maxSafeUniformInset` so the offset ring cannot fold past itself
    /// (mirrors the edge-extrude face-aware inset clamp, ~2520 — "the
    /// reference bumps the inset ... and stops"). Clamping can still land
    /// several corners on (or very near) the same position — e.g. a square
    /// face clamped to its inradius collapses every corner onto the
    /// centroid, an elongated face collapses pairwise onto a line. The
    /// reference KEEPS that collapse as a DEGENERATE QUAD RING (fuzz D3):
    /// the coincident cap corners stay distinct referenced verts, so the
    /// cap and each ring quad remain 4-vertex zero-area faces. The clamped
    /// pass therefore does NOT weld — welding + the resulting fan-to-triangle
    /// topology was a `vibe3d-divergence` (task 0304), corrected here to the
    /// reference's coincident-corner quad ring. (Overshoot clamping is NOT
    /// applied to `group`'s shared corners below — untested combination,
    /// documented gap.)
    ///
    /// `group` (task 0391 Phase 4, `capture-verified` default TRUE at the
    /// command/tool layer — see `commands/mesh/bevel.d`): when true and ≥2
    /// selected faces are mutually adjacent, their SHARED corners collapse
    /// to ONE new vertex instead of each face computing its own independent
    /// corner there, and the ring quad for any EDGE shared by 2 selected
    /// faces ("internal") is suppressed entirely (no bridge — it dissolves
    /// into the merged interior). Shift accumulates via `aveNormal()`'s
    /// `AVE_N = k·N/|N|²` (task 0458, the reference's group-average-normal recovered
    /// rr/gdb — see that function's doc comment and
    /// `toolcards/poly.bevel/findings.md`), not a plain `Σ(unit normal)` —
    /// the two coincide only when the incident corner normals are mutually
    /// orthogonal, which is why every pre-0458 cube-corner fixture passed
    /// regardless (a 0453-class symmetry trap). Three corner laws
    /// (`internalCnt`/`anyBoundary` from the vertex's own incident-edge
    /// classification):
    ///   - EXACTLY 1 internal edge ("half-shared", on the group's own outer
    ///     boundary but shared by the 2 faces either side of that internal
    ///     edge): `orig + shift·AVE_N + boundaryInset`, where `boundaryInset`
    ///     is the recovered `bevGenInset` mitered-corner offset
    ///     (`boundaryContourInset`, task 0458 follow-up — findings.md
    ///     §1/§5) built from `v`'s own two group-boundary-contour edges
    ///     (`findGroupBoundaryContour`), NOT the internal edge. That
    ///     construction is singular (`|D·U|→0`) exactly on a coplanar
    ///     ridge — a gate falls back to `inset·dir(orig → the internal
    ///     edge's other endpoint)` there, the original 3-plane-meet law,
    ///     bit-exact against `poly_bevel_G1_halfshared_tent` (6e-9,
    ///     including on non-90°/unequal-edge-length asymmetric geometry).
    ///     Off the gate, bit-exact against `poly_bevel_G2_apex_v3`'s ring
    ///     vertices (1.2e-8 to 6.4e-8) — a ring vertex whose sole internal
    ///     edge runs to a fully-enclosed apex is the SAME `internalCnt==1`
    ///     case, just clear of the gate.
    ///   - EVERY incident edge internal (fully enclosed by the group, no
    ///     boundary edge left — the group's own analog of edge-bevel's
    ///     N-way junction hub): `orig + shift·AVE_N`, no inset term (no
    ///     boundary edge left to inset against) — bit-exact against
    ///     `poly_bevel_G2_apex_v3`'s apex vertex (2.6e-8).
    ///   - 0 internal edges (standalone — touched by only ONE selected face)
    ///     on a face that is itself ISOLATED (no group-internal edge, i.e.
    ///     `!faceGrouped` — always so when `group=false`, or a single/
    ///     non-adjacent selected face): task 0467. The reference's
    ///     `bevGenInset` places the inset corner by a mitered offset that
    ///     stays in the
    ///     TANGENT PLANE ⟂ the WHOLE-FACE Newell normal —
    ///     `orig + faceNormal·shift + boundaryContourInset(eNext,ePrev,
    ///     faceNormal,inset)`. The pre-0467 `insetCorner`/`offsetMeet`
    ///     instead intersected the two offset lines along the corner's actual
    ///     TILTED edge directions, so on a non-planar quad the meet slid off
    ///     the tangent plane and gained a spurious normal-direction component
    ///     (the reported ~0.005–0.05 residual, e.g. a beveled subdivided-cube
    ///     face). Bit-exact (rr/gdb + fresh capture) against
    ///     `poly_bevel_{W1,W2,W3}_warped_standalone*` (findings.md §6). The
    ///     per-face path below (the `else` branch of the final-corner loop)
    ///     gates this on an isolated face (a GROUPED face's standalone
    ///     corners are the SEPARATE per-corner-AVE_N regime `poly_bevel_
    ///     {G2,G3}` pin — left untouched, out of scope here) AND a genuinely
    ///     non-planar corner (a planar corner keeps `offsetMeet`, so every
    ///     flat-face bevel is BYTE-IDENTICAL to pre-0467) AND a
    ///     well-conditioned miter.
    ///   - ≥2 internal edges AND ≥1 remaining boundary edge (a partial,
    ///     "some but not all" enclosure — task 0458 finding G3): SHARES one
    ///     vertex (topology matches the reference; the pre-0458 stub fell
    ///     through to the per-face formula, splitting it into one vertex
    ///     PER incident face) at `orig + shift·AVE_N + boundaryInset` — the
    ///     SAME recovered mitered-corner offset as the half-shared branch
    ///     above, using `v`'s two group-boundary-contour edges (its
    ///     internal spokes excluded entirely) — bit-exact against
    ///     `poly_bevel_G3_partial_fan`'s shared apex vertex (1.1e-8, task
    ///     0458 follow-up).
    /// `group=false` (default) is byte-identical to the pre-0391 kernel.
    ///
    /// `segments` (task 0391 Phase 5, `capture-verified` LINEAR staircase —
    /// `vibe3d-divergence` from edge.bevel's Round Level, which is a TRUE
    /// circular arc, see `bevelEdgesByMask`'s own doc comment): `N ≥ 1`
    /// interpolates `N` EQUAL linear steps from the original boundary to
    /// the final (inset+shift, or group-shared) corner, emitting `N` ring
    /// quads per boundary edge instead of 1 (`N-1` new intermediate rings).
    /// `segments<=1` (the default 0, or 1) is byte-identical to the flat
    /// single-ring result above. Intermediate (non-endpoint) ring vertices
    /// at a group-shared corner are memoized PER RING LEVEL (task 0458
    /// +S1 — `sharedVertIdxByLevel`), same as the t=Nseg final corner —
    /// a standalone corner (touched by only one selected face) always got
    /// a fresh per-face vertex either way, so this only changes shared
    /// corners. Before 0458 the intermediate rings were created per-face
    /// unconditionally, leaving two COINCIDENT-position vertices at a
    /// shared corner's every non-final ring level — a topology divergence
    /// `poly_bevel_S1_group_segs2` exposed (12 new verts / 20 total
    /// expected, 14 new / 22 total pre-fix — 2 grouped cube faces, segs=2).
    /// `group=true && segments>1`: bit-exact against that dump (task
    /// 0458 Phase 1) — the shared corner IS segmented the same equal-lerp
    /// way as every other boundary vertex, orig→group-final (the middle
    /// ring lands at exactly
    /// half-inset/half-shift, including at the grouped shared corner).
    ///
    /// `square` (task 0458 Phase 3, recovered square-cap boundary-mark +
    /// rebuild callback post-pass — `toolcards/poly.bevel/findings.md`
    /// §0/§3): composition order is `square( group_xor_notgroup( segments
    /// ) )` — square wraps whatever the (group|non-group)+segments solve
    /// above already produced, touching ONLY the outermost ring (the
    /// original boundary → `ringVerts[1]` bridge); any deeper segment
    /// rings (`ringVerts[1..Nseg]`) are untouched plain quads, unchanged.
    /// For each boundary-contour vertex `V` of a selected face:
    ///   - STANDALONE (not a group-shared corner, i.e. not in
    ///     `sharedCornerPos` — every corner when `group=false`, since
    ///     square is a pure per-face op there, task 0458 Q2 finding):
    ///     `V` is RETAINED at its original position, and TWO new split
    ///     points are inserted on `V`'s own two original boundary edges,
    ///     each at distance `effInset/Nseg` from `V` (the OUTERMOST
    ///     ring's own inset — Q3 finding: with segments, the split
    ///     distance is `inset/segs`, not the full inset). A quad CAP
    ///     replaces `V`'s corner: `[V, splitToward-next, ringVerts[1][V],
    ///     splitToward-prev]`.
    ///   - RIDGE (a group-shared corner, `internalCnt>=1` —
    ///     `sharedCornerPos`, task 0458 Q4 finding): NEITHER of its two
    ///     boundary edges gets a split near it, and NO cap is built — its
    ///     neighbourhood is already closed by the two edge-panels
    ///     (below) meeting directly at the original vertex, connected by
    ///     the radial edge to its own `ringVerts[1]` position (its group-
    ///     solved final/segment-ring position, computed above,
    ///     unaffected by square).
    /// Every surviving boundary edge (i.e. not group-dissolved — the
    /// existing `internalEdgeSet` skip above already excludes internal
    /// edges from ever reaching this code) gets an edge-panel quad:
    /// `[pointNear-i, pointNear-next, ringVerts[1][next], ringVerts[1][i]]`
    /// where `pointNear-*` is the new split (standalone) or the raw
    /// original vertex (ridge). The UNSELECTED face sharing that same
    /// original edge (there is always exactly one on a 2-manifold mesh)
    /// absorbs whichever split point(s) were created, splicing them into
    /// its own vertex loop between the two shared corners so the mesh
    /// stays watertight (no T-junction) — becoming an n-gon (hexagon in
    /// Q1/Q4, octagon in Q2 where a side face borders TWO independently-
    /// squared faces). Reproduced bit-exact (topology + position) against
    /// all four dump-oracles (`poly_bevel_{Q1_single_square,
    /// Q2_nonadjacent_square,Q3_square_segs2}.json` +
    /// `poly_bevel_two_faces_grouped_square1.json` = Q4). `square=false`
    /// (default) touches none of this code — byte-identical to the
    /// pre-0458-Phase-3 kernel.
    ///
    /// KNOWN LIMITATION (not exercised by any of the four dump-oracles,
    /// flagged rather than guessed): the split distance `effInset/Nseg`
    /// is not clamped against the boundary edge's own length the way the
    /// mitered final-ring inset is (`maxSafeUniformInset`) — an
    /// exceptionally large inset relative to a short edge could produce
    /// an overlapping/self-intersecting cap+panel pair. Left unclamped
    /// pending a captured case that actually exercises it.

    /// Two-layer DoS clamp: `segments` is hard-capped to
    /// `MAX_BEVEL_SEGMENTS` HERE (kernel-side, authoritative for any
    /// caller) since it scales ring-quad allocation linearly per selected
    /// face; the command/tool Param's `.min(0).max(MAX_BEVEL_SEGMENTS)
    /// .enforceBounds()` hint is a shallower UI/HTTP-only second line of
    /// defense.
    size_t bevelFacesByMask(const bool[] maskIn, float inset, float shift,
                             bool group = false, int segments = 0,
                             bool square = false) {
        const mask = maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        import std.math : abs;
        // Parity (fuzz D6): inset==0 && shift==0 is NOT a no-op — the
        // reference still builds a ZERO-WIDTH bevel ring (the inset cap
        // ring lands exactly on the original boundary, giving coincident
        // inner=outer corners + zero-area ring quads + a degenerate cap).
        // We therefore let a masked face through even at 0/0 and let the
        // per-face loop decide: an EMPTY mask still returns 0 (processed
        // stays 0 below → no commit), so a genuine "nothing selected"
        // call is unaffected. `shift==0` alone (inset>0) and `inset==0`
        // alone (shift!=0) already built a ring before this change.

        int segN = segments;
        if (segN < 0) segN = 0;
        if (segN > MAX_BEVEL_SEGMENTS) segN = MAX_BEVEL_SEGMENTS;
        immutable int Nseg = (segN < 1) ? 1 : segN; // segs=0 == segs=1 == flat

        size_t processed = 0;
        bool anyClamped = false;
        const size_t nFaces = faces.length;

        // Task 0467: `faceGrouped[fi]` = does selected face `fi` share a
        // group-internal edge with another selected face (i.e. is it part of
        // an ADJACENT group). Its STANDALONE corners then keep the
        // per-corner-AVE_N group regime (`poly_bevel_{G2,G3}`); an ISOLATED
        // face (no internal edge — always so when `group=false`) uses the
        // whole-face tangent-plane inset instead. Default false → every face
        // isolated unless the group pre-pass proves otherwise.
        bool[] faceGrouped = new bool[](nFaces);

        // --- group=true pre-pass: classify edges internal/boundary and
        // pre-compute each shared-corner vertex's target position. ---
        bool[ulong] internalEdgeSet;  // edgeKey → true(internal)/false(boundary), only for edges bordering >=1 selected face
        Vec3[uint]  sharedCornerPos;  // orig vertex idx → shared new position (half-shared or apex)
        if (group) {
            auto edgeFacesMap = buildEdgeFaces();
            foreach (fi; 0 .. nFaces) {
                if (fi >= mask.length || !mask[fi]) continue;
                auto f = faces[fi];
                immutable int Nf = cast(int)f.length;
                foreach (k; 0 .. Nf) {
                    uint a = f[k], b = f[(k + 1) % Nf];
                    immutable ulong key = edgeKey(a, b);
                    if (key in internalEdgeSet) continue;
                    auto fp = key in edgeFacesMap;
                    bool internal = false;
                    if (fp !is null && (*fp)[0] >= 0 && (*fp)[1] >= 0) {
                        immutable uint fa = cast(uint)(*fp)[0], fb = cast(uint)(*fp)[1];
                        internal = (fa < mask.length && mask[fa]) && (fb < mask.length && mask[fb]);
                        if (internal) { faceGrouped[fa] = true; faceGrouped[fb] = true; }
                    }
                    internalEdgeSet[key] = internal;
                }
            }

            // Per-vertex CORNER-NORMAL accumulator: once per (vertex,
            // selected face it corners) pair, regardless of how many of its
            // edges are internal — used only for vertices that end up
            // shared. Accumulates the RAW per-corner unit normal (task
            // 0458's `cornerNormalAt`, NOT yet shift-scaled) plus a count,
            // so `aveNormal()` below can apply the reference's `k·N/|N|²`
            // amplification — a plain `Σ(unit normal)*shift` (pre-0458)
            // only coincides with that when the corner normals are
            // mutually orthogonal (see `aveNormal`'s doc comment).
            Vec3[uint] normalSum;
            uint[uint] normalCount;
            foreach (fi; 0 .. nFaces) {
                if (fi >= mask.length || !mask[fi]) continue;
                foreach (v; faces[fi]) {
                    immutable Vec3 cn = cornerNormalAt(cast(uint)fi, v);
                    if (auto p = v in normalSum) *p = *p + cn;
                    else normalSum[v] = cn;
                    if (auto c = v in normalCount) ++(*c);
                    else normalCount[v] = 1;
                }
            }

            foreach (v, nSum; normalSum) {
                uint internalCnt = 0, lastInternalOther = uint.max;
                bool anyBoundary = false;
                foreach (ei; edgesAroundVertex(v)) {
                    immutable uint w = edgeOtherVertex(ei, v);
                    immutable ulong key = edgeKey(v, w);
                    auto ip = key in internalEdgeSet;
                    if (ip is null) continue; // doesn't border any selected face — irrelevant
                    if (*ip) { ++internalCnt; lastInternalOther = w; }
                    else     { anyBoundary = true; }
                }
                if (internalCnt == 0) continue; // standalone — default formula below
                immutable Vec3 aveN = aveNormal(nSum, normalCount[v]);
                immutable Vec3 sSum = aveN * shift;
                if (internalCnt == 1) {
                    // Half-shared (task 0458 finding G1) OR a ring vertex
                    // whose sole internal edge runs to a fully-enclosed
                    // apex (finding G2's OTHER, internalCnt>=2 vertex) —
                    // findings.md §1/§5: BOTH are governed by the SAME
                    // recovered mitered-corner offset built from `v`'s own
                    // two group-boundary-contour edges (NOT the internal
                    // edge). That construction is singular exactly on G1's
                    // coplanar-ridge topology (`boundaryContourInset`'s
                    // `|D·U|` gate) — there we fall back to the original
                    // 3-plane-meet law (along the internal edge itself),
                    // bit-exact against `poly_bevel_G1_halfshared_tent`
                    // (6e-9, incl. on non-90°/unequal-length asymmetric
                    // geometry). Off the gate, bit-exact against
                    // `poly_bevel_G2_apex_v3`'s ring vertices (1.2e-8 to
                    // 6.4e-8, task 0458 follow-up).
                    uint eA, eB;
                    Vec3 offset;
                    if (findGroupBoundaryContour(v, mask, internalEdgeSet, eA, eB) &&
                        boundaryContourInset(vertices[eA] - vertices[v],
                                              vertices[eB] - vertices[v], aveN, inset, offset)) {
                        sharedCornerPos[v] = vertices[v] + sSum + offset;
                    } else {
                        sharedCornerPos[v] = vertices[v] + sSum +
                            safeNormalize(vertices[lastInternalOther] - vertices[v]) * inset;
                    }
                } else if (!anyBoundary) {
                    // Fully-enclosed apex (finding G2): bit-exact against
                    // `poly_bevel_G2_apex_v3` (2.6e-8), no inset term (no
                    // boundary edge to inset against).
                    sharedCornerPos[v] = vertices[v] + sSum;
                } else {
                    // Partial — internalCnt>=2 with a remaining boundary
                    // edge (finding G3). Reference SHARES one vertex at
                    // `orig + shift·AVE_N + boundaryInset` — the SAME
                    // recovered mitered-corner offset as the half-shared
                    // branch above, using `v`'s two group-boundary-contour
                    // edges (excluding its internal spokes entirely) —
                    // bit-exact against `poly_bevel_G3_partial_fan`'s
                    // shared apex vertex (1.1e-8, task 0458 follow-up,
                    // `findings.md` §1/§5). The topology divergence the
                    // pre-0458 stub had (3 split per-face verts instead of
                    // 1) stays fixed regardless. Falls back to the plain
                    // `orig + shift·AVE_N` term (no documented case
                    // exercises this — the gate is only known to trigger
                    // on G1's coplanar-ridge topology, which cannot arise
                    // here since G3 always has a strict remaining
                    // boundary distinct from any coplanar internal ridge).
                    uint eA, eB;
                    Vec3 offset;
                    if (findGroupBoundaryContour(v, mask, internalEdgeSet, eA, eB) &&
                        boundaryContourInset(vertices[eA] - vertices[v],
                                              vertices[eB] - vertices[v], aveN, inset, offset)) {
                        sharedCornerPos[v] = vertices[v] + sSum + offset;
                    } else {
                        sharedCornerPos[v] = vertices[v] + sSum;
                    }
                }
            }
        }
        // orig vertex idx → already-created shared mesh vertex, memoized
        // PER RING LEVEL (index 0 unused — t=0 is always the untouched
        // original vertex, already naturally shared). `sharedVertIdxByLevel
        // [Nseg]` is the final ring's memo (pre-existing); task 0458 Phase 1
        // +S1 extends the SAME memoization to every intermediate ring
        // 1..Nseg-1 — `poly_bevel_S1_group_segs2` showed the reference
        // shares a group corner's intermediate-ring vertex too (one vertex
        // per distinct corner per ring, 12 new verts for 2 grouped
        // cube faces at segs=2), where the pre-0458 per-face-only
        // intermediate-ring code created TWO coincident-position vertices
        // (one per incident face) at every non-final ring level for a
        // shared corner — a topology divergence `group=true &&
        // segments>1` never had a fixture to catch (doc'd as
        // "KNOWN-UNTESTED" until this task).
        uint[uint][] sharedVertIdxByLevel = new uint[uint][](Nseg + 1);

        // task 0458 Phase 3 (square): per ORIGINAL boundary edge, the split
        // point (if any) created near each of its two endpoints, keyed by
        // an ORDERED pair `(fromVertex<<32)|towardVertex` (NOT
        // `edgeKey`'s canonical min/max — a single edge has two
        // independent split points, one per direction, and this key
        // disambiguates which). Populated while a selected face builds its
        // own splits below; consumed afterward by the unselected-neighbour
        // absorption pass so the mesh stays watertight (findings.md §3).
        uint[ulong] squareSplitAt;

        // --- Per-corner map carry (task 0697) ------------------------------
        // The frozen law (fixture cases `face_bevel_connected*`): the inset ring
        // takes the SOURCE FACE'S OWN UV polygon, inset by
        // `inset * uvPerimeter / geomPerimeter` — a computed value, not a blend
        // of corners, so it rides mechanism (e) (`PolyVertexGen.InsetRing`). The
        // kernel supplies the purely GEOMETRIC ratio `inset / geomPerimeter` and
        // each map insets its own polygon by that fraction of its own perimeter.
        // Walls need nothing of their own: their base corners are corners of the
        // source face (a copy) and their top corners stand on ring vertices (the
        // same gen, resolved once per vertex, so cap and wall agree by
        // construction).
        //
        // Before this the map was not even DROPPED here — the cap face keeps its
        // arity and `addFace` grows the tail, so `resizePolyVertexMaps` saw a
        // length-correct map and KEPT it: the cap silently carried the UN-inset
        // source values (correct only at inset==0) while every wall read 0.
        struct RingGen { uint srcFace; uint srcCorner; float amount; }
        RingGen[uint]         ringGenOfVertex;  // new ring vertex → its law
        PolyVertexBlend[uint] vertBlend;        // square split points
        uint[]                faceSrcOf;        // final face → source old face
        // Task 0830: the hand-rolled capture (dup the windings, prefix-sum the
        // offsets, guard the whole thing on `hasPolyVertexMap`) is now the
        // obligation handle. It arms the drop: from here until the declaration
        // at the bottom of the kernel, saying nothing loses the plane instead of
        // keeping stale values — which is precisely the failure this kernel
        // shipped before task 0697.
        auto rw = beginCornerRewrite();
        const bool remapUv = rw.active();
        if (remapUv) {
            faceSrcOf.length = nFaces;
            foreach (fi; 0 .. nFaces) faceSrcOf[fi] = cast(uint)fi;
        }

        foreach (fi; 0 .. nFaces) {
            if (fi >= mask.length || !mask[fi]) continue;
            const uint[] origFaceVerts = faces[fi].dup;
            const int    Nc            = cast(int)origFaceVerts.length;
            if (Nc < 3) continue;
            Vec3[] origPos = new Vec3[](Nc);
            foreach (i; 0 .. Nc) origPos[i] = vertices[origFaceVerts[i]];
            const Vec3 n = faceNormal(cast(uint)fi);

            float effInset = inset;
            if (inset > 0) {
                Vec3[] probe = new Vec3[](Nc);
                foreach (i; 0 .. Nc) probe[i] = insetCorner(origPos, i, n, 1.0f) - origPos[i];
                const float capT = maxSafeUniformInset(origPos, probe);
                // Landing AT the cap exactly (inset == capT) already collapses a
                // ring edge to zero length (its two corners coincide) — trigger
                // the weld cleanup below even when effInset doesn't need to move.
                if (capT <= effInset) { effInset = capT; anyClamped = true; }
            }

            // Geometric perimeter of the source face — the denominator of the
            // frozen UV inset ratio (task 0697). Zero on a degenerate face; the
            // ratio is then left at 0 so the ring reads the un-inset polygon
            // rather than a division by zero.
            float geomPerim = 0.0f;
            if (remapUv)
                foreach (i; 0 .. Nc)
                    geomPerim += (origPos[(i + 1) % Nc] - origPos[i]).length;
            const float insetRatio = (remapUv && geomPerim > 1e-12f)
                                   ? effInset / geomPerim : 0.0f;
            // Register a ring vertex's law. Level `t` of `Nseg` insets by its own
            // share of the distance — the measured law applied at that ring's own
            // inset, which is what its POSITION is (the ring is a linear lerp
            // toward the final corner). Only Nseg==1 is measured; deeper rings
            // are that same law read at their own t, not a second law.
            void noteRing(uint nv, int i, int t) {
                if (!remapUv) return;
                if (nv in ringGenOfVertex) return;   // group-shared: creator wins
                ringGenOfVertex[nv] = RingGen(cast(uint)fi, cast(uint)i,
                                              insetRatio * cast(float)t / cast(float)Nseg);
            }

            // Final (t=Nseg) corner per index — group-aware: a shared
            // corner is created ONCE and reused across every face it touches.
            uint[] finalVerts = new uint[](Nc);
            Vec3[] finalPos   = new Vec3[](Nc);
            foreach (i; 0 .. Nc) {
                immutable uint origV = origFaceVerts[i];
                auto shP = group ? (origV in sharedCornerPos) : null;
                if (shP !is null) {
                    finalPos[i] = *shP;
                    if (auto p = origV in sharedVertIdxByLevel[Nseg]) finalVerts[i] = *p;
                    else {
                        immutable uint nv = addVertex(finalPos[i]);
                        sharedVertIdxByLevel[Nseg][origV] = nv;
                        finalVerts[i] = nv;
                    }
                    noteRing(finalVerts[i], i, Nseg);
                } else {
                    // Standalone (non-group-shared) corner: touched by only
                    // ONE selected face (`internalCnt==0`, so it never got a
                    // `sharedCornerPos` entry above) — also every corner when
                    // `group=false`.
                    //
                    // Task 0467 — WARPED-quad inset on an ISOLATED face. For a
                    // face with no group-internal edge (a single selected
                    // face, or any non-adjacent selected face — the regime the
                    // reported ~0.005–0.05 residual lives in, e.g. a beveled
                    // subdivided-cube face), the reference's `bevGenInset`
                    // places the inset corner by a mitered offset that stays
                    // IN THE TANGENT PLANE (⟂ the whole-face Newell normal) —
                    // `boundaryContourInset(eNext,ePrev, faceNormal, inset)`,
                    // plus `faceNormal·shift`. The pre-0467 `insetCorner`
                    // (`offsetMeet`) instead intersects the two offset lines
                    // along the corner's ACTUAL (tilted) edge directions, so
                    // on a non-planar quad the meet point slides OFF the
                    // tangent plane and picks up a spurious normal-direction
                    // component (the residual). rr/gdb + fresh capture
                    // (`poly_bevel_{W1,W2,W3}_warped_standalone*`, findings.md
                    // §6): `bevGenInset` fires per face-corner and its AVE_N
                    // here is the WHOLE-FACE normal, NOT a per-corner
                    // cross-product — bit-exact on all three warped oracles.
                    //
                    // Gated to (a) an ISOLATED face (`!faceGrouped[fi]`) —
                    // uses the WHOLE-FACE Newell normal for both the tangent
                    // plane and the shift. A GROUPED face's standalone corners
                    // are a DIFFERENT regime (`poly_bevel_{G2,G3}`): the same
                    // mitered offset but built around the corner's own
                    // per-corner normal `cn`, handled by the `faceGrouped[fi]`
                    // branch just below; (b) a genuinely non-planar corner
                    // (`cornerNormal != faceNormal`) so every FLAT-face bevel
                    // stays BYTE-IDENTICAL to the pre-0467 `offsetMeet` law;
                    // and (c) a well-conditioned miter (`boundaryContourInset`
                    // non-degenerate). Off any gate it is the unchanged old
                    // law.
                    immutable Vec3 cn = cornerNormalAt(cast(uint)fi, origV);
                    Vec3 bcOffset;
                    if (!faceGrouped[fi] && dot(cn, n) < 1.0f - 1e-6f &&
                        boundaryContourInset(origPos[(i + 1) % Nc]      - origPos[i],
                                             origPos[(i + Nc - 1) % Nc] - origPos[i],
                                             n, effInset, bcOffset)) {
                        finalPos[i] = origPos[i] + n * shift + bcOffset;
                    } else if (faceGrouped[fi] && dot(cn, n) < 1.0f - 1e-6f &&
                        boundaryContourInset(origPos[(i + 1) % Nc]      - origPos[i],
                                             origPos[(i + Nc - 1) % Nc] - origPos[i],
                                             cn, effInset, bcOffset)) {
                        // GROUPED-STANDALONE corner (parity task): a standalone
                        // corner (internalCnt==0) of a face that IS part of an
                        // adjacent group (`faceGrouped[fi]`). Measured against
                        // the reference dumps (`poly_bevel_{G2,G3}`), this
                        // regime uses the SAME mitered-corner offset as the
                        // isolated branch above, but built around the corner's
                        // OWN (per-corner) shift normal `cn` — NOT the
                        // whole-face Newell normal `n`. Both the tangent plane
                        // fed to `boundaryContourInset` and the shift direction
                        // use `cn`. Bit-exact (< 1e-6) against every diverging
                        // standalone vertex in both dumps (G2 orig 1/3/5;
                        // G3 orig 0/1/3/5/6); the whole-face-`n` variant of
                        // this same offset is measurably worse there, so the
                        // per-corner normal is the discriminated law. Gated on
                        // a genuinely non-planar corner (`dot(cn,n) < 1-eps`)
                        // so every FLAT grouped face (cube corner, tent, square,
                        // segments) where `cn==n` stays BYTE-IDENTICAL to the
                        // old `offsetMeet` law, and on a well-conditioned miter.
                        finalPos[i] = origPos[i] + cn * shift + bcOffset;
                    } else {
                        finalPos[i] = insetCorner(origPos, i, n, effInset) + n * shift;
                    }
                    finalVerts[i] = addVertex(finalPos[i]);
                    noteRing(finalVerts[i], i, Nseg);
                }
            }

            // Intermediate segment rings: t=0 is the original boundary,
            // t=Nseg is finalVerts; t=1..Nseg-1 are new equal-lerp rings.
            // A group-shared corner (origV has a sharedCornerPos entry) is
            // memoized per ring level too — `poly_bevel_S1_group_segs2`
            // (task 0458 +S1): the reference shares the SAME intermediate
            // vertex across both faces at a grouped corner, not just the
            // final one. A standalone corner (no sharedCornerPos entry) is
            // touched by only one face anyway, so "per-face" and "shared"
            // coincide there — unchanged, always a fresh vertex per ring.
            uint[][] ringVerts = new uint[][](Nseg + 1);
            ringVerts[0]    = origFaceVerts.dup;
            ringVerts[Nseg] = finalVerts;
            foreach (t; 1 .. Nseg) {
                uint[] ring = new uint[](Nc);
                immutable float f = cast(float)t / cast(float)Nseg;
                foreach (i; 0 .. Nc) {
                    immutable uint origV = origFaceVerts[i];
                    if (group && (origV in sharedCornerPos) !is null) {
                        if (auto p = origV in sharedVertIdxByLevel[t]) ring[i] = *p;
                        else {
                            immutable uint nv = addVertex(origPos[i] + (finalPos[i] - origPos[i]) * f);
                            sharedVertIdxByLevel[t][origV] = nv;
                            ring[i] = nv;
                        }
                    } else {
                        ring[i] = addVertex(origPos[i] + (finalPos[i] - origPos[i]) * f);
                    }
                    noteRing(ring[i], i, t);
                }
                ringVerts[t] = ring;
            }

            // task 0458 Phase 3 (square): per-corner classification + the
            // two new split points on a STANDALONE corner's own two
            // original boundary edges (findings.md §3). A RIDGE corner
            // (group-shared, `sharedCornerPos`) gets neither — see the
            // function's own doc comment above for the full rule.
            uint[] splitToNext, splitToPrev;
            bool[] isRidgeCorner;
            // 0458 Phase-3 hardening (reviewer SHOULD-FIX): a zero effective
            // inset (inset=0 with shift>0 — reachable via the square UI toggle)
            // gives splitStep=0, collapsing the split points onto the corner →
            // degenerate zero-area caps + duplicate-vertex n-gons. Gate the WHOLE
            // square path on a non-degenerate inset so it falls back to the plain
            // (square=false) ring treatment there.
            immutable bool doSquare = square && effInset > 1e-6f;
            if (doSquare) {
                splitToNext   = new uint[](Nc);
                splitToPrev   = new uint[](Nc);
                isRidgeCorner = new bool[](Nc);
                immutable float splitStep = effInset / cast(float)Nseg;
                foreach (i; 0 .. Nc) {
                    immutable uint origV = origFaceVerts[i];
                    isRidgeCorner[i] = group && (origV in sharedCornerPos) !is null;
                    if (isRidgeCorner[i]) continue;
                    immutable int nxt = (i + 1) % Nc;
                    immutable int prv = (i + Nc - 1) % Nc;
                    immutable Vec3 dirNext = safeNormalize(origPos[nxt] - origPos[i]);
                    immutable Vec3 dirPrev = safeNormalize(origPos[prv] - origPos[i]);
                    splitToNext[i] = addVertex(origPos[i] + dirNext * splitStep);
                    splitToPrev[i] = addVertex(origPos[i] + dirPrev * splitStep);
                    squareSplitAt[(cast(ulong)origV << 32) | origFaceVerts[nxt]] = splitToNext[i];
                    squareSplitAt[(cast(ulong)origV << 32) | origFaceVerts[prv]] = splitToPrev[i];
                    if (remapUv) {
                        // A split point sits ON an original edge, so it is an
                        // ordinary edge-split blend — the same law the rest of
                        // the family uses, in whichever face reads it (its own
                        // panel, or the unselected neighbour it is spliced into).
                        void noteSplit(uint nv, int far) {
                            const float len = (origPos[far] - origPos[i]).length;
                            if (len < 1e-12f) return;
                            const float t = splitStep / len;
                            PolyVertexBlend b;
                            b.add(origFaceVerts[i],   1.0f - t);
                            b.add(origFaceVerts[far], t);
                            vertBlend[nv] = b;
                        }
                        noteSplit(splitToNext[i], nxt);
                        noteSplit(splitToPrev[i], prv);
                    }
                }
            }

            faces[fi] = finalVerts.dup;
            // Task 0389: read the source face's Subpatch bit BEFORE the ring
            // quads below grow `faceMarks` (addFace does not grow it itself —
            // `fi`'s own bit is unaffected by the in-place replace above).
            immutable bool srcSub  = isFaceSubpatch(fi);
            immutable size_t ringStart = faces.length;
            foreach (i; 0 .. Nc) {
                const int next = (i + 1) % Nc;
                if (group) {
                    immutable ulong key = edgeKey(origFaceVerts[i], origFaceVerts[next]);
                    if (internalEdgeSet.get(key, false)) continue; // internal — dissolves, no bridge
                }
                if (doSquare) {
                    // Outermost (t=0) bridge is replaced by the square
                    // edge-panel; deeper segment rings (t=1..Nseg-1) stay
                    // plain, unchanged (Q3 finding — square wraps only the
                    // outermost ring).
                    immutable uint pointAtI    = isRidgeCorner[i]
                        ? origFaceVerts[i] : splitToNext[i];
                    immutable uint pointAtNext = isRidgeCorner[next]
                        ? origFaceVerts[next] : splitToPrev[next];
                    addFace([pointAtI, pointAtNext, ringVerts[1][next], ringVerts[1][i]]);
                    foreach (t; 1 .. Nseg)
                        addFace([ringVerts[t][i],     ringVerts[t][next],
                                 ringVerts[t+1][next], ringVerts[t+1][i]]);
                } else {
                    foreach (t; 0 .. Nseg)
                        addFace([ringVerts[t][i],     ringVerts[t][next],
                                 ringVerts[t+1][next], ringVerts[t+1][i]]);
                }
            }
            if (doSquare) {
                // Quad cap per STANDALONE corner only — a ridge corner's
                // neighbourhood is already closed by the two edge-panels
                // above meeting at the original vertex (Q4 finding).
                foreach (i; 0 .. Nc)
                    if (!isRidgeCorner[i])
                        addFace([origFaceVerts[i], splitToNext[i],
                                 ringVerts[1][i],   splitToPrev[i]]);
            }
            // Ring quads inherit Subpatch from the beveled source face.
            resizeSubpatch();
            foreach (rfi; ringStart .. faces.length) setFaceSubpatch(rfi, srcSub);
            // Every face this source face appended reads its island (task 0697).
            if (remapUv) {
                faceSrcOf.length = faces.length;
                foreach (rfi; ringStart .. faces.length) faceSrcOf[rfi] = cast(uint)fi;
            }
            ++processed;
        }
        if (processed == 0) return 0;
        if (square && squareSplitAt.length > 0) {
            // Splice each surviving split point into the UNSELECTED face
            // sharing that original edge, so the mesh stays watertight (no
            // T-junction) — task 0458 Phase 3, findings.md §3. Only
            // ORIGINAL (pre-op) faces can need this; a face already
            // rebuilt above (`mask[fi]`) holds its own new ring/final
            // verts already, not the original boundary, and is skipped.
            foreach (fi; 0 .. nFaces) {
                if (fi < mask.length && mask[fi]) continue;
                const uint[] cur = faces[fi];
                immutable int N = cast(int)cur.length;
                if (N < 3) continue;
                uint[] rebuilt;
                foreach (k; 0 .. N) {
                    immutable uint a = cur[k], b = cur[(k + 1) % N];
                    rebuilt ~= a;
                    if (auto p = ((cast(ulong)a << 32) | b) in squareSplitAt) rebuilt ~= *p;
                    if (auto p2 = ((cast(ulong)b << 32) | a) in squareSplitAt) rebuilt ~= *p2;
                }
                faces[fi] = rebuilt;
            }
        }
        // Parity (fuzz D3): a positive inset clamped to `maxSafeUniformInset`
        // lands the cap ring AT the collapse point — several (or all) cap
        // corners coincide (a square face → all four onto the centroid). The
        // reference KEEPS that as a degenerate quad ring: the coincident
        // corners stay DISTINCT referenced verts, so the cap and every ring
        // quad remain 4-vertex (zero-area) faces rather than being welded
        // down + fan-triangulated. We therefore do NOT weld the clamped
        // pass — the ring quads/cap the loop already emitted are exactly the
        // reference topology (byte-verified against the fuzz repro's
        // 12v/10f all-quad dump). A non-clamped bevel never reaches here
        // (`anyClamped` stays false), so normal poly-bevel is byte-identical.
        // Per-corner map carry (task 0697) — BEFORE `compactUnreferenced`, which
        // renumbers vertices and would break the lookups into `oldFaces`, and
        // before the tail `buildLoops`. `faces` is already final here: the cap
        // was replaced in place, the ring quads appended, the square splice
        // done. `addFace` has grown each map at the TAIL, so the original values
        // still sit at their original offsets and `oldFaceLoop` still resolves.
        if (remapUv) {
            uint[]          srcOfCorner;
            PolyVertexGen[] gens;
            size_t loop = 0;
            foreach (fi, f; faces) {
                const uint sf = (fi < faceSrcOf.length) ? faceSrcOf[fi] : ~0u;
                foreach (v; f) {
                    srcOfCorner ~= sf;
                    if (auto g = v in ringGenOfVertex)
                        gens ~= PolyVertexGen(loop, g.srcFace, g.srcCorner,
                                              PolyVertexGen.Law.InsetRing, g.amount);
                    ++loop;
                }
            }
            declareCornerProvenance(
                rw.carried(faces.range, srcOfCorner, vertBlend, gens));
        }
        if (anyClamped || group) {
            // group's fully-enclosed apex vertices (every incident edge
            // internal) are never referenced by any surviving face or ring
            // quad once every incident face's corner has moved to the
            // shared apex — compact them away.
            compactUnreferenced();
        }
        rebuildEdges();
        buildLoops();
        syncSelection();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return processed;
    }

    unittest { // bevelFacesByMask: GROUP accumulator on ASYMMETRIC geometry —
               // task 0458 Phase 1, finding G1 (internalCnt==1, half-shared).
               // poly_bevel_corner.json's 3-face cube corner is axis-aligned —
               // its incident normals are mutually orthogonal, where the
               // reference's AVE_N=k·N/|N|² degenerates to the naive
               // Σ(unit normal) sum (the SAME 0453-class symmetry trap this
               // task's brief warns about). This raw mesh is a deliberately
               // asymmetric "tent" (non-90° dihedral, unequal adjacent-edge
               // lengths) — a naive-sum accumulator FAILS it; bit-exact
               // against the frozen reference dump (`poly_bevel_
               // G1_halfshared_tent`, 6.2e-9 on the reference side) is the
               // discriminator. See tests/fixtures/poly_bevel_G1_halfshared_
               // tent.json for the same case run through the HTTP fixture path.
        auto m = buildRawMesh(
            [Vec3(0.0f, 0.0f, 0.0f), Vec3(0.0f, 0.0f, 2.0f), Vec3(1.5f, 0.8f, 2.0f),
             Vec3(1.5f, 0.8f, 0.0f), Vec3(-0.7f, 1.0f, 0.0f), Vec3(-0.7f, 1.0f, 2.0f)],
            [[0u,1,2,3], [1u,0,4,5]]);
        bool[] mask = [true, true];
        size_t n = m.bevelFacesByMask(mask, 0.1f, 0.1f, true, 0);
        assert(n == 2);
        assert(m.vertices.length == 12, "6 orig (unchanged) + 2 shared ridge + 4 standalone");
        assert(m.faces.length    == 8,  "2 final quads + 2 faces x 3 remaining boundary bridges");

        bool foundA = false, foundB = false;
        foreach (v; m.vertices) {
            if ((v - Vec3(0.03111569f, 0.12992836f, 0.1f)).length < 1e-4f) foundA = true;
            if ((v - Vec3(0.03111569f, 0.12992836f, 1.9f)).length < 1e-4f) foundB = true;
        }
        assert(foundA, "shared ridge endpoint A should land at the AVE_N-amplified shift + inset-along-ridge position");
        assert(foundB, "shared ridge endpoint B (same accumulator, mirrored) should match too");
    }

    unittest { // bevelFacesByMask: GROUP accumulator, finding G2 (fully-enclosed
               // apex, internalCnt>=2 && !anyBoundary) — task 0458 Phase 1
               // (+ follow-up). Valence-3 apex surrounded by 3 irregular
               // NON-planar, non-orthogonal quads (all selected); the apex has
               // 3 internal edges and no boundary edge. `orig + shift·AVE_N`
               // (no inset term) is bit-exact against the reference dump
               // (`poly_bevel_G2_apex_v3`, 2.6e-8) for the apex vertex itself.
               // The SAME dump's ring vertices (each internalCnt==1, shared
               // between 2 of the 3 faces) are now ALSO bit-exact via the
               // recovered `bevGenInset` mitered-corner offset
               // (`boundaryContourInset`/`findGroupBoundaryContour`, task 0458
               // follow-up, findings.md §1/§5) — the position gap this
               // unittest used to document is closed.
        auto m = buildRawMesh(
            [Vec3(1.0f, 0.0f, 0.0f), Vec3(0.6f, -0.1f, 1.1f), Vec3(-0.5f, 0.05f, 1.3f),
             Vec3(-1.2f, -0.05f, 0.2f), Vec3(-0.7f, 0.1f, -1.0f), Vec3(0.5f, -0.2f, -0.9f),
             Vec3(0.1f, 1.0f, 0.05f)],
            // reference dump used reverse_winding=true for +Y outward normals —
            // pre-reversed here so vibe3d's own faceNormal() convention matches.
            [[2u,1,0,6], [4u,3,2,6], [0u,5,4,6]]);
        bool[] mask = [true, true, true];
        size_t n = m.bevelFacesByMask(mask, 0.1f, 0.1f, true, 0);
        assert(n == 3);
        bool foundApex = false;
        foreach (v; m.vertices)
            if ((v - Vec3(0.13126321f, 1.18738139f, 0.04756028f)).length < 1e-4f) foundApex = true;
        assert(foundApex, "fully-enclosed apex should sit at orig + shift*AVE_N (bit-exact against poly_bevel_G2_apex_v3)");

        // Ring vertices (dump[7]/[9]/[11], near orig-vert 0/2/4): bit-exact
        // against `poly_bevel_G2_apex_v3` via the recovered mitered-corner
        // offset (task 0458 follow-up).
        bool foundRing0 = false, foundRing2 = false, foundRing4 = false;
        foreach (v; m.vertices) {
            if ((v - Vec3(1.01231349f, 0.14855729f, -0.00942456f)).length < 1e-4f) foundRing0 = true;
            if ((v - Vec3(-0.48344547f, 0.20435742f, 1.27598262f)).length < 1e-4f) foundRing2 = true;
            if ((v - Vec3(-0.67538124f, 0.25805962f, -0.98621768f)).length < 1e-4f) foundRing4 = true;
        }
        assert(foundRing0, "ring vertex near orig-vert 0 should be bit-exact against poly_bevel_G2_apex_v3's dump[7]");
        assert(foundRing2, "ring vertex near orig-vert 2 should be bit-exact against poly_bevel_G2_apex_v3's dump[9]");
        assert(foundRing4, "ring vertex near orig-vert 4 should be bit-exact against poly_bevel_G2_apex_v3's dump[11]");
        // STANDALONE ring vertices (dump[8]/[10]/[12], near orig-vert 1/3/5 —
        // each touches only ONE selected face, internalCnt==0). These sit in the
        // grouped-standalone per-corner-AVE_N regime: `orig + shift*cn +
        // boundaryContourInset(eNext,ePrev, cn)` with `cn` the corner's own shift
        // normal (NOT the whole-face Newell normal, which is measurably worse).
        // Bit-exact against poly_bevel_G2_apex_v3's dump[8]/[10]/[12] (parity task).
        bool foundStd1 = false, foundStd3 = false, foundStd5 = false;
        foreach (v; m.vertices) {
            if ((v - Vec3(0.54333192f, 0.02258310f, 1.02778912f)).length < 1e-4f) foundStd1 = true;
            if ((v - Vec3(-1.10951495f, 0.07091790f, 0.19473825f)).length < 1e-4f) foundStd3 = true;
            if ((v - Vec3(0.46943665f, -0.06014295f, -0.84538692f)).length < 1e-4f) foundStd5 = true;
        }
        assert(foundStd1, "grouped-standalone vertex near orig-vert 1 should be bit-exact against poly_bevel_G2_apex_v3's dump[8]");
        assert(foundStd3, "grouped-standalone vertex near orig-vert 3 should be bit-exact against poly_bevel_G2_apex_v3's dump[10]");
        assert(foundStd5, "grouped-standalone vertex near orig-vert 5 should be bit-exact against poly_bevel_G2_apex_v3's dump[12]");
    }

    unittest { // bevelFacesByMask: GROUP accumulator, finding G3 (partial,
               // internalCnt>=2 && anyBoundary) — task 0458 Phase 1 (+
               // follow-up). Before Phase 1 the branch fell through entirely,
               // so a partial vertex got the STANDALONE per-face formula
               // applied once per incident face — 3 SEPARATE vertices instead
               // of the reference's ONE shared vertex (a topology divergence,
               // not just numeric). Valence-4 fan, only 3 of 4 quads selected,
               // so the shared apex has 2 internal + 2 boundary edges.
               //
               // This asserts BOTH the topology fix (one shared vertex,
               // referenced by every incident new face, matching the
               // reference's vertex/face counts) AND — since the follow-up —
               // the exact position via the recovered `bevGenInset`
               // mitered-corner offset (`boundaryContourInset`/
               // `findGroupBoundaryContour`, findings.md §1/§5): `orig +
               // shift·AVE_N + boundaryInset`, bit-exact against
               // `poly_bevel_G3_partial_fan`'s shared apex vertex (1.1e-8).
        import std.conv : to;
        auto m = buildRawMesh(
            [Vec3(1.0f, 0.0f, 0.0f), Vec3(0.7f, -0.1f, 0.8f), Vec3(0.0f, 0.05f, 1.2f),
             Vec3(-0.9f, -0.05f, 0.7f), Vec3(-1.1f, 0.1f, -0.1f), Vec3(-0.6f, -0.15f, -0.9f),
             Vec3(0.2f, 0.05f, -1.1f), Vec3(0.8f, -0.2f, -0.7f), Vec3(0.05f, 0.9f, 0.0f)],
            // reference dump used reverse_winding=true — pre-reversed.
            [[2u,1,0,8], [4u,3,2,8], [6u,5,4,8], [0u,7,6,8]]);
        bool[] mask = [true, true, true, false]; // only 3 of 4 quads selected
        size_t n = m.bevelFacesByMask(mask, 0.1f, 0.1f, true, 0);
        assert(n == 3);
        // Reference: 9 orig + 8 new = 17 verts; 12 faces (3 final quads + the
        // 4th untouched quad + bridges over the 4 remaining boundary edges of
        // the 3-face selection — matches poly_bevel_G3_partial_fan's 17v/12f).
        assert(m.vertices.length == 17, "partial-fan topology should match the reference vertex count (shared, not split)");
        assert(m.faces.length    == 12);

        // The shared partial vertex must sit at the bit-exact recovered
        // position (poly_bevel_G3_partial_fan's dump[16]) AND be referenced by
        // every incident new face exactly once (not duplicated into 3 separate
        // vertices, one per selected face, the pre-0458 fallback's behavior).
        immutable Vec3 expectedShared = Vec3(-0.07055401f, 1.00857651f, 0.10307505f);
        uint sharedIdx = uint.max;
        foreach (i, v; m.vertices)
            if ((v - expectedShared).length < 1e-4f) { sharedIdx = cast(uint)i; break; }
        assert(sharedIdx != uint.max,
            "expected the shared partial vertex bit-exact at orig + shift*AVE_N + boundaryInset (poly_bevel_G3_partial_fan's dump[16])");
        size_t refCount = 0;
        foreach (f; m.faces)
            foreach (v; f)
                if (v == sharedIdx) { ++refCount; break; }
        assert(refCount == 5, "the shared partial vertex should be referenced by all 5 incident faces (3 final + 2 bridges), got " ~ refCount.to!string);

        // STANDALONE corners (orig 0/1/3/5/6 — each internalCnt==0, touching one
        // selected face). Grouped-standalone per-corner-AVE_N regime: bit-exact
        // against poly_bevel_G3_partial_fan's dump[9]/[10]/[12]/[14]/[15]
        // (parity task).
        bool fStd0=false, fStd1=false, fStd3=false, fStd5=false, fStd6=false;
        foreach (v; m.vertices) {
            if ((v - Vec3(0.95582151f, 0.12657540f, 0.12734687f)).length < 1e-4f) fStd0 = true;
            if ((v - Vec3(0.65931493f, 0.03504139f, 0.75914669f)).length < 1e-4f) fStd1 = true;
            if ((v - Vec3(-0.84032083f, 0.08062109f, 0.66145885f)).length < 1e-4f) fStd3 = true;
            if ((v - Vec3(-0.57754570f, -0.00480662f, -0.87185556f)).length < 1e-4f) fStd5 = true;
            if ((v - Vec3(0.06068159f, 0.16000065f, -1.05715966f)).length < 1e-4f) fStd6 = true;
        }
        assert(fStd0, "grouped-standalone vertex near orig-vert 0 should be bit-exact against poly_bevel_G3_partial_fan's dump[9]");
        assert(fStd1, "grouped-standalone vertex near orig-vert 1 should be bit-exact against poly_bevel_G3_partial_fan's dump[10]");
        assert(fStd3, "grouped-standalone vertex near orig-vert 3 should be bit-exact against poly_bevel_G3_partial_fan's dump[12]");
        assert(fStd5, "grouped-standalone vertex near orig-vert 5 should be bit-exact against poly_bevel_G3_partial_fan's dump[14]");
        assert(fStd6, "grouped-standalone vertex near orig-vert 6 should be bit-exact against poly_bevel_G3_partial_fan's dump[15]");
    }

    unittest { // bevelFacesByMask: WARPED single quad, ISOLATED-face inset law —
               // captured-reference parity (task 0467). A symmetric saddle quad
               // (z alternates ±0.2 around the ring → strongly non-planar; its
               // whole-face Newell normal is exactly +Z) beveled as a SINGLE
               // face. This is the `poly_bevel_W1_warped_standalone` oracle,
               // rr/gdb-grounded (findings.md §6): the reference places each inset
               // corner by a mitered offset in the tangent plane ⟂ the WHOLE-FACE
               // normal (`boundaryContourInset(faceNormal)`) plus `faceNormal·
               // shift`, NOT by the old `offsetMeet` line-intersection (which
               // slides off the tilted edges and lands ~0.06 off in the normal
               // direction). The captured reference output (v4..v7) is bit-exact.
        auto m = buildRawMesh(
            [Vec3(-0.5f,-0.5f, 0.2f), Vec3(0.5f,-0.5f,-0.2f),
             Vec3( 0.5f, 0.5f, 0.2f), Vec3(-0.5f, 0.5f,-0.2f)],
            [[0u,1,2,3]]);
        immutable float inset = 0.15f, shift = 0.1f;
        const Vec3 n = m.faceNormal(0);
        assert((n - Vec3(0, 0, 1)).length < 1e-6f, "saddle quad's Newell normal must be +Z");
        size_t nb = m.bevelFacesByMask([true], inset, shift, false, 0);
        assert(nb == 1);
        // Captured reference (poly_bevel_W1_warped_standalone_group): the 4 inset
        // cap corners. XY = the in-tangent-plane 90° miter (±0.35); Z = orig ±0.2
        // shifted by +0.1 along the whole-face +Z normal (→ 0.30 / -0.10).
        immutable Vec3[4] refCap = [
            Vec3(-0.35f, -0.35f,  0.30f), Vec3( 0.35f, -0.35f, -0.10f),
            Vec3( 0.35f,  0.35f,  0.30f), Vec3(-0.35f,  0.35f, -0.10f)];
        // The old off-plane `offsetMeet` law (what the corner would get without
        // the fix): same XY, but Z = orig ± (inset-slide) + shift — lands ~0.06
        // off in Z. Assert the mesh is on the reference value and NOT the old one.
        foreach (mc; refCap) {
            bool found = false;
            foreach (v; m.vertices) if ((v - mc).length < 1e-4f) { found = true; break; }
            assert(found, "warped isolated-face cap corner must be bit-exact to the captured reference (poly_bevel_W1)");
        }
        // Guard the fix is actually engaged (not accidentally the old law): the
        // old whole-face `offsetMeet` corner for v0 would sit at z≈0.24, absent.
        bool foundOld = false;
        foreach (v; m.vertices)
            if ((v - Vec3(-0.35f, -0.35f, 0.24f)).length < 1e-3f) foundOld = true;
        assert(!foundOld, "the pre-0467 off-plane offsetMeet corner (z≈0.24) must be gone");
    }

    unittest { // bevelFacesByMask: FLAT quad stays on the OLD whole-face law
               // (task 0467 planarity gate — flat-face byte-identity guard). A
               // planar quad's per-corner normal equals its face normal, so the
               // gate (`dot(cn,n) >= 1-1e-6`) keeps the exact pre-0467
               // `insetCorner + n·shift` expression — every flat-face bevel
               // fixture is unaffected.
        auto m = buildRawMesh(
            [Vec3(-0.5f,-0.5f, 0.0f), Vec3(0.5f,-0.5f, 0.0f),
             Vec3( 0.5f, 0.5f, 0.0f), Vec3(-0.5f, 0.5f, 0.0f)],
            [[0u,1,2,3]]);
        immutable float inset = 0.2f, shift = 0.13f;
        Vec3[] origPos = [m.vertices[0], m.vertices[1], m.vertices[2], m.vertices[3]];
        const Vec3 n = m.faceNormal(0);
        Vec3[4] expOld;
        foreach (i; 0 .. 4) {
            immutable Vec3 cn = m.cornerNormalAt(0, cast(uint)i);
            assert(dot(cn, n) >= 1.0f - 1e-6f, "flat quad corner normal must equal the face normal");
            expOld[i] = m.insetCorner(origPos, cast(int)i, n, inset) + n * shift;
        }
        assert(m.bevelFacesByMask([true], inset, shift, false, 0) == 1);
        foreach (i; 0 .. 4) {
            bool exact = false;
            foreach (v; m.vertices) if (v == expOld[i]) { exact = true; break; } // byte-exact
            assert(exact, "flat cap corner must be BYTE-IDENTICAL to the pre-0467 insetCorner+n*shift law");
        }
    }

    /// Per-face spikey: for each face flagged true in `mask`, add a new apex
    /// vertex at the face centroid displaced along the face normal, then replace
    /// the face with a triangle fan to that apex (one tri per original edge).
    ///
    /// Displacement formula (D1-B, SDK-faithful): `disp = amount * (perimeter/N)`
    /// where perimeter = sum of edge lengths and N = vertex count. On a unit-edge
    /// face (N=4, perimeter=4) `disp == amount`. `amount == 0` is NOT a no-op —
    /// it produces an in-place fan-triangulate (apex at centroid, zero offset).
    ///
    /// The original face slot `fi` is replaced in-place with the first fan tri
    /// `[v0, v1, apex]`, preserving `faceMarks[fi]` (select + subpatch flag) and
    /// `faceMaterial[fi]`. The remaining N-1 fan tris are appended via `addFace`
    /// with the parent face's material and subpatch flag carried over. All
    /// appended fan tris are also selected (D3: select whole spike).
    ///
    /// Returns the number of faces processed (> 0 on success; 0 means nothing in
    /// `mask` had ≥ 3 verts — caller should discard snapshot).
    size_t spikeFacesByMask(const bool[] maskIn, float amount) {
        const mask = maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        size_t processed = 0;
        const size_t nFaces = faces.length; // snapshot before appending fan tris

        // Per-corner (UV) capture — task 0690. This kernel changes an EXISTING
        // face's arity in place (an N-gon becomes the first fan triangle), which
        // re-lays the corner space of every face after it: the appended tris'
        // atomic growth via `addFace` is therefore NOT enough, and without a
        // relocate the tail `buildLoops` zeroes the map WHOLE — spiking one face
        // would cost every other face its UV. Captured before the first mutation.
        // Task 0830: the capture is the obligation handle; the drop is what
        // happens if this kernel reaches `buildLoops` having said nothing.
        auto rw = beginCornerRewrite();
        const bool carryUv = rw.active();

        // Parallel lists: for each appended fan tri, record its face index
        // (captured at addFace time = faces.length-1) and its source face fi.
        uint[] appendedFi;
        uint[] fanSrc;

        foreach (fi; 0 .. nFaces) {
            if (fi >= mask.length || !mask[fi]) continue;
            const uint[] origFaceVerts = faces[fi].dup;
            const int    N             = cast(int)origFaceVerts.length;
            if (N < 3) continue;

            // Compute centroid and normal BEFORE mutating faces[fi].
            const Vec3 c = faceCentroid(cast(uint)fi);
            const Vec3 n = faceNormal(cast(uint)fi);

            // Perimeter = sum of edge lengths around the face ring.
            float perimeter = 0f;
            foreach (i; 0 .. N) {
                Vec3  a  = vertices[origFaceVerts[i]];
                Vec3  b  = vertices[origFaceVerts[(i + 1) % N]];
                float dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z;
                perimeter += sqrt(dx*dx + dy*dy + dz*dz);
            }

            // D1-B: displacement = amount * average edge length.
            float disp = amount * (perimeter / cast(float)N);
            uint apex = addVertex(c + n * disp);

            // In-place replace: first fan tri [v0, v1, apex] stays in slot fi,
            // automatically preserving faceMarks[fi] (Select + Subpatch bits)
            // and faceMaterial[fi].
            faces[fi] = [origFaceVerts[0], origFaceVerts[1], apex];

            // Append the remaining N-1 fan tris [vi, vi+1, apex] for i=1..N-1.
            foreach (i; 1 .. N) {
                uint newFi = cast(uint)faces.length; // capture BEFORE addFace grows
                addFace([origFaceVerts[i], origFaceVerts[(i + 1) % N], apex]);
                appendedFi ~= newFi;
                fanSrc     ~= cast(uint)fi;
            }

            ++processed;
        }

        if (processed == 0) return 0;

        // Attribute carry-over for appended fan tris.
        // addFace grows PolyVertex maps but NOT faceMaterial/facePart/faceMarks.
        // Save original array lengths for the source-read guard, then
        // grow all arrays (D zero-fills new slots).
        const size_t origMatLen  = faceMaterial.length;
        const size_t origPartLen = facePart.length;
        const size_t origSetLen  = faceSetMask.length;   // task 1060, Stage 5c
        resizeSubpatch();               // grows faceMarks to faces.length
        faceMaterial.length = faces.length;
        facePart.length     = faces.length;
        faceSetMask.length  = faces.length;
        foreach (k; 0 .. appendedFi.length) {
            const uint newFi = appendedFi[k];
            const uint srcFi  = fanSrc[k];
            faceMaterial[newFi] = (srcFi < origMatLen  ? faceMaterial[srcFi] : 0u);
            facePart[newFi]     = (srcFi < origPartLen ? facePart[srcFi]     : 0u);
            faceSetMask[newFi]  = (srcFi < origSetLen  ? faceSetMask[srcFi]  : 0UL);
            setFaceSubpatch(newFi, isFaceSubpatch(srcFi));
        }

        // Per-corner (UV) relocate — mechanism (c) with NO blends (task 0690).
        // Every corner standing on a vertex the source face already had copies
        // that face's value; the APEX corner is a genuinely new vertex whose UV
        // this port does not claim to know (the fixture measures edge splits and
        // bilerps, not a fan apex), so it is left at zero — the honest drop, for
        // one corner per spiked face instead of for the whole mesh.
        // (The pre-0830 `oldFaceLoop.length == nFaces` guard is gone with the
        // hand-rolled capture that needed it: `captureFaceLoop()` copied a
        // `faceLoop` that could be stale, whereas `rw`'s offsets are prefix-
        // summed from the very `faces` array `nFaces` was measured on.)
        if (carryUv) {
            uint[] srcFaceOfNewFace;
            srcFaceOfNewFace.length = faces.length;
            foreach (fi; 0 .. faces.length)
                srcFaceOfNewFace[fi] = (fi < nFaces) ? cast(uint)fi : ~0u;
            foreach (k, newFi; appendedFi)
                if (newFi < srcFaceOfNewFace.length)
                    srcFaceOfNewFace[newFi] = fanSrc[k];
            PolyVertexBlend[uint] noBlends;
            declareCornerProvenance(
                rw.carriedPerFace(faces.range, srcFaceOfNewFace, noBlends));
        }

        // Tail — correct order: syncSelection BEFORE selectFace so that
        // faceSelectionOrder (grown by syncSelection) is in bounds for appended
        // indices.
        rebuildEdges();
        buildLoops();
        syncSelection();  // grows faceSelectionOrder et al. to faces.length

        // D3: select all appended fan tris (slot fi stays selected via in-place).
        foreach (newFi; appendedFi) selectFace(cast(int)newFi);

        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return processed;
    }
}
