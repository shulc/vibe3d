module uv_relax;

/// Pure Jacobi uniform-Laplacian UV relax kernel.
///
/// Welds per-corner UV values into UV vertices (union-find over interior twin
/// pairs that agree in UV within epsUV), then runs N Jacobi passes: interior
/// UV vertices move toward the mean of their UV neighbours by `strength` per
/// pass; boundary / seam UV vertices are pinned.  An optional `cornerPinned`
/// mask adds caller-supplied pins (used by the command for selected-faces scope
/// restriction).
///
/// No mesh-level side-effects — the owning command calls
/// `commitChange(MeshEditScope.Material)`.
///
/// Mirrors the Jacobi-from-snapshot approach of mesh.smooth (smooth.d:261-283)
/// and smoothSubdivide (mesh.d:10120-10134), lifted into UV space.  The exact
/// smoothing law is a vibe3d-divergence; capture-gated parity deferred.

import mesh    : Mesh, MeshMap;
import std.math : fabs;

private enum float epsUV = 1e-6f;

private bool uvEq(const float[] data, size_t i, size_t j) {
    return fabs(data[i * 2]     - data[j * 2])     < epsUV
        && fabs(data[i * 2 + 1] - data[j * 2 + 1]) < epsUV;
}

// ---------------------------------------------------------------------------
// Union-find with two-hop path compression + union-by-size.
// ---------------------------------------------------------------------------

private struct UnionFind {
    uint[] parent;
    uint[] sz;

    void init(uint n) {
        parent = new uint[](n);
        sz     = new uint[](n);
        foreach (i; 0 .. n) { parent[i] = i; sz[i] = 1; }
    }

    uint find(uint x) {
        while (parent[x] != x) {
            parent[x] = parent[parent[x]];
            x = parent[x];
        }
        return x;
    }

    void unite(uint a, uint b) {
        a = find(a); b = find(b);
        if (a == b) return;
        if (sz[a] < sz[b]) { auto t = a; a = b; b = t; }
        parent[b] = a;
        sz[a] += sz[b];
    }
}

// ---------------------------------------------------------------------------
// Public kernel.
// ---------------------------------------------------------------------------

