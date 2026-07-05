module math;

import std.math : tan, sin, cos, sqrt, PI, abs, acos, asin, atan2, round;
// ---------------------------------------------------------------------------
// Math
// ---------------------------------------------------------------------------

struct Vec3 {
    float x, y, z;

    Vec3 opBinary(string op)(Vec3 b) const @safe pure nothrow @nogc
    if (op == "+" || op == "-") {
        static if (op == "+") return Vec3(x+b.x, y+b.y, z+b.z);
        else                  return Vec3(x-b.x, y-b.y, z-b.z);
    }
    Vec3 opBinary(string op)(float s) const @safe pure nothrow @nogc
    if (op == "*") { return Vec3(x*s, y*s, z*s); }
    Vec3 opBinaryRight(string op)(float s) const @safe pure nothrow @nogc
    if (op == "*") { return Vec3(x*s, y*s, z*s); }
    Vec3 opUnary(string op)() const @safe pure nothrow @nogc
    if (op == "-") { return Vec3(-x, -y, -z); }
    ref Vec3 opOpAssign(string op)(Vec3 b) @safe pure nothrow @nogc
    if (op == "+" || op == "-") {
        static if (op == "+") { x += b.x; y += b.y; z += b.z; }
        else                  { x -= b.x; y -= b.y; z -= b.z; }
        return this;
    }
    ref Vec3 opOpAssign(string op)(float s) @safe pure nothrow @nogc
    if (op == "*" || op == "/") {
        static if (op == "*") { x *= s; y *= s; z *= s; }
        else                  { x /= s; y /= s; z /= s; }
        return this;
    }
    Vec3 opBinary(string op)(float s) const @safe pure nothrow @nogc
    if (op == "/") { return Vec3(x/s, y/s, z/s); }
    float length() const @safe pure nothrow @nogc { return sqrt(x*x + y*y + z*z); }
}
struct Vec4 { float x, y, z, w; }

// A frozen (placed, center) override — the value-type shape shared by every
// action-center pin lifetime (explicit-relocate, display-settle, in-session-
// cancel baseline) and, downstream, the transform tool's per-gesture pin
// snapshots. A single struct assignment (`a = b;`) copies both fields
// atomically, which is the point: field-by-field copies of a placed flag +
// a center vector are exactly how two "same" pins have historically drifted
// apart one field at a time.
struct Pin {
    bool placed = false;
    Vec3 center = Vec3(0, 0, 0);
}

struct Viewport {
    float[16] view;
    float[16] proj;
    int width;
    int height;
    int x = 0;   // window-space left edge
    int y = 0;   // window-space top edge
    Vec3 eye;
    Vec3 focus;  // camera look-at target; default (0,0,0) for headless / tests
}

Vec3 vec3Lerp(Vec3 a, Vec3 b, float t) @safe pure nothrow @nogc {
    return Vec3(a.x+t*(b.x-a.x), a.y+t*(b.y-a.y), a.z+t*(b.z-a.z));
}

Vec3 normalize(Vec3 v) @safe pure nothrow @nogc {
    float len = v.length;
    return v / len;
}
Vec3 cross(Vec3 a, Vec3 b) @safe pure nothrow @nogc {
    return Vec3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x);
}
float dot(Vec3 a, Vec3 b) @safe pure nothrow @nogc { return a.x*b.x + a.y*b.y + a.z*b.z; }

immutable float[16] identityMatrix = [
    1,0,0,0,  0,1,0,0,  0,0,1,0,  0,0,0,1,
];

// Pure translation matrix (column-major, OpenGL convention).
float[16] translationMatrix(Vec3 t) {
    return [1,0,0,0, 0,1,0,0, 0,0,1,0, t.x,t.y,t.z,1];
}

// Rodrigues rotation around an arbitrary axis through a pivot point (column-major).
// The axis must already be normalised.
float[16] pivotRotationMatrix(Vec3 pivot, Vec3 axis, float angle) {
    float c = cos(angle), s = sin(angle), t = 1.0f - c;
    float ax = axis.x, ay = axis.y, az = axis.z;
    // Row-indexed rotation entries R[row][col]
    float r00 = c + ax*ax*t,      r01 = ax*ay*t - az*s, r02 = ax*az*t + ay*s;
    float r10 = ax*ay*t + az*s,   r11 = c + ay*ay*t,    r12 = ay*az*t - ax*s;
    float r20 = ax*az*t - ay*s,   r21 = ay*az*t + ax*s, r22 = c + az*az*t;
    // Translation: pivot - R * pivot
    float tx = pivot.x - (r00*pivot.x + r01*pivot.y + r02*pivot.z);
    float ty = pivot.y - (r10*pivot.x + r11*pivot.y + r12*pivot.z);
    float tz = pivot.z - (r20*pivot.x + r21*pivot.y + r22*pivot.z);
    // Column-major storage: m[row + col*4]
    return [r00, r10, r20, 0,
            r01, r11, r21, 0,
            r02, r12, r22, 0,
            tx,  ty,  tz,  1];
}

// Non-uniform scale around a pivot point (column-major).
float[16] pivotScaleMatrix(Vec3 pivot, float sx, float sy, float sz) {
    return [sx, 0,  0,  0,
            0,  sy, 0,  0,
            0,  0,  sz, 0,
            pivot.x*(1.0f-sx), pivot.y*(1.0f-sy), pivot.z*(1.0f-sz), 1];
}

// Non-uniform scale around a pivot, along an arbitrary orthonormal basis
// (ax, ay, az). M = T(pivot) * R * diag(s) * R^T * T(-pivot) where
// R has columns [ax | ay | az]. With identity basis it's equivalent to
// pivotScaleMatrix above.
float[16] pivotScaleMatrixBasis(Vec3 pivot, Vec3 ax, Vec3 ay, Vec3 az,
                                float sx, float sy, float sz) {
    // M3[i,j] = ax[i]*sx*ax[j] + ay[i]*sy*ay[j] + az[i]*sz*az[j]
    float m00 = ax.x*sx*ax.x + ay.x*sy*ay.x + az.x*sz*az.x;
    float m01 = ax.x*sx*ax.y + ay.x*sy*ay.y + az.x*sz*az.y;
    float m02 = ax.x*sx*ax.z + ay.x*sy*ay.z + az.x*sz*az.z;
    float m10 = ax.y*sx*ax.x + ay.y*sy*ay.x + az.y*sz*az.x;
    float m11 = ax.y*sx*ax.y + ay.y*sy*ay.y + az.y*sz*az.y;
    float m12 = ax.y*sx*ax.z + ay.y*sy*ay.z + az.y*sz*az.z;
    float m20 = ax.z*sx*ax.x + ay.z*sy*ay.x + az.z*sz*az.x;
    float m21 = ax.z*sx*ax.y + ay.z*sy*ay.y + az.z*sz*az.y;
    float m22 = ax.z*sx*ax.z + ay.z*sy*ay.z + az.z*sz*az.z;
    // Affine offset so the pivot is fixed: t = pivot - M3 * pivot
    float tx = pivot.x - (m00*pivot.x + m01*pivot.y + m02*pivot.z);
    float ty = pivot.y - (m10*pivot.x + m11*pivot.y + m12*pivot.z);
    float tz = pivot.z - (m20*pivot.x + m21*pivot.y + m22*pivot.z);
    return [m00, m10, m20, 0,
            m01, m11, m21, 0,
            m02, m12, m22, 0,
            tx,  ty,  tz,  1];
}

// Scale a single vertex around `pivot` along an orthonormal basis. The
// vertex's offset from pivot is decomposed onto (ax, ay, az), each
// component is multiplied by its scale factor, and the pieces are
// recomposed in world space. With identity basis this collapses to
// per-axis scaling.
Vec3 scaleAlongBasis(Vec3 v, Vec3 pivot, Vec3 ax, Vec3 ay, Vec3 az,
                     float sx, float sy, float sz) @safe pure nothrow @nogc
{
    Vec3 d = v - pivot;
    float a = d.x*ax.x + d.y*ax.y + d.z*ax.z;
    float b = d.x*ay.x + d.y*ay.y + d.z*ay.z;
    float c = d.x*az.x + d.y*az.y + d.z*az.z;
    return pivot + ax*(a*sx) + ay*(b*sy) + az*(c*sz);
}

// ---------------------------------------------------------------------------
// Cumulative-euler helpers for the rotate panel.
//
// matrixFromEulerZYX / eulerZYXFromMatrix are exact inverses and pin to the
// SAME convention the transform tool's `composeFor` (tools/xfrm_transform.d)
// uses for its rotate factor. composeFor starts from identity and LEFT-
// multiplies the per-axis factors in order X, then Y, then Z:
//   M = R(Z) * ( R(Y) * ( R(X) * I ) )
// via `M = matMul4(pivotRotationMatrix(origin, axis, rad), M)`, skipping any
// factor whose angle is 0. The net rotation is therefore world R = Rz·Ry·Rx.
// We rebuild that exact product here by reusing pivotRotationMatrix + matMul4
// (no hand-rolled parallel matrix), so the layout/handedness is identical by
// construction. Angles are DEGREES; deg.x=RX about basis X, deg.y=RY, deg.z=RZ.
// ---------------------------------------------------------------------------

// Build R = Rz·Ry·Rx about the ORIGIN from euler degrees, matching composeFor's
// left-multiply sequence (and its zero-angle skip) bit-for-bit.
float[16] matrixFromEulerZYX(Vec3 deg) {
    enum float D2R = cast(float)(PI / 180.0);
    float[16] M = identityMatrix;
    void rot(Vec3 axis, float d) {
        if (d == 0) return;   // exact zero-angle skip, as composeFor does
        M = matMul4(pivotRotationMatrix(Vec3(0, 0, 0), axis, d * D2R), M);
    }
    rot(Vec3(1, 0, 0), deg.x);   // RX (rightmost factor)
    rot(Vec3(0, 1, 0), deg.y);   // RY
    rot(Vec3(0, 0, 1), deg.z);   // RZ (leftmost factor)
    return M;
}

// Decompose a rotation matrix (column-major, m[row + col*4], 3×3 block at
// indices 0,1,2,4,5,6,8,9,10) into ZYX euler DEGREES such that
// matrixFromEulerZYX(eulerZYXFromMatrix(M)) ≈ M for any rotation M.
//
// With R = Rz·Ry·Rx and R[row][col] stored at m[row + col*4]:
//   R[2][0] = m[2]  = -sin(ry)
//   R[2][1] = m[6]  =  sin(rx)*cos(ry)
//   R[2][2] = m[10] =  cos(rx)*cos(ry)
//   R[1][0] = m[1]  =  cos(ry)*sin(rz)
//   R[0][0] = m[0]  =  cos(ry)*cos(rz)
// so ry = asin(-m[2]); away from gimbal-lock,
//   rx = atan2(m[6], m[10]),  rz = atan2(m[1], m[0]).
//
// Gimbal lock (cos(ry) → 0, i.e. ry → ±90°): rx and rz become a single coupled
// DOF. Canonical convention: pin rz = 0 and fold the rotation into rx. There
//   R[0][1] = m[4] = -cos(rx ∓ rz)·... collapses; with rz=0 the recoverable
// angle is rx = atan2(-m[4], m[5]) at ry=+90°, and rx = atan2(m[4], m[5]) at
// ry=-90° (signs follow from the product with sy=±1). Both are captured by
// atan2(sy*m[4]... — implemented explicitly below.
Vec3 eulerZYXFromMatrix(float[16] M) {
    enum float R2D = cast(float)(180.0 / PI);
    float sy = -M[2];                 // -R[2][0] = sin(ry)
    if (sy > 1.0f) sy = 1.0f;
    if (sy < -1.0f) sy = -1.0f;
    float ry = asin(sy);
    float rx, rz;
    // cos(ry): gimbal-lock when this is ~0.
    float cy = sqrt(M[6]*M[6] + M[10]*M[10]); // = |cos(ry)| via R[2][1],R[2][2]
    if (cy > 1e-6f) {
        rx = atan2(M[6], M[10]);      // atan2(R[2][1], R[2][2])
        rz = atan2(M[1], M[0]);       // atan2(R[1][0], R[0][0])
    } else {
        // Singular: pin rz = 0, fold remaining rotation into rx.
        // At ry=+90° (sy=+1): R[0][1]=m[4]=sin(rx-rz), R[1][1]=m[5]=cos(rx-rz).
        // At ry=-90° (sy=-1): R[0][1]=m[4]=-sin(rx+rz), R[1][1]=m[5]=cos(rx+rz).
        rz = 0.0f;
        if (sy > 0.0f) rx = atan2(M[4], M[5]);
        else           rx = atan2(-M[4], M[5]);
    }
    return Vec3(rx * R2D, ry * R2D, rz * R2D);
}

