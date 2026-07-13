module remesh.region_stitch;

// ---------------------------------------------------------------------------
// region_stitch — boundary-pinned stitch of a remeshed OPEN patch back into
// its surrounding mesh (task 0385, "Approach 1" / band-bridge boundary
// pinning). Ported faithfully from a validated Python reference
// (`pin_boundary.py::pin_region` + `pin_common.py` helpers) that passes on
// both flat and curved 3D regions, for ANY target-quads density, with zero
// introduced non-manifold edges and a bit-exact pin (original boundary
// vertices are SHARED by index — no merge, no snapping, no tolerance).
//
// WHY THIS EXISTS: the external quad-remesher (autoremesher_cli) resamples
// an open patch's rim to a DIFFERENT vertex count than the original region
// boundary — it does not (and structurally cannot, without invasive
// surgery) reuse the caller's exact boundary vertices. So the patch cannot
// simply be vertex-welded back onto the hole it came from: the counts don't
// match. This module bridges that gap topologically instead of
// geometrically.
//
// ALGORITHM (per region boundary loop Bo; mirrors pin_boundary.py's
// module docstring 1:1 — read that file for the fully worked rationale):
//   1. (caller's job) extract + remesh the region; the patch rim lies ON
//      the Bo curve but is resampled to a different vertex count.
//   2. Identify the patch's OUTER RIM per Bo_i = the patch boundary loop
//      with the smallest MEAN DISTANCE to the Bo_i polyline. Centroid-fan
//      every other patch boundary loop (spurious interior holes the
//      remesher left behind).
//   3. TRIM the outer-rim ring (drop every patch face touching an
//      outer-rim vertex) -> exposes an INSET "second ring" L2, one
//      quad-ring in from Bo. L2 has real width and is NOT on the Bo
//      curve — this is what makes the bridge band non-degenerate. Trimming
//      can re-expose a spurious hole; keep only the nearest-centroid main
//      inner loop per Bo_i and fan the rest.
//   4. GREEDY SHORTEST-DIAGONAL BRIDGE Bo_i <-> L2 (arbitrary vertex
//      counts m, n): try both windings of L2, starting near Bo_i[0]; walk
//      pointers over both loops, at each step taking whichever of the two
//      candidate diagonals is shorter. Every Bo/L2 edge is consumed
//      exactly once -> manifold BY CONSTRUCTION, independent of m, n, or
//      curvature.
//   5. ASSEMBLE by pure index sharing: kept faces (unchanged) + trimmed
//      patch interior (reindexed, appended past the original vertex
//      count) + bridge triangles. Bo vertices are shared between kept
//      faces and the bridge by identical index — the pin is exact.
//
// Multiple region boundary loops (e.g. an annulus-shaped selection) are
// matched to their outer rim / inner loop by nearest centroid, and bridged
// independently, exactly as in the reference.
// ---------------------------------------------------------------------------

import std.algorithm.iteration : map;
import std.array : array;
import std.conv  : to;

import math : Vec3;
import mesh : Mesh;

/// Result of `stitchRegion`. `ok == false` means the patch could not be
/// pinned back robustly (see `failReason`) — the caller (remesh_job) should
/// treat this as a soft-fail: retry with a different remesh mode, or give
/// up without touching the live mesh.
struct StitchResult {
    Vec3[]   vertices;
    uint[][] faces;
    bool     ok;
    string   failReason;
}

