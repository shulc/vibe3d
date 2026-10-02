// The smooth normal stream's kernel (`vertex_normals`, task 9070) and the one
// normal matrix (`math.normalMatrix`). Law (captured, viewport shading S0 C3/C6):
// angle split at the surface's smoothing angle (default `kDefaultSmoothingAngleDeg`)
// between face normals, uniform weighting, hidden faces contribute, degenerate
// faces do not; per-surface policy, the LOWER slot of a pair deciding for both
// faces (owner ruling, S1e). The hinge cells sit at θ ± 10 as EXPRESSIONS of
// the constant, so a re-captured θ moves them along.
module tests.unit.vertex_normals_test;

import std.format : format;
import std.math   : abs, cos, sin, sqrt, isFinite, PI;

import math : Vec3, normalMatrix;
import mesh : Mesh, Surface, kDefaultSmoothingAngleDeg, kSurfaceSlots;
import vertex_normals : FaceAdjacency, buildFaceAdjacency, cornerSmoothNormals,
    faceCornerTotal, smoothingCosine, MAX_SMOOTH_VALENCE, SmoothPolicy,
    buildSmoothPolicy, kSmoothOff;

/// The policy `m` itself carries (its surfaces, its face tags).
private SmoothPolicy policyOf(const ref Mesh m) {
    SmoothPolicy p;
    buildSmoothPolicy(m, p);
    return p;
}

/// A policy giving every face of `m` one surface smoothing at `angleDeg`.
private SmoothPolicy uniformPolicy(const ref Mesh m, float angleDeg) {
    Surface s;
    s.smoothingAngleDeg = angleDeg;
    SmoothPolicy p;
    buildSmoothPolicy(null, m.faces.length, [s], p);
    return p;
}

/// `VIBE3D_CELL=<name>` runs only that named cell (the must-redden drill runs
/// each witness alone); unset, every cell runs.
private bool cellOn(string name) {
    import std.process : environment;
    immutable string want = environment.get("VIBE3D_CELL", "");
    return want.length == 0 || want == name;
}

private Vec3 nrm(Vec3 v) {
    immutable double l = sqrt(cast(double)v.x * v.x + cast(double)v.y * v.y
                              + cast(double)v.z * v.z);
    return Vec3(cast(float)(v.x / l), cast(float)(v.y / l), cast(float)(v.z / l));
}

private Vec3 faceN(const ref Mesh m, size_t f) {
    auto a = m.vertices[m.faces[f][0]], b = m.vertices[m.faces[f][1]],
         c = m.vertices[m.faces[f][2]];
    immutable Vec3 e1 = Vec3(b.x - a.x, b.y - a.y, b.z - a.z);
    immutable Vec3 e2 = Vec3(c.x - a.x, c.y - a.y, c.z - a.z);
    return nrm(Vec3(e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z,
                    e1.x * e2.y - e1.y * e2.x));
}

private bool near(Vec3 a, Vec3 b, float eps = 1e-5f) {
    return abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps && abs(a.z - b.z) <= eps;
}

/// Corner normals of `m` (all faces), with the adjacency floor asserted first.
private float[] corners(ref Mesh m, out FaceAdjacency adj) {
    buildFaceAdjacency(m, adj);
    // Population floor [E2]: the CSR holds exactly Σ distinct-vertex valence.
    size_t valence;
    foreach (f; m.faces) {
        if (f.length < 3) continue;
        foreach (j, v; f) {
            bool rep;
            foreach (k; 0 .. j) if (f[k] == v) rep = true;
            if (!rep) ++valence;
        }
    }
    assert(adj.offsets[m.vertices.length] == valence && valence > 0,
        format("adjacency floor: CSR holds %d incident-face entries, the faces predict %d",
               adj.offsets[m.vertices.length], valence));
    Vec3[] scratch;
    auto out_ = new float[](faceCornerTotal(m) * 3);
    const pol = policyOf(m);
    cornerSmoothNormals(m, m.vertices, adj, pol, scratch, out_);
    return out_;
}

private Vec3 cornerOf(const ref Mesh m, const float[] c, size_t face, uint vert) {
    size_t base;
    foreach (f; 0 .. face) base += m.faces[f].length;
    foreach (j, v; m.faces[face])
        if (v == vert) {
            immutable size_t k = (base + j) * 3;
            return Vec3(c[k], c[k + 1], c[k + 2]);
        }
    assert(false, format("vertex %d is not on face %d", vert, face));
}