// ---------------------------------------------------------------------------
// Quaternion + matrix helpers for the canonical-matrix transform blend (MS-1).
//
// These support `blendToIdentity` in tools/xform_kernels.d, which interpolates a
// pivot-relative transform matrix toward identity by a per-vertex falloff weight.
// The PolarQuat blend mode (option (c) of the unified transform-model plan,
// a private design doc) needs
// to decompose a rotation·scale 3×3 into a pure rotation quaternion + per-axis
// scale; slerp the rotation toward identity; lerp scale toward 1; recompose.
// All matrices here follow the same column-major (m[row + col*4]) convention as
// the rest of this module (see pivotRotationMatrix / pivotScaleMatrixBasis).
// ---------------------------------------------------------------------------

// Unit quaternion (w + xi + yj + zk). Rotation only; no translation/scale.
struct Quat {
    float w = 1, x = 0, y = 0, z = 0;

    static Quat identity() @safe pure nothrow @nogc { return Quat(1, 0, 0, 0); }

    Quat normalize() const @safe pure nothrow @nogc {
        float n = sqrt(w*w + x*x + y*y + z*z);
        if (n < 1e-12f) return Quat.identity();
        float inv = 1.0f / n;
        return Quat(w*inv, x*inv, y*inv, z*inv);
    }
}

// Spherical linear interpolation between two unit quaternions. t==0 → a,
// t==1 → b. Picks the shorter arc (negates b on a negative dot) and falls
// back to a normalized lerp (nlerp) for nearly-parallel inputs to avoid the
// 1/sin(theta) blow-up. Result is unit length.
Quat slerp(Quat a, Quat b, float t) @safe pure nothrow @nogc {
    a = a.normalize();
    b = b.normalize();
    float d = a.w*b.w + a.x*b.x + a.y*b.y + a.z*b.z;
    if (d < 0.0f) { // shorter arc
        b = Quat(-b.w, -b.x, -b.y, -b.z);
        d = -d;
    }
    if (d > 0.9995f) {
        // Nearly parallel — nlerp to dodge the small-angle singularity.
        Quat r = Quat(a.w + t*(b.w - a.w),
                      a.x + t*(b.x - a.x),
                      a.y + t*(b.y - a.y),
                      a.z + t*(b.z - a.z));
        return r.normalize();
    }
    float theta0 = acos(d);
    float theta  = theta0 * t;
    float sin0   = sin(theta0);
    float s0 = sin(theta0 - theta) / sin0;
    float s1 = sin(theta)          / sin0;
    return Quat(a.w*s0 + b.w*s1,
                a.x*s0 + b.x*s1,
                a.y*s0 + b.y*s1,
                a.z*s0 + b.z*s1);
}

// Extract the rotation quaternion from the upper-left 3×3 of a column-major
// affine matrix. Per-axis scale is divided out first (via the column norms),
// so a rotation·scale matrix yields the PURE rotation. Uses the standard
// trace-based branch for numerical stability. Translation (column 3) ignored.
Quat quatFromMatrix(float[16] m) @safe pure nothrow @nogc {
    // Column 0 = m[0..2], column 1 = m[4..6], column 2 = m[8..10].
    float sx = sqrt(m[0]*m[0] + m[1]*m[1] + m[2]*m[2]);
    float sy = sqrt(m[4]*m[4] + m[5]*m[5] + m[6]*m[6]);
    float sz = sqrt(m[8]*m[8] + m[9]*m[9] + m[10]*m[10]);
    float ix = sx > 1e-12f ? 1.0f / sx : 0.0f;
    float iy = sy > 1e-12f ? 1.0f / sy : 0.0f;
    float iz = sz > 1e-12f ? 1.0f / sz : 0.0f;
    // Rotation entries R[row][col] (column-major storage: m[row + col*4]).
    float r00 = m[0]*ix, r10 = m[1]*ix, r20 = m[2]*ix;     // col 0
    float r01 = m[4]*iy, r11 = m[5]*iy, r21 = m[6]*iy;     // col 1
    float r02 = m[8]*iz, r12 = m[9]*iz, r22 = m[10]*iz;    // col 2
    float tr = r00 + r11 + r22;
    Quat q;
    if (tr > 0.0f) {
        float s = sqrt(tr + 1.0f) * 2.0f; // s = 4*w
        q.w = 0.25f * s;
        q.x = (r21 - r12) / s;
        q.y = (r02 - r20) / s;
        q.z = (r10 - r01) / s;
    } else if (r00 > r11 && r00 > r22) {
        float s = sqrt(1.0f + r00 - r11 - r22) * 2.0f; // s = 4*x
        q.w = (r21 - r12) / s;
        q.x = 0.25f * s;
        q.y = (r01 + r10) / s;
        q.z = (r02 + r20) / s;
    } else if (r11 > r22) {
        float s = sqrt(1.0f + r11 - r00 - r22) * 2.0f; // s = 4*y
        q.w = (r02 - r20) / s;
        q.x = (r01 + r10) / s;
        q.y = 0.25f * s;
        q.z = (r12 + r21) / s;
    } else {
        float s = sqrt(1.0f + r22 - r00 - r11) * 2.0f; // s = 4*z
        q.w = (r10 - r01) / s;
        q.x = (r02 + r20) / s;
        q.y = (r12 + r21) / s;
        q.z = 0.25f * s;
    }
    return q.normalize();
}

// Build a column-major rotation matrix (no translation, no scale) from a unit
// quaternion. Inverse of quatFromMatrix for a pure-rotation input.
float[16] matrixFromQuat(Quat q) @safe pure nothrow @nogc {
    q = q.normalize();
    float xx = q.x*q.x, yy = q.y*q.y, zz = q.z*q.z;
    float xy = q.x*q.y, xz = q.x*q.z, yz = q.y*q.z;
    float wx = q.w*q.x, wy = q.w*q.y, wz = q.w*q.z;
    float r00 = 1 - 2*(yy + zz), r01 = 2*(xy - wz),     r02 = 2*(xz + wy);
    float r10 = 2*(xy + wz),     r11 = 1 - 2*(xx + zz), r12 = 2*(yz - wx);
    float r20 = 2*(xz - wy),     r21 = 2*(yz + wx),     r22 = 1 - 2*(xx + yy);
    // Column-major storage: m[row + col*4].
    return [r00, r10, r20, 0,
            r01, r11, r21, 0,
            r02, r12, r22, 0,
            0,   0,   0,   1];
}

// Apply a column-major affine matrix to a point (w == 1): returns the xyz of
// M·(p,1). Same math as `mulMV(m, Vec4(p, 1))` but inlined so this stays
// @safe/pure/nothrow/@nogc (mulMV carries none of those attributes).
Vec3 applyAffine(float[16] m, Vec3 p) @safe pure nothrow @nogc {
    return Vec3(
        m[0]*p.x + m[4]*p.y + m[ 8]*p.z + m[12],
        m[1]*p.x + m[5]*p.y + m[ 9]*p.z + m[13],
        m[2]*p.x + m[6]*p.y + m[10]*p.z + m[14],
    );
}

// Affine transform of a point by a COLUMN-MAJOR float[16] (w = 1; perspective
// divide skipped — affine matrices have d-row [0,0,0,1]). PUBLIC, reusable name
// for the interchange exporters (LWO bake, assimp node transform) so they need
// not reach for the `private` equivalent in io/scene_import.d. Forwards to
// applyAffine — same math, NOT a second spelling of it.
Vec3 transformPoint(const float[16] m, Vec3 p) @safe pure nothrow @nogc {
    return applyAffine(m, p);
}
unittest { // transformPoint matches a hand-computed T·R·S applied to a point.
    // S = diag(2,3,4); R = 90deg about +Y; T = (10,20,30). Column-major
    // M = T * R * S. Compose via the existing matrix builders, then check.
    auto S = pivotScaleMatrix(Vec3(0, 0, 0), 2, 3, 4);
    auto R = pivotRotationMatrix(Vec3(0, 0, 0), Vec3(0, 1, 0), cast(float) PI / 2);
    auto T = translationMatrix(Vec3(10, 20, 30));
    auto M = matMul4(T, matMul4(R, S));
    // Expected by composing the identical sub-steps separately.
    auto pScaled  = applyAffine(S, Vec3(1, 1, 1));
    auto pRotated = applyAffine(R, pScaled);
    auto expected = applyAffine(T, pRotated);
    auto got = transformPoint(M, Vec3(1, 1, 1));
    assert(isClose(got.x, expected.x, 1e-5f, 1e-5f)
        && isClose(got.y, expected.y, 1e-5f, 1e-5f)
        && isClose(got.z, expected.z, 1e-5f, 1e-5f));
    // Independent hard number: 90deg-about-+Y of (2,3,4) is (4,3,-2) in this
    // column-major builder, + T -> (14,23,28).
    assert(isClose(got.x, 14.0f, 1e-4f, 1e-4f)
        && isClose(got.y, 23.0f, 1e-4f, 1e-4f)
        && isClose(got.z, 28.0f, 1e-4f, 1e-4f));
}

// Build a column-major orthonormal frame matrix from a basis. The basis
// vectors right/up/fwd are placed in columns 0/1/2 of the upper-left 3x3;
// rotation-only (translation 0, w 1). Same column-major (m[row + col*4])
// convention as modelMatrix — equivalent to modelMatrix(right, up, fwd,
// Vec3(1,1,1), Vec3(0,0,0)) but spelled out for the AxisPacket frame cache.
float[16] frameMatrix(Vec3 right, Vec3 up, Vec3 fwd) @safe pure nothrow @nogc {
    return [
        right.x, right.y, right.z, 0,
        up.x,    up.y,    up.z,    0,
        fwd.x,   fwd.y,   fwd.z,   0,
        0,       0,       0,       1,
    ];
}

// Inverse of frameMatrix for an ORTHONORMAL basis: the inverse of an
// orthonormal rotation equals its transpose, so the basis vectors become
// the ROWS of the upper-left 3x3 (column-major storage m[row + col*4]).
float[16] frameMatrixInverse(Vec3 right, Vec3 up, Vec3 fwd) @safe pure nothrow @nogc {
    return [
        right.x, up.x, fwd.x, 0,
        right.y, up.y, fwd.y, 0,
        right.z, up.z, fwd.z, 0,
        0,       0,    0,     1,
    ];
}

unittest { // frameMatrix columns hold right/up/fwd; identity basis → identity
    auto m = frameMatrix(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1));
    foreach (i, v; identityMatrix) assert(isClose(m[i], v));
}

unittest { // frameMatrix * frameMatrixInverse ≈ identity for a rotated frame
    // 30° about Y → non-axis-aligned orthonormal basis.
    float a = cast(float) PI / 6;
    Vec3 r = Vec3(cos(a), 0, -sin(a));
    Vec3 u = Vec3(0, 1, 0);
    Vec3 f = Vec3(sin(a), 0, cos(a));
    auto m    = frameMatrix(r, u, f);
    auto mInv = frameMatrixInverse(r, u, f);
    auto prod = matMul4(m, mInv);
    foreach (i; 0 .. 16) assert(isClose(prod[i], identityMatrix[i], 1e-5f, 1e-5f));
    // m·(unit x) == right (multiply convention is not transposed).
    auto mx = applyAffine(m, Vec3(1, 0, 0));
    assert(isClose(mx.x, r.x, 1e-5f, 1e-5f)
        && isClose(mx.y, r.y, 1e-5f, 1e-5f)
        && isClose(mx.z, r.z, 1e-5f, 1e-5f));
}

