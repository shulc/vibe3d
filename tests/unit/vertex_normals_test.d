// The smooth normal stream's kernel (`vertex_normals`, task 9070) and the one
// normal matrix (`math.normalMatrix`). Law (captured, viewport shading S0 C3/C6):
// angle split at `kSmoothingAngleDeg` between face normals, uniform weighting,
// hidden faces contribute, degenerate faces do not. The hinge cells sit at
// θ ± 10 as EXPRESSIONS of the constant, so a re-captured θ moves them along.
module tests.unit.vertex_normals_test;

import std.format : format;
import std.math   : abs, cos, sin, sqrt, isFinite, PI;

import math : Vec3, normalMatrix;
import mesh : Mesh;
import vertex_normals : FaceAdjacency, buildFaceAdjacency, cornerSmoothNormals,
    faceCornerTotal, smoothingCosine, kSmoothingAngleDeg, MAX_SMOOTH_VALENCE;

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
    cornerSmoothNormals(m, m.vertices, adj, smoothingCosine(), scratch, out_);
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
    Mesh m = hinge(kSmoothingAngleDeg - 10.0);
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
    Mesh m = hinge(kSmoothingAngleDeg + 10.0);
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
        assert(na.x * nb.x + na.y * nb.y + na.z * nb.z >= smoothingCosine(),
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
    assert(abs((25.0 - -5.0) - (kSmoothingAngleDeg - 10.0)) < 1e-9, "degenerate premise: dihedral is not θ-10");
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
        assert(faceN(m, f).y > cos(kSmoothingAngleDeg * PI / 180),
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
    Mesh m = hinge(kSmoothingAngleDeg - 10.0);
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
    Mesh m = hinge(kSmoothingAngleDeg - 10.0);
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