/// Stitch a remeshed open `patch` back into the mesh it was cut from.
///
/// Params:
///   origVerts           = the FULL original mesh's vertex array (global
///                          indices — `keepFaces` and `regionBoundaryLoops`
///                          both index into this array).
///   keepFaces            = every face NOT in the selected region, unchanged,
///                          global vertex indices.
///   regionBoundaryLoops  = one entry per boundary loop of the SELECTED
///                          region (Bo_i), each an ORDERED list of ORIGINAL
///                          global vertex indices (oriented consistently
///                          with the region's own face winding — the caller
///                          is expected to derive these via the mesh's own
///                          directed boundary-loop walk, e.g. a temporary
///                          Mesh over just the region's faces).
///   patchVerts/patchFaces = the remesher's output: patch-local vertex
///                          positions and patch-local face index lists.
///
/// Returns a `StitchResult` with the assembled mesh (kept faces first, then
/// reindexed patch-interior faces, then bridge triangles — in that order,
/// so a caller that already knows `keepFaces.length` can slice off exactly
/// the newly-introduced faces without any extra bookkeeping field).
StitchResult stitchRegion(
    const(Vec3)[]   origVerts,
    const(uint[])[] keepFaces,
    const(uint[])[] regionBoundaryLoops,
    const(Vec3)[]   patchVerts,
    const(uint[])[] patchFaces)
{
    StitchResult fail(string reason) {
        StitchResult r;
        r.ok         = false;
        r.failReason = reason;
        return r;
    }

    if (origVerts.length == 0)
        return fail("empty original mesh");
    if (regionBoundaryLoops.length == 0)
        return fail("no region boundary loops supplied");
    foreach (loop; regionBoundaryLoops)
        if (loop.length < 3) return fail("degenerate region boundary loop (<3 verts)");
    if (patchVerts.length == 0 || patchFaces.length == 0)
        return fail("empty patch");

    // Working copies — hole-filling appends vertices/faces in place.
    Vec3[]   pv = patchVerts.dup;
    uint[][] pf = patchFaces.map!(f => f.dup).array;

    // bbox diagonal of the ORIGINAL mesh — the outer-rim identification
    // reject threshold (mirrors pin_boundary.py's `0.02*bbox`).
    Vec3 lo = origVerts[0], hi = origVerts[0];
    foreach (v; origVerts) {
        if (v.x < lo.x) lo.x = v.x; if (v.x > hi.x) hi.x = v.x;
        if (v.y < lo.y) lo.y = v.y; if (v.y > hi.y) hi.y = v.y;
        if (v.z < lo.z) lo.z = v.z; if (v.z > hi.z) hi.z = v.z;
    }
    const float bbox = (hi - lo).length();
    const float outerRimThreshold = 0.02f * (bbox > 1e-9f ? bbox : 1.0f);

    // ---- Step 2: identify the outer rim per region boundary loop --------
    auto patchLoops = patchBoundaryLoops(pv, pf);
    if (patchLoops.length < regionBoundaryLoops.length)
        return fail("patch has fewer boundary loops (" ~ patchLoops.length.to!string
                   ~ ") than the region (" ~ regionBoundaryLoops.length.to!string ~ ")");

    bool[size_t] usedPatchLoop;
    auto outerRims = new uint[][](regionBoundaryLoops.length);
    foreach (ri, Bo; regionBoundaryLoops) {
        auto boCurve = gather(origVerts, Bo);
        float best = float.max;
        size_t bestIdx = size_t.max;
        foreach (k, loop; patchLoops) {
            if (k in usedPatchLoop) continue;
            const float score = meanLoopToCurve(gather(pv, loop), boCurve);
            if (score < best) { best = score; bestIdx = k; }
        }
        if (bestIdx == size_t.max || best > outerRimThreshold)
            return fail("no patch rim found near region boundary loop " ~ ri.to!string
                       ~ " (best mean-distance " ~ best.to!string ~ ", threshold " ~ outerRimThreshold.to!string ~ ")");
        usedPatchLoop[bestIdx] = true;
        outerRims[ri] = patchLoops[bestIdx].dup;
    }

    // Fill every OTHER patch loop (spurious interior holes) — everything
    // that isn't one of the identified outer rims.
    fillInteriorHoles(pv, pf, outerRims);

    // ---- Step 3: trim the outer-rim ring, exposing the inset L2 loop(s) -
    bool[uint] rimSet;
    foreach (loop; outerRims) foreach (v; loop) rimSet[v] = true;

    pf = trimFacesTouching(pf, rimSet);
    if (pf.length == 0)
        return fail("trimming the outer rim removed the entire patch");

    uint[][] innerLoops;
    innerOuter: foreach (loop; patchBoundaryLoops(pv, pf)) {
        foreach (v; loop) if (v in rimSet) continue innerOuter;
        innerLoops ~= loop;
    }

    if (innerLoops.length > regionBoundaryLoops.length) {
        // Trimming re-exposed extra spurious holes — keep the loop nearest
        // each region loop's centroid, fan the rest.
        bool[size_t] usedInner;
        auto mainLoops = new uint[][](regionBoundaryLoops.length);
        foreach (ri, Bo; regionBoundaryLoops) {
            const Vec3 rc = meanOf(gather(origVerts, Bo));
            float best = float.max;
            size_t bestIdx = size_t.max;
            foreach (k, loop; innerLoops) {
                if (k in usedInner) continue;
                const float d = (meanOf(gather(pv, loop)) - rc).length();
                if (d < best) { best = d; bestIdx = k; }
            }
            if (bestIdx == size_t.max)
                return fail("could not match an inner loop to region boundary loop " ~ ri.to!string);
            usedInner[bestIdx] = true;
            mainLoops[ri] = innerLoops[bestIdx].dup;
        }
        fillInteriorHoles(pv, pf, mainLoops);

        innerLoops = [];
        mainOuter: foreach (loop; patchBoundaryLoops(pv, pf)) {
            foreach (m; mainLoops)
                if (sameVertexSet(loop, m)) { innerLoops ~= loop; continue mainOuter; }
        }
    }

    if (innerLoops.length != regionBoundaryLoops.length || pf.length == 0)
        return fail("inner-loop count mismatch after trim/fill (" ~ innerLoops.length.to!string
                   ~ " vs " ~ regionBoundaryLoops.length.to!string ~ ")");

    // ---- Step 5 (part 1): assemble kept + reindexed patch-interior faces -
    Vec3[]   outVerts = origVerts.dup;
    uint[][] outFaces = keepFaces.map!(f => f.dup).array;

    bool[uint] usedPatchVert;
    foreach (f; pf) foreach (v; f) usedPatchVert[v] = true;
    uint[] usedList = usedPatchVert.keys.dup;
    // Deterministic ordering (not load-bearing for correctness, but keeps
    // output reproducible across runs / helps test diffs).
    import std.algorithm.sorting : sort;
    sort(usedList);

    uint[uint] p2g;
    const uint baseIdx = cast(uint) outVerts.length;
    foreach (i, pvi; usedList) {
        p2g[pvi] = baseIdx + cast(uint) i;
        outVerts ~= pv[pvi];
    }
    foreach (f; pf) {
        uint[] gf = new uint[](f.length);
        foreach (i, v; f) gf[i] = p2g[v];
        outFaces ~= gf;
    }

    // ---- Step 4 + Step 5 (part 2): bridge each Bo_i <-> its inner loop ---
    bool[size_t] usedInnerForBridge;
    foreach (ri, Bo; regionBoundaryLoops) {
        const Vec3 rc = meanOf(gather(origVerts, Bo));
        float best = float.max;
        size_t bestIdx = size_t.max;
        foreach (k, loop; innerLoops) {
            if (k in usedInnerForBridge) continue;
            const float d = (meanOf(gather(pv, loop)) - rc).length();
            if (d < best) { best = d; bestIdx = k; }
        }
        if (bestIdx == size_t.max)
            return fail("could not pair region boundary loop " ~ ri.to!string ~ " with an inner loop for bridging");
        usedInnerForBridge[bestIdx] = true;
        auto L2 = innerLoops[bestIdx];

        auto boPts = gather(origVerts, Bo);
        auto l2Pts = gather(pv, L2);
        foreach (t; bridgeLoops(boPts, l2Pts)) {
            if (t.isA)
                outFaces ~= [Bo[t.a0], Bo[t.a1], p2g[L2[t.b0]]];
            else
                outFaces ~= [Bo[t.a0], p2g[L2[t.b0]], p2g[L2[t.b1]]];
        }
    }

    // The remesher's patch (and hence the bridge built off its L2 loop) can be
    // wound OPPOSITE to the surrounding mesh, which shows up as flipped normals
    // along the seam (topologically manifold, but visually inverted under
    // subdiv/lighting). Propagate a consistent winding outward from the
    // untouched keep-faces — the authoritative anchor — to the patch + bridge.
    orientConsistently(outFaces, keepFaces.length);

    StitchResult res;
    res.ok       = true;
    res.vertices = outVerts;
    res.faces    = outFaces;
    return res;
}