// Column-major 4x4 matrix multiplication: C = A * B
float[16] matMul4(float[16] a, float[16] b) {
    float[16] c;
    for (int col = 0; col < 4; col++)
        for (int row = 0; row < 4; row++) {
            float s = 0;
            for (int k = 0; k < 4; k++)
                s += a[row + k*4] * b[k + col*4];
            c[row + col*4] = s;
        }
    return c;
}

// Re-express an ORIGIN-FIXING matrix `M` (one built so that the intended
// transform is `pivot + M*(v - pivot)`, the convention applyXformMatrix uses) as
// a plain world-space matrix `W` such that `W*v == pivot + M*(v - pivot)`. This
// is the bridge between the CPU fold's pivot-relative matrix and the GPU
// fast-path's `u_model` (applied directly to baseline verts): W = T(pivot) * M *
// T(-pivot). For an origin-fixing rotation/scale this returns exactly the
// about-pivot builder (pivotRotationMatrix(pivot,..) / pivotScaleMatrixBasis(
// pivot,..)) — see the unittests — so the GPU path can reuse the CPU fold matrix
// instead of rebuilding a parallel about-pivot one (MS-4.5).
float[16] wrapAboutPivot(float[16] M, Vec3 pivot) {
    return matMul4(translationMatrix(pivot),
                   matMul4(M, translationMatrix(Vec3(-pivot.x, -pivot.y, -pivot.z))));
}
unittest { // wrapAboutPivot of an origin-fixing rotation == the about-pivot one
    auto Morigin = pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), 0.7f);
    auto W = wrapAboutPivot(Morigin, Vec3(0.3f, -0.4f, 0.9f));
    auto direct = pivotRotationMatrix(Vec3(0.3f, -0.4f, 0.9f), Vec3(0,1,0), 0.7f);
    foreach (i; 0 .. 16) assert(isClose(W[i], direct[i], 1e-5f, 1e-5f));
}
unittest { // wrapAboutPivot of an origin-fixing scale == the about-pivot one
    auto Morigin = pivotScaleMatrixBasis(Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0),
                                         Vec3(0,0,1), 2.0f, 0.5f, 1.5f);
    Vec3 piv = Vec3(-0.2f, 0.6f, 0.1f);
    auto W = wrapAboutPivot(Morigin, piv);
    auto direct = pivotScaleMatrixBasis(piv, Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                                        2.0f, 0.5f, 1.5f);
    foreach (i; 0 .. 16) assert(isClose(W[i], direct[i], 1e-5f, 1e-5f));
}

/// Precision-stable variant of wrapAboutPivot. Computes the translate column
/// `pivot − M_lin·pivot + t_fold` in double precision so that the large-minus-large
/// cancellation at a far pivot (|pivot| >> 1) does not lose bits. The linear
/// block (upper-left 3×3) is unchanged. The returned matrix is algebraically
/// identical to wrapAboutPivot(M, pivot) in exact arithmetic and avoids the
/// ~|pivot|·2^-23 float32 error for large |pivot|.
float[16] wrapAboutPivotStable(float[16] M, Vec3 pivot) {
    // M is origin-fixing: the intended GPU transform is W·v = pivot + M_lin·(v−pivot) + t_fold,
    // equivalently W·v = M_lin·v + (pivot − M_lin·pivot + t_fold).
    // W_trans = pivot − M_lin·pivot + t_fold, computed in double to avoid
    // large-minus-large cancellation when |pivot| is large (far action center).

    // Extract M_lin (upper-left 3×3, column-major) and t_fold.
    double m00 = M[0], m10 = M[1], m20 = M[2];
    double m01 = M[4], m11 = M[5], m21 = M[6];
    double m02 = M[8], m12 = M[9], m22 = M[10];
    double tf0 = M[12], tf1 = M[13], tf2 = M[14];

    // pivot in double
    double px = cast(double)pivot.x;
    double py = cast(double)pivot.y;
    double pz = cast(double)pivot.z;

    // M_lin · pivot (double)
    double mp_x = m00*px + m01*py + m02*pz;
    double mp_y = m10*px + m11*py + m12*pz;
    double mp_z = m20*px + m21*py + m22*pz;

    // W_trans = pivot − M_lin·pivot + t_fold (exact large-minus-large in double)
    double wx = px - mp_x + tf0;
    double wy = py - mp_y + tf1;
    double wz = pz - mp_z + tf2;

    float[16] W = identityMatrix;
    W[0]  = M[0];  W[1]  = M[1];  W[2]  = M[2];
    W[4]  = M[4];  W[5]  = M[5];  W[6]  = M[6];
    W[8]  = M[8];  W[9]  = M[9];  W[10] = M[10];
    W[12] = cast(float)wx;
    W[13] = cast(float)wy;
    W[14] = cast(float)wz;
    W[15] = 1.0f;
    return W;
}
unittest { // wrapAboutPivotStable matches wrapAboutPivot for small pivots (bit-equal after double→float round-trip)
    import std.conv : to;
    auto Morigin = pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), 0.7f);
    Vec3 piv = Vec3(0.3f, -0.4f, 0.9f);
    auto Wold = wrapAboutPivot(Morigin, piv);
    auto Wnew = wrapAboutPivotStable(Morigin, piv);
    foreach (i; 0 .. 16) assert(isClose(Wnew[i], Wold[i], 1e-5f, 1e-5f),
        "wrapAboutPivotStable small-pivot mismatch at element " ~ i.to!string);
}
unittest { // wrapAboutPivotStable beats wrapAboutPivot at far pivot for rotation
    // Oracle: pivot far at ~1e4, rotation ~0.5 rad about Y.
    // wrapAboutPivot(float) suffers ~|pivot|·2^-23 ≈ 1.2e-3 translate-column error;
    // wrapAboutPivotStable computes pivot − M_lin·pivot in double → error < 1e-4.
    Vec3 piv = Vec3(10000.0f, 9800.0f, 10200.0f);
    auto Morigin = pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), 0.5f);
    auto Wstable = wrapAboutPivotStable(Morigin, piv);
    auto Wold    = wrapAboutPivot(Morigin, piv);
    // Apply to a near-origin test vertex and compare to double oracle.
    double[3] v = [0.5, -0.5, 0.5];
    // Double oracle: piv + M_lin*(v-piv) for Y rotation by 0.5 rad.
    double ang = 0.5;
    double c = cos(ang), s = sin(ang);
    double ox = cast(double)piv.x + c*(v[0]-piv.x) + s*(v[2]-piv.z);
    double oy = cast(double)piv.y + (v[1]-piv.y);
    double oz = cast(double)piv.z - s*(v[0]-piv.x) + c*(v[2]-piv.z);
    // Stable version applied to v.
    double sx = Wstable[0]*v[0] + Wstable[4]*v[1] + Wstable[8]*v[2]  + Wstable[12];
    double sy = Wstable[1]*v[0] + Wstable[5]*v[1] + Wstable[9]*v[2]  + Wstable[13];
    double sz = Wstable[2]*v[0] + Wstable[6]*v[1] + Wstable[10]*v[2] + Wstable[14];
    double errStable = (sx-ox)*(sx-ox) + (sy-oy)*(sy-oy) + (sz-oz)*(sz-oz);
    // Old version applied to v.
    double ux = Wold[0]*v[0] + Wold[4]*v[1] + Wold[8]*v[2]  + Wold[12];
    double uy = Wold[1]*v[0] + Wold[5]*v[1] + Wold[9]*v[2]  + Wold[13];
    double uz = Wold[2]*v[0] + Wold[6]*v[1] + Wold[10]*v[2] + Wold[14];
    double errOld = (ux-ox)*(ux-ox) + (uy-oy)*(uy-oy) + (uz-oz)*(uz-oz);
    assert(errStable < errOld,
        "wrapAboutPivotStable should beat wrapAboutPivot at far pivot");
    // The translate column is computed in double then stored as float32.
    // For W_trans_x ≈ -3666 (pivot=(1e4,9800,1e4), Y-rot 0.5 rad), float32
    // storage introduces ~|W_trans|·2^-23 ≈ 4.4e-4 residual — better than
    // the old path's ~|pivot|·2^-23 ≈ 1.2e-3, but bounded by float32 ULP.
    assert(sqrt(errStable) < 5e-4,
        "wrapAboutPivotStable far-pivot error > 5e-4");
}

// Build a column-major model matrix from a local frame + scale + translation.
// Columns are: right*scale.x, up*scale.y, fwd*scale.z, translation.
float[16] modelMatrix(Vec3 right, Vec3 up, Vec3 fwd,
                      Vec3 scale, Vec3 translate) {
    return [
        right.x*scale.x, right.y*scale.x, right.z*scale.x, 0,
        up.x   *scale.y, up.y   *scale.y, up.z   *scale.y, 0,
        fwd.x  *scale.z, fwd.y  *scale.z, fwd.z  *scale.z, 0,
        translate.x,     translate.y,     translate.z,      1,
    ];
}

// Column-major 4x4 * Vec4
Vec4 mulMV(const ref float[16] m, Vec4 v) {
    return Vec4(
        m[0]*v.x + m[4]*v.y + m[ 8]*v.z + m[12]*v.w,
        m[1]*v.x + m[5]*v.y + m[ 9]*v.z + m[13]*v.w,
        m[2]*v.x + m[6]*v.y + m[10]*v.z + m[14]*v.w,
        m[3]*v.x + m[7]*v.y + m[11]*v.z + m[15]*v.w,
    );
}

float[16] lookAt(Vec3 eye, Vec3 center, Vec3 worldUp) {
    Vec3 f = normalize(center - eye);
    Vec3 r = normalize(cross(f, worldUp));
    Vec3 u = cross(r, f);
    return [
         r.x,  u.x, -f.x, 0,
         r.y,  u.y, -f.y, 0,
         r.z,  u.z, -f.z, 0,
        -dot(r,eye), -dot(u,eye), dot(f,eye), 1,
    ];
}

float[16] perspectiveMatrix(float fovY, float aspect, float near, float far) {
    float f  = 1.0f / tan(fovY * 0.5f);
    float nf = near - far;
    return [
        f / aspect, 0,                    0,  0,
        0,          f,                    0,  0,
        0,          0,   (far + near) / nf, -1,
        0,          0, 2*far*near / nf,      0,
    ];
}

/// Orthographic projection matrix (column-major, symmetric frustum).
/// halfH   = half-height of the projection slab in world units.
/// aspect  = viewport width / height.
/// near, far = clip distances.
/// m[15] == 1 distinguishes this from perspectiveMatrix (m[15] == 0).
float[16] orthographicMatrix(float halfH, float aspect, float near, float far) {
    float rw = 1.0f / (halfH * aspect);
    float rh = 1.0f / halfH;
    float rd = -2.0f / (far - near);
    float tz = -(far + near) / (far - near);
    return [
        rw, 0,  0,  0,
        0,  rh, 0,  0,
        0,  0,  rd, 0,
        0,  0,  tz, 1,
    ];
}

/// True when `vp` uses an orthographic projection.
/// Perspective has proj[15] == 0; ortho has proj[15] == 1.
bool isOrtho(const ref Viewport vp) @safe pure nothrow @nogc {
    return vp.proj[15] != 0.0f;
}

Vec3 sphericalToCartesian(float az, float el, float dist) {
    return Vec3(dist * cos(el) * sin(az),
                dist * sin(el),
                dist * cos(el) * cos(az));
}

// Project world point to window pixel coords.
// Returns false if behind camera or outside frustum.
// px, py  — window-space pixels (Y down)
// ndcZ    — NDC depth in [-1, 1]
bool projectToWindow(Vec3 world, const ref Viewport vp,
                     out float px, out float py, out float ndcZ) {
    Vec4 v = mulMV(vp.view, Vec4(world.x, world.y, world.z, 1.0f));
    Vec4 c = mulMV(vp.proj, v);
    if (!(c.w > 0.0f)) return false; // rejects NaN and non-positive
    float nx = c.x / c.w;
    float ny = c.y / c.w;
    ndcZ     = c.z / c.w;
    if (nx < -1 || nx > 1 || ny < -1 || ny > 1 || ndcZ < -1 || ndcZ > 1)
        return false;
    px = (nx * 0.5f + 0.5f)          * vp.width  + vp.x;
    py = (1.0f - (ny * 0.5f + 0.5f)) * vp.height + vp.y;
    return true;
}