/// Two quads hinged on the X axis, normals `dihedralDeg` apart: face 0 in z=0
/// (+Z), face 1 folded about X. Shared vertices 0 and 1.
private Mesh hinge(double dihedralDeg) {
    immutable double d = dihedralDeg * PI / 180.0;
    Mesh m;
    m.vertices = [Vec3(-1, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(-1, 1, 0),
                  Vec3(1, cast(float)-cos(d), cast(float)-sin(d)),
                  Vec3(-1, cast(float)-cos(d), cast(float)-sin(d))];
    m.faces ~= [0u, 1, 2, 3];
    m.faces ~= [5u, 4, 1, 0];
    return m;
}

unittest { // hinge at θ − 10: both corners on the shared edge get the bisector
    Mesh m = hinge(kDefaultSmoothingAngleDeg - 10.0);
    FaceAdjacency adj;
    auto c = corners(m, adj);
    immutable Vec3 bis = nrm(Vec3(faceN(m, 0).x + faceN(m, 1).x,
                                  faceN(m, 0).y + faceN(m, 1).y,
                                  faceN(m, 0).z + faceN(m, 1).z));
    foreach (uint v; [0u, 1u]) {
        assert(near(cornerOf(m, c, 0, v), bis) && near(cornerOf(m, c, 1, v), bis),
            format("θ-10 hinge: vertex %d corners %s / %s, expected the bisector %s",
                   v, cornerOf(m, c, 0, v), cornerOf(m, c, 1, v), bis));
    }
    // Off the shared edge the face keeps its own normal.
    assert(near(cornerOf(m, c, 0, 2), faceN(m, 0)), "θ-10 hinge: an unshared corner moved");
}

unittest { // hinge at θ + 10: the edge stays hard, each corner keeps its face normal
    Mesh m = hinge(kDefaultSmoothingAngleDeg + 10.0);
    FaceAdjacency adj;
    auto c = corners(m, adj);
    foreach (uint v; [0u, 1u]) {
        assert(near(cornerOf(m, c, 0, v), faceN(m, 0)) && near(cornerOf(m, c, 1, v), faceN(m, 1)),
            format("θ+10 hinge: vertex %d corners %s / %s, expected the face normals %s / %s "
                 ~ "(the angle split did not hold)", v, cornerOf(m, c, 0, v),
                   cornerOf(m, c, 1, v), faceN(m, 0), faceN(m, 1)));
    }
}

unittest { // a pole of a shallow irregular fan: the corner is the normalized UNIFORM mean
    Mesh m;
    m.vertices = [Vec3(0, 0, 0.2f)];
    immutable double[7] ang = [0, 0.7, 1.9, 2.6, 3.5, 4.4, 5.6];
    immutable double[7] rad = [1, 1.4, 0.8, 1.1, 2.0, 0.9, 1.3];
    foreach (i; 0 .. 7)
        m.vertices ~= Vec3(cast(float)(rad[i] * cos(ang[i])), cast(float)(rad[i] * sin(ang[i])), 0);
    foreach (uint i; 0 .. 7) m.faces ~= [0u, 1 + i, 1 + (i + 1) % 7];
    FaceAdjacency adj;
    auto c = corners(m, adj);
    // Premise: every pair of faces is inside the angle, so all seven count.
    foreach (a; 0 .. 7) foreach (b; 0 .. 7) {
        immutable Vec3 na = faceN(m, a), nb = faceN(m, b);
        assert(na.x * nb.x + na.y * nb.y + na.z * nb.z >= smoothingCosine(kDefaultSmoothingAngleDeg),
            format("pole premise: faces %d and %d are split", a, b));
    }
    Vec3 s = Vec3(0, 0, 0);
    foreach (f; 0 .. 7) { auto n = faceN(m, f); s = Vec3(s.x + n.x, s.y + n.y, s.z + n.z); }
    immutable Vec3 mean = nrm(s);
    foreach (f; 0 .. 7)
        assert(near(cornerOf(m, c, f, 0), mean),
            format("pole: face %d corner %s, the uniform mean is %s", f, cornerOf(m, c, f, 0), mean));
}

unittest { // a degenerate face contributes nothing; its own corners take the flat fallback
    // An ASYMMETRIC hinge near +Y (normals 25° and -5° from +Y, dihedral
    // θ - 10): the flat fallback (0,1,0) of a degenerate face is inside the
    // smoothing angle of both faces and NOT along their bisector, so a
    // degenerate face that was counted would bend the corner.
    immutable double pa = 25.0 * PI / 180, pb = -5.0 * PI / 180;
    assert(abs((25.0 - -5.0) - (kDefaultSmoothingAngleDeg - 10.0)) < 1e-9, "degenerate premise: dihedral is not θ-10");
    Mesh m;
    // Face A holds the X axis and direction (0,-sin pa, cos pa); face B the
    // opposite side, direction -(0,-sin pb, cos pb).
    m.vertices = [Vec3(-1, 0, 0), Vec3(1, 0, 0),
                  Vec3(1, cast(float)-sin(pa), cast(float)cos(pa)),
                  Vec3(-1, cast(float)-sin(pa), cast(float)cos(pa)),
                  Vec3(1, cast(float)sin(pb), cast(float)-cos(pb)),
                  Vec3(-1, cast(float)sin(pb), cast(float)-cos(pb))];
    m.faces ~= [0u, 1, 2, 3];
    m.faces ~= [1u, 0, 5, 4];
    foreach (f; 0 .. 2)
        if (faceN(m, f).y < 0) { import std.algorithm : reverse; m.faces[f].reverse(); }
    foreach (f; 0 .. 2)
        assert(faceN(m, f).y > cos(kDefaultSmoothingAngleDeg * PI / 180),
            format("degenerate premise: face %d normal %s is not within θ of +Y", f, faceN(m, f)));
    FaceAdjacency adj0;
    auto ref_ = corners(m, adj0);
    // Discrimination floor: counting (0,1,0) would move the corner visibly.
    immutable Vec3 a = faceN(m, 0), b = faceN(m, 1);
    immutable Vec3 counted = nrm(Vec3(a.x + b.x, a.y + b.y + 1, a.z + b.z));
    assert(!near(counted, cornerOf(m, ref_, 0, 0), 1e-3f),
        "degenerate floor: counting the fallback normal would not move the corner");
    m.vertices ~= Vec3(-2, 0, 0);           // collinear with vertices 0 and 1
    m.faces ~= [0u, 1, 6];
    FaceAdjacency adj;
    auto c = corners(m, adj);
    foreach (uint v; [0u, 1u])
        assert(near(cornerOf(m, c, 0, v), cornerOf(m, ref_, 0, v)),
            format("degenerate: vertex %d corner moved to %s from %s — the degenerate face counted",
                   v, cornerOf(m, c, 0, v), cornerOf(m, ref_, 0, v)));
    assert(near(cornerOf(m, c, 2, 6), Vec3(0, 1, 0)),
        "degenerate: the degenerate face's own corner is not the flat fallback (0,1,0)");
}

unittest { // a vertex listed twice by one face counts once; a face under 3 corners is not listed
    Mesh m = hinge(kDefaultSmoothingAngleDeg - 10.0);
    FaceAdjacency adj0;
    auto ref_ = corners(m, adj0);
    m.faces ~= [0u, 2, 0, 3];               // vertex 0 twice
    m.faces ~= [0u, 1];                     // a two-corner face
    FaceAdjacency adj;
    auto c = corners(m, adj);               // the CSR floor counts distinct vertices of faces >= 3
    size_t at0;
    foreach (k; adj.offsets[0] .. adj.offsets[1]) if (adj.faces[k] == 2) ++at0;
    assert(at0 == 1, format("repeat: face 2 is listed %d times around vertex 0", at0));
    foreach (k; adj.offsets[0] .. adj.offsets[1])
        assert(adj.faces[k] != 3, "repeat: the two-corner face 3 is listed around vertex 0");
}

unittest { // hidden faces still contribute (captured C6)
    Mesh m = hinge(kDefaultSmoothingAngleDeg - 10.0);
    FaceAdjacency adj0;
    auto ref_ = corners(m, adj0);
    m.faceMarks.length = m.faces.length;
    m.faceMarks[1] |= Mesh.Marks.Hide;
    assert(m.isFaceHidden(1), "hidden premise: face 1 is not hidden");
    FaceAdjacency adj;
    auto c = corners(m, adj);
    assert(near(cornerOf(m, c, 0, 0), cornerOf(m, ref_, 0, 0))
        && !near(cornerOf(m, c, 0, 0), faceN(m, 0), 1e-3f),
        format("hidden: face 0's corner at vertex 0 is %s; with the hidden face counted it is %s",
               cornerOf(m, c, 0, 0), cornerOf(m, ref_, 0, 0)));
}

unittest { // MAX_SMOOTH_VALENCE: a vertex averages its FIRST cap faces (plus its own)
    Mesh m;
    m.vertices = [Vec3(0, 0, 0)];
    immutable uint total = MAX_SMOOTH_VALENCE + 76;
    immutable double tilt = 30.0 * PI / 180.0;
    foreach (uint i; 0 .. total) {
        immutable double t = 2 * PI * i / total;
        // First MAX faces lie in z = 0 (+Z); the rest are tilted 30° about the
        // X axis (inside the angle, so only the cap can exclude them).
        Vec3 a = Vec3(cast(float)cos(t), cast(float)sin(t), 0);
        Vec3 b = Vec3(cast(float)cos(t + 0.001), cast(float)sin(t + 0.001), 0);
        if (i >= MAX_SMOOTH_VALENCE) {
            a = Vec3(1, 0, 0); b = Vec3(0, cast(float)cos(tilt), cast(float)sin(tilt));
        }
        immutable uint ia = cast(uint)m.vertices.length;
        m.vertices ~= a; m.vertices ~= b;
        m.faces ~= [0u, ia, ia + 1];
    }
    FaceAdjacency adj;
    auto c = corners(m, adj);
    immutable Vec3 tilted = faceN(m, total - 1);
    assert(abs(tilted.z - cos(tilt)) < 1e-4, format("cap premise: tilted face normal %s", tilted));
    // Uncapped, face 0's corner would lean toward the 76 tilted faces.
    immutable double uncappedY = 76 * tilted.y / sqrt((76 * tilted.y) ^^ 2
        + (MAX_SMOOTH_VALENCE + 76 * tilted.z) ^^ 2);
    assert(abs(uncappedY) > 0.01, "cap discrimination floor: the uncapped mean is not distinguishable");
    assert(near(cornerOf(m, c, 0, 0), Vec3(0, 0, 1), 1e-6f),
        format("cap: face 0's corner is %s, the capped mean is (0,0,1) (uncapped y = %.4f)",
               cornerOf(m, c, 0, 0), uncappedY));
}

// ---- normalMatrix -------------------------------------------------------

private Vec3 mul(const float[9] n, Vec3 v) {   // column-major 3×3
    return Vec3(n[0] * v.x + n[3] * v.y + n[6] * v.z,
                n[1] * v.x + n[4] * v.y + n[7] * v.z,
                n[2] * v.x + n[5] * v.y + n[8] * v.z);
}

private float[16] diag(float a, float b, float c) {
    return [a, 0, 0, 0,  0, b, 0, 0,  0, 0, c, 0,  5, 6, 7, 1];   // translation is ignored
}

unittest { // identity and a rotation map to themselves
    immutable float[9] i = normalMatrix(diag(1, 1, 1));
    assert(i == [1f, 0, 0, 0, 1, 0, 0, 0, 1], format("normalMatrix(I) = %s", i));
    immutable float c = cast(float)cos(0.6), s = cast(float)sin(0.6);
    // Rotation about Z then a column-major embed.
    immutable float[16] r = [c, s, 0, 0,  -s, c, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1];
    immutable float[9] n = normalMatrix(r);
    immutable float[9] want = [c, s, 0, -s, c, 0, 0, 0, 1];
    foreach (k; 0 .. 9)
        assert(abs(n[k] - want[k]) < 1e-6, format("normalMatrix(R) = %s, expected R = %s", n, want));
}

unittest { // non-uniform scale: the inverse-transpose direction, not mat3(m)
    immutable float[9] n = normalMatrix(diag(1, 4, 1));
    immutable Vec3 got = nrm(mul(n, nrm(Vec3(1, 1, 0))));
    immutable Vec3 want = nrm(Vec3(1, 0.25f, 0));
    assert(near(got, want), format("diag(1,4,1): normal (1,1,0)/√2 → %s, expected ∝ (1,0.25,0) = %s",
                                   got, want));
}

unittest { // mirror: sign(det) keeps the orientation (+Z stays +Z under diag(-1,1,1))
    immutable float[9] n = normalMatrix(diag(-1, 1, 1));
    immutable Vec3 got = nrm(mul(n, Vec3(0, 0, 1)));
    assert(near(got, Vec3(0, 0, 1)), format("mirror diag(-1,1,1): ẑ → %s, expected +ẑ", got));
}

unittest { // det = 0: finite, sign taken as +1
    immutable float[9] n = normalMatrix(diag(1, 1, 0));
    foreach (k; 0 .. 9) assert(isFinite(n[k]), format("det=0: non-finite entry %d in %s", k, n));
    assert(n == [0f, 0, 0, 0, 0, 0, 0, 0, 1], format("det=0: normalMatrix(diag(1,1,0)) = %s", n));
}

// ---------------------------------------------------------------------------
// The incremental refresh (`updateCornerSmooth`): the drag frame recomputes
// only the faces around moved vertices and the corners at those faces'
// vertices. Oracle: the full pass over the same positions — the same corner
// rule, so the incremental result must be BIT-identical, not merely close.

import vertex_normals : SmoothNormalCache, updateCornerSmooth;

/// An open, non-cube patch: a 6×5 vertex grid in XZ with a gentle swell,
/// folded by `kDefaultSmoothingAngleDeg + 10` about the line x = 2 (a hard hinge
/// across the patch), cell (0,0) split into two triangles and cells (3,1),
/// (4,1) merged into one hexagon. Vertex (i, j) is `i * 5 + j`.
Mesh hingedPatch() {
    import std.math : cos, sin;
    immutable double fold = (kDefaultSmoothingAngleDeg + 10) * PI / 180.0;
    Mesh m;
    foreach (i; 0 .. 6)
        foreach (j; 0 .. 5) {
            immutable double swell = 0.08 * sin(j * 0.9);
            double x = i, y = swell;
            if (i > 2) {   // rotate (x - 2, y) by `fold` about the hinge line
                immutable double dx = i - 2;
                x = 2 + dx * cos(fold);
                y = swell + dx * sin(fold);
            }
            m.vertices ~= Vec3(cast(float)x, cast(float)y, cast(float)j);
        }
    uint at(int i, int j) { return cast(uint)(i * 5 + j); }
    m.faces ~= [at(0, 0), at(0, 1), at(1, 1)];
    m.faces ~= [at(0, 0), at(1, 1), at(1, 0)];
    foreach (i; 0 .. 5)
        foreach (j; 0 .. 4) {
            if (i == 0 && j == 0) continue;
            if (j == 1 && (i == 3 || i == 4)) continue;
            m.faces ~= [at(i, j), at(i, j + 1), at(i + 1, j + 1), at(i + 1, j)];
        }
    m.faces ~= [at(4, 1), at(3, 1), at(3, 2), at(4, 2), at(5, 2), at(5, 1)];
    return m;
}

/// The full pass over `m` under `pol` (a fresh adjacency, fresh scratch).
private float[] fullCorners(ref Mesh m, const ref SmoothPolicy pol) {
    FaceAdjacency adj;
    buildFaceAdjacency(m, adj);
    Vec3[] fn;
    auto out_ = new float[](faceCornerTotal(m) * 3);
    cornerSmoothNormals(m, m.vertices, adj, pol, fn, out_);
    return out_;
}

/// ditto, under the policy `m` carries.
private float[] fullCorners(ref Mesh m) {
    const pol = policyOf(m);
    return fullCorners(m, pol);
}

/// First corner where `got` and `want` differ in bits, or -1.
private ptrdiff_t firstDiff(const float[] got, const float[] want) {
    foreach (i; 0 .. want.length) if (got[i] !is want[i]) return cast(ptrdiff_t)i;
    return -1;
}

/// One incremental session over `m`: adjacency + caches that persist.
private struct Session {
    FaceAdjacency adj;
    Vec3[] faceNormal;
    float[] corner;
    SmoothNormalCache cache;
    ulong gen = 1;
    bool step(ref Mesh m, const ref SmoothPolicy pol) {
        buildFaceAdjacency(m, adj);   // the GpuMesh rebuilds it per layout; cheap here
        return updateCornerSmooth(m, m.vertices, adj, pol, gen, faceNormal, corner, cache);
    }
    /// ditto, under the policy `m` carries.
    bool step(ref Mesh m) {
        const pol = policyOf(m);
        return step(m, pol);
    }
}

unittest { // the patch rig: population and a hard hinge that the angle split keeps
    auto m = hingedPatch();
    // Floor [E4]: 30 vertices; 2 triangles + 17 quads + 1 hexagon = 20 faces, 80 corners.
    assert(m.vertices.length == 30 && m.faces.length == 20 && faceCornerTotal(m) == 80,
        format("rig: %d vertices, %d faces, %d corners (expected 30, 20, 80)",
               m.vertices.length, m.faces.length, faceCornerTotal(m)));
    // The fold is a hinge: a corner on x = 2 keeps its own face's normal on
    // each side (the corners of quads (1,2) = face 7 and (2,2) = face 11 at
    // vertex (2,2) = 12 differ).
    const c = fullCorners(m);
    immutable Vec3 left = cornerOf(m, c, 7, 12), right = cornerOf(m, c, 11, 12);
    assert(!near(left, right, 1e-2f),
        format("rig: the hinge at x = 2 does not split (%s vs %s) — the patch cannot witness the angle test", left, right));
}

/// The faces an incremental update must re-fan, derived from the mesh
/// alone (not from the CSR the kernel reads): the faces incident to any
/// vertex of a face that has a moved vertex. `prev` = the positions of the
/// previous update; a vertex moved iff its bits differ. Sorted, distinct.
private uint[] expectedWriteSet(const ref Mesh m, const(Vec3)[] prev) {
    bool[] moved = new bool[](m.vertices.length), touched = new bool[](m.vertices.length);
    foreach (v; 0 .. m.vertices.length) moved[v] = m.vertices[v] !is prev[v];
    foreach (f; m.faces) {
        bool hit;
        foreach (v; f) if (moved[v]) hit = true;
        if (hit) foreach (v; f) touched[v] = true;
    }
    uint[] want;
    foreach (fi, f; m.faces) {
        bool hit;
        foreach (v; f) if (touched[v]) hit = true;
        if (hit) want ~= cast(uint)fi;
    }
    return want;
}

/// `cache.writeFaces[0 .. writeCount]` equals `want` as a set, with no repeats.
private void assertWriteSet(const ref SmoothNormalCache cache, const uint[] want, string what) {
    import std.algorithm.sorting : sort;
    assert(cache.writeCount == want.length,
        format("%s: the update re-fanned %d face entries, the faces around the changed faces' vertices are %d %s",
               what, cache.writeCount, want.length, want));
    auto got = cache.writeFaces[0 .. cache.writeCount].dup;
    sort(got);
    assert(got == want, format("%s: re-fanned faces %s, expected %s", what, got, want));
}

unittest { // a one-vertex drag re-fans EXACTLY the faces around the changed faces' vertices, once each
    auto m = hingedPatch();
    Session s;
    s.step(m);
    immutable Vec3[] prev = m.vertices.idup;
    m.vertices[0].y += 0.3f;   // the triangle corner: changed faces 0 and 1
    assert(!s.step(m), "one moved vertex must take the incremental path");
    const uint[] want = expectedWriteSet(m, prev);
    // Floor [E4]: the two triangles and the three quads around vertex (1,1);
    // the CSR lists 11 incident entries over those faces' vertices, so a
    // write list without its dedupe holds 11.
    assert(want == [0u, 1, 2, 5, 6], format("rig: the expected re-fan set is %s", want));
    assertWriteSet(s.cache, want, "one-vertex drag");
}

unittest { // partial drags: incremental == full, bit for bit, at every step
    auto m = hingedPatch();
    Session s;
    assert(s.step(m), "the first update must be full (empty cache)");
    // Each step moves a vertex subset: interior, the hinge line, a hexagon
    // corner, a triangle corner, then a step that UNDOES an earlier move.
    immutable uint[][] subsets = [[7u], [12u, 11u], [21u, 22u], [0u], [12u], [16u, 17u, 18u]];
    immutable Vec3[] deltas = [Vec3(0, 0.3f, 0), Vec3(0.05f, -0.2f, 0.1f), Vec3(0, 0.25f, -0.1f),
                               Vec3(0, 0.4f, 0), Vec3(-0.05f, 0.2f, -0.1f), Vec3(0.1f, 0.1f, 0)];
    immutable Vec3[] before = m.vertices.idup;
    size_t partial;
    foreach (k, sub; subsets) {
        immutable Vec3[] prev = m.vertices.idup;
        foreach (v; sub) {
            if (k == 4) m.vertices[v] = before[v];   // undo the hinge move of step 1
            else {
                m.vertices[v].x += deltas[k].x;
                m.vertices[v].y += deltas[k].y;
                m.vertices[v].z += deltas[k].z;
            }
        }
        immutable bool full = s.step(m);
        // Path control [E10]: a small subset takes the incremental path and
        // re-fans some, not all, faces — else this cell cannot witness it.
        assert(!full && s.cache.writeCount > 0 && s.cache.writeCount < m.faces.length,
            format("step %d: expected an incremental update over a face subset, got full=%s faces=%d",
                   k, full, s.cache.writeCount));
        assertWriteSet(s.cache, expectedWriteSet(m, prev), format("step %d", k));
        ++partial;
        const want = fullCorners(m);
        immutable d = firstDiff(s.corner[0 .. want.length], want);
        assert(d < 0, format("step %d: incremental corner float %d is %s, the full pass gives %s",
                             k, d, d < 0 ? 0 : s.corner[d], d < 0 ? 0 : want[d]));
    }
    assert(partial == subsets.length);
    // An idle refresh moves nothing and re-fans nothing.
    assert(!s.step(m) && s.cache.writeCount == 0,
        "an idle refresh must re-fan no face");
}

unittest { // stale cache: a new face layout (same arrays, same counts) recomputes all
    auto m = hingedPatch();
    Session s;
    s.step(m);
    // In-place winding flip of face 5: the face array, the counts and every
    // position are unchanged; only the layout generation says so.
    import std.algorithm.mutation : reverse;
    reverse(m.faces[5]);
    ++s.gen;
    s.step(m);
    const want = fullCorners(m);
    immutable d = firstDiff(s.corner[0 .. want.length], want);
    assert(d < 0, format("after a layout change corner float %d is stale (%s, full gives %s)",
                         d, s.corner[d < 0 ? 0 : d], want[d < 0 ? 0 : d]));
}

unittest { // a new smoothing policy arrives WITH a new layout generation and recomputes all
    // The invariant (`SmoothNormalCache`): the policy changes only together
    // with `faceLayoutGen` (the GpuMesh rebuilds it with the adjacency).
    auto m = hingedPatch();
    Session s;
    s.step(m);
    // 60°: the 50° hinge now smooths, so the corner normals move.
    const p60 = uniformPolicy(m, 60);
    ++s.gen;
    s.step(m, p60);
    const want = fullCorners(m, p60);
    const before = fullCorners(m);
    assert(firstDiff(before, want) >= 0, "rig: 40° and 60° give the same corners — the cell cannot witness");
    immutable d = firstDiff(s.corner[0 .. want.length], want);
    assert(d < 0, format("after a smoothing-policy change corner float %d is stale", d));
}

unittest { // stale cache: a different face array (same gen) or a dropped face recomputes all
    auto m = hingedPatch();
    Session s;
    s.step(m);
    // A dropped LAST face keeps the array's pointer: only the face count moved.
    m.faces = m.faces[0 .. $ - 1];
    s.step(m);
    const want = fullCorners(m);
    immutable d = firstDiff(s.corner[0 .. want.length], want);
    assert(d < 0, format("after a face-count change corner float %d is stale", d));
    // A replaced face array of the same count, a face's winding flipped.
    auto m2 = hingedPatch();
    Session s2;
    s2.step(m2);
    auto faces = m2.faces.dup;
    faces[3] = [faces[3][0], faces[3][3], faces[3][2], faces[3][1]];
    m2.faces = faces;
    s2.step(m2);
    const want2 = fullCorners(m2);
    immutable d2 = firstDiff(s2.corner[0 .. want2.length], want2);
    assert(d2 < 0, format("after a face-array swap corner float %d is stale", d2));
}

unittest { // stale cache: a SHRUNK vertex array (same layout) recomputes all
    // Above the grown-array cell: without the vertex-count stamp the grown
    // case dies on a slice bound, this one fails by name.
    auto m = hingedPatch();
    m.vertices ~= Vec3(9, 9, 9);   // unreferenced
    Session s;
    s.step(m);
    m.vertices = m.vertices[0 .. $ - 1];
    // Nothing referenced moved: only the vertex-count stamp can see it.
    assert(s.step(m) && s.cache.lastFull,
        "a vertex-count shrink must take the full pass");
    const want = fullCorners(m);
    assert(firstDiff(s.corner[0 .. want.length], want) < 0, "after a vertex-count shrink the corners are stale");
}

unittest { // stale cache: a grown vertex array (same layout) recomputes all
    auto m = hingedPatch();
    Session s;
    s.step(m);
    // An unreferenced vertex appended: nothing else moved. The cache's
    // position copy is one short, so only a full pass may read the new length.
    m.vertices ~= Vec3(9, 9, 9);
    assert(s.step(m) && s.cache.lastFull,
        "a vertex-count change must take the full pass");
    const want = fullCorners(m);
    assert(firstDiff(s.corner[0 .. want.length], want) < 0, "after a vertex-count change the corners are stale");
}

unittest { // the switch to the full pass: above a quarter of the vertices moved
    // 30 vertices: 7 moved (28 <= 30) stays incremental, 8 (32 > 30) goes full.
    foreach (moved; [7, 8, 30]) {
        auto m = hingedPatch();
        Session s;
        s.step(m);
        foreach (v; 0 .. moved) m.vertices[v].y += 0.25f;
        immutable bool full = s.step(m);
        assert(full == (moved > 7),
            format("%d of 30 vertices moved: expected %s pass, got %s", moved,
                   moved > 7 ? "the full" : "an incremental", full ? "full" : "incremental"));
        const want = fullCorners(m);
        assert(firstDiff(s.corner[0 .. want.length], want) < 0,
            format("%d moved: corners differ from the full pass", moved));
    }
}

// ---------------------------------------------------------------------------
// S1e: per-surface smoothing policy. The pair (f, g) at a vertex is decided by
// the surface of the LOWER effective slot, for BOTH faces (owner ruling 1).
// The cells hold in-test copies of the ruling and of five losers, and first
// assert that every loser is separated from the ruling by some cell.

private enum Rule { Ruling, HS, F, M, FI, ASYM }

/// The pair threshold under `r` (in-test copies; `Ruling` is the shipped rule).
private float pairCos(Rule r, const ref SmoothPolicy p, size_t fi, size_t g) {
    immutable uint sf = p.faceSlot[fi], sg = p.faceSlot[g];
    immutable uint lo = sf < sg ? sf : sg, hi = sf < sg ? sg : sf;
    final switch (r) {
        case Rule.Ruling: return p.slotCos[lo];
        case Rule.HS:     return p.slotCos[hi];
        case Rule.F:      return p.slotCos[sf];
        case Rule.M:      return p.slotCos[sf] > p.slotCos[sg] ? p.slotCos[sf] : p.slotCos[sg];
        case Rule.FI:     return p.slotCos[fi < g ? sf : sg];
        case Rule.ASYM:   return p.slotCos[lo] == kSmoothOff ? p.slotCos[sf] : p.slotCos[lo];
    }
}

/// The corner of face `fi` at vertex `v` under rule `r`, from first principles
/// (face normals by `faceN`, every face at `v` — edge or vertex-only).
private Vec3 predictCorner(Rule r, const ref Mesh m, const ref SmoothPolicy p, size_t fi, uint v) {
    immutable Vec3 nf = faceN(m, fi);
    double sx = nf.x, sy = nf.y, sz = nf.z;
    foreach (g, f; m.faces) {
        if (g == fi) continue;
        bool at;
        foreach (w; f) if (w == v) at = true;
        if (!at) continue;
        immutable Vec3 ng = faceN(m, g);
        if (ng.x * nf.x + ng.y * nf.y + ng.z * nf.z < pairCos(r, p, fi, g)) continue;
        sx += ng.x; sy += ng.y; sz += ng.z;
    }
    return nrm(Vec3(cast(float)sx, cast(float)sy, cast(float)sz));
}

/// A two-face 30° hinge whose faces carry slots `slotL`, `slotR` over `surfs`.
private Mesh hingeSlots(uint slotL, uint slotR, Surface[] surfs) {
    Mesh m = hinge(30.0);
    m.faceMaterial = [slotL, slotR];
    m.surfaces = surfs;
    return m;
}

private Surface surf(float angle, bool on = true) {
    Surface s;
    s.smoothing = on;
    s.smoothingAngleDeg = angle;
    return s;
}

/// The 2×2 grid around the centre vertex 4 (faces f0..f3 in ring order; f0–f2
/// and f1–f3 share ONLY the centre), bent so every pairwise normal angle is
/// distinct and under 20°. `slots[k]` = face k's slot.
private Mesh grid2x2(uint[4] slots, Surface[] surfs) {
    Mesh m;
    immutable float[9] z = [0.06f, 0.03f, -0.048f, -0.018f, 0.0f, 0.072f, 0.09f, -0.036f, 0.012f];
    foreach (j; 0 .. 3) foreach (i; 0 .. 3)
        m.vertices ~= Vec3(i - 1.0f, j - 1.0f, z[j * 3 + i]);
    m.faces ~= [0u, 1, 4, 3];   // f0 lower-left
    m.faces ~= [1u, 2, 5, 4];   // f1 lower-right
    m.faces ~= [4u, 5, 8, 7];   // f2 upper-right
    m.faces ~= [3u, 4, 7, 6];   // f3 upper-left
    m.faceMaterial = slots[].dup;
    m.surfaces = surfs;
    return m;
}

private struct RulingCell {
    string name;
    Mesh   m;
    size_t face;
    uint   vert;
    bool   rulingSmooth;   // the prediction stated in the plan (smooth vs own flat)
}

private RulingCell[] rulingCells() {
    RulingCell[] c;
    // Hinge cells (face 0 = L, face 1 = R; the shared edge is vertices 0, 1).
    c ~= RulingCell("a",    hingeSlots(0, 1, [surf(40), surf(40)]), 0, 0, true);
    c ~= RulingCell("b",    hingeSlots(0, 1, [surf(60), surf(20)]), 0, 0, true);
    c ~= RulingCell("b-R",  hingeSlots(0, 1, [surf(60), surf(20)]), 1, 0, true);
    c ~= RulingCell("b3",   hingeSlots(0, 1, [surf(20), surf(60)]), 0, 0, false);
    c ~= RulingCell("b3-R", hingeSlots(0, 1, [surf(20), surf(60)]), 1, 0, false);
    c ~= RulingCell("sw",   hingeSlots(1, 0, [surf(20), surf(60)]), 0, 0, false);
    c ~= RulingCell("sw-R", hingeSlots(1, 0, [surf(20), surf(60)]), 1, 0, false);
    c ~= RulingCell("c1",   hingeSlots(0, 1, [surf(40, false), surf(40)]), 0, 0, false);
    c ~= RulingCell("c1-R", hingeSlots(0, 1, [surf(40, false), surf(40)]), 1, 0, false);
    c ~= RulingCell("c2",   hingeSlots(0, 1, [surf(40), surf(40, false)]), 0, 0, true);
    c ~= RulingCell("c2-R", hingeSlots(0, 1, [surf(40), surf(40, false)]), 1, 0, true);
    c ~= RulingCell("c2sw", hingeSlots(1, 0, [surf(40), surf(40, false)]), 0, 0, true);
    c ~= RulingCell("c2sw-R", hingeSlots(1, 0, [surf(40), surf(40, false)]), 1, 0, true);
    // Vertex-only cells on the 2×2 grid, at the centre vertex 4.
    c ~= RulingCell("V1-f0", grid2x2([0, 1, 1, 1], [surf(40, false), surf(40)]), 0, 4, false);
    c ~= RulingCell("V1-f2", grid2x2([0, 1, 1, 1], [surf(40, false), surf(40)]), 2, 4, true);
    c ~= RulingCell("V2-f0", grid2x2([1, 1, 0, 1], [surf(40), surf(40, false)]), 0, 4, true);
    return c;
}

unittest { // the ruling cells: rig premises, then the discrimination floor, then production
    auto cells = rulingCells();
    assert(cells.length == 16, format("ruling cell population %d, expected 16", cells.length));
    // Grid premise: every pairwise normal angle distinct and < 20°.
    {
        auto g = grid2x2([0, 0, 0, 0], [surf(40)]);
        double[] seen;
        foreach (a; 0 .. 4) foreach (b; a + 1 .. 4) {
            immutable Vec3 na = faceN(g, a), nb = faceN(g, b);
            immutable double d = na.x * nb.x + na.y * nb.y + na.z * nb.z;
            assert(d > cos(20.0 * PI / 180), format("grid premise: faces %d, %d are %.2f° apart",
                a, b, acosDeg(d)));
            foreach (o; seen) assert(abs(o - d) > 1e-4, "grid premise: two pairs share an angle");
            seen ~= d;
        }
    }
    // Discrimination floor [E4]: each loser differs from the ruling in some cell.
    foreach (r; [Rule.HS, Rule.F, Rule.M, Rule.FI, Rule.ASYM]) {
        bool separated;
        foreach (ref c; cells) {
            const p = policyOf(c.m);
            if (!near(predictCorner(r, c.m, p, c.face, c.vert),
                      predictCorner(Rule.Ruling, c.m, p, c.face, c.vert), 1e-3f))
                separated = true;
        }
        assert(separated, format("discrimination floor: no cell separates the loser %s from the ruling", r));
    }
    // The stated predictions agree with the in-test ruling (smooth = differs from own flat).
    foreach (ref c; cells) {
        const p = policyOf(c.m);
        immutable bool smooth = !near(predictCorner(Rule.Ruling, c.m, p, c.face, c.vert),
                                      faceN(c.m, c.face), 1e-3f);
        assert(smooth == c.rulingSmooth, format("cell %s: the ruling predicts %s, the plan states %s",
            c.name, smooth ? "smooth" : "flat", c.rulingSmooth ? "smooth" : "flat"));
    }
}

private double acosDeg(double d) { import std.math : acos; return acos(d) * 180 / PI; }

unittest { // production == the ruling, per cell (each cell runnable alone: VIBE3D_CELL)
    size_t ran;
    foreach (ref c; rulingCells()) {
        if (!cellOn("ruling-" ~ c.name)) continue;
        FaceAdjacency adj;
        auto got = corners(c.m, adj);
        const p = policyOf(c.m);
        immutable Vec3 want = predictCorner(Rule.Ruling, c.m, p, c.face, c.vert);
        immutable Vec3 g = cornerOf(c.m, got, c.face, c.vert);
        assert(near(g, want), format("ruling cell %s: face %d corner at vertex %d is %s, the lower-slot "
            ~ "rule predicts %s (%s)", c.name, c.face, c.vert, g, want, c.rulingSmooth ? "smooth" : "flat"));
        ++ran;
    }
    assert(ran > 0, "VIBE3D_CELL names no ruling cell");
}

/// Within one float ulp (`smoothCorner` renormalises a lone face normal).
private bool ulpNear(Vec3 a, Vec3 b) {
    return abs(a.x - b.x) <= float.epsilon && abs(a.y - b.y) <= float.epsilon
        && abs(a.z - b.z) <= float.epsilon;
}

unittest { // one surface OFF: every corner is its face's flat normal
    if (!cellOn("off-all")) return;
    auto m = hingedPatch();
    m.surfaces = [surf(kDefaultSmoothingAngleDeg, false)];
    FaceAdjacency adj;
    auto c = corners(m, adj);
    size_t n;
    foreach (fi, f; m.faces) foreach (v; f) ++n;
    assert(n == faceCornerTotal(m) && n == 80, format("off floor: %d corners", n));
    // The rig smooths somewhere under the default (else OFF is unwitnessed).
    auto on = hingedPatch();
    FaceAdjacency adj2;
    auto cOn = corners(on, adj2);
    size_t moved;
    foreach (fi, f; m.faces) foreach (v; f)
        if (!near(cornerOf(on, cOn, fi, v), faceN(on, fi), 1e-3f)) ++moved;
    assert(moved > 0, "off premise: the patch has no smoothed corner under the default");
    foreach (fi, f; m.faces) foreach (v; f)
        assert(ulpNear(cornerOf(m, c, fi, v), faceN(m, fi)),
            format("off: face %d corner at %d is %s, flat is %s", fi, v, cornerOf(m, c, fi, v), faceN(m, fi)));
}

unittest { // a non-finite angle is OFF; an angle above 180 clamps to 180
    if (!cellOn("angle-domain")) return;
    {
        auto m = hingeSlots(0, 0, [surf(float.nan)]);
        FaceAdjacency adj;
        auto c = corners(m, adj);
        assert(ulpNear(cornerOf(m, c, 0, 0), faceN(m, 0)), "NaN angle: the 30° hinge smoothed — NaN is not OFF");
    }
    {
        // A 170° hinge: cos(200°) = -0.94 would keep it hard, the 180° clamp smooths it.
        Mesh m = hinge(170.0);
        m.surfaces = [surf(200)];
        FaceAdjacency adj;
        auto c = corners(m, adj);
        assert(!near(cornerOf(m, c, 0, 0), faceN(m, 0), 1e-3f),
            "angle 200: the 170° hinge stayed hard — the angle is not clamped to 180°");
    }
}

unittest { // the EFFECTIVE slot orders the pair: faceMaterial 70 reads slot 0
    if (!cellOn("slot-70")) return;
    auto m = hingeSlots(70, 1, [surf(40, false), surf(40)]);
    const p = policyOf(m);
    assert(p.faceSlot[0] == 0, format("slot rule: faceMaterial 70 maps to slot %d", p.faceSlot[0]));
    assert(70 >= kSurfaceSlots, "slot premise: 70 is a valid slot");
    FaceAdjacency adj;
    auto c = corners(m, adj);
    assert(ulpNear(cornerOf(m, c, 1, 0), faceN(m, 1)),
        "faceMaterial 70: the pair smoothed — the effective slot 0 (OFF) did not decide");
}

/// The 3×3 quad grid (4×4 vertices) with slots 0/1/2 placed so every slot
/// pair meets at a vertex-only diagonal; 0 OFF, 1 @40, 2 @60; a bumpy surface.
private Mesh grid3x3Slots() {
    Mesh m;
    foreach (j; 0 .. 4) foreach (i; 0 .. 4)
        m.vertices ~= Vec3(i, j, cast(float)(0.7 * sin(1.3 * i + 0.4 * j) + 0.5 * cos(1.1 * j) * i * 0.4));
    immutable uint[9] slot = [0, 1, 2,  2, 0, 1,  1, 2, 0];
    foreach (r; 0 .. 3) foreach (cc; 0 .. 3) {
        immutable uint a = cast(uint)(r * 4 + cc);
        m.faces ~= [a, a + 1, a + 5, a + 4];
        m.faceMaterial ~= slot[r * 3 + cc];
    }
    m.surfaces = [surf(40, false), surf(40), surf(60)];
    return m;
}

unittest { // full == incremental, bit-identical, on the three-slot grid
    if (!cellOn("full-incremental-slots")) return;
    auto m = grid3x3Slots();
    // Floor from the rig: a vertex-only cross-slot pair for every slot pair.
    bool[3][3] pairSeen;
    foreach (r; 0 .. 2) foreach (cc; 0 .. 3) {
        foreach (dc; [-1, 1]) {
            immutable int c2 = cast(int)cc + dc;
            if (c2 < 0 || c2 > 2) continue;
            immutable uint sa = m.faceMaterial[r * 3 + cc], sb = m.faceMaterial[(r + 1) * 3 + c2];
            if (sa != sb) pairSeen[sa < sb ? sa : sb][sa < sb ? sb : sa] = true;
        }
    }
    assert(pairSeen[0][1] && pairSeen[0][2] && pairSeen[1][2],
        "grid floor: some slot pair has no vertex-only diagonal");
    Session s;
    assert(s.step(m), "the first update must be full");
    foreach (v; [0u, 1u, 3u]) m.vertices[v].z += 0.35f;   // one row: faces 0..5 re-fan
    immutable bool full = s.step(m);
    assert(!full && s.cache.writeCount > 0 && s.cache.writeCount < m.faces.length,
        format("three-slot grid: the 3-vertex move did not take the incremental path (full=%s, faces=%d)",
               full, s.cache.writeCount));
    const want = fullCorners(m);
    immutable d = firstDiff(s.corner[0 .. want.length], want);
    assert(d < 0, format("three-slot grid: incremental corner float %d differs from the full pass", d));
}
