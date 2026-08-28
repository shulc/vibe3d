module mesh_ops.bevel_fin;

import mesh;
import math;
import std.array : uninitializedArray;
import mesh_edit_delta : MeshEditScope;

// ---------------------------------------------------------------------------
// The two NON-MANIFOLD fin-bundle spine kernels
// (`bevelIsolatedFinBundleSpine`, `bevelFinBundleSpineMultiEdge`).
//
// Split out of source/mesh_ops/edge_bevel.d (task 0717, audit 0678 §2B-M2 step B).
// They are a separate family from the manifold edge bevel that calls them:
// `bevelEdgesByMask` detects the fin-bundle shape and hands the whole edit
// over (the call sites are its only two early returns of that kind), and
// nothing else in the family shares a line with them.
//
// Converted from `mixin template MeshBevelFinOps` to module-level FREE
// FUNCTIONS by task 1903 Stage E4 (`doc/mesh_edit_seam_plan.md` §4, §5.2 row
// E4, which pairs this file with `mesh_ops/bevel_vertex.d`). Function BODIES
// are unchanged — every edit is an `ed.` prefix — and the shapes settled at
// C / D1 / D2 / D3 / E1 / E2 / E3 hold here verbatim: the receiver of a
// mutating kernel is the batch, the `mixin MeshBevelFinOps;` line left
// `struct Mesh` in the SAME change, and no kernel opens a batch of its own.
// What E4 adds to that memo is below.
//
// ONE RECEIVER, because both entries mutate (§4.1 cell one):
// `ref MeshEditBatch ed`. Both add vertices, rewrite fin windings in place and
// append two cap faces. §4.1's second cell (`ref const(Mesh)`) and its THIRD
// (a plain `ref Mesh` for a memoizing query) do not occur here: this file has
// no read-only entry and memoizes nothing.
//
// §4.4a's FOURTH CELL DOES OCCUR, AND IT IS THE REASON THIS FAMILY CARRIES A
// DEBT. Both kernels have exactly one caller each, and it is
// `mesh_ops/edge_bevel.d`'s `bevelEdgesByMask` — still a `mixin` until Stage
// G, so the caller IS the mesh and §4.1's "the boundary opens the batch" has
// nowhere to land. The TRANSITIONAL `unrecorded` batch therefore sits at those
// two call sites, scoped to the converted call alone, labelled, and named for
// the stage that removes it (G). See edge_bevel.d's own comment; the tripwire
// is the per-command `changeBus.nestedBatchOpens` DELTA in
// `tests/test_bevel_fin_bundle.d`, which drives `mesh.bevel` over a live
// three-fin bundle — the branch is unreachable from a cube, so a delta assert
// on any other bevel cell would be inert.
//
// WHAT THIS FAMILY DID NOT RECORD — CLOSED BY STAGE L7 (`bevel/inset`), AND
// THIS IS THE MEASUREMENT THAT CLOSED IT.
//
// Until L7 the fin rewrite was `ed.faces[fi] = nf;`, a DIRECT indexed winding
// install that reached no mutation hook — `mesh_planes.rewriteFaces` is never
// called here — so inside a RECORDING batch the op-log named the added rail
// vertices and the two cap faces and said NOTHING about the N fins whose
// windings changed. Measured on a three-fin stand driven through the
// production door (`bevelEdgesByMask` inside a recording batch): the log was
// `[AddVerts AddFaces RemoveVerts Reindex]`, four entries, and `revert()`
// THREW out of `finalize` -> `buildLoops` ("index [9] is out of bounds for
// array of length 8") leaving the mesh half-reverted — V and F back at the
// pre-op 8 / 3 with six face corners still naming rail vertices that no longer
// existed.
//
// BOTH kernels now install their fin windings with ONE BULK
// `ed.setFaceWindings(idx, to)` after the loop (see each Phase B for why bulk,
// why after the cap appends, and why the accumulator is ascending). The log on
// the same stand is `[AddVerts AddFaces (MeshMapDelta) ReshapeFaces
// RemoveVerts Reindex]` — the `MeshMapDelta` appears only when the mesh
// carries a PolyVertex map, and it is ADJACENT to the `ReshapeFaces` by
// contract (`CornerCarry.payloadForCount` binds the two by that adjacency) —
// and `revert()` returns true, throws nothing, and restores V / F / E,
// every winding, every vertex position bit-exactly, the material / part /
// subpatch planes, and every per-corner map value.
//
// THE ONE RESIDUAL, NAMED. The kernels' own selection edits
// (`clearFaceSelection` / `selectFace` / `clearVertexSelection` /
// `clearEdgeSelectionResize`) are still in NO op-log entry, so a revert leaves
// the fins selected and the pre-op vertex/edge selection cleared. That gap
// predates L7 (the four-entry log above had no `SelectionDelta` either) and is
// untouched by it; the delta still declares `Marks`, which is what its scope
// constant says.
//
// THE CORNER SPACE IS WHERE THE TWO KERNELS DIVERGE, and it is measured, not
// reasoned: `bevelIsolatedFinBundleSpine` reshapes at EQUAL arity, so
// `resizePolyVertexMaps`' length insurance keeps every value on its own corner
// and it declares no provenance. `bevelFinBundleSpineMultiEdge`'s corner cut
// CHANGES a fin's arity, and before L7 that tripped mesh.d's always-on
// `debug assert` — verbatim, on a UV stand in a `-debug` build: "corner
// provenance: a face rewrite reached buildLoops without declaring what became
// of the corners, and without arming beginCornerRewrite()/
// beginCornerRelocate() either …", through `resizePolyVertexMaps <-
// buildLoops <- finalizeTopologyEdit <- bevelFinBundleSpineMultiEdge <-
// bevelEdgesByMask`. It declares a CARRY now; the reasoning is at that site.
//
// (`tests/unit/mesh_ops/bevel_fin_test.d`'s recording block still asserts the
// PRE-L7 four-entry log and `ReshapeFaces == 0`, under a comment labelled
// "STAGE K/L7 FLIPS THIS". L7 is that stage: that block and its comment have
// to move with this change.)
//
// `Mesh.finalizeTopologyEdit` is one of §2.6's eleven private names, widened
// to public in this stage's commit because this file (and bevel_vertex.d)
// stopped being a mixin body instantiated in mesh.d's scope. The census row
// naming its callers is in tests/unit/commit_seam_census_test.d.
// ---------------------------------------------------------------------------