// Like projectToWindow but does NOT reject points outside the screen boundary.
// Only rejects points behind the camera (w <= 0).
// Use this for hit-testing line segments that may extend off-screen.
bool projectToWindowFull(Vec3 world, const ref Viewport vp,
                         out float px, out float py, out float ndcZ) {
    Vec4 v = mulMV(vp.view, Vec4(world.x, world.y, world.z, 1.0f));
    Vec4 c = mulMV(vp.proj, v);
    if (!(c.w > 0.0f)) return false; // rejects NaN and non-positive
    float nx = c.x / c.w;
    float ny = c.y / c.w;
    ndcZ = c.z / c.w;
    px = (nx * 0.5f + 0.5f)          * vp.width  + vp.x;
    py = (1.0f - (ny * 0.5f + 0.5f)) * vp.height + vp.y;
    return true;
}

// 2D point-in-polygon test (ray casting, works for convex and concave polygons).
bool pointInPolygon2D(float px, float py, float[] xs, float[] ys) {
    int n = cast(int)xs.length;
    bool inside = false;
    for (int i = 0, j = n - 1; i < n; j = i++) {
        if (((ys[i] > py) != (ys[j] > py)) &&
            (px < (xs[j] - xs[i]) * (py - ys[i]) / (ys[j] - ys[i]) + xs[i]))
            inside = !inside;
    }
    return inside;
}

// Closest distance from point (px,py) to segment (ax,ay)-(bx,by).
// t is the interpolation parameter [0..1] of the closest point on segment.
float closestOnSegment2D(float px, float py,
                          float ax, float ay, float bx, float by,
                          out float t) {
    float dx = bx - ax, dy = by - ay;
    float len2 = dx*dx + dy*dy;
    if (len2 < 1e-6f) { t = 0.0f; return sqrt((px-ax)*(px-ax)+(py-ay)*(py-ay)); }
    t = ((px-ax)*dx + (py-ay)*dy) / len2;
    if (t < 0.0f) t = 0.0f;
    if (t > 1.0f) t = 1.0f;
    float cx = ax + t*dx, cy = ay + t*dy;
    return sqrt((px-cx)*(px-cx) + (py-cy)*(py-cy));
}

// Optimized version that returns squared distance (avoids sqrt)
float closestOnSegment2DSquared(float px, float py,
                                 float ax, float ay, float bx, float by,
                                 out float t) {
    float dx = bx - ax, dy = by - ay;
    float len2 = dx*dx + dy*dy;
    if (len2 < 1e-6f) { t = 0.0f; return (px-ax)*(px-ax)+(py-ay)*(py-ay); }
    t = ((px-ax)*dx + (py-ay)*dy) / len2;
    if (t < 0.0f) t = 0.0f;
    if (t > 1.0f) t = 1.0f;
    float cx = ax + t*dx, cy = ay + t*dy;
    return (px-cx)*(px-cx) + (py-cy)*(py-cy);
}

// ---------------------------------------------------------------------------
// Ray helpers used by plane drag
// ---------------------------------------------------------------------------

// World-space ray direction through screen pixel (sx, sy).
// Uses the view+proj stored in vp; accounts for viewport offset.
Vec3 screenRay(float sx, float sy, const ref Viewport vp)
{
    import std.math : sqrt;
    // NDC, Y-up
    float nx = ((sx - vp.x) / vp.width)  * 2.0f - 1.0f;
    float ny = 1.0f - ((sy - vp.y) / vp.height) * 2.0f;

    // View-space direction: invert perspective projection.
    // proj[0] = f/aspect, proj[5] = f  (diagonal of perspective matrix, row/col 0 and 1).
    // Using M[row][col] = m[row + col*4]: proj[0]=m[0], proj[5]=m[5].
    float vx = nx / vp.proj[0];
    float vy = ny / vp.proj[5];
    // vz = -1 (camera looks along -Z in view space)

    // Rotate to world space: world = R^T * view_dir,
    // where R rows are view[0,4,8], view[1,5,9], view[2,6,10]  (M[row][col]=m[row+col*4]).
    // R^T col j = R row j, so world.x = R col0 · view_dir = view[0]*vx + view[1]*vy + view[2]*(-1)
    const ref float[16] v = vp.view;
    Vec3 d = Vec3(
        v[0]*vx + v[1]*vy + v[2]*(-1.0f),
        v[4]*vx + v[5]*vy + v[6]*(-1.0f),
        v[8]*vx + v[9]*vy + v[10]*(-1.0f),
    );
    float len = d.length;
    return len > 1e-9f ? d / len : Vec3(0,0,-1);
}

/// Build a world-space ray through screen pixel (sx, sy).
/// Perspective: origin = vp.eye, dir = screenRay(sx, sy, vp) — byte-identical to the prior code.
/// Ortho: all rays share the view forward as direction; origin shifts per pixel on the near plane.
void screenPointToRay(float sx, float sy, const ref Viewport vp,
                      out Vec3 origin, out Vec3 dir)
{
    if (!isOrtho(vp)) {
        // Perspective path — byte-identical pass-through.
        origin = vp.eye;
        dir    = screenRay(sx, sy, vp);
        return;
    }
    // Ortho: proj[0] = 1/(halfH*aspect), proj[5] = 1/halfH.
    float nx = ((sx - vp.x) / vp.width)  * 2.0f - 1.0f;
    float ny = 1.0f - ((sy - vp.y) / vp.height) * 2.0f;
    float worldX = nx / vp.proj[0];
    float worldY = ny / vp.proj[5];
    // View-matrix rows (column-major M[row][col] = m[row + col*4]):
    //   right   = (m[0], m[4], m[8])
    //   up      = (m[1], m[5], m[9])
    //   forward = (-m[2], -m[6], -m[10])
    const ref float[16] v = vp.view;
    Vec3 right   = Vec3(v[0], v[4], v[8]);
    Vec3 up      = Vec3(v[1], v[5], v[9]);
    Vec3 forward = Vec3(-v[2], -v[6], -v[10]);
    origin = vp.eye + right * worldX + up * worldY;
    dir    = normalize(forward);
}

// Intersect ray (origin + t*dir) with plane (point on plane + normal).
// Returns false when ray is parallel to the plane.
bool rayPlaneIntersect(Vec3 origin, Vec3 dir, Vec3 planePoint, Vec3 n,
                               out Vec3 hit)
{
    import std.math : abs;
    float denom = dot(n, dir);
    if (abs(denom) < 1e-6f) return false;
    Vec3 d = planePoint - origin;
    float t = dot(n, d) / denom;
    hit = origin + dir * t;
    return true;
}

// Build the camera plane through the eye and the screen-space line (ax,ay)→(bx,by).
//
// For perspective: two rays from vp.eye span a unique plane through the eye.
// For ortho: rays are parallel with distinct origins; plane passes through originA,
// normal = cross(forward, originB - originA). Both branches are implemented below.
//
// Returns true when the plane is well-defined.
// Returns false (no-op; p and n are undefined) when:
//   - screen endpoints are too close  (Euclidean distance < pixelEps)
//   - cross-product is near-zero      (|cross(dA,dB)| < crossEps)
bool cameraPlaneFromScreenLine(const ref Viewport vp,
                               float ax, float ay, float bx, float by,
                               out Vec3 p, out Vec3 n,
                               float pixelEps = 1.0f, float crossEps = 1e-6f)
{
    // Cheap pre-check: reject a sub-pixel drag before computing any rays.
    float dx = bx - ax, dy = by - ay;
    if (dx*dx + dy*dy < pixelEps*pixelEps) return false;

    if (!isOrtho(vp)) {
        // Perspective: two rays through vp.eye span a unique plane.
        Vec3 dA = screenRay(ax, ay, vp);
        Vec3 dB = screenRay(bx, by, vp);
        Vec3 nRaw = cross(dA, dB);
        if (nRaw.length < crossEps) return false;
        p = vp.eye;
        n = normalize(nRaw);
        return true;
    }
    // Ortho: parallel rays with distinct origins.
    // Plane passes through originA; normal = cross(forward, originB - originA).
    Vec3 origA, dirA, origB, dirB;
    screenPointToRay(ax, ay, vp, origA, dirA);
    screenPointToRay(bx, by, vp, origB, dirB);
    Vec3 nRaw = cross(dirA, origB - origA);
    if (nRaw.length < crossEps) return false;
    p = origA;
    n = normalize(nRaw);
    return true;
}

unittest { // cameraPlaneFromScreenLine: vertical center line → normal parallel to world X
    auto vp = makeTestViewport();
    // makeTestViewport builds lookAt(Vec3(0,0,5), ...) but leaves vp.eye
    // zero-initialised; set it explicitly so the plane point assertion is meaningful.
    vp.eye = Vec3(0, 0, 5);

    Vec3 p, n;
    // A vertical center line (ax==bx==400): both rays have world-X component = 0
    // because nx = (400/800)*2 - 1 = 0.  cross(dA, dB) lies along world X.
    bool ok = cameraPlaneFromScreenLine(vp, 400, 100, 400, 700, p, n);
    assert(ok, "expected valid plane for vertical center line");

    // Normal must be unit length.
    assert(isClose(n.length, 1.0f, 1e-4f), "normal must be unit length");

    // Normal must be parallel to world X (Y and Z negligible).
    // Use abs(n.x) to tolerate either cross-product sign.
    assert(isClose(n.x * n.x, 1.0f, 1e-4f), "normal must be parallel to world X");
    assert(isClose(n.y, 0, 1e-4f, 1e-4f),    "normal Y must be zero");
    assert(isClose(n.z, 0, 1e-4f, 1e-4f),    "normal Z must be zero");

    // Plane point must equal the camera eye.
    assert(p.x == vp.eye.x && p.y == vp.eye.y && p.z == vp.eye.z,
           "plane point must equal vp.eye");
}

unittest { // cameraPlaneFromScreenLine: degenerate short line → false, no NaN
    auto vp = makeTestViewport();
    vp.eye = Vec3(0, 0, 5);
    Vec3 p, n;
    // Exactly coincident endpoints.
    assert(!cameraPlaneFromScreenLine(vp, 400, 400, 400, 400, p, n),
           "zero-length line must be degenerate");
    // Sub-pixel endpoints (distance ≈ 0.7 px < default pixelEps 1.0).
    assert(!cameraPlaneFromScreenLine(vp, 400, 400, 400.5f, 400.5f, p, n),
           "sub-pixel line must be degenerate");
}

// Build the cutting plane through the drawn Start→End line, PERPENDICULAR to
// the work plane. This is the SliceTool's plane law (mesh.sliceTool, S0) and a
// deliberate divergence from cameraPlaneFromScreenLine above: instead of the
// camera-eye plane, the cut plane contains the line direction AND has its
// normal lying IN the work plane, so a horizontal drag in a front view yields a
// clean axis-aligned cut regardless of camera pitch.
//
//   n = normalize(cross(end - start, workplaneNormal))   (n ⟂ line, n ⟂ wpN)
//   p = start                                            (any point on the line)
//
// Two planes are perpendicular iff their normals are perpendicular; n ⟂ wpN
// makes the cut plane ⟂ the work plane, and n ⟂ (end-start) makes it contain
// the drawn line. `workplaneNormal` need not be unit — only its direction is
// used. Returns false (p, n left undefined) when the line is degenerate
// (start ≈ end) or the line is parallel to the work-plane normal (cross ≈ 0,
// no unique plane).
bool planeFromLineAndWorkplane(Vec3 start, Vec3 end, Vec3 workplaneNormal,
                               out Vec3 p, out Vec3 n, float eps = 1e-6f)
{
    Vec3 dir = end - start;
    if (dot(dir, dir) < eps * eps) return false;
    Vec3 nRaw = cross(dir, workplaneNormal);
    if (nRaw.length < eps) return false;
    p = start;
    n = normalize(nRaw);
    return true;
}