/// Apply `iterations` Jacobi uniform-Laplacian passes over the per-corner UV
/// map `uv`.
///
/// Interior UV vertices (welded-corner clusters whose incident edges are all
/// interior and UV-continuous) move toward the mean of their UV neighbours by
/// `strength` per pass.  Boundary / seam UV vertices are pinned.
/// `cornerPinned[L]` force-pins the UV vertex at loop L regardless of topology
/// (used by UvRelax for selected-faces scope: unselected-face corners are
/// pinned so only the selected region's interior relaxes).
///
/// Returns `true` if any UV vertex moved; `false` for a true no-op (all verts
/// pinned, `iterations < 1`, or `strength == 0`).  The caller records undo
/// only on `true`.
bool uvRelax(const ref Mesh m, MeshMap* uv,
             int iterations, float strength,
             const bool[] cornerPinned = null)
{
    if (iterations < 1 || strength == 0.0f) return false;

    const size_t nL = m.loops.length;
    if (nL == 0) return false;

    float[] data = uv.data;   // alias — mutations write through to the map

    // -----------------------------------------------------------------------
    // 1.  Build UV-vertex weld via union-find.
    //
    // For each interior half-edge L (twin T = L.twin != ~0u):
    //   a-side: if uv[L]      ≈ uv[next(T)] → unite(L, next(T))
    //   b-side: if uv[next(L)] ≈ uv[T]       → unite(next(L), T)
    //
    // Iterating over all loops visits each twin pair twice (once as (L,T) and
    // once as (T,L)); unite() is idempotent so the duplicates are harmless.
    // -----------------------------------------------------------------------
    UnionFind uf;
    uf.init(cast(uint)nL);

    foreach (L; 0 .. nL) {
        const uint T = m.loops[L].twin;
        if (T == uint.max) continue;
        const uint nL_ = m.loops[L].next;
        const uint nT  = m.loops[T].next;
        if (uvEq(data, L, nT))  uf.unite(cast(uint)L, nT);
        if (uvEq(data, nL_, T)) uf.unite(nL_, T);
    }

    // -----------------------------------------------------------------------
    // 2.  Compact class IDs: map each root loop to a contiguous id in
    //     [0, nClasses).
    // -----------------------------------------------------------------------
    uint[] rep     = new uint[](nL);
    uint[] classId = new uint[](nL);
    classId[] = uint.max;
    uint nClasses = 0;

    foreach (L; 0 .. nL) rep[L] = uf.find(cast(uint)L);
    foreach (L; 0 .. nL)
        if (classId[rep[L]] == uint.max) classId[rep[L]] = nClasses++;

    // -----------------------------------------------------------------------
    // 3.  Pin classification.
    //
    // A UV class is pinned if ANY member loop's outgoing edge is:
    //   (a) a mesh boundary (L.twin == ~0u), or
    //   (b) a UV seam (twin exists but UV disagrees on the a or b side), or
    //   (c) force-pinned via cornerPinned[].
    //
    // Iterating over all loops and pinning both endpoints of each bad edge
    // (class(L) and class(next(L)) for boundary; class(L)+class(next(T)) for
    // an a-side seam; class(next(L))+class(T) for a b-side seam) covers every
    // endpoint of every pin edge, possibly redundantly.
    // -----------------------------------------------------------------------
    bool[] pinned = new bool[](nClasses);

    foreach (L; 0 .. nL) {
        if (cornerPinned.length > L && cornerPinned[L])
            pinned[classId[rep[L]]] = true;

        const uint T = m.loops[L].twin;
        if (T == uint.max) {
            // Mesh-boundary edge L→next(L): pin both endpoint classes.
            pinned[classId[rep[L]]]              = true;
            pinned[classId[rep[m.loops[L].next]]] = true;
        } else {
            const uint nL_ = m.loops[L].next;
            const uint nT  = m.loops[T].next;
            if (!uvEq(data, L, nT)) {
                // a-side UV seam.
                pinned[classId[rep[L]]]  = true;
                pinned[classId[rep[nT]]] = true;
            }
            if (!uvEq(data, nL_, T)) {
                // b-side UV seam.
                pinned[classId[rep[nL_]]] = true;
                pinned[classId[rep[T]]]   = true;
            }
        }
    }

    // -----------------------------------------------------------------------
    // 4.  Class UV positions (UV of any member — equal by the weld criterion)
    //     and dedup-undirected UV-edge adjacency.
    //
    // For each loop L the pair {class(L), class(next(L))} is a UV edge.
    // A bool AA keyed on (min,max) deduplicates directed/duplicate occurrences
    // so each shared edge is counted exactly once (true uniform Laplacian).
    // -----------------------------------------------------------------------
    float[] upos = new float[](nClasses * 2);
    foreach (L; 0 .. nL) {
        const uint c = classId[rep[L]];
        upos[c * 2]     = data[L * 2];
        upos[c * 2 + 1] = data[L * 2 + 1];
    }

    uint[][] neighbors = new uint[][](nClasses);
    bool[ulong] edgeSeen;

    foreach (L; 0 .. nL) {
        const uint cA = classId[rep[L]];
        const uint cB = classId[rep[m.loops[L].next]];
        if (cA == cB) continue;
        const uint lo  = cA < cB ? cA : cB;
        const uint hi  = cA < cB ? cB : cA;
        const ulong key = (cast(ulong)lo << 32) | hi;
        if (key in edgeSeen) continue;
        edgeSeen[key] = true;
        neighbors[cA] ~= cB;
        neighbors[cB] ~= cA;
    }

    // Early-out when nothing can relax.
    {
        bool any = false;
        foreach (c; 0 .. nClasses)
            if (!pinned[c] && neighbors[c].length > 0) { any = true; break; }
        if (!any) return false;
    }

    // -----------------------------------------------------------------------
    // 5.  Jacobi passes — read from `prev`, write to `cur`, swap each pass.
    //     After N passes `prev` holds the final state (last swap).
    // -----------------------------------------------------------------------
    float[] prev = upos.dup;
    float[] cur  = upos.dup;

    foreach (_; 0 .. iterations) {
        foreach (c; 0 .. nClasses) {
            if (pinned[c]) continue;
            auto nbrs = neighbors[c];
            if (nbrs.length == 0) continue;
            float su = 0.0f, sv = 0.0f;
            foreach (nb; nbrs) {
                su += prev[nb * 2];
                sv += prev[nb * 2 + 1];
            }
            const float invN = 1.0f / cast(float)nbrs.length;
            cur[c * 2]     = prev[c * 2]     + strength * (su * invN - prev[c * 2]);
            cur[c * 2 + 1] = prev[c * 2 + 1] + strength * (sv * invN - prev[c * 2 + 1]);
        }
        // Swap buffers — no alloc per pass.
        auto tmp = prev; prev = cur; cur = tmp;
    }

    // -----------------------------------------------------------------------
    // 6.  Scatter back: write final UV to every member loop of each NON-PINNED
    //     class only.  Pinned class bytes in uv.data are never written, so
    //     they are provably byte-unchanged on any input.
    // -----------------------------------------------------------------------
    bool anyMoved = false;
    foreach (L; 0 .. nL) {
        const uint c = classId[rep[L]];
        if (pinned[c]) continue;
        const float uFinal = prev[c * 2];
        const float vFinal = prev[c * 2 + 1];
        if (data[L * 2] != uFinal || data[L * 2 + 1] != vFinal) {
            data[L * 2]     = uFinal;
            data[L * 2 + 1] = vFinal;
            anyMoved = true;
        }
    }
    return anyMoved;
}

