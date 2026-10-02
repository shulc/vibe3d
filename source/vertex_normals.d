module vertex_normals;

// The smooth normal stream of the face VBO (model M3; viewport shading S1a,
// task 9070). GL-free. One function computes every face corner's smooth
// normal; the three face-VBO writers in `mesh_gpu.d` call it, so there is one
// smoothing rule. Law (captured, doc/captures/viewport_shading_rig_capture_
// 2026-10-02.md C3/C6): a corner of face f at vertex v averages the UNIT face
// normals (uniform weighting) of every face g around v whose normal is within
// the smoothing angle of f's (`dot(n_g, n_f) >= cos θ`, θ = 40°); hidden faces
// contribute; degenerate faces contribute nothing; f itself always counts.

import math : Vec3, faceNormalFirst3;
import mesh : Mesh;

/// The smoothing angle between face normals above which an edge stays hard
/// (the captured material default; one value for every face — a per-material
/// angle is a declared divergence).
enum float kSmoothingAngleDeg = 40.0f;

/// Kernel cap on the faces one vertex averages: a vertex of higher valence
/// averages its first `MAX_SMOOTH_VALENCE` incident faces (plus the corner's
/// own face). Bounds the per-corner loop; no Param scales it.
enum uint MAX_SMOOTH_VALENCE = 1024;

/// `cos(kSmoothingAngleDeg)`, the threshold `cornerSmoothNormals` takes.
float smoothingCosine(float angleDeg = kSmoothingAngleDeg) @safe pure nothrow @nogc {
    import std.math : cos, PI;
    return cast(float)cos(angleDeg * PI / 180.0);
}

/// Vertex → incident faces, CSR: the faces around vertex `v` are
/// `faces[offsets[v] .. offsets[v + 1]]`, in face-index order, each listed
/// once. Every face of length ≥ 3 is listed, hidden or not.
struct FaceAdjacency {
    uint[] offsets;
    uint[] faces;
}

/// Rebuild `adj` for `mesh`'s faces. Grow-only scratch: no allocation once
/// the arrays have reached the mesh's size.
void buildFaceAdjacency(const ref Mesh mesh, ref FaceAdjacency adj) @safe pure nothrow {
    immutable size_t nv = mesh.vertices.length;
    if (adj.offsets.length < nv + 1) adj.offsets.length = nv + 1;
    adj.offsets[0 .. nv + 1] = 0;
    size_t total;
    foreach (fi, face; mesh.faces) {
        if (face.length < 3) continue;
        foreach (j, v; face) {
            if (v >= nv || repeatsEarlier(face, j)) continue;
            ++adj.offsets[v + 1];
            ++total;
        }
    }
    foreach (v; 0 .. nv) adj.offsets[v + 1] += adj.offsets[v];
    if (adj.faces.length < total) adj.faces.length = total;
    // Fill with a running cursor per vertex (offsets[v] advanced, then shifted back).
    foreach (fi, face; mesh.faces) {
        if (face.length < 3) continue;
        foreach (j, v; face) {
            if (v >= nv || repeatsEarlier(face, j)) continue;
            adj.faces[adj.offsets[v]++] = cast(uint)fi;
        }
    }
    foreach_reverse (v; 0 .. nv) adj.offsets[v + 1] = adj.offsets[v];
    adj.offsets[0] = 0;
}

/// The number of incident-face entries `adj` holds (its `faces` population).
size_t adjacencyEntries(const ref FaceAdjacency adj, size_t vertexCount) @safe pure nothrow @nogc {
    return adj.offsets.length > vertexCount ? adj.offsets[vertexCount] : 0;
}

private bool repeatsEarlier(const(uint)[] face, size_t j) @safe pure nothrow @nogc {
    foreach (k; 0 .. j) if (face[k] == face[j]) return true;
    return false;
}