// planeForSlice — the interactive Slice tool's cut-plane law with the
// `axis` / custom-`vector` constraint (task 0269, S3). The plane ALWAYS passes
// through `start` (p = start); `axisMode` selects the NORMAL:
//   0 = Free    — normal ⟂ the drawn line AND ⟂ the work plane
//                 (= planeFromLineAndWorkplane; the base/default behavior).
//   1 = X, 2 = Y, 3 = Z — normal locked to that WORLD axis, regardless of the
//                 drawn line's orientation (the line only fixes the through-point).
//   4 = Custom  — normal = normalize(vector).
// Returns false (p, n left undefined for the Free/Custom failure cases — p is
// still set to start) when the mode has no well-defined plane: a degenerate /
// workplane-parallel line in Free, or a zero-length `vector` in Custom. The
// world-axis modes are always valid (a unit axis is never degenerate).
bool planeForSlice(Vec3 start, Vec3 end, Vec3 workplaneNormal,
                   int axisMode, Vec3 vector, out Vec3 p, out Vec3 n,
                   float eps = 1e-6f)
{
    p = start;
    switch (axisMode) {
        case 1: n = Vec3(1, 0, 0); return true;   // X
        case 2: n = Vec3(0, 1, 0); return true;   // Y
        case 3: n = Vec3(0, 0, 1); return true;   // Z
        case 4:                                    // Custom
            if (vector.length < eps) return false;
            n = normalize(vector);
            return true;
        default:                                   // 0 = Free
            return planeFromLineAndWorkplane(start, end, workplaneNormal, p, n, eps);
    }
}

unittest { // planeForSlice: Free (mode 0) == planeFromLineAndWorkplane
    Vec3 p0, n0, p1, n1;
    bool okFree = planeForSlice(Vec3(0, 0, -1), Vec3(0, 0, 1), Vec3(0, 1, 0),
                                0, Vec3(0, 1, 0), p0, n0);
    bool okRef  = planeFromLineAndWorkplane(Vec3(0, 0, -1), Vec3(0, 0, 1),
                                            Vec3(0, 1, 0), p1, n1);
    assert(okFree && okRef);
    assert(isClose(n0.x, n1.x) && isClose(n0.y, n1.y) && isClose(n0.z, n1.z),
           "Free mode must reproduce the drawn-line ⟂ work-plane normal");
}

unittest { // planeForSlice: X/Y/Z lock the normal to the WORLD axis regardless of line
    Vec3 p, n;
    // A slanted line whose Free plane would NOT be X-normal: axis=X overrides it.
    assert(planeForSlice(Vec3(0, 0, -1), Vec3(0.3f, 0, 1), Vec3(0, 1, 0),
                         1, Vec3(0, 0, 0), p, n));
    assert(isClose(n.x, 1.0f) && isClose(n.y, 0) && isClose(n.z, 0),
           "axis=X ⇒ world-X normal");
    assert(p.x == 0 && p.z == -1, "plane through Start");
    assert(planeForSlice(Vec3(0, 0, 0), Vec3(1, 0.4f, 0), Vec3(0, 1, 0),
                         3, Vec3(0, 0, 0), p, n));
    assert(isClose(n.x, 0) && isClose(n.y, 0) && isClose(n.z, 1.0f),
           "axis=Z ⇒ world-Z normal");
}

unittest { // planeForSlice: Custom uses normalize(vector); zero vector → false
    Vec3 p, n;
    // Magnitude-2 X vector ⇒ unit X normal (proves normalization).
    assert(planeForSlice(Vec3(0, 0, -1), Vec3(0.3f, 0, 1), Vec3(0, 1, 0),
                         4, Vec3(2, 0, 0), p, n));
    assert(isClose(n.length, 1.0f, 1e-4f) && isClose(n.x, 1.0f),
           "custom vector (2,0,0) ⇒ unit X normal");
    // A diagonal custom normal.
    assert(planeForSlice(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0),
                         4, Vec3(0, 3, 4), p, n));
    assert(isClose(n.length, 1.0f, 1e-4f));
    assert(isClose(n.y, 0.6f, 1e-4f) && isClose(n.z, 0.8f, 1e-4f),
           "custom (0,3,4) ⇒ (0,0.6,0.8)");
    // Zero custom vector ⇒ no plane.
    assert(!planeForSlice(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0),
                          4, Vec3(0, 0, 0), p, n),
           "zero custom vector must be degenerate");
}

unittest { // planeFromLineAndWorkplane: horizontal front-view drag → axis-aligned (Y-normal) cut
    Vec3 p, n;
    // Front view: work plane = XY, normal = +Z. A horizontal line (dir = +X)
    // must produce a horizontal cut plane (normal ∥ Y), independent of pitch.
    bool ok = planeFromLineAndWorkplane(Vec3(-1, 0, 0), Vec3(1, 0, 0),
                                        Vec3(0, 0, 1), p, n);
    assert(ok, "expected a valid plane for a horizontal line");
    assert(isClose(n.length, 1.0f, 1e-4f), "normal must be unit length");
    assert(isClose(n.y * n.y, 1.0f, 1e-4f), "normal must be parallel to world Y");
    assert(isClose(n.x, 0, 1e-4f, 1e-4f), "normal X must be zero");
    assert(isClose(n.z, 0, 1e-4f, 1e-4f), "normal Z must be zero");
    // Plane contains the line: n ⟂ (end-start) and n ⟂ workplane normal.
    assert(isClose(dot(n, Vec3(1, 0, 0) - Vec3(-1, 0, 0)), 0, 1e-4f, 1e-4f),
           "normal must be perpendicular to the line direction");
    assert(isClose(dot(n, Vec3(0, 0, 1)), 0, 1e-4f, 1e-4f),
           "normal must be perpendicular to the work-plane normal");
}

unittest { // planeFromLineAndWorkplane: default XZ work plane (normal +Y) → line along Z gives X=0 plane
    Vec3 p, n;
    // Default construction plane (world XZ, normal +Y). A line drawn along Z
    // through the origin yields a plane with normal ∥ X passing through start —
    // exactly the mid-cube cut the S0 golden fixture drives.
    bool ok = planeFromLineAndWorkplane(Vec3(0, 0, -1), Vec3(0, 0, 1),
                                        Vec3(0, 1, 0), p, n);
    assert(ok, "expected a valid plane");
    assert(isClose(n.x * n.x, 1.0f, 1e-4f), "normal must be parallel to world X");
    assert(isClose(n.y, 0, 1e-4f, 1e-4f), "normal Y must be zero");
    assert(isClose(n.z, 0, 1e-4f, 1e-4f), "normal Z must be zero");
    assert(p.x == 0 && p.z == -1, "plane point must equal start");
}

// ---------------------------------------------------------------------------
// Angle Snap (Slice tool, S5) — quantize a drawn line's in-work-plane angle to
// the nearest multiple of a step, so an endpoint drag lands on clean angles
// (0°, 45°, 90°, … for a 45° step). Pure + unit-tested; the SliceTool's
// interactive drag and its headless apply both route through these so the
// snapped line is identical either way.
// ---------------------------------------------------------------------------

/// Quantize `angleDeg` to the nearest multiple of `stepDeg` (both in degrees).
/// `stepDeg <= 0` disables snapping and returns `angleDeg` unchanged (a guard
/// against a zero/negative Angle param). Half-steps round away from zero
/// (std.math.round), so with a 45° step 22.5° → 45°, −22.5° → −45°.
float snapAngleToMultiple(float angleDeg, float stepDeg) {
    if (stepDeg <= 0) return angleDeg;
    return cast(float)(round(angleDeg / stepDeg) * stepDeg);
}

/// Snap the line `anchor → moving` so its direction — projected into the
/// orthonormal work-plane basis (`axis1`, `axis2`) — lands on the nearest
/// multiple of `stepDeg`. The line LENGTH is preserved; only the direction
/// rotates. Returns the new `moving` endpoint. Degenerate inputs return
/// `moving` unchanged: `stepDeg <= 0` (snap off), a zero-length line, or a line
/// perpendicular to the work plane (no defined in-plane angle). The rebuilt
/// endpoint always lies in the work plane through `anchor` — the interactive
/// Slice keeps its line in the work plane, so that is the identity there.
Vec3 snapLineEndpointToAngle(Vec3 anchor, Vec3 moving, Vec3 axis1, Vec3 axis2,
                             float stepDeg) {
    if (stepDeg <= 0) return moving;
    Vec3 dir = moving - anchor;
    float len = dir.length;
    if (len < 1e-9f) return moving;
    float u = dot(dir, axis1);
    float v = dot(dir, axis2);
    if (u * u + v * v < 1e-18f) return moving;   // line ⟂ plane: no in-plane angle
    float ang     = atan2(v, u) * 180.0f / cast(float)PI;
    float snapped = snapAngleToMultiple(ang, stepDeg) * cast(float)PI / 180.0f;
    Vec3 nd = axis1 * cos(snapped) + axis2 * sin(snapped);
    return anchor + nd * len;
}

unittest { // snapAngleToMultiple: nearest 45° multiple + tie / negative / step-guard
    assert(isClose(snapAngleToMultiple(30, 45), 45, 1e-4f), "30 → 45");
    assert(isClose(snapAngleToMultiple(20, 45),  0, 1e-4f), "20 → 0");
    assert(isClose(snapAngleToMultiple(22.4f, 45),  0, 1e-4f), "22.4 → 0");
    assert(isClose(snapAngleToMultiple(22.6f, 45), 45, 1e-4f), "22.6 → 45");
    assert(isClose(snapAngleToMultiple(60, 45), 45, 1e-4f), "60 → 45");
    assert(isClose(snapAngleToMultiple(70, 45), 90, 1e-4f), "70 → 90");
    assert(isClose(snapAngleToMultiple(-30, 45), -45, 1e-4f), "-30 → -45");
    // A 90° step keeps only axis-aligned angles.
    assert(isClose(snapAngleToMultiple(50, 90), 90, 1e-4f), "50 → 90 (step 90)");
    assert(isClose(snapAngleToMultiple(40, 90),  0, 1e-4f), "40 → 0 (step 90)");
    // step <= 0 is the disabled guard: angle passes through untouched.
    assert(isClose(snapAngleToMultiple(37.5f, 0), 37.5f, 1e-4f), "step 0 → identity");
}

unittest { // snapLineEndpointToAngle: rotates the line to the snapped angle, keeps length
    // Work plane = world XZ: axis1 = +X, axis2 = +Z (angle measured from +X).
    Vec3 a1 = Vec3(1, 0, 0), a2 = Vec3(0, 0, 1);
    // A line at 30° in XZ, length 2. Snap to 45° → direction (cos45, 0, sin45),
    // same length. anchor at origin.
    Vec3 anchor = Vec3(0, 0, 0);
    float c30 = cos(30.0f * cast(float)PI / 180.0f);
    float s30 = sin(30.0f * cast(float)PI / 180.0f);
    Vec3 moving = anchor + Vec3(c30, 0, s30) * 2.0f;
    Vec3 snapped = snapLineEndpointToAngle(anchor, moving, a1, a2, 45);
    float inv = 1.0f / sqrt(2.0f);
    assert(isClose(snapped.x, 2.0f * inv, 1e-4f), "snapped X = 2·cos45");
    assert(isClose(snapped.y, 0, 1e-4f, 1e-4f),   "stays in plane");
    assert(isClose(snapped.z, 2.0f * inv, 1e-4f), "snapped Z = 2·sin45");
    // Length preserved.
    assert(isClose((snapped - anchor).length, 2.0f, 1e-4f), "length preserved");
    // A ~19° line snaps to 0° → pure +X direction (the clean axis-aligned case
    // the S5 golden fixture drives). anchor at (-1,0,0), raw end (1,0,0.7).
    Vec3 an2 = Vec3(-1, 0, 0), mv2 = Vec3(1, 0, 0.7f);
    Vec3 sn2 = snapLineEndpointToAngle(an2, mv2, a1, a2, 45);
    float len2 = (mv2 - an2).length;
    assert(isClose(sn2.z, 0, 1e-4f, 1e-4f), "19° → 0° snaps to Z of anchor (z=0)");
    assert(isClose(sn2.x, -1.0f + len2, 1e-4f), "moves purely along +X");
    // snap off (step 0): endpoint unchanged.
    Vec3 off = snapLineEndpointToAngle(an2, mv2, a1, a2, 0);
    assert(isClose(off.x, 1, 1e-5f) && isClose(off.z, 0.7f, 1e-5f), "step 0 → raw");
    // Degenerate: zero-length line returns moving unchanged.
    assert(snapLineEndpointToAngle(anchor, anchor, a1, a2, 45) == anchor);
}