/// Propagate a consistent face winding outward from the first `anchorCount`
/// faces (the untouched, already-consistent keep-faces) to every other face,
/// so the stitched patch + bridge match the surrounding mesh. BFS over edge
/// adjacency: since the assembled mesh is manifold (each interior edge has
/// exactly two faces), a neighbour is correctly oriented iff it traverses the
/// shared edge OPPOSITE to an already-oriented face; if it traverses it the
/// same way, reverse it. No-op for faces already consistent (e.g. a whole-mesh
/// result has anchorCount == faces.length).
private void orientConsistently(ref uint[][] faces, size_t anchorCount) {
    import std.algorithm.mutation : reverse;
    if (faces.length == 0) return;

    static ulong ekey(uint a, uint b) {
        return a < b ? (cast(ulong) a << 32) | b : (cast(ulong) b << 32) | a;
    }
    size_t[][ulong] edgeFaces;
    foreach (fi, f; faces) {
        const size_t n = f.length;
        foreach (k; 0 .. n)
            edgeFaces[ekey(f[k], f[cast(size_t)((k + 1) % n)])] ~= fi;
    }

    bool traversesDir(size_t fi, uint a, uint b) {
        auto f = faces[fi];
        const size_t n = f.length;
        foreach (k; 0 .. n)
            if (f[k] == a && f[cast(size_t)((k + 1) % n)] == b) return true;
        return false;
    }

    auto oriented = new bool[](faces.length);
    uint[] queue;
    const size_t anchors = anchorCount <= faces.length ? anchorCount : faces.length;
    foreach (i; 0 .. anchors) { oriented[i] = true; queue ~= cast(uint) i; }
    if (queue.length == 0) { oriented[0] = true; queue ~= 0; } // no anchor -> seed face 0

    size_t head = 0;
    while (head < queue.length) {
        const size_t fi = queue[head++];
        auto f = faces[fi];
        const size_t n = f.length;
        foreach (k; 0 .. n) {
            const uint a = f[k], b = f[cast(size_t)((k + 1) % n)];
            foreach (nf; edgeFaces[ekey(a, b)]) {
                if (nf == fi || oriented[nf]) continue;
                // `fi` traverses a->b; a consistent neighbour traverses b->a.
                // If it also traverses a->b, it's wound the same way -> flip.
                if (traversesDir(nf, a, b)) reverse(faces[nf]);
                oriented[nf] = true;
                queue ~= cast(uint) nf;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Private helpers — mirror pin_common.py's reusable building blocks.
// ---------------------------------------------------------------------------

/// Ordered, directed boundary vertex loops of a standalone (verts, faces)
/// patch. Built by wrapping the data in a throwaway `Mesh` and reusing its
/// already-validated `boundaryLoops()` (directed half-edge walk, oriented
/// per the input's own face winding) rather than reimplementing loop-chasing
/// here. `verts`/`faces` need not be compacted — a face may reference any
/// index within `verts.length`.
private uint[][] patchBoundaryLoops(const(Vec3)[] verts, const(uint[])[] faces) {
    Mesh m = Mesh.init;
    m.vertices = verts.dup;
    uint[ulong] lookup;
    foreach (f; faces) {
        if (f.length < 3) continue;
        m.addFaceFast(lookup, f.dup);
    }
    m.buildLoops();
    return m.boundaryLoops();
}

/// Centroid-fan every boundary loop of (verts, faces) that is NOT (by exact
/// vertex-index set) one of `keepLoops`. Mutates `verts`/`faces` in place —
/// each filled hole appends one centroid vertex + one fan triangle per edge.
private void fillInteriorHoles(ref Vec3[] verts, ref uint[][] faces, const(uint[])[] keepLoops) {
    auto loops = patchBoundaryLoops(verts, faces);
    loopIter: foreach (loop; loops) {
        foreach (k; keepLoops)
            if (sameVertexSet(loop, k)) continue loopIter;

        const Vec3 c  = meanOf(gather(verts, loop));
        const uint ci = cast(uint) verts.length;
        verts ~= c;
        const size_t L = loop.length;
        foreach (i; 0 .. L)
            faces ~= [loop[i], loop[(i + 1) % L], ci];
    }
}

/// Drop every face that touches any vertex in `rimSet` — exposes the inset
/// "second ring" one quad-ring in from a just-identified outer rim.
private uint[][] trimFacesTouching(const(uint[])[] faces, const(bool[uint]) rimSet) {
    uint[][] kept;
    faceLoop: foreach (f; faces) {
        foreach (v; f) if (v in rimSet) continue faceLoop;
        kept ~= f.dup;
    }
    return kept;
}

/// True iff `a` and `b` contain exactly the same vertex indices (order- and
/// duplicate-count-insensitive — a loop-identity check, not an ordered
/// comparison).
private bool sameVertexSet(const(uint)[] a, const(uint)[] b) {
    if (a.length != b.length) return false;
    bool[uint] s;
    foreach (x; a) s[x] = true;
    foreach (x; b) if (x !in s) return false;
    return true;
}

private Vec3[] gather(const(Vec3)[] verts, const(uint)[] idx) {
    auto r = new Vec3[](idx.length);
    foreach (i, v; idx) r[i] = verts[v];
    return r;
}

private Vec3 meanOf(const(Vec3)[] pts) {
    if (pts.length == 0) return Vec3(0, 0, 0);
    Vec3 s = Vec3(0, 0, 0);
    foreach (p; pts) s = s + p;
    return s * (1.0f / pts.length);
}

/// Closest distance from point `p` to the segment [a,b].
private float pointSegDist(Vec3 p, Vec3 a, Vec3 b) {
    import math : dot;
    const Vec3 ab = b - a;
    const float denom = dot(ab, ab);
    float t = denom > 1e-30f ? dot(p - a, ab) / denom : 0.0f;
    if (t < 0.0f) t = 0.0f;
    if (t > 1.0f) t = 1.0f;
    const Vec3 closest = a + ab * t;
    return (p - closest).length();
}

/// Mean distance from every point in `loopPts` to the nearest segment of the
/// CLOSED polyline `curvePts` — the "is this patch loop on the Bo curve?"
/// metric (outer rims sit ON the curve; spurious interior holes are far).
private float meanLoopToCurve(const(Vec3)[] loopPts, const(Vec3)[] curvePts) {
    if (loopPts.length == 0 || curvePts.length < 2) return float.max;
    float tot = 0.0f;
    const size_t m = curvePts.length;
    foreach (p; loopPts) {
        float best = float.max;
        foreach (i; 0 .. m) {
            const float d = pointSegDist(p, curvePts[i], curvePts[(i + 1) % m]);
            if (d < best) best = d;
        }
        tot += best;
    }
    return tot / loopPts.length;
}

private size_t nearestIndex(const(Vec3)[] pts, Vec3 p) {
    size_t best = 0;
    float bestD = float.max;
    foreach (i, q; pts) {
        const float d = (q - p).length();
        if (d < bestD) { bestD = d; best = i; }
    }
    return best;
}

/// One directed-walk candidate's triangle stream (step 4, before winding /
/// start-offset are locked in). `isA` selects which of the two triangle
/// shapes: true -> (A[ai],A[an],B[bj]); false -> (A[ai],B[bj],B[bn]).
private struct DirTri { bool isA; size_t ai, an, bj, bn; }
private struct DirResult { DirTri[] tris; float total; }

/// Greedy shortest-diagonal walk consuming every A-edge (0..m) and every
/// B-edge (0..n, starting at `j0`) exactly once.
private DirResult bridgeDir(const(Vec3)[] A, const(Vec3)[] B, size_t j0) {
    const size_t m = A.length, n = B.length;
    DirTri[] tris;
    float tot = 0.0f;
    size_t i = 0, j = 0;
    while (i < m || j < n) {
        const size_t ai = i % m, bj = (j0 + j) % n, an = (i + 1) % m, bn = (j0 + j + 1) % n;
        bool advA;
        if (j >= n) advA = true;
        else if (i >= m) advA = false;
        else advA = (A[an] - B[bj]).length() <= (B[bn] - A[ai]).length();

        if (advA) { tris ~= DirTri(true,  ai, an, bj, bn); tot += (A[an] - B[bj]).length(); ++i; }
        else      { tris ~= DirTri(false, ai, an, bj, bn); tot += (B[bn] - A[ai]).length(); ++j; }
    }
    return DirResult(tris, tot);
}

/// Final (post winding/start-offset resolution) bridge triangle, expressed
/// purely as indices into the caller's original A (Bo) / B (L2) loops —
/// `isA` selects (A[a0],A[a1],B[b0]) vs (A[a0],B[b0],B[b1]).
struct BridgeTri { bool isA; size_t a0, a1, b0, b1; }

/// Bridge two closed loops (arbitrary, independent vertex counts) into a
/// manifold triangle band. Tries both windings of `B` and, for each, the
/// three start offsets nearest `A[0]`; keeps whichever run has the smallest
/// total diagonal length (the untwisted solution) — this is what makes the
/// bridge robust to `B`'s unknown orientation without ever needing to know
/// it up front.
private BridgeTri[] bridgeLoops(const(Vec3)[] Apts, const(Vec3)[] Bpts) {
    const size_t n = Bpts.length;
    float bestTot = float.max;
    DirTri[] bestTris;
    bool bestFlip;

    foreach (flipI; 0 .. 2) {
        const bool doFlip = flipI == 1;
        Vec3[] Bp;
        if (doFlip) {
            Bp = new Vec3[](n);
            foreach (k; 0 .. n) Bp[k] = Bpts[n - 1 - k];
        } else {
            Bp = Bpts.dup;
        }

        const size_t j0s = nearestIndex(Bp, Apts.length ? Apts[0] : Vec3(0, 0, 0));
        const size_t[3] cands = [j0s, (j0s + 1) % n, (j0s + n - 1) % n];
        bool[size_t] tried;
        foreach (j0; cands) {
            if (j0 in tried) continue;
            tried[j0] = true;
            auto res = bridgeDir(Apts, Bp, j0);
            if (res.total < bestTot) {
                bestTot  = res.total;
                bestTris = res.tris;
                bestFlip = doFlip;
            }
        }
    }

    size_t mapB(size_t k) { return bestFlip ? (n - 1 - k) % n : k; }

    auto outTris = new BridgeTri[](bestTris.length);
    foreach (i, t; bestTris) {
        outTris[i] = t.isA
            ? BridgeTri(true,  t.ai, t.an, mapB(t.bj), 0)
            : BridgeTri(false, t.ai, 0,    mapB(t.bj), mapB(t.bn));
    }
    return outTris;
}

// ---------------------------------------------------------------------------
// Unit tests — the crux of this module. Build flat quad-grid meshes in D
// (no external remesher needed), select a region, synthesize a plausible
// finer "remeshed" patch over the SAME physical footprint (mirroring how a
// real remesher resamples a rim to a different vertex count), stitch, and
// assert the reference algorithm's own validation metrics: introduced
// non-manifold == 0, the seam is fully closed (stitched boundary-edge set
// == original mesh's), and every region-boundary vertex is shared (not
// duplicated) between a kept face and a newly-added face.
// ---------------------------------------------------------------------------

version (unittest) {
    private struct GridMesh { Vec3[] verts; uint[][] faces; }

    /// Row-major nx*ny quad grid over [x0,x0+nx*cell] x [y0,y0+ny*cell] at
    /// z=0, CCW winding (agrees with +Z). Vertex (i,j) -> j*(nx+1)+i; face
    /// (i,j) -> index j*nx+i.
    private GridMesh genGrid(int nx, int ny, float cell, float x0 = 0, float y0 = 0) {
        GridMesh g;
        g.verts = new Vec3[]((nx + 1) * (ny + 1));
        foreach (j; 0 .. ny + 1)
            foreach (i; 0 .. nx + 1)
                g.verts[j * (nx + 1) + i] = Vec3(x0 + i * cell, y0 + j * cell, 0);
        foreach (j; 0 .. ny)
            foreach (i; 0 .. nx) {
                uint v00 = cast(uint)(j * (nx + 1) + i);
                uint v10 = cast(uint)(j * (nx + 1) + i + 1);
                uint v11 = cast(uint)((j + 1) * (nx + 1) + i + 1);
                uint v01 = cast(uint)((j + 1) * (nx + 1) + i);
                g.faces ~= [v00, v10, v11, v01];
            }
        return g;
    }

    /// Same grid, but every face inside the CENTERED holeN x holeN sub-block
    /// is omitted — a one-ring-wide frame/annulus when holeN > 0.
    private GridMesh genGridWithHole(int outerN, int holeN, float cell, float x0 = 0, float y0 = 0) {
        GridMesh g;
        g.verts = new Vec3[]((outerN + 1) * (outerN + 1));
        foreach (j; 0 .. outerN + 1)
            foreach (i; 0 .. outerN + 1)
                g.verts[j * (outerN + 1) + i] = Vec3(x0 + i * cell, y0 + j * cell, 0);
        const int off = (outerN - holeN) / 2;
        foreach (j; 0 .. outerN)
            foreach (i; 0 .. outerN) {
                if (holeN > 0 && i >= off && i < off + holeN && j >= off && j < off + holeN) continue;
                uint v00 = cast(uint)(j * (outerN + 1) + i);
                uint v10 = cast(uint)(j * (outerN + 1) + i + 1);
                uint v11 = cast(uint)((j + 1) * (outerN + 1) + i + 1);
                uint v01 = cast(uint)((j + 1) * (outerN + 1) + i);
                g.faces ~= [v00, v10, v11, v01];
            }
        return g;
    }

    /// Undirected edge -> use-count, element-arity agnostic.
    private int[ulong] edgeUseCounts(const(uint[])[] faces) {
        int[ulong] ec;
        foreach (f; faces) {
            const size_t n = f.length;
            foreach (k; 0 .. n) {
                uint a = f[k], b = f[(k + 1) % n];
                ulong key = a < b ? (cast(ulong) a << 32) | b : (cast(ulong) b << 32) | a;
                if (auto p = key in ec) ++(*p); else ec[key] = 1;
            }
        }
        return ec;
    }

    private size_t countNonManifold(const(uint[])[] faces) {
        size_t n = 0;
        foreach (c; edgeUseCounts(faces).byValue) if (c > 2) ++n;
        return n;
    }

    private bool[ulong] boundaryEdgeSet(const(uint[])[] faces) {
        bool[ulong] s;
        foreach (key, c; edgeUseCounts(faces)) if (c == 1) s[key] = true;
        return s;
    }

    /// Count interior edges whose two faces traverse them in the SAME direction
    /// (flipped-normal seam). 0 == the whole mesh is consistently wound.
    private size_t countOrientationDefects(const(uint[])[] faces) {
        int[ulong] dir; // directed-edge counts, key = (a<<32)|b in traversal order
        foreach (f; faces) {
            const size_t n = f.length;
            foreach (k; 0 .. n) {
                uint a = f[k], b = f[cast(size_t)((k + 1) % n)];
                ulong key = (cast(ulong) a << 32) | b;
                if (auto p = key in dir) ++(*p); else dir[key] = 1;
            }
        }
        size_t d = 0;
        foreach (key, c; dir) if (c >= 2) ++d; // same directed edge from 2+ faces
        return d;
    }
}

unittest {
    // Single central 2x2-quad region cut out of a 6x6 grid, remeshed at a
    // finer resolution over the SAME physical footprint (a stand-in for a
    // real remesher's rim-resampled output). Validates: stitch succeeds,
    // zero introduced non-manifold edges, the outer mesh boundary is
    // untouched (seam over the hole fully closed), and every region-
    // boundary vertex is shared between a kept face and a new face.
    auto big = genGrid(6, 6, 1.0f);

    uint[][] keepFaces;
    uint[][] regionFaces;
    foreach (j; 0 .. 6) foreach (i; 0 .. 6) {
        auto f = big.faces[j * 6 + i];
        if (i >= 2 && i < 4 && j >= 2 && j < 4) regionFaces ~= f;
        else                                    keepFaces   ~= f;
    }
    assert(regionFaces.length == 4);
    assert(keepFaces.length == 32);

    auto regionLoops = patchBoundaryLoops(big.verts, regionFaces);
    assert(regionLoops.length == 1, "solid 2x2 block: expected 1 boundary loop");
    assert(regionLoops[0].length == 8, "2x2 block perimeter: expected 8 vertices");

    auto patch = genGrid(4, 4, 0.5f, 2.0f, 2.0f); // same [2,4]x[2,4] footprint, finer

    auto res = stitchRegion(big.verts, keepFaces, regionLoops, patch.verts, patch.faces);
    assert(res.ok, "stitch should succeed: " ~ res.failReason);
    assert(countNonManifold(res.faces) == 0, "introduced non-manifold edges must be 0");
    assert(countOrientationDefects(res.faces) == 0, "seam must be consistently wound (no flipped normals)");

    auto origFull = keepFaces ~ regionFaces;
    assert(boundaryEdgeSet(res.faces) == boundaryEdgeSet(origFull),
           "stitched mesh's boundary-edge set must equal the original mesh's");

    auto newFaces = res.faces[keepFaces.length .. $];
    foreach (v; regionLoops[0]) {
        bool inKept = false, inNew = false;
        foreach (f; keepFaces) foreach (fv; f) if (fv == v) { inKept = true; break; }
        foreach (f; newFaces)  foreach (fv; f) if (fv == v) { inNew  = true; break; }
        assert(inKept, "Bo vertex must still appear in a kept face");
        assert(inNew,  "Bo vertex must appear in a bridge/patch face (shared, not duplicated)");
    }
}

unittest {
    // Annulus region (2 boundary loops): a one-quad-wide frame cut out of a
    // 6x6 grid, with BOTH an outer boundary (against the background) and an
    // inner boundary (against a kept "island" filling the frame's hole).
    // Exercises the multi-loop match-by-centroid path end to end.
    auto big = genGrid(6, 6, 1.0f);

    uint[][] keepFaces;
    uint[][] regionFaces;
    foreach (j; 0 .. 6) foreach (i; 0 .. 6) {
        auto f = big.faces[j * 6 + i];
        const bool inOuterBlock = i >= 1 && i < 5 && j >= 1 && j < 5;
        const bool inHole       = i >= 2 && i < 4 && j >= 2 && j < 4;
        if (inOuterBlock && !inHole) regionFaces ~= f;
        else                         keepFaces   ~= f;
    }
    assert(regionFaces.length == 12, "4x4 block minus 2x2 hole -> 12 frame faces");
    assert(keepFaces.length == 24);

    auto regionLoops = patchBoundaryLoops(big.verts, regionFaces);
    assert(regionLoops.length == 2, "frame region: expected 2 boundary loops");

    const size_t outerLi = regionLoops[0].length >= regionLoops[1].length ? 0 : 1;
    const size_t innerLi = 1 - outerLi;
    assert(regionLoops[outerLi].length == 16, "outer (4x4 block) perimeter: 16 vertices");
    assert(regionLoops[innerLi].length == 8,  "inner (2x2 hole) perimeter: 8 vertices");

    // Finer frame patch over the SAME footprint: outer [1,5]x[1,5], hole [2,4]x[2,4].
    // Frame must be several cells wide so trimming BOTH the outer and inner
    // rim leaves a genuine residual annulus (too-thin a frame trims away
    // entirely -- both rims' 1-cell touch bands would overlap).
    auto patch = genGridWithHole(16, 8, 0.25f, 1.0f, 1.0f);

    auto res = stitchRegion(big.verts, keepFaces, regionLoops, patch.verts, patch.faces);
    assert(res.ok, "annulus stitch should succeed: " ~ res.failReason);
    assert(countNonManifold(res.faces) == 0, "introduced non-manifold edges must be 0");
    assert(countOrientationDefects(res.faces) == 0, "annulus seam must be consistently wound");

    auto origFull = keepFaces ~ regionFaces;
    assert(boundaryEdgeSet(res.faces) == boundaryEdgeSet(origFull),
           "stitched mesh's boundary-edge set must equal the original mesh's (2-loop case)");

    auto newFaces = res.faces[keepFaces.length .. $];
    foreach (loop; regionLoops) {
        foreach (v; loop) {
            bool inKept = false, inNew = false;
            foreach (f; keepFaces) foreach (fv; f) if (fv == v) { inKept = true; break; }
            foreach (f; newFaces)  foreach (fv; f) if (fv == v) { inNew  = true; break; }
            assert(inKept, "Bo vertex must still appear in a kept face (annulus)");
            assert(inNew,  "Bo vertex must appear in a bridge/patch face (annulus)");
        }
    }
}

unittest {
    // Failure path: a patch with only 1 boundary loop cannot satisfy a
    // 2-loop (annulus) region -- must soft-fail cleanly, not crash.
    auto big = genGrid(6, 6, 1.0f);

    uint[][] keepFaces;
    uint[][] regionFaces;
    foreach (j; 0 .. 6) foreach (i; 0 .. 6) {
        auto f = big.faces[j * 6 + i];
        const bool inOuterBlock = i >= 1 && i < 5 && j >= 1 && j < 5;
        const bool inHole       = i >= 2 && i < 4 && j >= 2 && j < 4;
        if (inOuterBlock && !inHole) regionFaces ~= f;
        else                         keepFaces   ~= f;
    }
    auto regionLoops = patchBoundaryLoops(big.verts, regionFaces);
    assert(regionLoops.length == 2);

    auto bogusPatch = genGrid(8, 8, 0.5f, 1.0f, 1.0f); // plain grid: 1 loop, no hole

    auto res = stitchRegion(big.verts, keepFaces, regionLoops, bogusPatch.verts, bogusPatch.faces);
    assert(!res.ok, "a single-loop patch must not satisfy a 2-loop region");
    assert(res.failReason.length > 0);
}