/// The edit class both fin-bundle kernels declare, in ONE place. Both add
/// vertices and faces (`Points | Polygons`) and rewrite the face selection
/// (`Marks`); neither moves an EXISTING vertex, which is why `Position` — the
/// bit decimate and the plane cut carry — is absent here. The caller passes
/// this to `MeshEditBatch`; the kernels' own `commitChange` calls keep their
/// literal spelling, exactly as cut.d and cleanup.d do.
enum uint kBevelFinEditScope = MeshEditScope.Geometry | MeshEditScope.Marks;

/// endpoints must touch NOTHING but the N incident fins — a spine embedded in
/// a larger mesh (an endpoint carrying any other face) is refused. Reference
/// law, captured bit-exact for N=3 and N=4 (`edge_bevel_0438_{A3face,B4face}_*`):
///   * each fin is inset in place — its two spine corners (a, b) are each
///     replaced by a rail point `p + width·û_perp`, where û_perp is the
///     in-plane direction at that corner perpendicular to the spine, toward
///     the fin's interior (the identical per-face formula ordinary two-face
///     edges use); the fin keeps its arity and its winding.
///   * exactly one new N-gon cap is added at EACH spine end, fanning that
///     end's N rail points in incident-face order. BOTH caps use the same
///     order, so their winding is emergent-consistent with the reference's.
/// `sharp` is not a parameter here and Round Level does not round this cap —
/// both measured inert, so this takes neither. Returns 1 on success, or 0
/// (leaving the mesh byte-identical) when the isolated-bundle precondition
/// fails — honoring `bevelEdgesByMask`'s "return 0 ⇒ no-op" contract, so all
/// precondition checks run BEFORE the first mutation.
size_t bevelIsolatedFinBundleSpine(ref MeshEditBatch ed, uint spineEdge, float width) {
    if (spineEdge >= ed.edges.length) return 0;
    immutable uint a = ed.edges[spineEdge][0];
    immutable uint b = ed.edges[spineEdge][1];
    if (a == b) return 0;

    // Incident fins in FACE-INDEX order (reproduces the reference's incident-
    // polygon fan order; the winding check is rotation-invariant so the
    // starting offset is immaterial). Scanning faces directly is non-
    // manifold-safe, unlike a fan walk around a non-manifold vertex.
    uint[] fins;
    foreach (fi; 0 .. cast(uint)ed.faces.length) {
        auto f = ed.faces[fi];
        immutable L = f.length;
        foreach (k; 0 .. L) {
            immutable uint u = f[k], w = f[(k + 1) % L];
            if ((u == a && w == b) || (u == b && w == a)) { fins ~= fi; break; }
        }
    }
    immutable size_t N = fins.length;
    if (N < 3) return 0;

    // Isolated-bundle precondition: neither endpoint may touch any face that
    // is NOT one of the N fins. Every fin already contains both a and b, so
    // "incident-face count == N" at each endpoint is exactly that condition.
    size_t facesWith(uint v) {
        size_t c = 0;
        foreach (f; ed.faces) foreach (vv; f) if (vv == v) { ++c; break; }
        return c;
    }
    if (facesWith(a) != N || facesWith(b) != N) return 0;

    // --- Phase A: compute everything, mutate nothing (no-op contract). ---
    Vec3 railPos(uint p, uint q, uint nbr, out bool ok) {
        immutable Vec3 P = ed.vertices[p];
        Vec3 uu = ed.vertices[q] - P;
        immutable float ul = uu.length;
        if (ul > 1e-12f) uu = uu / ul;
        immutable Vec3 e = ed.vertices[nbr] - P;
        immutable Vec3 perp = e - uu * dot(e, uu);
        immutable float pl = perp.length;
        if (pl < 1e-9f) { ok = false; return P; }
        ok = true;
        return P + perp / pl * width;
    }
    Vec3[] railAPos; railAPos.reserve(N);
    Vec3[] railBPos; railBPos.reserve(N);
    auto finPa = new int[](N);
    auto finPb = new int[](N);
    foreach (idx, fi; fins) {
        auto f = ed.faces[fi];
        immutable L = f.length;
        int pa = -1, pb = -1;
        foreach (k; 0 .. L) { if (f[k] == a) pa = cast(int)k; if (f[k] == b) pb = cast(int)k; }
        if (pa < 0 || pb < 0) return 0;
        immutable uint aOther = (f[(pa + 1) % L] == b) ? f[(pa + L - 1) % L] : f[(pa + 1) % L];
        immutable uint bOther = (f[(pb + 1) % L] == a) ? f[(pb + L - 1) % L] : f[(pb + 1) % L];
        bool okA, okB;
        immutable Vec3 ra = railPos(a, b, aOther, okA);
        immutable Vec3 rb = railPos(b, a, bOther, okB);
        if (!okA || !okB) return 0;
        railAPos ~= ra; railBPos ~= rb;
        finPa[idx] = pa; finPb[idx] = pb;
    }

    // --- Phase B: mutate. Add rails, rewrite each fin in place, add caps. ---
    //
    // TASK 1903 STAGE L7 — THE FIN WINDINGS HAVE A PUBLISHER NOW.
    //
    // `ed.faces[fi] = nf;` was a RAW indexed install: `alias mesh this` makes
    // it compile inside a recording batch and it reaches no record primitive at
    // all, so the op-log named the six rails (`AddVerts`), the two fan caps
    // (`AddFaces`) and the tail compaction (`RemoveVerts Reindex`) and said
    // NOTHING about the N fin windings it had just rewritten. Measured on the
    // three-fin stand before this change: `[AddVerts AddFaces RemoveVerts
    // Reindex]`, four entries, and `revert()` THREW out of `finalize` ->
    // `buildLoops` ("index [9] is out of bounds for array of length 8") leaving
    // the mesh half-reverted — V and F back at 8 / 3 with six face corners
    // still naming rail vertices that no longer exist. That is the file
    // header's "WHAT THIS FAMILY DOES NOT RECORD" row, and this is the call it
    // said the family owed.
    //
    // ONE BULK CALL AFTER THE LOOP, not one per fin. `Mesh.setFaceWindings`
    // pairs its `ReshapeFaces` entry with a per-corner payload, and
    // `recordPolyVertexPayload` resolves the corner bases of the faces it is
    // handed by ONE ordered sweep over `faces` — so N single-face calls are
    // O(N·F) (card 2260 measured the per-element door at 31x on 3 600 faces and
    // 66x on 10 000; judged by TIME, never by the GC byte counter, which points
    // the wrong way on this choice). The install is also deferred past the two
    // cap `addFace`s for the same reason `spikeFacesByMask` defers past its fan
    // appends: `addFace` grows the PolyVertex maps in lock-step with `faces`,
    // and every read in this call has to happen in one consistent corner space.
    //
    // `windIdx` IS STRICTLY ASCENDING BY CONSTRUCTION, which `setFaceWindings`
    // REQUIRES and which it enforces only in a `debug` build: on an unordered
    // list its ordered sweep bails at `k != oldFaceIdx.length` and DECLINES
    // SILENTLY, leaving the entry unpaired and the per-corner values re-derived
    // slot-for-slot instead of restored verbatim. `fins` is filled by a
    // `foreach (fi; 0 .. faces.length)` scan above, so it is ascending, and
    // this loop walks it in order.
    //
    // THE ARRAYS ARE PRE-SIZED AND SLICED, never grown with `~=`. `FaceIdx`
    // `@disable`s default construction (a defaulted face index would be face 0,
    // and face 0 is a real face), so `.length =` does not compile on a
    // `FaceIdx[]` in either direction — `uninitializedArray` plus a slice is
    // the only spelling.
    //
    // NO CORNER-PROVENANCE DECLARATION HERE, and that is measured rather than
    // assumed: this kernel replaces two corners of each fin with rail vertices
    // at EQUAL arity, so the corner space is untouched and `resizePolyVertexMaps`'
    // length insurance keeps every value on its own corner. Driven on a UV
    // stand in a `-debug` build it does not trip the provenance assert (its
    // multi-edge sibling, whose corner cut changes arity, does — see there).
    uint[] railA; railA.reserve(N);
    uint[] railB; railB.reserve(N);
    auto windIdx = uninitializedArray!(FaceIdx[])(N);
    auto windTo  = uninitializedArray!(uint[][])(N);
    size_t nw = 0;
    foreach (idx, fi; fins) {
        immutable uint ia = ed.addVertex(railAPos[idx]);
        immutable uint ib = ed.addVertex(railBPos[idx]);
        railA ~= ia; railB ~= ib;
        uint[] nf = ed.faces[fi].dup;
        nf[finPa[idx]] = ia;
        nf[finPb[idx]] = ib;
        // COLLECTED here, INSTALLED in the one bulk call below. Nothing between
        // this point and that call reads `ed.faces[fi]` for a rewritten fin —
        // verified: the rest of this loop only calls `addVertex`, the cap
        // builders read `railA`/`railB` (vertex indices, not windings), and
        // `ed.faces.length` is a count. So the deferral is forward-invisible.
        assert(nw == 0 || windIdx[nw - 1].raw < fi,
            "bevelIsolatedFinBundleSpine: the winding accumulator went "
          ~ "non-ascending — `setFaceWindings` DECLINES SILENTLY on an "
          ~ "unordered list, which would unpair the per-corner payload");
        windIdx[nw] = ed.faceIndexAt(fi);
        windTo[nw]  = nf;
        ++nw;
    }
    // One N-gon fan cap per spine end, both in incident-face order.
    immutable uint capA = cast(uint)ed.faces.length; ed.addFace(railA);
    immutable uint capB = cast(uint)ed.faces.length; ed.addFace(railB);
    assert(nw == N, "bevelIsolatedFinBundleSpine: the fin loop and the winding "
                  ~ "accumulator disagree about how many fins were rewritten");
    cast(void) ed.setFaceWindings(windIdx[0 .. nw], windTo[0 .. nw]);

    // The original spine verts a, b are now unreferenced; the tail
    // compaction drops them (net: −2 spine verts, +2N rails; +2 cap faces).
    ed.syncSelection();
    ed.clearFaceSelection();
    foreach (fi; fins) ed.selectFace(cast(int)fi);
    ed.selectFace(cast(int)capA);
    ed.selectFace(cast(int)capB);
    ed.resizeVertexSelection();
    ed.clearVertexSelection();
    ed.clearEdgeSelectionResize();
    ed.finalizeTopologyEdit();
    ed.commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
    return 1;
}