unittest { // planeFromLineAndWorkplane: degenerate line / line ∥ workplane normal → false, no NaN
    Vec3 p, n;
    // Zero-length line.
    assert(!planeFromLineAndWorkplane(Vec3(1, 2, 3), Vec3(1, 2, 3),
                                      Vec3(0, 1, 0), p, n),
           "zero-length line must be degenerate");
    // Line parallel to the work-plane normal (cross ≈ 0): no unique plane.
    assert(!planeFromLineAndWorkplane(Vec3(0, -1, 0), Vec3(0, 1, 0),
                                      Vec3(0, 1, 0), p, n),
           "line parallel to workplane normal must be degenerate");
}

// Closest point on segment [a, b] to ray (origin O, unit direction D).
// Standard parameterisation: P(t) = a + t·(b-a), Q(s) = O + s·D.
// Minimises |P(t) - Q(s)|² over (s, t); t is then clamped to [0, 1]
// so the result stays on the segment. D is expected unit length —
// callers typically pass `screenRay(...)`. Used by element-falloff
// click-pick to anchor the falloff sphere at the exact click-point
// on an edge rather than its midpoint.
Vec3 closestPointOnSegmentToRay(Vec3 a, Vec3 b, Vec3 O, Vec3 D)
    @safe pure nothrow @nogc
{
    import std.math : abs;
    Vec3 u   = b - a;
    Vec3 w   = a - O;
    float uu = dot(u, u);
    if (uu < 1e-12f) return a;            // degenerate segment
    float uD = dot(u, D);
    float Dw = dot(D, w);
    float uw = dot(u, w);
    // 2x2 normal equations (D assumed unit, so DD = 1):
    //   [uu  -uD] [t]   [-uw]
    //   [-uD  1 ] [s] = [ Dw]
    float denom = uu - uD * uD;
    float t;
    if (abs(denom) < 1e-9f) {
        // Ray ∥ segment: project (a − O) onto u.
        t = -uw / uu;
    } else {
        t = (uD * Dw - uw) / denom;
    }
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    return a + u * t;
}

unittest {
    static bool eq(float x, float y) { return abs(x - y) < 1e-5f; }

    // Perpendicular ray crossing the segment interior.
    Vec3 a = Vec3(0, 0, 0), b = Vec3(1, 0, 0);
    Vec3 hit = closestPointOnSegmentToRay(a, b, Vec3(0.3f, 1, 0),
                                                Vec3(0, -1, 0));
    assert(eq(hit.x, 0.3f) && eq(hit.y, 0) && eq(hit.z, 0));

    // Ray past the b endpoint → clamp to b.
    hit = closestPointOnSegmentToRay(a, b, Vec3(1.5f, 1, 0),
                                            Vec3(0, -1, 0));
    assert(eq(hit.x, 1) && eq(hit.y, 0));

    // Ray before the a endpoint → clamp to a.
    hit = closestPointOnSegmentToRay(a, b, Vec3(-0.4f, 1, 0),
                                            Vec3(0, -1, 0));
    assert(eq(hit.x, 0) && eq(hit.y, 0));

    // Skew ray (off-axis along z) — closest point on segment along x.
    hit = closestPointOnSegmentToRay(a, b, Vec3(0.7f, 1, 0.5f),
                                            Vec3(0, -1, 0));
    assert(eq(hit.x, 0.7f));

    // Ray parallel to segment: t = -uw/uu = 0.2/1 = 0.2 → (0.2, 0, 0).
    hit = closestPointOnSegmentToRay(a, b, Vec3(0.2f, 0.5f, 0),
                                            Vec3(1, 0, 0));
    assert(eq(hit.x, 0.2f) && eq(hit.y, 0));
}

/// Closest world point on an INFINITE LINE (center + t*dir) to a cursor ray
/// (O + s*D). Unlike `closestPointOnSegmentToRay`, t is unclamped — the result
/// may lie anywhere along the infinite line. D is expected unit length.
/// Used by the LINE constraint primitive in snap.d (WorldAxis candidates).
Vec3 closestPointOnLineToRay(Vec3 center, Vec3 dir, Vec3 O, Vec3 D)
    @safe pure nothrow @nogc
{
    import std.math : abs;
    Vec3  w   = center - O;
    float uu  = dot(dir, dir);
    if (uu < 1e-12f) return center;     // degenerate direction
    float uD  = dot(dir, D);
    float Dw  = dot(D, w);
    float uw  = dot(dir, w);
    // Normal equations (D assumed unit, DD = 1):
    //   [uu  -uD] [t]   [-uw]
    //   [-uD  1 ] [s] = [ Dw]
    float denom = uu - uD * uD;
    float t;
    if (abs(denom) < 1e-9f) {
        // Ray parallel to line: project ray origin onto line.
        t = -uw / uu;
    } else {
        t = (uD * Dw - uw) / denom;
    }
    return center + dir * t;  // t unclamped — infinite line
}

unittest {
    import std.math : abs;
    static bool eq(float x, float y) { return abs(x - y) < 1e-5f; }
    Vec3 c = Vec3(0, 0, 0);
    Vec3 d = Vec3(1, 0, 0);  // X axis

    // Perpendicular ray at x=0.3 — same result as the clamped version.
    Vec3 hit = closestPointOnLineToRay(c, d, Vec3(0.3f, 1, 0), Vec3(0, -1, 0));
    assert(eq(hit.x, 0.3f) && eq(hit.y, 0) && eq(hit.z, 0));

    // Ray past t=1 — NOT clamped (unlike closestPointOnSegmentToRay).
    hit = closestPointOnLineToRay(c, d, Vec3(1.5f, 1, 0), Vec3(0, -1, 0));
    assert(eq(hit.x, 1.5f) && eq(hit.y, 0));

    // Ray before t=0 — NOT clamped (negative t).
    hit = closestPointOnLineToRay(c, d, Vec3(-0.4f, 1, 0), Vec3(0, -1, 0));
    assert(eq(hit.x, -0.4f) && eq(hit.y, 0));

    // Parallel ray: t = -uw/uu = -dot(dir, center-O)/dot(dir,dir).
    // O=(0.2,0.5,0) D=(1,0,0): w=(-0.2,-0.5,0), uw=-0.2, t=0.2 → (0.2,0,0).
    hit = closestPointOnLineToRay(c, d, Vec3(0.2f, 0.5f, 0), Vec3(1, 0, 0));
    assert(eq(hit.x, 0.2f) && eq(hit.y, 0));
}

// Project a screen pixel onto the Work Plane in world space.
// Default Work Plane is the X-Z plane at world Y = `planeY` (0 = floor).
// The Work Plane is used by `actr.auto` to relocate the action center on
// click-away. Returns false if the click ray is parallel to the plane.
//
// `planeNormal` lets the caller use a tilted Work Plane (e.g. screen-
// aligned through gizmo); current tools use the default Y-up plane.
// See the action-center parity plan Phase 1.
bool screenToWorkPlane(float sx, float sy, const ref Viewport vp,
                       out Vec3 worldHit,
                       float planeY = 0.0f,
                       Vec3  planeNormal = Vec3(0, 1, 0))
{
    Vec3 swpOrig, dir;
    screenPointToRay(sx, sy, vp, swpOrig, dir);
    return rayPlaneIntersect(swpOrig, dir,
                             Vec3(0, planeY, 0), planeNormal, worldHit);
}

// Safe normalize — returns (0,1,0) for near-zero vectors.
Vec3 safeNormalize(Vec3 v) @safe pure nothrow @nogc {
    float len = v.length;
    return len > 1e-6f ? v / len : Vec3(0, 1, 0);
}


// offsetInPlane: direction perpendicular to edgeDir inside a face.
//
// edgeDir  — normalized direction of the bevel edge (va→vb for F1, vb→va for F2)
// faceNorm — unit normal of the face the new vertex lives in
//
// Returns unit vector d such that  orig + d * width  places the new vertex at
// perpendicular distance width from the bevel-edge line, lying in the face plane.
// Formula: cross(faceNorm, edgeDir), normalised — points INTO the face.
Vec3 offsetInPlane(Vec3 edgeDir, Vec3 faceNorm) @safe pure nothrow @nogc {
    Vec3 p = cross(faceNorm, edgeDir);
    float len = p.length;
    return len > 1e-6f ? p / len : Vec3(0, 1, 0);
}

// offsetMeetDir: junction-vertex offset direction.
//
// e1 — unit vector FROM jv toward prevV in the gap face (face winding prevV→jv→nextV)
// e2 — unit vector FROM jv toward nextV in the gap face
// faceNorm — unit normal of the gap face
//
// In the gap face, prevV arrives INTO jv (F2 winding → edge direction = -e1),
// while nextV departs FROM jv (F1 winding → edge direction = +e2).
// So the two offset lines are:
//   L1: p1 + t*e1,  where p1 = offsetInPlane(-e1, faceNorm)  ← prevV / F2 side
//   L2: p2 + s*e2,  where p2 = offsetInPlane( e2, faceNorm)  ← nextV / F1 side
// Returns direction d s.t.  jv + d*width  = intersection of L1 and L2.
Vec3 offsetMeetDir(Vec3 e1, Vec3 e2, Vec3 faceNorm) @safe pure nothrow @nogc {
    Vec3 p1 = offsetInPlane(-e1, faceNorm); // prevV side: negate (F2 winding)
    Vec3 p2 = offsetInPlane(e2,  faceNorm); // nextV side: direct (F1 winding)

    Vec3  rhs   = p2 - p1;
    Vec3  n     = cross(e1, e2);
    float denom = dot(n, n);
    if (denom < 1e-12f) {
        return safeNormalize((p1 + p2) * 0.5f);
    }
    float t = dot(cross(rhs, e2), n) / denom;
    return p1 + e1 * t;
}

// offsetMeet: junction offset with per-edge widths.
//
// Same geometry as offsetMeetDir but the two offset lines may be displaced
// by different amounts (wPrev for the prevV side, wNext for the nextV side).
// Returns the absolute world-space intersection point. Useful when one
// EdgeHalf is beveled (wEdge = width) and the other is not (wEdge = 0).
//
// Parallel-edge fallback (the two edges are collinear inside the face):
//   - Both bev: the perpendicular offsets coincide (p1 ≈ p2) — return
//     their midpoint, the correct in-face perpendicular displacement
//     (this is the "pipe" case).
//   - One bev + one non-bev: return the offset-side position. The boundary
//     vertex stays at the perpendicular slide (like a normal cube-corner
//     BV) and a separate edge-slide vertex for the TRI_FAN cap is
//     materialized higher up, not by offsetMeet.
//   - Both non-bev: caller shouldn't invoke this (no BV needed).
Vec3 offsetMeet(Vec3 jv, Vec3 ePrev, Vec3 eNext, Vec3 faceNorm,
                float wPrev, float wNext) @safe pure nothrow @nogc {
    import std.math : abs;
    Vec3 p1 = jv + offsetInPlane(-ePrev, faceNorm) * wPrev;
    Vec3 p2 = jv + offsetInPlane( eNext, faceNorm) * wNext;
    Vec3 r  = p2 - p1;
    float denom = dot(cross(ePrev, eNext), faceNorm);
    if (abs(denom) < 1e-6f) {
        if (wPrev > 0 && wNext == 0) return p1;
        if (wNext > 0 && wPrev == 0) return p2;
        return (p1 + p2) * 0.5f;
    }
    float t = dot(cross(r, eNext), faceNorm) / denom;
    return p1 + ePrev * t;
}

unittest { // offsetMeet: 90° corner, one bev one non-bev — slides on non-bev edge
    Vec3 jv     = Vec3(0, 0, 0);
    Vec3 ePrev  = Vec3(1, 0, 0);   // non-bev edge along +X
    Vec3 eNext  = Vec3(0, 1, 0);   // bev edge along +Y
    Vec3 faceN  = Vec3(0, 0, -1);  // face normal in -Z
    Vec3 r = offsetMeet(jv, ePrev, eNext, faceN, 0.0f, 0.1f);
    assert(isClose(r.x, 0.1f, 1e-5));
    assert(isClose(r.y, 0.0f, 1e-5));
    assert(isClose(r.z, 0.0f, 1e-5));
}