/// Unit normal of face `face` at `vpos` — the same `faceNormalFirst3` the
/// flat stream uses — or the zero vector for a degenerate face or one under
/// 3 corners (so it adds nothing to a corner's sum). The one face-normal home
/// of the face VBO: the flat stream (`mesh_gpu.writeFaceCorners`, which maps
/// zero to the `(0,1,0)` fallback) and the smooth stream both read it.
pragma(inline, true)
Vec3 faceUnitNormal(const(uint)[] face, const(Vec3)[] vpos) @safe pure nothrow @nogc {
    if (face.length < 3) return Vec3(0, 0, 0);
    bool deg;
    immutable Vec3 n = faceNormalFirst3(vpos[face[0]], vpos[face[1]], vpos[face[2]], deg);
    return deg ? Vec3(0, 0, 0) : n;
}

/// The smooth normal of face `fi`'s corner at vertex `v`, from the per-face
/// unit normals (`faceUnitNormal`). The ONE corner rule: the full pass and
/// the incremental pass both call it, so their results are bit-identical.
private Vec3 smoothCorner(const ref FaceAdjacency adj, const(Vec3)[] faceNormal,
                          float cosSmooth, size_t fi, uint v) @safe pure nothrow @nogc {
    import std.math : sqrt;
    immutable Vec3 nf_ = faceNormal[fi];
    if (nf_.x == 0 && nf_.y == 0 && nf_.z == 0) return Vec3(0, 1, 0);
    if (v + 1 >= adj.offsets.length) return nf_;
    float sx = nf_.x, sy = nf_.y, sz = nf_.z;
    immutable uint lo = adj.offsets[v];
    uint hi = adj.offsets[v + 1];
    if (hi - lo > MAX_SMOOTH_VALENCE) hi = lo + MAX_SMOOTH_VALENCE;
    foreach (g; adj.faces[lo .. hi]) {
        if (g == fi) continue;
        immutable Vec3 ng = faceNormal[g];
        if (ng.x * nf_.x + ng.y * nf_.y + ng.z * nf_.z < cosSmooth) continue;
        sx += ng.x; sy += ng.y; sz += ng.z;
    }
    immutable float len = sqrt(sx * sx + sy * sy + sz * sz);
    return len > 1e-6f ? Vec3(sx / len, sy / len, sz / len) : nf_;
}

/// Smooth normal of every face corner, written as xyz triples into
/// `outCorner` indexed by face corner (face 0's corners, then face 1's, …:
/// `3 * Σ face.length` floats, faces of length < 3 included). `faceNormal` is
/// grow-only scratch for the per-face unit normals (`faceUnitNormal`); a
/// degenerate face's own corners take the flat stream's fallback normal.
void cornerSmoothNormals(const ref Mesh mesh, const(Vec3)[] vpos,
                         const ref FaceAdjacency adj, float cosSmooth,
                         ref Vec3[] faceNormal, float[] outCorner) @safe pure nothrow {
    immutable size_t nf = mesh.faces.length;
    if (faceNormal.length < nf) faceNormal.length = nf;
    foreach (fi, face; mesh.faces) faceNormal[fi] = faceUnitNormal(face, vpos);
    size_t c;
    foreach (fi, face; mesh.faces)
        foreach (v; face) {
            immutable Vec3 n = smoothCorner(adj, faceNormal, cosSmooth, fi, v);
            outCorner[c * 3 + 0] = n.x;
            outCorner[c * 3 + 1] = n.y;
            outCorner[c * 3 + 2] = n.z;
            ++c;
        }
}

/// Above `vertexCount / kIncrementalDirtyDivisor` moved vertices the full
/// pass is cheaper than the incremental one (both give the same bits).
enum size_t kIncrementalDirtyDivisor = 4;

/// Persistent state of the incremental smooth-normal refresh
/// (`updateCornerSmooth`): the positions the cached face/corner normals were
/// computed from, the per-face corner-start offsets, and the validity stamp
/// (face layout generation, smoothing cosine, face and vertex counts, the
/// face array's identity). Any stamp mismatch recomputes everything.
struct SmoothNormalCache {
    bool   valid;
    ulong  layoutGen;
    float  cosSmooth = 0;   // not NaN: `GpuMesh ==` compares this struct
    size_t faceCount, vertexCount, facesId;
    Vec3[] lastPos;       // positions the cached normals describe
    uint[] cornerStart;   // face fi's corners: [cornerStart[fi], cornerStart[fi + 1])
    uint[] faceMark, vertMark;
    uint   epoch;
    uint[] dirtyVerts, changedFaces;
    uint[] writeFaces;    // faces whose VBO corners changed in the last update
    size_t writeCount;
    bool   lastFull;      // the last update recomputed every corner