/// Bevel an isolated fin-bundle spine (edge shared by N≥3 fins whose two
/// endpoints touch NOTHING but those fins) together with a set of "extra"
/// selected edges — the measured law for a multi-edge selection *through* the
/// non-manifold spine (parity task, fuzz divergence D2). Generalizes the
/// single-spine `bevelIsolatedFinBundleSpine`; each extra edge must be a
/// fin's OUTER boundary edge (a rim edge, one incident face = a fin) that is
/// incident to a spine endpoint. Captured bit-exact for N=3 across a
/// rectangular AND a skewed fin (the skew disambiguates the corner law from
/// the rectangle's 90° degeneracy).
///
/// Per fin, at each spine endpoint p (outer neighbour W = p's fin neighbour
/// that is not the other spine endpoint):
///   * If the outer edge (p, W) is NOT selected: p's spine corner insets to
///     the spine rail `p + width·û_perp` exactly as the single-spine case.
///     The cap at that end fans this rail.
///   * If (p, W) IS selected: p's corner becomes a MITER — the intersection
///     of the spine-chamfer inset line and the (p, W)-chamfer inset line
///     (both in the fin plane, each offset `width` from its edge). The cap
///     fans this miter. The far endpoint W is corner-cut into TWO vertices:
///     a perpendicular inset of the fin's NEXT edge (W, Wnext) at W, and a
///     slide along (W, Wnext) by `width`; so the fin gains one ring vertex
///     per extra edge.
/// One N-gon fan cap is added at EACH spine end (incident-face order, same
/// winding convention as the single-spine sibling).
///
/// Returns the number of selected edges consumed (spine + extras) on success,
/// or 0 (mesh byte-identical) when any precondition fails — every check runs
/// BEFORE the first mutation, honouring `bevelEdgesByMask`'s no-op contract.
/// Anything past the measured shape refuses: >1 spine, an extra that is not a
/// fin's rim edge at a spine endpoint, an extra whose far vertex is the other
/// spine endpoint, a fin carrying extras at BOTH ends (their corner-cuts can
/// collide on a quad), or a degenerate miter / perpendicular.
size_t bevelFinBundleSpineMultiEdge(ref MeshEditBatch ed, uint spineEdge,
                                   const uint[] extraEdges, float width) {
    if (spineEdge >= ed.edges.length) return 0;
    immutable uint a = ed.edges[spineEdge][0];
    immutable uint b = ed.edges[spineEdge][1];
    if (a == b) return 0;

    // Incident fins in FACE-INDEX order (scan faces directly — non-manifold-
    // safe, unlike a fan walk around a non-manifold vertex; see the single-
    // spine sibling).
    uint[] fins;
    foreach (fi; 0 .. cast(uint)ed.faces.length) {
        auto f = ed.faces[fi];
        immutable L = f.length;
        foreach (k; 0 .. L) {
            immutable uint u = f[k], w = f[(k + 1) % L];
            if ((u == a && w == b) || (u == b && w == a)) { fins ~= fi; break; }
        }
    }
    immutable size_t N = fins.length;
    if (N < 3) return 0;

    // Isolated-bundle precondition (identical to the single-spine sibling):
    // neither endpoint may touch any face that is not one of the N fins.
    size_t facesWith(uint v) {
        size_t c = 0;
        foreach (f; ed.faces) foreach (vv; f) if (vv == v) { ++c; break; }
        return c;
    }
    if (facesWith(a) != N || facesWith(b) != N) return 0;

    int finPos(uint fi) { foreach (idx, ff; fins) if (ff == fi) return cast(int)idx; return -1; }

    // Classify each extra edge → (fin, spine endpoint slot, far vertex W).
    // extraFar[finIdx][0] = W for an extra at `a`, [1] = W for an extra at
    // `b`; ~0u = none. Reject anything outside the measured shape here,
    // before any mutation.
    auto extraFar = new uint[2][](N);
    foreach (ref e; extraFar) { e[0] = ~0u; e[1] = ~0u; }
    foreach (ee; extraEdges) {
        if (ee >= ed.edges.length) return 0;
        immutable uint u = ed.edges[ee][0], v = ed.edges[ee][1];
        uint incFace = ~0u; size_t incCount = 0;
        foreach (fi; 0 .. cast(uint)ed.faces.length) {
            auto f = ed.faces[fi]; immutable L = f.length;
            foreach (k; 0 .. L) {
                immutable uint x = f[k], y = f[(k + 1) % L];
                if ((x == u && y == v) || (x == v && y == u)) { incFace = fi; ++incCount; break; }
            }
        }
        if (incCount != 1) return 0;             // not a rim edge
        immutable int fp = finPos(incFace);
        if (fp < 0) return 0;                     // rim edge not on a fin
        uint p, W;
        if (u == a || u == b) { p = u; W = v; }
        else if (v == a || v == b) { p = v; W = u; }
        else return 0;                            // extra not at a spine endpoint
        if (W == a || W == b) return 0;           // far vertex is the other spine endpoint
        immutable int slot = (p == a) ? 0 : 1;
        if (extraFar[fp][slot] != ~0u) return 0;  // two extras same fin+endpoint
        extraFar[fp][slot] = W;
    }
    foreach (fp; 0 .. N)
        if (extraFar[fp][0] != ~0u && extraFar[fp][1] != ~0u) return 0; // extras both ends

    // --- Phase A: compute everything, mutate nothing (no-op contract). ---
    // p slid `width` along the in-plane perpendicular to edge (p→q), toward
    // `nbr` (the identical rail idiom the single-spine path and two-face
    // edges use).
    Vec3 railFrom(uint p, uint q, uint nbr, out bool ok) {
        immutable Vec3 P = ed.vertices[p];
        Vec3 uu = ed.vertices[q] - P;
        immutable float ul = uu.length;
        if (ul > 1e-12f) uu = uu / ul;
        immutable Vec3 e = ed.vertices[nbr] - P;
        immutable Vec3 perp = e - uu * dot(e, uu);
        immutable float pl = perp.length;
        if (pl < 1e-9f) { ok = false; return P; }
        ok = true;
        return P + perp / pl * width;
    }
    // Miter at spine endpoint p (outer neighbour W): intersection of the
    // spine-chamfer inset line (through the spine rail, along the spine) and
    // the (p,W)-chamfer inset line (through (p,W)'s inset rail, along (p,W)).
    Vec3 miterAt(uint p, uint other, uint W, out bool ok) {
        bool o1, o2;
        immutable Vec3 R  = railFrom(p, other, W, o1);   // on the spine inset line
        immutable Vec3 Rp = railFrom(p, W, other, o2);   // on the (p,W) inset line
        if (!o1 || !o2) { ok = false; return ed.vertices[p]; }
        immutable Vec3 dS = safeNormalize(ed.vertices[other] - ed.vertices[p]);
        immutable Vec3 dO = safeNormalize(ed.vertices[W] - ed.vertices[p]);
        immutable Vec3 nrm = cross(dS, dO);
        immutable float nn = dot(nrm, nrm);
        if (nn < 1e-12f) { ok = false; return ed.vertices[p]; }  // parallel ⇒ degenerate
        immutable Vec3 r = Rp - R;
        immutable float s = dot(cross(r, dO), nrm) / nn;
        ok = true;
        return R + dS * s;
    }

    // Per-fin plan: new-vertex positions + a ring template (≥0 ⇒ existing
    // vertex index, <0 ⇒ −(local+1) into `np`), plus which local slot is the
    // a-end / b-end cap point.
    struct FinPlan { Vec3[] np; int[] ring; int aCapL; int bCapL; }
    FinPlan[] plans; plans.reserve(N);

    foreach (fp, fi; fins) {
        auto f = ed.faces[fi]; immutable L = f.length;
        int ia = -1, ib = -1;
        foreach (k; 0 .. L) { if (f[k] == a) ia = cast(int)k; if (f[k] == b) ib = cast(int)k; }
        if (ia < 0 || ib < 0) return 0;
        immutable uint aN = (f[(ia + 1) % L] == b) ? f[(ia + L - 1) % L] : f[(ia + 1) % L];
        immutable uint bN = (f[(ib + 1) % L] == a) ? f[(ib + L - 1) % L] : f[(ib + 1) % L];
        immutable uint aFar = extraFar[fp][0];
        immutable uint bFar = extraFar[fp][1];

        bool ok;
        Vec3 aCornerPos = (aFar != ~0u) ? miterAt(a, b, aN, ok) : railFrom(a, b, aN, ok);
        if (!ok) return 0;
        Vec3 bCornerPos = (bFar != ~0u) ? miterAt(b, a, bN, ok) : railFrom(b, a, bN, ok);
        if (!ok) return 0;

        FinPlan pl; pl.aCapL = -1; pl.bCapL = -1;
        foreach (k; 0 .. L) {
            immutable uint v = f[k];
            if (v == a) {
                pl.np ~= aCornerPos; pl.aCapL = cast(int)(pl.np.length - 1);
                pl.ring ~= -(cast(int)pl.np.length);
            } else if (v == b) {
                pl.np ~= bCornerPos; pl.bCapL = cast(int)(pl.np.length - 1);
                pl.ring ~= -(cast(int)pl.np.length);
            } else if (aFar != ~0u && v == aN) {
                // Corner-cut aN (far end of the extra edge at `a`).
                immutable bool fwd = (f[(k + 1) % L] != a);   // walk goes a → aN → Wnext
                immutable uint Wnext = fwd ? f[(k + 1) % L] : f[(k + L - 1) % L];
                if (Wnext == a || Wnext == b) return 0;
                bool okp;
                immutable Vec3 Vperp = railFrom(aN, Wnext, a, okp);        // perp inset of (aN,Wnext)
                if (!okp) return 0;
                immutable Vec3 Valong = ed.vertices[aN] + safeNormalize(ed.vertices[Wnext] - ed.vertices[aN]) * width;
                if (fwd) { pl.np ~= Vperp; pl.ring ~= -(cast(int)pl.np.length);
                           pl.np ~= Valong; pl.ring ~= -(cast(int)pl.np.length); }
                else     { pl.np ~= Valong; pl.ring ~= -(cast(int)pl.np.length);
                           pl.np ~= Vperp; pl.ring ~= -(cast(int)pl.np.length); }
            } else if (bFar != ~0u && v == bN) {
                immutable bool fwd = (f[(k + 1) % L] != b);   // walk goes b → bN → Wnext
                immutable uint Wnext = fwd ? f[(k + 1) % L] : f[(k + L - 1) % L];
                if (Wnext == a || Wnext == b) return 0;
                bool okp;
                immutable Vec3 Vperp = railFrom(bN, Wnext, b, okp);
                if (!okp) return 0;
                immutable Vec3 Valong = ed.vertices[bN] + safeNormalize(ed.vertices[Wnext] - ed.vertices[bN]) * width;
                if (fwd) { pl.np ~= Vperp; pl.ring ~= -(cast(int)pl.np.length);
                           pl.np ~= Valong; pl.ring ~= -(cast(int)pl.np.length); }
                else     { pl.np ~= Valong; pl.ring ~= -(cast(int)pl.np.length);
                           pl.np ~= Vperp; pl.ring ~= -(cast(int)pl.np.length); }
            } else {
                pl.ring ~= cast(int)v;
            }
        }
        if (pl.aCapL < 0 || pl.bCapL < 0) return 0;
        plans ~= pl;
    }

    // --- Phase B: mutate. Add rails/miters/cuts, rewrite fins, add caps. ---
    //
    // TASK 1903 STAGE L7 — THE PUBLISHER, AND THE CORNER DECLARATION THIS
    // KERNEL (UNLIKE ITS SINGLE-SPINE SIBLING) ALSO OWES.
    //
    // The winding install is the same story as the sibling's — see the long
    // note there for why it is ONE BULK `setFaceWindings` after every append,
    // why `windIdx` is ascending by construction, and why the arrays are
    // pre-sized and sliced rather than grown. What is EXTRA here is the corner
    // space: a corner cut splices two ring vertices in place of one, so a fin's
    // ARITY changes, and a kernel that renumbers corners without saying what
    // became of them is exactly what `Mesh.resizePolyVertexMaps`' always-on
    // `debug assert` refuses. MEASURED, not predicted — on a three-fin stand
    // carrying a PolyVertex map, in a `-debug` build, this kernel used to die
    // FORWARD at mesh.d's "corner provenance: a face rewrite reached buildLoops
    // without declaring what became of the corners, and without arming
    // beginCornerRewrite()/beginCornerRelocate() either", through
    // `resizePolyVertexMaps <- buildLoops <- finalizeTopologyEdit <- here`. The
    // single-spine sibling reshapes at EQUAL arity and does NOT fire; its
    // provenance is deliberately left alone.
    //
    // WHAT IS DECLARED, AND WHAT IS DELIBERATELY NOT. The declaration below
    // states what the splice ALREADY performs — nothing more. Sourcing is by
    // VERTEX IDENTITY, `spikeFacesByMask`'s carry shape: each new face names
    // the OLD face in its own slot, so a corner still standing on a vertex that
    // fin already had resolves to that fin's own corner and keeps its value,
    // while a corner standing on a genuinely NEW vertex — a spine rail, a
    // miter, either half of a corner cut — finds no source and comes out at an
    // honest ZERO. The two fan caps name no source face at all (`~0u`), so all
    // their corners are zero, which is the same answer the pre-L7 whole-map
    // drop gave them. The gain is that the drop is now ONE CORNER WIDE instead
    // of the WHOLE MESH.
    //
    // NO GEOMETRIC UV LAW FOR A CHAMFER CORNER IS INVENTED HERE. What a miter
    // or a corner-cut vertex's per-corner value SHOULD be is an unmeasured
    // question and it belongs to tasks 0830 / 0901 (the corner-law census), not
    // to this stage: a `PolyVertexGen` law written from a plausible guess would
    // look like a working feature and be re-litigated forever (task 0697's
    // exact failure). Zero is the honest answer until someone captures one.
    immutable size_t nFacesPre = ed.faces.length;   // faces that EXISTED, and the
                                                    // srcFace of their own corners
    auto rw = ed.beginCornerRewrite();   // opened AFTER the last refusal above:
                                         // Phase A owns every `return 0`, so the
                                         // arming can never outlive a no-op.
    const bool carryUv = rw.active();
    uint[] aCapG; aCapG.reserve(N);
    uint[] bCapG; bCapG.reserve(N);
    auto windIdx = uninitializedArray!(FaceIdx[])(N);
    auto windTo  = uninitializedArray!(uint[][])(N);
    size_t nw = 0;
    foreach (fp, fi; fins) {
        auto pl = plans[fp];
        uint[] gnew; gnew.reserve(pl.np.length);
        foreach (p; pl.np) gnew ~= ed.addVertex(p);
        uint[] nf; nf.reserve(pl.ring.length);
        foreach (r; pl.ring) nf ~= (r >= 0) ? cast(uint)r : gnew[-(r) - 1];
        // COLLECTED here, INSTALLED after the caps. Nothing between this point
        // and that call reads `ed.faces[fi]` for a rewritten fin — verified:
        // the rest of this loop only calls `addVertex` and indexes `gnew`, the
        // cap builders read `aCapG`/`bCapG` (vertex indices, not windings), and
        // `ed.faces.length` is a count. `fins` is ascending (a
        // `foreach (fi; 0 .. faces.length)` scan built it), which is what
        // `setFaceWindings` requires and what it declines SILENTLY without.
        assert(nw == 0 || windIdx[nw - 1].raw < fi,
            "bevelFinBundleSpineMultiEdge: the winding accumulator went "
          ~ "non-ascending — `setFaceWindings` DECLINES SILENTLY on an "
          ~ "unordered list, which would unpair the per-corner payload");
        windIdx[nw] = ed.faceIndexAt(fi);
        windTo[nw]  = nf;
        ++nw;
        aCapG ~= gnew[pl.aCapL];
        bCapG ~= gnew[pl.bCapL];
    }
    // One N-gon fan cap per spine end, both in incident-face order (matching
    // the single-spine sibling's emergent-consistent winding).
    immutable uint capA = cast(uint)ed.faces.length; ed.addFace(aCapG);
    immutable uint capB = cast(uint)ed.faces.length; ed.addFace(bCapG);
    assert(nw == N, "bevelFinBundleSpineMultiEdge: the fin loop and the winding "
                  ~ "accumulator disagree about how many fins were rewritten");
    cast(void) ed.setFaceWindings(windIdx[0 .. nw], windTo[0 .. nw]);
    // The corner declaration, against the space `rw` captured before the
    // rewrite. Built only when there is a per-corner plane to owe anything to —
    // `carriedPerFace` on an inactive handle degrades to `unchanged()` anyway,
    // but the `srcFaceOfNewFace` array should not be allocated for nothing.
    if (carryUv) {
        auto srcFaceOfNewFace = uninitializedArray!(uint[])(ed.faces.length);
        foreach (nfi; 0 .. ed.faces.length)
            srcFaceOfNewFace[nfi] = (nfi < nFacesPre) ? cast(uint)nfi : ~0u;
        PolyVertexBlend[uint] noBlends;   // no corner here is a BLEND of old
                                          // corners: see the note above.
        ed.declareCornerProvenance(
            rw.carriedPerFace(ed.faces.range, srcFaceOfNewFace, noBlends));
    }

    // The original spine verts a, b (and any corner-cut'd outer verts) are
    // now unreferenced; the tail compaction drops them.
    ed.syncSelection();
    ed.clearFaceSelection();
    foreach (fi; fins) ed.selectFace(cast(int)fi);
    ed.selectFace(cast(int)capA);
    ed.selectFace(cast(int)capB);
    ed.resizeVertexSelection();
    ed.clearVertexSelection();
    ed.clearEdgeSelectionResize();
    ed.finalizeTopologyEdit();
    ed.commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
    return 1 + extraEdges.length;
}