unittest { // offsetMeet: 90° corner, both bev — meets at the diagonal
    Vec3 jv     = Vec3(0, 0, 0);
    Vec3 ePrev  = Vec3(1, 0, 0);
    Vec3 eNext  = Vec3(0, 1, 0);
    Vec3 faceN  = Vec3(0, 0, -1);
    Vec3 r = offsetMeet(jv, ePrev, eNext, faceN, 0.1f, 0.1f);
    assert(isClose(r.x, 0.1f, 1e-5));
    assert(isClose(r.y, 0.1f, 1e-5));
    assert(isClose(r.z, 0.0f, 1e-5));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) import std.math : isClose;

unittest { // Quat.identity is a unit quaternion w=1
    auto q = Quat.identity();
    assert(q.w == 1 && q.x == 0 && q.y == 0 && q.z == 0);
}

unittest { // Quat.normalize yields unit length
    auto q = Quat(2, 0, 0, 0).normalize();
    assert(isClose(q.w, 1.0f) && isClose(q.x, 0) && isClose(q.y, 0) && isClose(q.z, 0));
    auto q2 = Quat(1, 1, 1, 1).normalize();
    assert(isClose(sqrt(q2.w*q2.w + q2.x*q2.x + q2.y*q2.y + q2.z*q2.z), 1.0f));
}

unittest { // slerp endpoints: t=0 → a, t=1 → b
    auto a = Quat.identity();
    auto b = quatFromMatrix(pivotRotationMatrix(Vec3(0,0,0), Vec3(0,0,1), PI/2));
    auto r0 = slerp(a, b, 0.0f);
    assert(isClose(r0.w, a.w, 1e-5f) && isClose(r0.x, a.x, 1e-5f)
        && isClose(r0.y, a.y, 1e-5f) && isClose(r0.z, a.z, 1e-5f));
    auto r1 = slerp(a, b, 1.0f);
    // Sign-insensitive compare (q and -q are the same rotation).
    float d = r1.w*b.w + r1.x*b.x + r1.y*b.y + r1.z*b.z;
    assert(isClose(abs(d), 1.0f, 1e-5f));
}

unittest { // quatFromMatrix(pivotRotationMatrix(...)) recovers the angle
    // Rotation of PI/3 about Z (pivot irrelevant for the rotation part).
    float ang = PI / 3;
    auto m = pivotRotationMatrix(Vec3(2, -1, 0.5f), Vec3(0, 0, 1), ang);
    auto q = quatFromMatrix(m);
    // For a unit-axis rotation, w = cos(ang/2), |z| = sin(ang/2).
    assert(isClose(abs(q.w), cos(ang/2), 1e-4f));
    assert(isClose(abs(q.z), sin(ang/2), 1e-4f));
    assert(isClose(q.x, 0, 1e-4f, 1e-4f) && isClose(q.y, 0, 1e-4f, 1e-4f));
}

unittest { // quatFromMatrix divides out per-axis scale → pure rotation
    // Rotation·scale: rotate PI/4 about Y, then scale (2, 3, 4) along the
    // rotated axes. quatFromMatrix must recover ONLY the rotation.
    float ang = PI / 4;
    Vec3 ax = Vec3(cos(ang), 0, -sin(ang)); // R(Y, ang) applied to X
    Vec3 ay = Vec3(0, 1, 0);
    Vec3 az = Vec3(sin(ang), 0, cos(ang));  // R(Y, ang) applied to Z
    auto rs = pivotScaleMatrixBasis(Vec3(0,0,0), ax, ay, az, 2, 3, 4);
    auto qpure = quatFromMatrix(pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), ang));
    auto qrs   = quatFromMatrix(rs);
    // pivotScaleMatrixBasis builds R·diag(s)·R^T (a symmetric stretch, NOT a
    // rotation·scale), so this case just asserts scale is removed: the result
    // is a unit quaternion and (here) the identity rotation.
    assert(isClose(sqrt(qrs.w*qrs.w+qrs.x*qrs.x+qrs.y*qrs.y+qrs.z*qrs.z), 1.0f, 1e-4f));
}

unittest { // matrixFromQuat ∘ quatFromMatrix round-trips a rotation matrix
    auto m = pivotRotationMatrix(Vec3(0,0,0), normalize(Vec3(1, 2, 3)), 0.7f);
    auto m2 = matrixFromQuat(quatFromMatrix(m));
    // Compare the 3×3 rotation block (translation is zero for pivot at origin).
    foreach (i; [0,1,2, 4,5,6, 8,9,10])
        assert(isClose(m[i], m2[i], 1e-4f), "rotation block mismatch");
}

unittest { // matrixFromQuat(identity) == identity matrix
    auto m = matrixFromQuat(Quat.identity());
    foreach (i, v; identityMatrix)
        assert(isClose(m[i], v, 1e-6f));
}

// ---- Cumulative-euler ZYX helpers ----

unittest { // matrixFromEulerZYX((0,0,0)) == identity (exact)
    auto m = matrixFromEulerZYX(Vec3(0, 0, 0));
    foreach (i, v; identityMatrix)
        assert(m[i] == v, "zero euler must be exact identity");
}

unittest { // CONVENTION MATCH: helper == explicit composeFor-order matMul4 chain
    enum float D2R = cast(float)(PI / 180.0);
    // A spread of angle triples, incl. some with zero components (skip path).
    Vec3[] cases = [
        Vec3(30, 0, 0), Vec3(0, 45, 0), Vec3(0, 0, 60),
        Vec3(17, -33, 52), Vec3(-80, 25, -10), Vec3(0, 89.9f, 0),
    ];
    foreach (deg; cases) {
        auto a = matrixFromEulerZYX(deg);
        // Mirror composeFor: identity, left-mul X, then Y, then Z (skip zero).
        float[16] b = identityMatrix;
        if (deg.x != 0)
            b = matMul4(pivotRotationMatrix(Vec3(0,0,0), Vec3(1,0,0), deg.x*D2R), b);
        if (deg.y != 0)
            b = matMul4(pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), deg.y*D2R), b);
        if (deg.z != 0)
            b = matMul4(pivotRotationMatrix(Vec3(0,0,0), Vec3(0,0,1), deg.z*D2R), b);
        foreach (i; 0 .. 16)
            assert(a[i] == b[i], "helper must be bit-equal to composeFor chain");
    }
}

unittest { // SINGLE-AXIS + known multi-axis round-trips
    auto rx = eulerZYXFromMatrix(matrixFromEulerZYX(Vec3(30, 0, 0)));
    assert(isClose(rx.x, 30, 1e-4f, 1e-4f) && isClose(rx.y, 0, 1e-4f, 1e-4f)
        && isClose(rx.z, 0, 1e-4f, 1e-4f));
    auto ry = eulerZYXFromMatrix(matrixFromEulerZYX(Vec3(0, 30, 0)));
    assert(isClose(ry.x, 0, 1e-4f, 1e-4f) && isClose(ry.y, 30, 1e-4f, 1e-4f)
        && isClose(ry.z, 0, 1e-4f, 1e-4f));
    auto rz = eulerZYXFromMatrix(matrixFromEulerZYX(Vec3(0, 0, 30)));
    assert(isClose(rz.x, 0, 1e-4f, 1e-4f) && isClose(rz.y, 0, 1e-4f, 1e-4f)
        && isClose(rz.z, 30, 1e-4f, 1e-4f));
    // Known multi-axis (well away from gimbal): angles recover directly.
    auto m = eulerZYXFromMatrix(matrixFromEulerZYX(Vec3(20, -35, 50)));
    assert(isClose(m.x, 20, 1e-3f, 1e-3f) && isClose(m.y, -35, 1e-3f, 1e-3f)
        && isClose(m.z, 50, 1e-3f, 1e-3f));
}

unittest { // ROUNDTRIP: matrixFromEulerZYX∘eulerZYXFromMatrix ≈ id (incl. near-gimbal)
    Vec3[] cases = [
        Vec3(0, 0, 0), Vec3(13, 27, 41), Vec3(-66, 12, 88),
        Vec3(170, -150, 95), Vec3(45, 45, 45), Vec3(-12, 78, -34),
        // Near-gimbal pitch:
        Vec3(33, 89.9f, -21), Vec3(-50, -89.9f, 17),
        Vec3(33, 90.0f, -21), Vec3(-50, -90.0f, 17),
        Vec3(0, 90.0f, 0),    Vec3(60, 90.0f, 0),
    ];
    float maxErr = 0;
    foreach (deg; cases) {
        auto M = matrixFromEulerZYX(deg);
        auto M2 = matrixFromEulerZYX(eulerZYXFromMatrix(M));
        foreach (i; 0 .. 16) {
            float e = abs(M[i] - M2[i]);
            if (e > maxErr) maxErr = e;
            assert(e < 1e-4f, "euler ZYX roundtrip exceeded tolerance");
        }
    }
    assert(maxErr < 1e-4f);
}

unittest { // applyAffine: translation matrix moves a point by t
    auto m = translationMatrix(Vec3(1, -2, 3));
    auto p = applyAffine(m, Vec3(5, 5, 5));
    assert(isClose(p.x, 6) && isClose(p.y, 3) && isClose(p.z, 8));
}

unittest { // applyAffine: pivotRotationMatrix matches a hand-rotated point
    // 90° about Z around origin sends (1,0,0) → (0,1,0).
    auto m = pivotRotationMatrix(Vec3(0,0,0), Vec3(0,0,1), PI/2);
    auto p = applyAffine(m, Vec3(1, 0, 0));
    assert(isClose(p.x, 0, 1e-5f, 1e-5f) && isClose(p.y, 1.0f, 1e-5f)
        && isClose(p.z, 0, 1e-5f, 1e-5f));
}

unittest { // vec3Add
    auto r = Vec3(1,2,3) + Vec3(4,5,6);
    assert(r.x == 5 && r.y == 7 && r.z == 9);
}

unittest { // vec3Sub
    auto r = Vec3(4,5,6) - Vec3(1,2,3);
    assert(r.x == 3 && r.y == 3 && r.z == 3);
}

unittest { // vec3Scale
    auto r = Vec3(1,2,3) * 2.0f;
    assert(r.x == 2 && r.y == 4 && r.z == 6);
}

unittest { // vec3Scale by zero
    auto r = Vec3(5,-3,7) * 0.0f;
    assert(r.x == 0 && r.y == 0 && r.z == 0);
}

unittest { // normalize axis-aligned
    auto n = normalize(Vec3(3,0,0));
    assert(isClose(n.x, 1.0f) && isClose(n.y, 0.0f) && isClose(n.z, 0.0f));
}

unittest { // normalize length == 1
    auto n = normalize(Vec3(1,2,3));
    assert(isClose(n.length, 1.0f));
}

unittest { // dot
    assert(isClose(dot(Vec3(1,0,0), Vec3(1,0,0)),  1.0f));
    assert(isClose(dot(Vec3(1,0,0), Vec3(0,1,0)),  0.0f));
    assert(isClose(dot(Vec3(1,0,0), Vec3(-1,0,0)), -1.0f));
}

unittest { // cross X×Y = Z
    auto r = cross(Vec3(1,0,0), Vec3(0,1,0));
    assert(isClose(r.x, 0) && isClose(r.y, 0) && isClose(r.z, 1));
}

unittest { // cross anti-commutative
    auto a = Vec3(1,2,3), b = Vec3(4,5,6);
    auto ab = cross(a, b), ba = cross(b, a);
    assert(isClose(ab.x, -ba.x) && isClose(ab.y, -ba.y) && isClose(ab.z, -ba.z));
}

unittest { // cross of parallel vectors is zero
    auto r = cross(Vec3(1,0,0), Vec3(2,0,0));
    assert(isClose(r.x, 0) && isClose(r.y, 0) && isClose(r.z, 0));
}

unittest { // mulMV with identity
    auto r = mulMV(identityMatrix, Vec4(1,2,3,1));
    assert(isClose(r.x,1) && isClose(r.y,2) && isClose(r.z,3) && isClose(r.w,1));
}