    /// An independent copy (the prepared-upload clone must not alias the
    /// live mesh's cache: both write it in place).
    SmoothNormalCache dup() const @safe pure nothrow {
        SmoothNormalCache c;
        c.valid = valid; c.layoutGen = layoutGen; c.cosSmooth = cosSmooth;
        c.faceCount = faceCount; c.vertexCount = vertexCount;
        c.facesId = facesId; c.epoch = epoch;
        c.lastPos = lastPos.dup; c.cornerStart = cornerStart.dup;
        c.faceMark = faceMark.dup; c.vertMark = vertMark.dup;
        c.dirtyVerts = dirtyVerts.dup; c.changedFaces = changedFaces.dup;
        c.writeFaces = writeFaces.dup; c.writeCount = writeCount; c.lastFull = lastFull;
        return c;
    }

    /// True when nothing is held (the empty-`GpuMesh` predicate reads it).
    bool isEmpty() const @safe pure nothrow @nogc {
        return !valid && lastPos.length == 0 && cornerStart.length == 0 &&
            faceMark.length == 0 && vertMark.length == 0 && dirtyVerts.length == 0 &&
            changedFaces.length == 0 && writeFaces.length == 0 && writeCount == 0 &&
            !lastFull;
    }
}

private size_t facesIdentity(const ref Mesh mesh) @trusted pure nothrow @nogc {
    return cast(size_t)cast(const(void)*)mesh.faces.ptr;
}

pragma(inline, true)
private bool sameBits(Vec3 a, Vec3 b) @trusted pure nothrow @nogc {
    auto pa = cast(const(uint)*)&a, pb = cast(const(uint)*)&b;
    return pa[0] == pb[0] && pa[1] == pb[1] && pa[2] == pb[2];
}

/// Bitwise equality of two position runs (memcmp; `-0.0` vs `0.0` differ).
private bool sameBytes(const(Vec3)[] a, const(Vec3)[] b) @trusted pure nothrow @nogc {
    import core.stdc.string : memcmp;
    return a.length == b.length && memcmp(a.ptr, b.ptr, a.length * Vec3.sizeof) == 0;
}

private uint nextEpoch(ref SmoothNormalCache c) @safe pure nothrow @nogc {
    if (++c.epoch == 0) {
        c.faceMark[] = 0;
        c.vertMark[] = 0;
        c.epoch = 1;
    }
    return c.epoch;
}