// ---------------------------------------------------------------------------
// Module-level unit tests — run by `dub test --config=modeling`.
// ---------------------------------------------------------------------------

unittest {
    // Degenerate: iter=0 or strn=0 → returns false, data untouched.
    import mesh : Mesh, MeshMap, MapDomain, kUvMapName;
    import math : Vec3;

    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0),
        Vec3(0,1,0), Vec3(1,1,0), Vec3(2,1,0),
        Vec3(0,2,0), Vec3(1,2,0), Vec3(2,2,0),
    ];
    m.addFace([0u,1u,4u,3u]);
    m.addFace([1u,2u,5u,4u]);
    m.addFace([3u,4u,7u,6u]);
    m.addFace([4u,5u,8u,7u]);
    m.buildLoops();

    auto uvMap = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uvMap !is null);
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        uvMap.data[L * 2]     = m.vertices[vi].x;
        uvMap.data[L * 2 + 1] = m.vertices[vi].y;
    }

    const float[] saved = uvMap.data.dup;
    assert(!uvRelax(m, uvMap, 0, 1.0f), "iter=0: must return false");
    assert(uvMap.data == saved,          "iter=0: data must be untouched");
    assert(!uvRelax(m, uvMap, 5, 0.0f), "strn=0: must return false");
    assert(uvMap.data == saved,          "strn=0: data must be untouched");
}

