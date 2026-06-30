module uv_weld;

/// Shared UV-vertex weld: UnionFind + buildUvClasses.
///
/// Both `uv_relax` and `uv_unwrap` need to partition per-corner UV values
/// into UV-vertex *classes* via the same union-find over twin-pair UV
/// agreement.  This module centralises that logic so both kernels are DRY.
///
/// Byte-identity contract: `buildUvClasses(m, data, null)` produces
/// rep/classId/nClasses IDENTICAL to the original private weld in `uv_relax`
/// — same a-side/b-side uvEq criterion, same first-seen-root class-id order.

import mesh    : Mesh;
import std.math : fabs;

// ---------------------------------------------------------------------------
// UV equality: two loop indices agree in both UV components within epsUV.
// Exposed package so sibling modules (uv_relax.d, uv_unwrap.d) can reuse
// it for seam-detection in pin classification without re-declaring.
// ---------------------------------------------------------------------------

private enum float epsUV = 1e-6f;

bool uvEq(const float[] data, size_t i, size_t j) pure nothrow @nogc {
    return fabs(data[i * 2]     - data[j * 2])     < epsUV
        && fabs(data[i * 2 + 1] - data[j * 2 + 1]) < epsUV;
}

// ---------------------------------------------------------------------------
// Union-find with two-hop path compression + union-by-size.
// (Moved verbatim from uv_relax.d so both kernels share one copy.)
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
// Public weld result + buildUvClasses.
// ---------------------------------------------------------------------------

/// Compact class assignment over all loops produced by `buildUvClasses`.
///
/// For loop L:
///   - `rep[L]`          = union-find root of L's component.
///   - `classId[rep[L]]` = contiguous class ID in [0 .. nClasses).
struct UvClasses {
    uint[] rep;       // rep[L] = union-find root of loop L
    uint[] classId;   // classId[root] = compact class ID; uint.max for non-roots
    uint   nClasses;  // total number of distinct UV-vertex classes
}

/// Build UV-vertex classes over all corner (loop) UV values.
///
/// Interior twin pairs that agree in UV within epsUV (both a-side and b-side)
/// are merged into one class — the exact criterion from `uv_relax`.
/// `isCutEdge(L)` is an ADDITIONAL cut: when true for loop L, the weld
/// across L's edge is suppressed even when UV agrees.  `null` = no extra cut
/// → result is byte-identical to `uv_relax`'s original weld.
///
/// Class IDs are assigned in first-seen-root loop order [0 .. nClasses).
UvClasses buildUvClasses(const ref Mesh m, const float[] data,
                         bool delegate(uint) isCutEdge = null)
{
    const size_t nL = m.loops.length;

    UnionFind uf;
    uf.init(cast(uint)nL);

    foreach (L; 0 .. nL) {
        const uint T = m.loops[L].twin;
        if (T == uint.max) continue;                               // mesh boundary
        if (isCutEdge !is null && isCutEdge(cast(uint)L)) continue; // explicit cut
        const uint nL_ = m.loops[L].next;
        const uint nT  = m.loops[T].next;
        if (uvEq(data, L, nT))  uf.unite(cast(uint)L, nT);  // a-side
        if (uvEq(data, nL_, T)) uf.unite(nL_, T);            // b-side
    }

    uint[] rep     = new uint[](nL);
    uint[] classId = new uint[](nL);
    classId[] = uint.max;
    uint nClasses = 0;

    foreach (L; 0 .. nL) rep[L] = uf.find(cast(uint)L);
    foreach (L; 0 .. nL)
        if (classId[rep[L]] == uint.max) classId[rep[L]] = nClasses++;

    return UvClasses(rep, classId, nClasses);
}

// ---------------------------------------------------------------------------
// Module unittests — run by `dub test --config=modeling`.
// ---------------------------------------------------------------------------

unittest {
    // 3×3 quad grid seeded from vertex XY: all interior edges agree in UV
    // → center v4 forms one class.  9 distinct 3D vertices → 9 UV classes.
    import mesh      : Mesh, MapDomain, kUvMapName;
    import math      : Vec3;
    import std.conv  : to;

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

    float[] data = new float[](m.loops.length * 2);
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        data[L * 2]     = m.vertices[vi].x;
        data[L * 2 + 1] = m.vertices[vi].y;
    }

    auto cls = buildUvClasses(m, data, null);
    assert(cls.nClasses == 9,
           "3×3 grid: expected 9 UV classes (one per unique vertex), got "
           ~ cls.nClasses.to!string);
}

unittest {
    // Cut predicate on one interior edge → one extra class vs baseline.
    import mesh : Mesh;
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

    float[] data = new float[](m.loops.length * 2);
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        data[L * 2]     = m.vertices[vi].x;
        data[L * 2 + 1] = m.vertices[vi].y;
    }

    auto cls0 = buildUvClasses(m, data, null);
    assert(cls0.nClasses == 9, "baseline: 9 classes");

    // Find first interior loop.
    uint cutL = uint.max;
    foreach (L; 0 .. m.loops.length) {
        if (m.loops[L].twin != uint.max) { cutL = cast(uint)L; break; }
    }
    assert(cutL != uint.max, "must find an interior loop");

    const uint cutT = m.loops[cutL].twin;
    auto cls1 = buildUvClasses(m, data,
                               L => L == cutL || L == cutT);
    assert(cls1.nClasses == cls0.nClasses + 1,
           "cutting one interior edge must add exactly 1 class");
}