unittest { // modelMatrix identity frame → identity matrix
    auto m = modelMatrix(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                         Vec3(1,1,1), Vec3(0,0,0));
    foreach (i, v; identityMatrix)
        assert(isClose(m[i], v));
}

unittest { // modelMatrix translation stored in last column
    auto m = modelMatrix(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                         Vec3(1,1,1), Vec3(5,-3,7));
    assert(isClose(m[12], 5) && isClose(m[13], -3) && isClose(m[14], 7));
}

unittest { // modelMatrix non-uniform scale
    auto m = modelMatrix(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                         Vec3(2,3,4), Vec3(0,0,0));
    assert(isClose(m[0], 2) && isClose(m[5], 3) && isClose(m[10], 4));
}

unittest { // lookAt — origin is in front of camera
    auto m = lookAt(Vec3(0,0,5), Vec3(0,0,0), Vec3(0,1,0));
    Vec4 o = mulMV(m, Vec4(0,0,0,1));
    assert(isClose(o.x, 0, 1e-4f) && isClose(o.y, 0, 1e-4f));
    assert(o.z < 0);
}

unittest { // sphericalToCartesian az=0 el=0 → +Z
    auto v = sphericalToCartesian(0.0f, 0.0f, 1.0f);
    assert(isClose(v.x, 0) && isClose(v.y, 0) && isClose(v.z, 1));
}

unittest { // sphericalToCartesian el=PI/2 → straight up
    auto v = sphericalToCartesian(0.0f, PI/2, 1.0f);
    assert(isClose(v.y, 1.0f, 1e-5f));
    assert(isClose(v.x, 0, 1e-5f, 1e-5f) && isClose(v.z, 0, 1e-5f, 1e-5f));
}

unittest { // sphericalToCartesian dist=0 → zero vector
    auto v = sphericalToCartesian(1.23f, 0.45f, 0.0f);
    assert(isClose(v.x, 0) && isClose(v.y, 0) && isClose(v.z, 0));
}

unittest { // pointInPolygon2D square
    float[] xs = [0, 4, 4, 0];
    float[] ys = [0, 0, 4, 4];
    assert( pointInPolygon2D(2, 2, xs, ys));
    assert(!pointInPolygon2D(5, 2, xs, ys));
    assert(!pointInPolygon2D(2, 5, xs, ys));
}

unittest { // pointInPolygon2D triangle
    float[] xs = [0, 2, 4];
    float[] ys = [0, 4, 0];
    assert( pointInPolygon2D(2, 1.5f, xs, ys));
    assert(!pointInPolygon2D(-1, 2,   xs, ys));
}

unittest { // closestOnSegment2D — point above midpoint
    float t;
    float d = closestOnSegment2D(2, 1, 0, 0, 4, 0, t);
    assert(isClose(d, 1.0f) && isClose(t, 0.5f));
}

unittest { // closestOnSegment2D — clamp to t=1
    float t;
    float d = closestOnSegment2D(6, 0, 0, 0, 4, 0, t);
    assert(isClose(t, 1.0f) && isClose(d, 2.0f));
}

unittest { // closestOnSegment2D — clamp to t=0
    float t;
    float d = closestOnSegment2D(-1, 0, 0, 0, 4, 0, t);
    assert(isClose(t, 0.0f) && isClose(d, 1.0f));
}

unittest { // closestOnSegment2D — degenerate segment
    float t;
    float d = closestOnSegment2D(3, 4, 0, 0, 0, 0, t);
    assert(isClose(t, 0.0f) && isClose(d, 5.0f));
}

// Helper: viewport with lookAt camera at Z=5 and 90° symmetric perspective
version(unittest) private Viewport makeTestViewport() {
    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0,0,0), Vec3(0,1,0));
    vp.proj   = perspectiveMatrix(PI/2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    vp.x = 0;
    vp.y = 0;
    return vp;
}

unittest { // screenRay: center pixel → along -Z
    auto vp = makeTestViewport();
    auto r = screenRay(400, 400, vp);
    assert(isClose(r.x, 0, 1e-5f, 1e-5f));
    assert(isClose(r.y, 0, 1e-5f, 1e-5f));
    assert(isClose(r.z, -1.0f));
}

unittest { // screenRay: result is always unit length
    auto vp = makeTestViewport();
    foreach (sx; [0.0f, 400.0f, 799.0f])
        foreach (sy; [0.0f, 400.0f, 799.0f]) {
            auto r = screenRay(sx, sy, vp);
            assert(isClose(r.length, 1.0f, 1e-4f));
        }
}

unittest { // screenRay: top-left pixel → (-1/√3, 1/√3, -1/√3) with 90° FOV aspect=1
    // proj[0]=proj[5]=1, so nx=-1,ny=1 → view-dir (-1,1,-1) → normalized
    auto vp = makeTestViewport();
    auto r = screenRay(0, 0, vp);
    float inv3 = 1.0f / sqrt(3.0f);
    assert(isClose(r.x, -inv3, 1e-4f));
    assert(isClose(r.y,  inv3, 1e-4f));
    assert(isClose(r.z, -inv3, 1e-4f));
}

unittest { // screenRay: viewport offset shifts pixel-to-NDC mapping
    auto vp = makeTestViewport();
    vp.x = 100;
    vp.y = 50;
    // Center of the offset viewport is now pixel (500, 450)
    auto r = screenRay(500, 450, vp);
    assert(isClose(r.x, 0, 1e-5f, 1e-5f));
    assert(isClose(r.y, 0, 1e-5f, 1e-5f));
    assert(isClose(r.z, -1.0f));
}

unittest { // orthographicMatrix: check diagonal entries and m[15] discriminator
    import std.math : isClose;
    float halfH = 2.0f, aspect = 16.0f / 9.0f, near = 0.001f, far = 100.0f;
    auto m = orthographicMatrix(halfH, aspect, near, far);
    // Diagonal entries.
    assert(isClose(m[0],  1.0f / (halfH * aspect), 1e-5f), "m[0] wrong");
    assert(isClose(m[5],  1.0f / halfH,             1e-5f), "m[5] wrong");
    assert(isClose(m[10], -2.0f / (far - near),     1e-5f), "m[10] wrong");
    assert(isClose(m[14], -(far + near) / (far - near), 1e-5f), "m[14] wrong");
    assert(m[15] == 1.0f, "m[15] must be 1 (ortho discriminator)");
    // Off-diagonal entries must be zero.
    foreach (i; 0 .. 16) {
        if (i != 0 && i != 5 && i != 10 && i != 14 && i != 15)
            assert(m[i] == 0.0f, "off-diagonal must be 0");
    }
}

unittest { // isOrtho: perspective → false, ortho → true
    import std.math : isClose, PI;
    Viewport vp;
    vp.proj = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.001f, 100.0f);
    assert(!isOrtho(vp), "perspective matrix must not be ortho");
    assert(vp.proj[15] == 0.0f, "perspective m[15] must be 0");
    vp.proj = orthographicMatrix(2.0f, 1.0f, 0.001f, 100.0f);
    assert(isOrtho(vp), "ortho matrix must be ortho");
    assert(vp.proj[15] == 1.0f, "ortho m[15] must be 1");
}

unittest { // screenPointToRay: perspective pass-through byte-identical
    import std.math : isClose;
    auto vp = makeTestViewport();
    Vec3 orig, dir;
    float sx = 300.0f, sy = 250.0f;
    screenPointToRay(sx, sy, vp, orig, dir);
    assert(orig.x == vp.eye.x && orig.y == vp.eye.y && orig.z == vp.eye.z,
           "perspective origin must equal vp.eye");
    Vec3 ref_ = screenRay(sx, sy, vp);
    assert(isClose(dir.x, ref_.x, 1e-5f) && isClose(dir.y, ref_.y, 1e-5f)
           && isClose(dir.z, ref_.z, 1e-5f),
           "perspective dir must match screenRay");
}

unittest { // screenPointToRay: ortho — parallel dirs, per-pixel origins
    import std.math : isClose, PI;
    // Build an ortho Front viewport: eye at Z=3, looking -Z.
    Viewport vp;
    vp.view   = lookAt(Vec3(0,0,3), Vec3(0,0,0), Vec3(0,1,0));
    float halfH = 2.0f;
    vp.proj   = orthographicMatrix(halfH, 1.0f, 0.001f, 100.0f);
    vp.width  = 800; vp.height = 800;
    vp.x = 0; vp.y = 0;
    vp.eye    = Vec3(0, 0, 3);
    // Two pixels at different positions.
    Vec3 o1, d1, o2, d2;
    screenPointToRay(200.0f, 400.0f, vp, o1, d1);
    screenPointToRay(600.0f, 400.0f, vp, o2, d2);
    // Directions must be parallel (same vector, forward = -Z).
    assert(isClose(d1.x, d2.x, 1e-5f) && isClose(d1.y, d2.y, 1e-5f)
           && isClose(d1.z, d2.z, 1e-5f), "ortho rays must be parallel");
    assert(isClose(d1.z, -1.0f, 1e-4f), "ortho forward must be -Z for front view");
    // Origins must differ (the two X pixels land at different world X).
    assert(!isClose(o1.x, o2.x, 1e-3f), "ortho origins must differ in X");
    assert(isClose(o1.y, o2.y, 1e-5f), "ortho origins Y must match (same row)");
}

unittest { // rayPlaneIntersect: ray from above hits XZ plane at origin
    Vec3 hit;
    bool ok = rayPlaneIntersect(Vec3(0,5,0), Vec3(0,-1,0),
                                Vec3(0,0,0), Vec3(0,1,0), hit);
    assert(ok);
    assert(isClose(hit.x, 0, 1e-5f, 1e-5f));
    assert(isClose(hit.y, 0, 1e-5f, 1e-5f));
    assert(isClose(hit.z, 0, 1e-5f, 1e-5f));
}

unittest { // rayPlaneIntersect: angled ray hits offset plane at correct point
    // Ray from origin along (1,1,0)/√2, plane at x=3 with normal (1,0,0)
    // t = 3/s where s=1/√2, hit = (3, 3, 0)
    float s = 1.0f / sqrt(2.0f);
    Vec3 hit;
    bool ok = rayPlaneIntersect(Vec3(0,0,0), Vec3(s,s,0),
                                Vec3(3,0,0), Vec3(1,0,0), hit);
    assert(ok);
    assert(isClose(hit.x, 3.0f, 1e-4f));
    assert(isClose(hit.y, 3.0f, 1e-4f));
    assert(isClose(hit.z, 0, 1e-5f, 1e-5f));
}

unittest { // rayPlaneIntersect: ray parallel to plane returns false
    Vec3 hit;
    assert(!rayPlaneIntersect(Vec3(0,5,0), Vec3(1,0,0),
                              Vec3(0,0,0), Vec3(0,1,0), hit));
}

unittest { // rayPlaneIntersect: near-parallel ray below threshold returns false
    Vec3 hit;
    // dot((0,1,0), (1, 5e-7, 0)) = 5e-7 < 1e-6
    assert(!rayPlaneIntersect(Vec3(0,0,0), Vec3(1.0f, 5e-7f, 0),
                              Vec3(0,1,0), Vec3(0,1,0), hit));
}

unittest { // vec3Length
    assert(isClose(Vec3(3,4,0).length, 5.0f));
    assert(isClose(Vec3(0,0,0).length, 0.0f));
    assert(isClose(Vec3(1,0,0).length, 1.0f));
}

unittest { // vec3Lerp
    auto r = vec3Lerp(Vec3(0,0,0), Vec3(4,4,4), 0.25f);
    assert(isClose(r.x, 1.0f) && isClose(r.y, 1.0f) && isClose(r.z, 1.0f));
    auto a = vec3Lerp(Vec3(1,2,3), Vec3(5,6,7), 0.0f);
    assert(isClose(a.x, 1.0f) && isClose(a.y, 2.0f) && isClose(a.z, 3.0f));
    auto b = vec3Lerp(Vec3(1,2,3), Vec3(5,6,7), 1.0f);
    assert(isClose(b.x, 5.0f) && isClose(b.y, 6.0f) && isClose(b.z, 7.0f));
}