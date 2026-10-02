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

/// Smooth normal of every face corner, written as xyz triples into
/// `outCorner` indexed by face corner (face 0's corners, then face 1's, …:
/// `3 * Σ face.length` floats, faces of length < 3 included). `faceNormal` is
/// grow-only scratch for the per-face unit normals — the same
/// `faceNormalFirst3` the flat stream uses — with a degenerate face stored as
/// the zero vector, so it adds nothing to a sum; a degenerate face's own
/// corners take the flat stream's fallback normal.
void cornerSmoothNormals(const ref Mesh mesh, const(Vec3)[] vpos,
                         const ref FaceAdjacency adj, float cosSmooth,
                         ref Vec3[] faceNormal, float[] outCorner) @safe pure nothrow {
    import std.math : sqrt;
    immutable size_t nf = mesh.faces.length;
    if (faceNormal.length < nf) faceNormal.length = nf;
    foreach (fi, face; mesh.faces) {
        bool deg = true;
        Vec3 n;
        if (face.length >= 3)
            n = faceNormalFirst3(vpos[face[0]], vpos[face[1]], vpos[face[2]], deg);
        faceNormal[fi] = deg ? Vec3(0, 0, 0) : n;
    }
    size_t c;
    foreach (fi, face; mesh.faces) {
        immutable Vec3 nf_ = faceNormal[fi];
        immutable bool deg = nf_.x == 0 && nf_.y == 0 && nf_.z == 0;
        foreach (v; face) {
            Vec3 n = deg ? Vec3(0, 1, 0) : nf_;
            if (!deg && v + 1 < adj.offsets.length) {
                float sx = nf_.x, sy = nf_.y, sz = nf_.z;
                immutable uint lo = adj.offsets[v];
                uint hi = adj.offsets[v + 1];
                if (hi - lo > MAX_SMOOTH_VALENCE) hi = lo + MAX_SMOOTH_VALENCE;
                foreach (k; lo .. hi) {
                    immutable uint g = adj.faces[k];
                    if (g == fi) continue;
                    immutable Vec3 ng = faceNormal[g];
                    if (ng.x * nf_.x + ng.y * nf_.y + ng.z * nf_.z < cosSmooth) continue;
                    sx += ng.x; sy += ng.y; sz += ng.z;
                }
                immutable float len = sqrt(sx * sx + sy * sy + sz * sz);
                if (len > 1e-6f) n = Vec3(sx / len, sy / len, sz / len);
            }
            outCorner[c * 3 + 0] = n.x;
            outCorner[c * 3 + 1] = n.y;
            outCorner[c * 3 + 2] = n.z;
            ++c;
        }
    }
}

/// Σ face.length over `mesh.faces`: the corner count `cornerSmoothNormals` writes.
size_t faceCornerTotal(const ref Mesh mesh) @safe pure nothrow @nogc {
    size_t n;
    foreach (face; mesh.faces) n += face.length;
    return n;
}