/// Bring `faceNormal` (per face) and `cornerSmooth` (per face corner, xyz,
/// the `cornerSmoothNormals` layout) up to the drawn positions `vpos`,
/// recomputing only what moved. The dirty set is DERIVED, never taken from a
/// caller's mask: the vertices whose `vpos` bits differ from the positions
/// the cache last saw; then the faces around them get new unit normals, and
/// every corner at a vertex of those faces is recomputed (`smoothCorner`,
/// the same rule as the full pass, so the result is bit-identical to it).
/// Returns true when everything was recomputed (a stamp mismatch, or more
/// than `1/kIncrementalDirtyDivisor` of the vertices moved) — the caller then
/// rewrites every face; otherwise `cache.writeFaces[0 .. cache.writeCount]`
/// lists the faces whose positions, flat or smooth normals changed.
bool updateCornerSmooth(const ref Mesh mesh, const(Vec3)[] vpos,
                        const ref FaceAdjacency adj, float cosSmooth, ulong layoutGen,
                        ref Vec3[] faceNormal, ref float[] cornerSmooth,
                        ref SmoothNormalCache cache) @safe pure nothrow {
    immutable size_t nf = mesh.faces.length, nv = vpos.length;
    cache.writeCount = 0;
    cache.lastFull = false;
    size_t nd;
    bool full = !(cache.valid && cache.layoutGen == layoutGen &&
                  cache.cosSmooth == cosSmooth && cache.faceCount == nf &&
                  cache.vertexCount == nv &&
                  cache.facesId == facesIdentity(mesh));
    if (!full) {
        // Blocks of identical bytes are skipped whole (an idle refresh, or a
        // drag of a small selection, compares mostly-equal memory).
        enum size_t kBlock = 64;
        for (size_t b = 0; b < nv; b += kBlock) {
            immutable size_t e = b + kBlock < nv ? b + kBlock : nv;
            if (sameBytes(vpos[b .. e], cache.lastPos[b .. e])) continue;
            foreach (v; b .. e)
                if (!sameBits(vpos[v], cache.lastPos[v])) cache.dirtyVerts[nd++] = cast(uint)v;
        }
        full = nd * kIncrementalDirtyDivisor > nv;
    }
    if (full) {
        immutable size_t total = faceCornerTotal(mesh);
        if (cornerSmooth.length < total * 3) cornerSmooth.length = total * 3;
        cornerSmoothNormals(mesh, vpos, adj, cosSmooth, faceNormal, cornerSmooth[0 .. total * 3]);
        if (cache.cornerStart.length < nf + 1) cache.cornerStart.length = nf + 1;
        uint c;
        foreach (fi, face; mesh.faces) {
            cache.cornerStart[fi] = c;
            c += cast(uint)face.length;
        }
        cache.cornerStart[nf] = c;
        if (cache.lastPos.length < nv) cache.lastPos.length = nv;
        cache.lastPos[0 .. nv] = vpos[];
        if (cache.vertMark.length < nv) cache.vertMark.length = nv;
        if (cache.dirtyVerts.length < nv) cache.dirtyVerts.length = nv;
        if (cache.faceMark.length < nf) cache.faceMark.length = nf;
        if (cache.changedFaces.length < nf) cache.changedFaces.length = nf;
        if (cache.writeFaces.length < nf) cache.writeFaces.length = nf;
        cache.valid = true;
        cache.layoutGen = layoutGen;
        cache.cosSmooth = cosSmooth;
        cache.faceCount = nf;
        cache.vertexCount = nv;
        cache.facesId = facesIdentity(mesh);
        cache.lastFull = true;
        return true;
    }
    if (nd == 0) return false;
    // The faces around a moved vertex: new positions, new unit normal.
    immutable uint e1 = nextEpoch(cache);
    size_t nc;
    foreach (v; cache.dirtyVerts[0 .. nd]) {
        cache.lastPos[v] = vpos[v];
        foreach (g; adj.faces[adj.offsets[v] .. adj.offsets[v + 1]])
            if (cache.faceMark[g] != e1) {
                cache.faceMark[g] = e1;
                cache.changedFaces[nc++] = g;
            }
    }
    foreach (g; cache.changedFaces[0 .. nc]) faceNormal[g] = faceUnitNormal(mesh.faces[g], vpos);
    // Every corner at a vertex of a changed face reads that face's normal
    // (as its own or as a neighbour's): recompute it, and list its face.
    immutable uint e2 = nextEpoch(cache);
    size_t nw;
    foreach (g; cache.changedFaces[0 .. nc])
        foreach (v; mesh.faces[g]) {
            if (v >= nv || cache.vertMark[v] == e2) continue;
            cache.vertMark[v] = e2;
            foreach (f; adj.faces[adj.offsets[v] .. adj.offsets[v + 1]]) {
                immutable Vec3 n = smoothCorner(adj, faceNormal, cosSmooth, f, v);
                immutable uint c0 = cache.cornerStart[f];
                foreach (j, w; mesh.faces[f])
                    if (w == v) {
                        immutable size_t k = (c0 + j) * 3;
                        cornerSmooth[k + 0] = n.x;
                        cornerSmooth[k + 1] = n.y;
                        cornerSmooth[k + 2] = n.z;
                    }
                if (cache.faceMark[f] != e2) {
                    cache.faceMark[f] = e2;
                    cache.writeFaces[nw++] = f;
                }
            }
        }
    cache.writeCount = nw;
    return false;
}

/// Σ face.length over `mesh.faces`: the corner count `cornerSmoothNormals` writes.
size_t faceCornerTotal(const ref Mesh mesh) @safe pure nothrow @nogc {
    size_t n;
    foreach (face; mesh.faces) n += face.length;
    return n;
}