// ---------------------------------------------------------------------------
// The gate that outlives the text census (task 1903 Stage C review, MAJOR-1 —
// compile-time, not a unittest). A member of `Mesh` BEATS a same-name UFCS free
// function silently — no ambiguity, no warning — so anything that puts one of
// these names back on the struct (`mixin MeshBevelFinOps;`, `mixin ...!()`, a
// named mixin, or a hand-written method with the old body) rebinds both call
// sites in `bevelEdgesByMask` to it and this module becomes dead code. The
// regex census in tests/unit/commit_seam_census_test.d sees only the literal
// `mixin Mesh*Ops;` spelling; this sees the fact, and at `dub build` time
// rather than only under --config=tests.
//
// It is ALSO the check that the mutating receiver did not quietly widen back:
// a `Mesh.bevelIsolatedFinBundleSpine` member could only exist by taking the
// mesh directly, i.e. by dropping the batch this stage exists to require —
// and on THIS family that batch is the transitional one edge_bevel.d holds,
// so losing it would put the fin path back to one stamp per added rail vertex
// with nothing that could say so.
// ---------------------------------------------------------------------------
static foreach (n; ["bevelIsolatedFinBundleSpine", "bevelFinBundleSpineMultiEdge"])
    static assert(!__traits(hasMember, Mesh, n),
        "`Mesh." ~ n ~ "` is a MEMBER again. A member BEATS a same-name UFCS free "
      ~ "function silently, so `bevelEdgesByMask`'s two fin-bundle early returns "
      ~ "bind back to it, the batch the kernel takes as its receiver goes away "
      ~ "with it, and task 1903 Stage E4 means nothing. Whatever re-added it — "
      ~ "`mixin MeshBevelFinOps;`, `mixin ...!()`, a named mixin, an `alias`, or "
      ~ "a hand-written method — must go.");