unittest {
    // Interior centroid: 3×3 quad grid, center vertex v4 perturbed to (1.3,
    // 1.3).  iter=1, strn=1 → center UV converges to (1,1) (the arithmetic
    // mean of neighbours v1,v3,v5,v7 at UVs (1,0),(0,1),(2,1),(1,2));
    // 12 border loops are byte-unchanged (pinned → never written).
    import mesh          : Mesh, MeshMap, MapDomain, kUvMapName;
    import math          : Vec3;
    import std.math      : fabs;
    import std.format    : format;
    import std.algorithm : canFind;

    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0),
        Vec3(0,1,0), Vec3(1,1,0), Vec3(2,1,0),
        Vec3(0,2,0), Vec3(1,2,0), Vec3(2,2,0),
    ];
    m.addFace([0u,1u,4u,3u]);
    m.addFace([1u,2u,5u,4u]);
    m.addFace([3u,4u,7u,6u]);
    m.addFace([4u,5u,8u,7u]);
    m.buildLoops();

    auto uvMap = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uvMap !is null);
    assert(uvMap.data.length == 32, "3×3 grid: 16 loops × 2 = 32 UV floats");
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        uvMap.data[L * 2]     = m.vertices[vi].x;
        uvMap.data[L * 2 + 1] = m.vertices[vi].y;
    }

    // Center-vertex loops: v4 appears at corner 2 of face 0, corner 3 of
    // face 1, corner 1 of face 2, corner 0 of face 3.
    const size_t cL0 = m.faceCornerLoop(0, 2);
    const size_t cL1 = m.faceCornerLoop(1, 3);
    const size_t cL2 = m.faceCornerLoop(2, 1);
    const size_t cL3 = m.faceCornerLoop(3, 0);
    assert(cL0 != size_t.max && cL1 != size_t.max
        && cL2 != size_t.max && cL3 != size_t.max,
        "center-vertex corner loop indices must be valid");

    // Snapshot entire UV data before perturbation (vertex XY = integers,
    // exactly representable as float; byte compare is valid for border loops).
    const float[] savedData = uvMap.data.dup;

    // Perturb all four center corners.
    foreach (cl; [cL0, cL1, cL2, cL3]) {
        uvMap.data[cl * 2]     = 1.3f;
        uvMap.data[cl * 2 + 1] = 1.3f;
    }

    const bool moved = uvRelax(m, uvMap, 1, 1.0f);
    assert(moved, "interior relax: uvRelax must return true");

    // Center corners must have converged to ≈ (1, 1).
    enum float eps = 1e-4f;
    foreach (cl; [cL0, cL1, cL2, cL3]) {
        const float u = uvMap.data[cl * 2];
        const float v = uvMap.data[cl * 2 + 1];
        assert(fabs(u - 1.0f) < eps,
               format("center u ≈ 1 at loop %d; got %g", cl, u));
        assert(fabs(v - 1.0f) < eps,
               format("center v ≈ 1 at loop %d; got %g", cl, v));
    }

    // All 12 border loops must be byte-unchanged (pinned → never written).
    const size_t[] centerLoops = [cL0, cL1, cL2, cL3];
    foreach (L; 0 .. m.loops.length) {
        if (centerLoops.canFind(L)) continue;
        assert(uvMap.data[L * 2]     == savedData[L * 2],
               format("border u unchanged at loop %d", L));
        assert(uvMap.data[L * 2 + 1] == savedData[L * 2 + 1],
               format("border v unchanged at loop %d", L));
    }
}

unittest {
    // Seam split: giving v4's corner in face 3 a different UV splits it into
    // two UV classes; both touch a seam edge → both are pinned → no-op.
    import mesh : Mesh, MeshMap, MapDomain, kUvMapName;
    import math : Vec3;

    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0),
        Vec3(0,1,0), Vec3(1,1,0), Vec3(2,1,0),
        Vec3(0,2,0), Vec3(1,2,0), Vec3(2,2,0),
    ];
    m.addFace([0u,1u,4u,3u]);
    m.addFace([1u,2u,5u,4u]);
    m.addFace([3u,4u,7u,6u]);
    m.addFace([4u,5u,8u,7u]);
    m.buildLoops();

    auto uvMap = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uvMap !is null);
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        uvMap.data[L * 2]     = m.vertices[vi].x;
        uvMap.data[L * 2 + 1] = m.vertices[vi].y;
    }

    // Perturb face-3, corner-0 (vertex v4) → creates a UV seam.
    const size_t seamL = m.faceCornerLoop(3, 0);
    assert(seamL != size_t.max);
    uvMap.data[seamL * 2]     = 1.5f;
    uvMap.data[seamL * 2 + 1] = 1.5f;

    const float[] before = uvMap.data.dup;
    assert(!uvRelax(m, uvMap, 1, 1.0f),
           "seam-split: uvRelax must return false (no-op)");
    assert(uvMap.data == before,
           "seam-split: uv.data must be byte-unchanged");
}
