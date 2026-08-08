module math;

import std.math : tan, sin, cos, sqrt, PI, abs, acos, asin, atan2, round, isFinite;
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
    // Camera look-at target. NOTE, and it used to read "default (0,0,0)":
    // `Vec3`'s own fields carry no initialiser, so `float.init` applies and a
    // default-constructed Viewport has focus == (NaN, NaN, NaN), not the
    // origin. Every real path sets it (`View.viewportWith`); hand-built
    // headless fixtures routinely do not. A consumer that must survive both
    // has to say so — see `viewPixelScale`.
    Vec3 focus;
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

// ---------------------------------------------------------------------------
// ModelSpace — the per-layer item transform, packaged for picking (task 0617,
// doc/picking_item_transform_plan.md).
//
// Geometry is DRAWN through a layer's item matrix (`ItemXform.composedMatrix`,
// document.d) but every picking path historically compared against raw LOCAL
// vertex coordinates — a layer with a non-identity transform was picked where
// it would sit at identity, not where it is actually drawn. `ModelSpace` is
// the value that closes that gap: every picking entry point takes one of
// these as a REQUIRED parameter (never defaulted — a call site that forgets
// it is a build error, not a silent wrong answer) and transforms the QUERY
// into the layer's local space, rather than baking world-space copies of the
// geometry into the picking caches (the GPU ID-buffer's VBOs, the BVH, the
// snap candidate grid). `document.ItemXform.modelSpace()` is the one
// production factory; `ModelSpace.world()` below is the identity constant
// used where there is no layer transform to apply (unit tests, and any path
// provably always identity).
//
// `mInv` is analytic (§3.1 of the plan), not a general 4x4 inverse — this
// module has none, and the composition order
// `M = T(pos)·T(pivot)·Rz·Ry·Rx·S·T(-pivot)` (document.d) never needs one.
// ---------------------------------------------------------------------------
struct ModelSpace {
    // Literal, not `= identityMatrix` (a static-array default field
    // initializer can't array-cast an `immutable` global at compile time) —
    // same nine 1s / zeros identityMatrix holds.
    float[16] m    = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]; // local -> world
    float[16] mInv = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]; // world -> local (analytic; see document.d)
    bool      isIdentity = true;
    bool      invertible = true;
    // det(m) < 0 — an odd number of negative scale components (for this
    // composition order det(M) == scl.x*scl.y*scl.z, no general 3x3
    // determinant helper needed).
    //
    // A mirrored M does flip apparent WINDING: cross(M*u, M*v) ==
    // det(M)*(M^-1)^T*cross(u,v), so a normal built by cross-producting two
    // (possibly already-world) edge vectors points the wrong way whenever
    // det(M) < 0. But a front-facing test done ENTIRELY in local space — a
    // local normal dotted against a local-space eye/point, i.e.
    // `dot(nLocal, pLocal - eyeLocal)` — needs NO correction for this,
    // mirrored or not. The reason: `eyeLocal == M^-1 * eyeWorld` and
    // `pLocal == M^-1 * pWorld` are already the exact local coordinates the
    // drawn geometry was built from, so `dot(nLocal, pLocal - eyeLocal)` IS
    // the local-space evaluation of "is the eye on the outward side" — no
    // world quantity is being approximated or reconstructed, so there is
    // nothing for `det(M)`'s sign to correct. (Equivalently: the true world
    // outward normal is `toWorldNormal(nLocal) == (M^-1)^T * nLocal`, and
    // `dot((M^-1)^T n, M v) == dot(n, v)` exactly, for ANY invertible M — the
    // local dot product already equals the correct world one, sign and all.)
    //
    // A previous version of this field's doc comment, and three call sites
    // (app.d's lasso `frontFacing`, snap.d's `faceVisible`, mesh.d's
    // `visibleVertices`), got this backwards: they XOR'd `mirrored` onto a
    // LOCAL-only front-facing test, which is the correction for the WINDING
    // normal case above, not this one. That flip has been removed from all
    // three; do not reintroduce it into a local-only cull. This field is not
    // read anywhere in the tree as of this fix — see `toWorldNormal`'s doc
    // comment below for the one construction (a normal built by
    // cross-producting WORLD points/vectors) where the mirror sign genuinely
    // does need correcting, and where `mirrored` itself still isn't the
    // mechanism (the inverse-transpose is applied directly instead).
    bool      mirrored   = false;

    /// The identity ModelSpace. Every field already defaults to it — this
    /// name exists so call sites can write `ModelSpace.world()` instead of
    /// the less self-explanatory `ModelSpace.init`.
    static ModelSpace world() @safe pure nothrow @nogc { return ModelSpace.init; }

    /// World point -> local point (full affine, via `mInv`).
    Vec3 toLocalPoint(Vec3 worldP) const @safe pure nothrow @nogc {
        return applyAffine(mInv, worldP);
    }
    /// Local point -> world point (full affine, via `m`).
    Vec3 toWorldPoint(Vec3 localP) const @safe pure nothrow @nogc {
        return applyAffine(m, localP);
    }
    /// World-space DIRECTION -> local-space direction: the LINEAR part of
    /// `mInv` only (no translation). Deliberately left UN-NORMALIZED — see
    /// doc/picking_item_transform_plan.md §3.4. Because
    /// `mInv·(org + t·dir) == mInv·org + t·(mInv·dir)`, leaving this
    /// un-normalized preserves a ray's hit parameter `t` exactly as a WORLD
    /// distance. Normalizing here (or at any caller) corrupts `t` — the
    /// nearest-hit comparison across layers of different scale would
    /// silently start favouring the smaller-scaled layer. Do not add a
    /// `normalize()` call to this function or its call sites.
    Vec3 toLocalDir(Vec3 worldDir) const @safe pure nothrow @nogc {
        return Vec3(
            mInv[0]*worldDir.x + mInv[4]*worldDir.y + mInv[ 8]*worldDir.z,
            mInv[1]*worldDir.x + mInv[5]*worldDir.y + mInv[ 9]*worldDir.z,
            mInv[2]*worldDir.x + mInv[6]*worldDir.y + mInv[10]*worldDir.z,
        );
    }
    /// Local-space NORMAL -> world-space normal: `(M^-1)^T` applied to
    /// `nLocal` — the standard normal-transform rule (normals do NOT
    /// transform the same way points/directions do under a non-uniform
    /// scale or shear), expressed directly as the transpose of `mInv`'s
    /// linear 3x3 rather than `m`'s. Linear part only, no translation; the
    /// result is not renormalized — callers that need a unit normal
    /// normalize it themselves.
    ///
    /// This IS the sanctioned path for a normal built by cross-producting
    /// two LOCAL edge vectors too (`bvh_pick.d`'s `pickSurfaceRay` calls it
    /// on exactly such a normal): `cross(u,v)` computed in local space and
    /// then mapped through this inverse-transpose gives the true outward
    /// world normal for any invertible `M`, mirrored or not — the
    /// `dot((M^-1)^T n, M v) == dot(n, v)` identity holds unconditionally. A
    /// previous version of this comment claimed the opposite — that
    /// `pickSurfaceRay` needed to cross-product already-WORLD vertices
    /// instead — reasoning that `cross(Ma,Mb) ==
    /// det(M)*(M^-1)^T*cross(a,b)` made the two paths "a different, stronger
    /// claim". That is true as a statement about the WINDING normal (which
    /// is exactly why cross-producting world vertices is wrong under a
    /// mirror: it silently carries the `det(M)` sign, pointing the result
    /// into the solid), but it does not apply here — this function is never
    /// given a world cross product to begin with; it transforms the LOCAL
    /// one, and the identity above holds without any determinant factor.
    /// Do not "fix" a mirror-flipped normal by cross-producting world points
    /// instead of calling this — that reintroduces the same defect.
    Vec3 toWorldNormal(Vec3 nLocal) const @safe pure nothrow @nogc {
        return Vec3(
            mInv[0]*nLocal.x + mInv[1]*nLocal.y + mInv[ 2]*nLocal.z,
            mInv[4]*nLocal.x + mInv[5]*nLocal.y + mInv[ 6]*nLocal.z,
            mInv[8]*nLocal.x + mInv[9]*nLocal.y + mInv[10]*nLocal.z,
        );
    }
    /// World-space NORMAL -> local-space normal: `M^T` applied to `nWorld`
    /// — the exact dual of `toWorldNormal` above, expressed as the transpose
    /// of `m`'s linear 3x3 (as `toWorldNormal` is the transpose of `mInv`'s).
    /// Linear part only, no translation; the result is NOT renormalized.
    ///
    /// Why it exists (task 0619, doc/tool_aiming_item_transform_plan.md §2.1):
    /// a cursor ray tested against a plane ANCHORED ON MESH GEOMETRY has to
    /// be evaluated in the layer's local space, because the consumer writes
    /// local vertex coordinates. Moving that test into local space needs the
    /// ray direction through `toLocalDir` (`M^-1`) and the plane's world
    /// normal through THIS (`M^T`), because
    /// `dot(M^T n, M^-1 d) == n^T M M^-1 d == dot(n, d)` EXACTLY, for any
    /// invertible `M`, mirrored or not — so the plane equation's sign and
    /// magnitude survive the move unchanged.
    ///
    /// Do NOT reach for `toLocalDir` to carry a normal: `M^T` and `M^-1` are
    /// EQUAL for a pure rotation, so the two agree exactly on a
    /// rotation-only fixture and diverge under any non-uniform scale or
    /// shear. That is the classic wrong normal transform, and a
    /// rotation-only test cannot see it.
    Vec3 toLocalNormal(Vec3 nWorld) const @safe pure nothrow @nogc {
        return Vec3(
            m[0]*nWorld.x + m[1]*nWorld.y + m[ 2]*nWorld.z,
            m[4]*nWorld.x + m[5]*nWorld.y + m[ 6]*nWorld.z,
            m[8]*nWorld.x + m[9]*nWorld.y + m[10]*nWorld.z,
        );
    }
}

unittest { // ModelSpace.world() is the identity: m/mInv == identityMatrix, flags all default.
    auto ms = ModelSpace.world();
    foreach (i; 0 .. 16) {
        assert(ms.m[i]    == identityMatrix[i]);
        assert(ms.mInv[i] == identityMatrix[i]);
    }
    assert(ms.isIdentity && ms.invertible && !ms.mirrored);
}

unittest { // toLocalPoint / toWorldPoint round-trip through a non-trivial M/mInv pair.
    // Pure translation is enough to exercise the full-affine (translation-
    // including) path independently of the rotation/scale helpers below.
    ModelSpace ms;
    ms.m    = translationMatrix(Vec3(3, -2, 5));
    ms.mInv = translationMatrix(Vec3(-3, 2, -5));
    ms.isIdentity = false;

    Vec3 localP = Vec3(1, 1, 1);
    Vec3 worldP = ms.toWorldPoint(localP);
    assert(isClose(worldP.x, 4.0f, 1e-5f, 1e-5f)
        && isClose(worldP.y, -1.0f, 1e-5f, 1e-5f)
        && isClose(worldP.z, 6.0f, 1e-5f, 1e-5f));
    Vec3 backToLocal = ms.toLocalPoint(worldP);
    assert(isClose(backToLocal.x, localP.x, 1e-5f, 1e-5f)
        && isClose(backToLocal.y, localP.y, 1e-5f, 1e-5f)
        && isClose(backToLocal.z, localP.z, 1e-5f, 1e-5f));
}

unittest { // toLocalDir preserves a ray's `t`: mInv*(org + t*dir) == toLocalPoint(org) + t*toLocalDir(dir).
    // §3.4 — the identity this un-normalized transform exists to guarantee.
    ModelSpace ms;
    ms.m    = pivotScaleMatrix(Vec3(0,0,0), 2, 1, 1);
    ms.mInv = pivotScaleMatrix(Vec3(0,0,0), 0.5f, 1, 1);
    ms.isIdentity = false;

    Vec3 org = Vec3(5, 5, 5);
    Vec3 dir = Vec3(1, -2, 0.5f); // deliberately not axis-aligned, not unit length
    float t = 3.7f;
    Vec3 worldHit  = org + dir * t;
    Vec3 localHit  = ms.toLocalPoint(worldHit);
    Vec3 orgLocal  = ms.toLocalPoint(org);
    Vec3 dirLocal  = ms.toLocalDir(dir); // must stay UN-normalized
    Vec3 predicted = orgLocal + dirLocal * t;
    assert(isClose(localHit.x, predicted.x, 1e-4f, 1e-4f)
        && isClose(localHit.y, predicted.y, 1e-4f, 1e-4f)
        && isClose(localHit.z, predicted.z, 1e-4f, 1e-4f),
        "toLocalDir must stay un-normalized for `t` to keep meaning a world distance");
}

// Rotation + NON-UNIFORM scale, with its exact analytic inverse. The two
// `toLocalNormal` unittests below both need it: under a pure rotation
// `M^T == M^-1`, so `toLocalNormal` and `toLocalDir` return the SAME vector
// and no rotation-only fixture can tell a correct implementation from the
// wrong one. `scl = (1.7, 1, 0.6)` is what makes them diverge.
version (unittest) private void rotNonUniformSpace(out ModelSpace ms) {
    Vec3 axis = normalize(Vec3(0.3f, 1.0f, -0.2f));
    auto R    = pivotRotationMatrix(Vec3(0,0,0), axis,  0.7f);
    auto Rinv = pivotRotationMatrix(Vec3(0,0,0), axis, -0.7f);
    auto S    = pivotScaleMatrix(Vec3(0,0,0), 1.7f, 1.0f, 0.6f);
    auto Sinv = pivotScaleMatrix(Vec3(0,0,0), 1.0f/1.7f, 1.0f, 1.0f/0.6f);
    ms.m    = matMul4(R, S);        // M    = R*S
    ms.mInv = matMul4(Sinv, Rinv);  // M^-1 = S^-1 * R^-1
    ms.isIdentity = false;
}

unittest { // toLocalNormal is the exact dual of toLocalDir:
    // `dot(M^T*n, M^-1*d) == dot(n, d)` for ANY invertible M (task 0619 §2.1).
    // This is the identity a RayPlane site relies on to move a plane test
    // anchored on mesh geometry into the layer's local space without
    // changing the number the test reads.
    ModelSpace ms;
    rotNonUniformSpace(ms);

    Vec3 nWorld = Vec3( 0.40f, -0.90f, 0.25f); // a world plane normal
    Vec3 dWorld = Vec3(-0.60f,  0.20f, 0.75f); // a world ray direction

    float truth = dot(nWorld, dWorld);
    float moved = dot(ms.toLocalNormal(nWorld), ms.toLocalDir(dWorld));
    assert(isClose(moved, truth, 1e-4f, 1e-4f),
        "dot(toLocalNormal(n), toLocalDir(d)) must equal dot(n, d) exactly");

    // ANTI-VACUITY. The plausible wrong implementation is "carry the normal
    // with toLocalDir as well" (the classic wrong normal transform). It must
    // read a DIFFERENT number on this same fixture, or the assertion above
    // would hold for both laws and would be measuring nothing.
    float wrong = dot(ms.toLocalDir(nWorld), ms.toLocalDir(dWorld));
    assert(!isClose(wrong, truth, 1e-2f, 1e-2f),
        "fixture is vacuous: the M^-1-on-the-normal law reads the same number here");
}

unittest { // toLocalNormal != toLocalDir under non-uniform scale (the negative
    // control), and they COINCIDE under a pure rotation — the second half is
    // why the fixture above is required to carry a non-uniform scale.
    ModelSpace ms;
    rotNonUniformSpace(ms);

    Vec3 n = Vec3(0.4f, -0.9f, 0.25f);
    Vec3 a = ms.toLocalNormal(n);
    Vec3 b = ms.toLocalDir(n);
    Vec3 d = a - b;
    assert(d.length > 1e-2f,
        "toLocalNormal must differ from toLocalDir under a non-uniform scale");

    // Pure rotation: M^T == M^-1, so the two are the same map. A test built
    // on a rotation-only ModelSpace would pass for either implementation.
    ModelSpace rot;
    Vec3 axis = normalize(Vec3(0.3f, 1.0f, -0.2f));
    rot.m    = pivotRotationMatrix(Vec3(0,0,0), axis,  0.7f);
    rot.mInv = pivotRotationMatrix(Vec3(0,0,0), axis, -0.7f);
    rot.isIdentity = false;
    Vec3 ra = rot.toLocalNormal(n);
    Vec3 rb = rot.toLocalDir(n);
    Vec3 rd = ra - rb;
    assert(rd.length < 1e-5f,
        "under a pure rotation toLocalNormal and toLocalDir must coincide — "
        ~ "this is why the discriminating fixture needs a non-uniform scale");
}

unittest { // The LOCAL front-facing test agrees DIRECTLY (no XOR, no
    // `mirrored` correction of any kind) with the TRUE GEOMETRIC world
    // front-facing test, for any invertible ModelSpace including a mirror.
    // "True geometric" here means the world outward normal is derived via
    // `ms.toWorldNormal(nLocal)` (the inverse-transpose rule) rather than by
    // cross-producting the triangle's WORLD-transformed vertices — the
    // latter is the WINDING normal, and this is exactly the distinction the
    // previous version of this unittest got backwards: it computed
    // `nWorldTrue` via `cross(bw-aw, cw-aw)` and labelled that "what is
    // ACTUALLY drawn", then asserted `localFront XOR mirrored` agreed with
    // it. That labelled a winding artefact as ground truth, so the
    // assertion just restated the determinant identity
    // `cross(Ma,Mb) == det(M)*(M^-1)^T*cross(a,b)` — it could not have
    // caught the flip being wrong, because it was built from the same
    // premise as the flip.
    //
    // The real identity: `dot((M^-1)^T n, M v) == dot(n, v)` EXACTLY (not
    // just same sign) for ANY invertible M, mirrored or not. Since
    // `pWorld - eyeWorld == M * (pLocal - eyeLocal)` for the linear part of
    // M, this makes `dot(toWorldNormal(nLocal), pWorld - eyeWorld) ==
    // dot(nLocal, pLocal - eyeLocal)` — literally the same number, no sign
    // correction possible or needed. That is why the flip was wrong: there
    // is nothing here for `ms.mirrored` to correct.
    void checkCase(float[16] m, float[16] mInv, bool mirrored) {
        ModelSpace ms;
        ms.m = m; ms.mInv = mInv; ms.isIdentity = false; ms.mirrored = mirrored;

        Vec3 a = Vec3(0, 0, 0), b = Vec3(1, 0, 0), c = Vec3(0, 1, 0);
        Vec3 eyeLocal = Vec3(0, 0, 5); // above the local A,B,C plane (+Z)

        Vec3 nLocal = cross(b - a, c - a);
        bool localFront = dot(nLocal, a - eyeLocal) < 0;

        Vec3 nWorldGeometric = ms.toWorldNormal(nLocal); // NOT a world cross product
        Vec3 aw           = ms.toWorldPoint(a);
        Vec3 eyeWorld      = ms.toWorldPoint(eyeLocal);
        bool worldFrontGeometric = dot(nWorldGeometric, aw - eyeWorld) < 0;

        assert(localFront == worldFrontGeometric,
            "the local front-facing test must agree with the geometric world "
            ~ "test directly — no mirror correction needed or applied");
    }

    // Non-mirrored: scl=(2,1,1) (det > 0).
    checkCase(pivotScaleMatrix(Vec3(0,0,0), 2, 1, 1),
              pivotScaleMatrix(Vec3(0,0,0), 0.5f, 1, 1), false);
    // Mirrored: scl=(-1,1,1) (det < 0) — a single negative axis.
    checkCase(pivotScaleMatrix(Vec3(0,0,0), -1, 1, 1),
              pivotScaleMatrix(Vec3(0,0,0), -1, 1, 1), true);
    // Mirrored: scl=(-1,-1,-1) (det < 0) — three negative axes (odd count).
    checkCase(pivotScaleMatrix(Vec3(0,0,0), -1, -1, -1),
              pivotScaleMatrix(Vec3(0,0,0), -1, -1, -1), true);
    // Non-mirrored: scl=(-1,-1,1) (det > 0) — two negative axes (even count).
    checkCase(pivotScaleMatrix(Vec3(0,0,0), -1, -1, 1),
              pivotScaleMatrix(Vec3(0,0,0), -1, -1, 1), false);
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
//
// Task 0617: attributed @safe pure nothrow @nogc (it always qualified — pure
// arithmetic over fixed-size stack arrays) so the "no allocation on a picking
// path" property of `ModelSpace`/`projectionSpace` below is compiler-enforced
// rather than merely asserted in a comment.
float[16] matMul4(float[16] a, float[16] b) @safe pure nothrow @nogc {
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

/// The eye vector at a world point: the direction the view looks ALONG as it
/// passes through `p`. Perspective diverges from the eye, orthographic is
/// constant.
///
/// Lives here rather than in a tool module because it is plain view geometry
/// with no tool semantics, and because two unrelated families need it: the
/// click-relocate plane law (`tools.transform.relocate_plane`, which
/// re-exports it for its own callers) and the gizmo's handle-facing cull
/// (`handles.gl_util.axisFacesViewer`). Being per-point rather than a single
/// global forward vector is the whole reason the cull is correct for a gizmo
/// that sits away from the camera focus.
Vec3 eyeVectorAt(const ref Viewport vp, Vec3 p) @safe pure nothrow @nogc {
    if (isOrtho(vp)) return normalize(Vec3(-vp.view[2], -vp.view[6], -vp.view[10]));
    return normalize(p - vp.eye);
}

/// The world axis a view is locked to, or -1 when it has none.
///
/// The reference reads a view TYPE field and decodes it to an axis; we have
/// no such field on `Viewport`, so the same class of view is recognised
/// GEOMETRICALLY: an orthographic projection whose forward vector is a world
/// axis. In vibe3d that is exactly `ProjKind.Ortho` with one of the six
/// `ViewPreset` axis presets, because `View.viewportWith` builds those six
/// from a hard-coded axis eye and ignores azimuth/elevation.
///
/// The two ways to be ortho WITHOUT a locked axis — `ViewPreset.Perspective`
/// or `.Camera` under `ProjKind.Ortho`, which keep the free spherical basis —
/// return -1 here unless the free camera happens to be exactly axis-aligned.
/// That coincidence is measure-zero and costs nothing when it happens: with
/// the rays parallel to `e_k` the ray arm and the locked arm agree on every
/// component except the quantum on the plane point.
///
/// Second consumer, added later: the rotate-ring cull (`handles.gl_util`),
/// where this stands in for the reference's viewport-TYPE lookup — a lookup
/// that never inspects where the camera points, which is why modelling it as
/// "ortho AND axis-aligned" rather than "ortho" is the faithful reading.
int lockedViewAxis(const ref Viewport vp) @safe pure nothrow @nogc {
    if (!isOrtho(vp)) return -1;
    // Column-major view matrix: forward = (-m[2], -m[6], -m[10]).
    Vec3 f = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
    enum float axisEps = 1e-4f;
    if (abs(abs(f.x) - 1.0f) < axisEps && abs(f.y) < axisEps && abs(f.z) < axisEps) return 0;
    if (abs(abs(f.y) - 1.0f) < axisEps && abs(f.x) < axisEps && abs(f.z) < axisEps) return 1;
    if (abs(abs(f.z) - 1.0f) < axisEps && abs(f.x) < axisEps && abs(f.y) < axisEps) return 2;
    return -1;
}

Vec3 sphericalToCartesian(float az, float el, float dist) {
    return Vec3(dist * cos(el) * sin(az),
                dist * sin(el),
                dist * cos(el) * cos(az));
}

// ---------------------------------------------------------------------------
// Orientation — a camera's rotational state as a 3x3, the STORED TRUTH.
// ---------------------------------------------------------------------------

/// An orthonormal, right-handed camera orientation held as nine floats whose
/// **columns** are the world-space camera basis:
///
///     m[0 .. 3]  screen-RIGHT
///     m[3 .. 6]  screen-UP
///     m[6 .. 9]  BACK  ( = -forward; focus -> eye, i.e. the orbit direction )
///
/// with `right x up == back`, matching the camera-looks-down-its-own-minus-Z
/// convention every consumer in the tree already reads off the view matrix
/// (`view[0]/[4]/[8]` = right, `[1]/[5]/[9]` = up, `-[2]/-[6]/-[10]` = forward).
///
/// **Why a matrix and not three angles.** Azimuth/elevation/roll is a CHART on
/// the rotation group, not the group: it is singular at the poles (which is
/// exactly why the spherical camera clamps elevation to 89 deg), and it cannot
/// express the composition of two rotations about different axes without going
/// back through the chart and losing the pole. A 3x3 has neither problem, and
/// it is the representation a reference viewport persists for itself — nine
/// floats per view, orthonormal to <= 1e-7, re-normalised on write.
///
/// The three angles remain available as DERIVED reads (`toAngles`), which is
/// the same relationship that reference publishes between its stored
/// orientation and the heading/pitch/bank triple it reports.
/// How far an orientation may sit from a perfect rotation before
/// `Orientation.orthonormalized` re-derives it. Two orders of magnitude above
/// the float dust a clean construction leaves (~3e-7 on the
/// `orthonormalityDefect` scale) and far below any drift that could matter, so
/// the normalisation is a repair and not a per-frame bit-churn. See
/// `orthonormalized` for why the gate is what makes that function idempotent.
enum float kOrientationTolerance = 1e-5f;

struct Orientation {
    /// Column-major, columns = basis vectors. Default = the identity camera
    /// (looking down -Z with +Y up), never a zero matrix: a default-init
    /// `Orientation` must be a usable rotation, because an aggregate that
    /// contains one is default-initialised before any constructor runs.
    float[9] m = [1, 0, 0,  0, 1, 0,  0, 0, 1];

    Vec3 right()   const @safe pure nothrow @nogc { return Vec3( m[0],  m[1],  m[2]); }
    Vec3 up()      const @safe pure nothrow @nogc { return Vec3( m[3],  m[4],  m[5]); }
    Vec3 back()    const @safe pure nothrow @nogc { return Vec3( m[6],  m[7],  m[8]); }
    Vec3 forward() const @safe pure nothrow @nogc { return Vec3(-m[6], -m[7], -m[8]); }

    /// Assemble from three basis vectors WITHOUT re-orthonormalising. Only for
    /// callers that built the triple orthonormal by construction; anything
    /// reading foreign data must go through `orthonormalized`.
    static Orientation fromBasis(Vec3 r, Vec3 u, Vec3 b) @safe pure nothrow @nogc {
        Orientation o;
        o.m = [r.x, r.y, r.z,  u.x, u.y, u.z,  b.x, b.y, b.z];
        return o;
    }

    /// The orientation of a spherical camera at (azimuth, elevation) banked by
    /// `roll`, in radians — the chart-to-group direction.
    ///
    /// Closed form rather than the cross-product chain the pre-matrix camera
    /// used, for one reason that matters: `normalize(cross(forward, +Y))` is
    /// 0/0 at the poles, so the chain produced NaN at |elevation| = 90 deg and
    /// the camera had to be clamped short of it. The closed form is the
    /// analytic limit and is finite everywhere, so a pole is a representable
    /// camera. The clamp stays where it is (in the ORBIT GESTURE, which is a
    /// separate question) but it is no longer load-bearing for the arithmetic.
    ///
    /// Derivation: the unbanked basis is
    ///     right  = ( cos az,            0,       -sin az           )
    ///     up     = (-sin az * sin el,   cos el,  -cos az * sin el  )
    ///     back   = ( cos el * sin az,   sin el,   cos el * cos az  )
    /// (`back` is `sphericalToCartesian(az, el, 1)`, i.e. the orbit offset
    /// direction), and a bank rotates the (right, up) pair about `back`.
    static Orientation fromAngles(float az, float el, float roll)
        @safe pure nothrow @nogc
    {
        immutable float ca = cos(az), sa = sin(az);
        immutable float ce = cos(el), se = sin(el);
        immutable Vec3 r0 = Vec3( ca,       0,   -sa);
        immutable Vec3 u0 = Vec3(-sa * se,  ce,  -ca * se);
        immutable Vec3 b  = Vec3( ce * sa,  se,   ce * ca);
        if (roll == 0.0f) return fromBasis(r0, u0, b);
        immutable float cr = cos(roll), sr = sin(roll);
        // The sign is pinned, not chosen: it is the one for which
        // `right.y == -sin(roll) * cos(elevation)`, the identity a reference
        // viewport's screen-right row obeys against its own reported bank.
        return fromBasis(r0 * cr - u0 * sr, u0 * cr + r0 * sr, b);
    }

    /// The (azimuth, elevation, roll) chart coordinates of this orientation —
    /// a DERIVED read, the inverse of `fromAngles`.
    ///
    /// At a pole (`|back.y| -> 1`) the chart degenerates: heading and bank
    /// describe the same rotation there and cannot be separated. The documented
    /// policy is to report `roll = 0` and fold the whole rotation into
    /// `azimuth`, which keeps `fromAngles(toAngles(o)) == o` (up to float dust)
    /// everywhere INCLUDING the pole rather than only away from it.
    void toAngles(out float az, out float el, out float roll)
        const @safe pure nothrow @nogc
    {
        immutable Vec3 b = back(), r = right(), u = up();
        float by = b.y;
        if (by >  1.0f) by =  1.0f;
        if (by < -1.0f) by = -1.0f;
        el = asin(by);
        immutable float ce = cos(el);
        if (ce > 1e-6f || ce < -1e-6f) {
            az   = atan2(b.x, b.z);
            // right.y == -sin(roll)*cos(el), up.y == cos(roll)*cos(el)
            roll = atan2(-r.y, u.y);
        } else {
            // Pole. `up` carries the heading: at el = +90 the unbanked up is
            // (-sin az, 0, -cos az), at el = -90 it is (sin az, 0, cos az).
            immutable float s = by > 0.0f ? -1.0f : 1.0f;
            az   = atan2(s * u.x, s * u.z);
            roll = 0.0f;
        }
    }

    @property float azimuth()   const @safe pure nothrow @nogc {
        float a, e, r; toAngles(a, e, r); return a;
    }
    @property float elevation() const @safe pure nothrow @nogc {
        float a, e, r; toAngles(a, e, r); return e;
    }
    @property float roll()      const @safe pure nothrow @nogc {
        float a, e, r; toAngles(a, e, r); return r;
    }

    /// How far this matrix has drifted from being an orthonormal right-handed
    /// rotation: the sum of the three unit-length defects, the three pairwise
    /// dot products, and the handedness residual `|right x up - back|`. Exactly
    /// 0 for a perfect rotation. Used by the write-time discipline and by tests
    /// (a reference viewport's shipped orientations score <= 1e-7 on this).
    float orthonormalityDefect() const @safe pure nothrow @nogc {
        immutable Vec3 r = right(), u = up(), b = back();
        immutable Vec3 h = cross(r, u) - b;
        return abs(r.length - 1.0f) + abs(u.length - 1.0f) + abs(b.length - 1.0f)
             + abs(dot(r, u)) + abs(dot(r, b)) + abs(dot(u, b))
             + abs(h.x) + abs(h.y) + abs(h.z);
    }

    /// Re-derive a clean orthonormal right-handed basis — the normalisation
    /// discipline. **Every write of an orientation that was not built
    /// orthonormal by construction goes through this**: deserialisation, the
    /// HTTP setter, and any incremental composition, so accumulated drift can
    /// never reach the view matrix.
    ///
    /// Anchored on `back`, because that is the direction the camera looks and
    /// the one a correction must not move: `back` is normalised, `right` is
    /// re-derived as `up x back`, and `up` as `back x right`. Degenerate inputs
    /// (zero columns, `up` parallel to `back`) fall back through the stored
    /// `right` column and then a world axis rather than producing NaN.
    ///
    /// **Idempotent, and that is a hard requirement rather than a nicety**:
    /// `o.orthonormalized().orthonormalized()` is bit-equal to
    /// `o.orthonormalized()`, which is what lets a serialisation round-trip be
    /// bit-exact even though the reader re-normalises everything it reads.
    ///
    /// A bare Gram-Schmidt pass is NOT idempotent — `normalize` does not return
    /// an exactly-unit vector, so a second pass moves the last bits again, and
    /// an orientation would drift by an ulp on every save/load cycle. The fixed
    /// point comes from the tolerance gate below: a matrix already within
    /// `kOrientationTolerance` of a rotation is returned UNTOUCHED, and one
    /// pass always lands inside that band, so the second call is a no-op. The
    /// gate is also the right policy on its own terms — float dust is not
    /// drift, and re-deriving nine floats to chase it would churn the camera
    /// every frame for no gain.
    Orientation orthonormalized() const @safe pure nothrow @nogc {
        if (orthonormalityDefect() <= kOrientationTolerance) return this;
        Vec3 b = back();
        float bl = b.length;
        if (!(bl > 1e-12f)) { b = Vec3(0, 0, 1); bl = 1.0f; }
        if (bl != 1.0f) b = b * (1.0f / bl);

        Vec3 r  = cross(up(), b);
        float rl = r.length;
        if (!(rl > 1e-6f)) {
            // `up` is parallel to `back` (or zero): recover the roll from the
            // stored right column instead.
            r  = right() - b * dot(right(), b);
            rl = r.length;
        }
        if (!(rl > 1e-6f)) {
            // Both transverse columns are unusable: any perpendicular will do.
            immutable Vec3 seed = (abs(b.y) < 0.9f) ? Vec3(0, 1, 0) : Vec3(1, 0, 0);
            r  = cross(seed, b);
            rl = r.length;
        }
        if (rl != 1.0f) r = r * (1.0f / rl);
        return fromBasis(r, cross(b, r), b);
    }

    /// This orientation followed by a rotation of `angle` radians about the
    /// WORLD-space `axis` (Rodrigues), re-orthonormalised.
    ///
    /// The composition primitive a matrix truth exists for: an arbitrary-axis
    /// increment has no expression in the angle chart, which is the whole
    /// reason the storage changed. Used here to build test orientations no
    /// scalar bank can represent.
    Orientation rotatedAbout(Vec3 axis, float angle) const @safe pure nothrow @nogc {
        immutable float al = axis.length;
        if (!(al > 1e-12f)) return this;
        immutable Vec3 k = axis * (1.0f / al);
        immutable float c = cos(angle), s = sin(angle);
        Vec3 rot(Vec3 v) {
            return v * c + cross(k, v) * s + k * (dot(k, v) * (1.0f - c));
        }
        return fromBasis(rot(right()), rot(up()), rot(back())).orthonormalized();
    }
}

/// The view matrix for a camera with orientation `o` sitting at `eye` — the
/// world-to-camera transform `[R^T | -R^T * eye]`, column-major.
///
/// This is `lookAt`'s output for the same camera, but taken from a STORED
/// orientation rather than rebuilt from an eye/target/world-up triple. The two
/// agree exactly on the nine rotation lanes; they can differ by one ulp in the
/// translation lanes because `lookAt` re-derives its forward from
/// `center - eye`, whose rounding depends on where the focus happens to sit.
float[16] viewMatrixFrom(Orientation o, Vec3 eye) @safe pure nothrow @nogc {
    immutable Vec3 r = o.right(), u = o.up(), b = o.back();
    return [
         r.x,  u.x,  b.x, 0,
         r.y,  u.y,  b.y, 0,
         r.z,  u.z,  b.z, 0,
        -dot(r, eye), -dot(u, eye), -dot(b, eye), 1,
    ];
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

// Compose a layer's item transform into a Viewport for FORWARD PROJECTION
// only: `proj*(view*M)*v_local == proj*view*(M*v_local)`, so folding `M`
// into `vp.view` (and `vp.eye` into local space, per the plan) lets every
// existing `projectToWindow*` call site pick up the item transform with a
// one-line `vp` -> `projectionSpace(vp, ms)` swap. A stack copy of Viewport;
// no allocation. Exact identity fast path (§3.5): `ms.isIdentity` returns
// `vp` unchanged, byte-identical to every call site's pre-0617 behaviour.
//
// DO NOT use the result of this function to build a ray (`screenRay`,
// `screenPointToRay`). Both derive the world ray direction by treating the
// view matrix's upper-left 3x3 AS ITS OWN INVERSE (transpose-as-inverse —
// see `screenRay`'s comment), which is only valid for an orthonormal
// rotation. Composing a scale or shear into `view` breaks that assumption
// SILENTLY — the ray direction comes out wrong with no error raised. Rays
// must be built in WORLD space from the real (uncomposed) Viewport, and only
// then transformed into local space with `ModelSpace.toLocalDir` /
// `toLocalPoint`. See doc/picking_item_transform_plan.md §3.3 (task 0617).
// `ms` is BY VALUE, not `const ref`: call sites routinely pass an rvalue
// (`ModelSpace.world()`, `primaryModelSpace()`), which a `const ref`
// parameter cannot bind without a compiler preview flag this project does
// not use. `ModelSpace` is two `float[16]` + three `bool` (~132 bytes) — a
// cheap stack copy, not a reason to reach for `ref`.
//
// DO NOT feed the result of this function into `viewPixelScale` (or any
// other helper measuring `eye`-to-`focus` distance). This function is
// PROJECTION-ONLY and deliberately transforms `eye` alone — `out_.focus` is
// left as `vp.focus`, still in WORLD space, while `out_.eye` is now in the
// LAYER's local space. `viewPixelScale` would then subtract a local-space
// point from a world-space one and return a meaningless scale. Transforming
// `focus` too would NOT fix this — it would make it WRONG in a different,
// worse way: `viewPixelScale`'s own contract (see its doc comment) is that
// the returned scale depends on the CAMERA ALONE, so every layer under one
// camera shares one pixel size. Folding a per-layer `M` into the eye/focus
// distance would make the "world units per pixel" answer depend on which
// layer's `ModelSpace` happened to be composed in — a single scalar can't
// mean that. Worse, under a NON-UNIFORM scale the local-space distance is
// direction-dependent (an isotropic world sphere maps to an ellipsoid), so
// no single scalar distance is even the right SHAPE of answer once `M` is
// non-uniform. If a future stage needs a per-pixel measure in local space,
// it has to be derived some other way — not by handing `projectionSpace`'s
// output to `viewPixelScale`.
Viewport projectionSpace(const ref Viewport vp, const ModelSpace ms) @safe pure nothrow @nogc {
    if (ms.isIdentity) return vp; // exact fast path — no matMul4, byte-identical
    Viewport out_ = vp;
    out_.view = matMul4(vp.view, ms.m);
    out_.eye  = ms.toLocalPoint(vp.eye);
    return out_;
}

unittest { // projectionSpace: identity fast path returns `vp` unchanged (byte-identical).
    Viewport vp;
    vp.view = identityMatrix; vp.proj = identityMatrix;
    vp.width = 800; vp.height = 600; vp.eye = Vec3(1, 2, 3);
    auto vp2 = projectionSpace(vp, ModelSpace.world());
    foreach (i; 0 .. 16) { assert(vp2.view[i] == vp.view[i]); assert(vp2.proj[i] == vp.proj[i]); }
    assert(vp2.eye.x == vp.eye.x && vp2.eye.y == vp.eye.y && vp2.eye.z == vp.eye.z);
}

unittest { // projectionSpace: forward projection agrees with pre-transforming the point —
    // projectToWindow(pLocal, projectionSpace(vp, ms)) == projectToWindow(ms.toWorldPoint(pLocal), vp).
    import std.math : PI;

    Vec3 eye = Vec3(0, 0, 8);
    Viewport vp;
    vp.view = lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj = perspectiveMatrix(60.0f * PI / 180.0f, 1.0f, 0.01f, 100.0f);
    vp.width = 400; vp.height = 400; vp.eye = eye;

    ModelSpace ms;
    ms.m    = matMul4(translationMatrix(Vec3(1, -0.5f, 0)),
                       pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), 0.4f));
    // mInv unused by projectionSpace's forward path except via toLocalPoint(eye);
    // give it the analytic inverse of the same T*R so that leg is exact too.
    ms.mInv = matMul4(pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), -0.4f),
                       translationMatrix(Vec3(-1, 0.5f, 0)));
    ms.isIdentity = false;

    Vec3 pLocal = Vec3(0.3f, 0.2f, -0.1f);

    Viewport vpLocal = projectionSpace(vp, ms);
    float px1, py1, z1;
    bool ok1 = projectToWindow(pLocal, vpLocal, px1, py1, z1);

    Vec3 pWorld = ms.toWorldPoint(pLocal);
    float px2, py2, z2;
    bool ok2 = projectToWindow(pWorld, vp, px2, py2, z2);

    assert(ok1 == ok2, "projectionSpace must agree with pre-transforming the point on visibility");
    assert(ok1);
    assert(isClose(px1, px2, 1e-3f, 1e-3f) && isClose(py1, py2, 1e-3f, 1e-3f)
        && isClose(z1, z2, 1e-3f, 1e-3f),
        "projectionSpace(vp,ms) projection must match projecting the pre-transformed world point");
}

// ---------------------------------------------------------------------------
// AimViewport — a NOMINAL type for "the aiming space" (task 0619 §2.0).
//
// `projectionSpace` returns a plain `Viewport`, so nothing stops a call site
// from projecting a LAYER-LOCAL mesh coordinate through the WORLD viewport —
// which is precisely the defect this family of tasks exists to remove, and
// which a naming convention (`vpAim*`) policed by a grep cannot prevent.
// `AimViewport` turns that into a compile error instead: it wraps a Viewport
// that has ALREADY had a `ModelSpace` composed into it, and it cannot be
// produced without supplying one, because
//
//   * its default constructor is `@disable`d, so `AimViewport v;` is illegal;
//   * its only constructor is module-private, so outside `math.d` the only
//     way to obtain one is `aimSpace(vp, ms)`;
//   * it does not implicitly convert from `Viewport`, so a world viewport
//     cannot be passed where an aim space is expected (and vice versa).
//
// The intended shape of an aiming helper is therefore a pair:
//   `f(Vec3 pLocal, const ref AimViewport vpAim, ...)`  — local geometry
//   `g(Vec3 pWorld, const ref Viewport    vp,    ...)`  — already-world value
// so an "this value is already in world space" site keeps a typed home and
// nobody has to fabricate an aim space to express it.
//
// The one residue this type does NOT catch is `aimSpace(vp, ModelSpace.world())`
// — a real aim space built from an identity transform. §2.3 of the plan bans
// `ModelSpace.world()` outright in the files this task edits for that reason.
//
// Deliberately NOT accepted by `screenPointToRay`/`screenRay`: a composed
// view matrix breaks their transpose-as-inverse assumption (see
// `projectionSpace`'s doc comment above), so keeping those on the plain
// `Viewport` makes the double-apply a type error too.
// ---------------------------------------------------------------------------
struct AimViewport {
    @disable this();                 // no accessible default construction
    private Viewport vp_;            // module-private: only math.d can fill it
    private this(Viewport v) @safe pure nothrow @nogc { vp_ = v; }
    /// The composed viewport, for handing to `projectToWindow*`.
    @property ref const(Viewport) vp() const return @safe pure nothrow @nogc {
        return vp_;
    }
}

/// Build the aiming space for `ms`: `projectionSpace(vp, ms)` in an
/// `AimViewport` wrapper. Adds a TYPE, not a behaviour — the composed
/// viewport is field-identical to `projectionSpace`'s, identity fast path
/// included. A stack copy plus (off the identity path) one `matMul4`: cheap
/// once per query, unacceptable per vertex — hoist it out of O(V) loops.
AimViewport aimSpace(const ref Viewport vp, const ModelSpace ms) @safe pure nothrow @nogc {
    return AimViewport(projectionSpace(vp, ms));
}

unittest { // aimSpace adds a type, not a behaviour: field-identical to projectionSpace.
    import std.math : PI;
    Vec3 eye = Vec3(0, 0, 8);
    Viewport vp;
    vp.view = lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.01f, 100.0f);
    vp.width = 640; vp.height = 480; vp.x = 7; vp.y = 11;
    vp.eye = eye; vp.focus = Vec3(0, 0, 0);

    ModelSpace ms;
    rotNonUniformSpace(ms);

    Viewport ref_ = projectionSpace(vp, ms);
    auto     aim  = aimSpace(vp, ms);
    foreach (i; 0 .. 16) {
        assert(aim.vp.view[i] == ref_.view[i]);
        assert(aim.vp.proj[i] == ref_.proj[i]);
    }
    assert(aim.vp.width == ref_.width && aim.vp.height == ref_.height);
    assert(aim.vp.x == ref_.x && aim.vp.y == ref_.y);
    assert(aim.vp.eye.x == ref_.eye.x && aim.vp.eye.y == ref_.eye.y
        && aim.vp.eye.z == ref_.eye.z);
    assert(aim.vp.focus.x == ref_.focus.x && aim.vp.focus.y == ref_.focus.y
        && aim.vp.focus.z == ref_.focus.z);

    // Identity fast path: byte-identical to the world viewport handed in.
    auto id = aimSpace(vp, ModelSpace.world());
    foreach (i; 0 .. 16) {
        assert(id.vp.view[i] == vp.view[i]);
        assert(id.vp.proj[i] == vp.proj[i]);
    }
}

unittest { // AimViewport is the compile GATE, not a naming convention.
    // A wrong-but-plausible call site is "pass the world viewport where the
    // aim space belongs". These static asserts are what make that impossible;
    // if any of them ever starts compiling, the gate is gone and every
    // converted site silently reverts to being policed by review alone.

    // (1) No accessible default constructor — `AimViewport v;` must not compile.
    static assert(!__traits(compiles, { AimViewport v; }),
        "AimViewport must not be default-constructible");

    // (2) NOT assertable HERE, deliberately: `private` in D is module-scoped,
    //     so both `AimViewport(someViewport)` and `AimViewport a = someViewport;`
    //     (D's one-argument-constructor initialiser form) DO compile inside
    //     math.d. The "only `aimSpace` can produce one" half of the gate binds
    //     every OTHER module, so it is asserted from a consumer module
    //     instead — see the `version (unittest)` gate block at the bottom of
    //     source/tools/edit/drag_weld.d. Writing that assert here would have
    //     been the exact vacuous-test shape this task is held to.

    // (3) A function that wants an aim space must reject a world viewport.
    static void wantsAim(const ref AimViewport a) { cast(void)a.vp.width; }
    static assert(!__traits(compiles, { Viewport w; wantsAim(w); }),
        "a helper taking AimViewport must not accept a plain Viewport");
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

/// The cursor ray of screen pixel (sx, sy), expressed in `ms`'s LOCAL space.
///
/// This is the **RayPlane** aiming law (task 0619,
/// doc/tool_aiming_item_transform_plan.md §1.2) as one call, so the three
/// steps that must not be reordered or skipped cannot be got wrong per site:
///
///  1. **Build the ray from the UN-composed, WORLD viewport.** An
///     `AimViewport` (a viewport with `M` folded into its view matrix) must
///     NOT be used here — `screenRay` treats the view 3x3's transpose as its
///     inverse, which is only valid for a rotation, and `M` generally carries
///     a scale. That is why this takes a plain `Viewport` and there is no
///     overload taking an `AimViewport`: the double-apply is a type error.
///  2. `toLocalPoint` the origin, `toLocalDir` the direction.
///  3. **Do NOT renormalize `dirLocal`.** `mInv*(o + t*d) == toLocalPoint(o)
///     + t*toLocalDir(d)`, so an un-normalized local direction keeps the ray
///     parameter `t` meaning a WORLD distance. Normalizing rescales `t` by
///     the layer's scale along the ray.
///
/// A plane test written against the result is EXACT, not approximate,
/// provided the plane is expressed in local space too — either because its
/// normal was built from local geometry already (a `mesh.faceNormal`), or by
/// carrying a world normal across with `ModelSpace.toLocalNormal` (`M^T`).
/// In both cases `dot(n_local, dirLocal) == dot(n_world, dirWorld)` exactly,
/// so `rayPlaneIntersect`'s parallel-ray guard fires on exactly the same
/// configurations it would have in world space.
///
/// Local is the destination (rather than lifting the geometry to world)
/// because the consumers of these hits WRITE LOCAL VERTEX COORDINATES.
/// Producing a world hit and handing it to such a consumer is the same
/// defect one call deeper.
void screenPointToLocalRay(float sx, float sy, const ref Viewport vpWorld,
                           const ModelSpace ms, out Vec3 orgLocal, out Vec3 dirLocal)
{
    Vec3 o, d;
    screenPointToRay(sx, sy, vpWorld, o, d);
    orgLocal = ms.toLocalPoint(o);
    dirLocal = ms.toLocalDir(d);   // deliberately NOT renormalized — see above
}

unittest { // screenPointToLocalRay + a local plane reads the SAME hit as the
    // world ray against the world plane — the identity every RayPlane site in
    // task 0619 relies on. Fixture: rotation + NON-UNIFORM scale, because
    // under a rotation alone every candidate law below collapses onto the
    // correct one.
    import std.math : PI, isClose;
    Vec3 eye = Vec3(2.5f, 1.8f, 7.0f);
    Viewport vp;
    vp.view = lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj = perspectiveMatrix(45.0f * PI / 180.0f, 4.0f / 3.0f, 0.001f, 100.0f);
    vp.width = 800; vp.height = 600; vp.x = 0; vp.y = 0;
    vp.eye = eye; vp.focus = Vec3(0, 0, 0);

    ModelSpace ms;
    rotNonUniformSpace(ms);

    // A plane anchored on LOCAL geometry, with a LOCAL normal — the tack /
    // face-plane shape.
    Vec3 anchorL = Vec3(0.35f, -0.20f, 0.45f);
    Vec3 nLocal  = normalize(Vec3(0.2f, 0.9f, -0.35f));

    Vec3 oL, dL;
    screenPointToLocalRay(430.0f, 260.0f, vp, ms, oL, dL);
    Vec3 hitL;
    assert(rayPlaneIntersect(oL, dL, anchorL, nLocal, hitL), "local ray must meet the plane");

    // Ground truth, derived independently: the SAME plane in world space
    // (anchor through `m`, normal through the inverse-transpose) met by the
    // world ray, then carried back with `mInv`.
    Vec3 oW, dW;
    screenPointToRay(430.0f, 260.0f, vp, oW, dW);
    Vec3 hitW;
    assert(rayPlaneIntersect(oW, dW, ms.toWorldPoint(anchorL),
                             ms.toWorldNormal(nLocal), hitW));
    Vec3 truth = ms.toLocalPoint(hitW);
    assert((hitL - truth).length < 1e-3f,
        "the local-space ray/plane meet must be the world meet carried back");

    // ANTI-VACUITY (1): the pre-0619 law — world ray against the LOCAL plane,
    // i.e. no transform at all — must read a different point here, or this
    // fixture proves nothing.
    Vec3 hitWrong;
    assert(rayPlaneIntersect(oW, dW, anchorL, nLocal, hitWrong));
    assert((hitWrong - hitL).length > 1e-2f,
        "fixture is vacuous: the untransformed ray reads the same hit");

    // ANTI-VACUITY (2): renormalizing the local direction. The HIT point is
    // unchanged by that (a ray is a set of points), but `t` is not — and `t`
    // is a world distance every nearest-hit comparison ranks on. Pin the
    // scale factor so a future `normalize()` here is caught by a number.
    float tExact = dot(hitL - oL, dL) / dot(dL, dL);
    float tWorld = dot(hitW - oW, dW);   // dW is unit, so this IS world distance
    assert(tExact > 1e-4f && tWorld > 1e-4f);
    assert(isClose(tExact, tWorld, 1e-3f, 1e-3f),
        "the un-normalized local direction must keep `t` a WORLD distance");
    // ...and that is not automatic: had the direction been normalized, `t`
    // would read the LOCAL distance instead, a different number on this
    // fixture. (Asserted second so a broken implementation trips the
    // assertion above, which names the defect, rather than this one.)
    Vec3  dUnit = normalize(dL);
    float tUnit = dot(hitL - oL, dUnit);
    assert(!isClose(tExact, tUnit, 1e-2f, 1e-2f),
        "fixture is vacuous: normalizing the local direction leaves `t` unchanged");
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

// ---------------------------------------------------------------------------
// closestOnSegmentToRay — the parameter on the world segment a→b of the point
// of CLOSEST APPROACH to the ray LINE (origin, dir), clamped to [0, 1].
//
// This is the ordinary 3D line/segment closest approach, and it is the law a
// cursor-to-edge election runs on. It is NOT the screen-nearest point on the
// segment, and the difference is not a rounding term: the two agree only when
// the eye, the cursor ray and the edge are coplanar, and disagree by up to 0.61
// in parameter otherwise (a clamp disagreement — one model wants a point past
// an endpoint and the other does not). Anyone reaching for "the point that
// projects nearest the cursor" wants a different function; the RANK that goes
// with this election is the re-projected screen distance of the point this
// returns, which the caller computes, not this.
//
// The construction, written as the perpendicular it is:
//
//     E = b − a
//     M = (dir × E) × dir      -- E's component perpendicular to `dir`, times
//                                 |dir|²; the plane the closest approach lives in
//     t = dot(origin − a, M) / dot(E, M)
//
// The usual statement of this normalises M first. That is redundant here and
// deliberately skipped: M appears once in the numerator and once in the
// denominator, so any positive scale on it cancels exactly, and dropping the
// normalise removes both a square root and its epsilon. `dot(E, M)` is then
// |M|²/|dir|² — always non-negative — so the single `> 0` denominator test
// below covers BOTH degeneracies the normalising form needs two tests for:
// a zero-length segment, and a segment parallel to the ray (where M vanishes).
//
// `dir` need not be unit-length; the ratio is invariant under its scale.
//
// DEGENERATE ⇒ false, with `t = 0`. A segment parallel to the view ray projects
// to a single pixel, so every parameter on it is equally near the cursor in
// screen space and no choice among them is more correct than another; `t = 0`
// is a choice, not a measurement, and the `false` return lets a caller that
// cares say so.
bool closestOnSegmentToRay(Vec3 origin, Vec3 dir, Vec3 a, Vec3 b, out float t)
{
    t = 0.0f;
    Vec3 e = b - a;
    Vec3 m = cross(cross(dir, e), dir);
    float den = dot(e, m);
    if (!(den > 0.0f)) return false;      // also rejects NaN
    float u = dot(origin - a, m) / den;
    if (u < 0.0f) u = 0.0f;
    else if (u > 1.0f) u = 1.0f;
    t = u;
    return true;
}

unittest { // closestOnSegmentToRay — the interior solution, on a rig where the
           // screen-nearest and the 3D-nearest points are NOT the same point.
    // Eye at the origin looking down -Z; the ray through a point that is off
    // the plane containing the segment, so coplanarity cannot hide a
    // difference. Segment spans a 5:1 depth ratio.
    Vec3 o = Vec3(0, 0, 0);
    Vec3 d = normalize(Vec3(0.2f, 0.1f, -1.0f));
    Vec3 a = Vec3(1.0f, 0.0f, -2.0f);
    Vec3 b = Vec3(0.0f, 1.0f, -10.0f);
    float t;
    assert(closestOnSegmentToRay(o, d, a, b, t), "a well-conditioned rig must solve");
    assert(t > 0.0f && t < 1.0f, "the closest approach is interior here");

    // The defining property, checked directly rather than against a second
    // implementation of the same formula: the elected point's perpendicular
    // distance to the ray line is a MINIMUM over the segment.
    float perp(float u) {
        Vec3 p = a + (b - a) * u;
        Vec3 w = p - o;
        Vec3 c = cross(w, d);
        return c.length / d.length;
    }
    immutable float best = perp(t);
    foreach (i; 0 .. 2001) {
        immutable float u = cast(float)i / 2000.0f;
        assert(perp(u) >= best - 1e-5f,
            "the elected parameter must minimise the distance to the ray line");
    }
}

unittest { // closestOnSegmentToRay — clamping, degeneracies, and dir-scale
           // invariance.
    Vec3 o = Vec3(0, 0, 0);
    Vec3 d = Vec3(0, 0, -1);
    float t;

    // Closest approach beyond b -> clamps to 1.
    assert(closestOnSegmentToRay(o, d, Vec3(1, 0, -5), Vec3(0.2f, 0, -5), t),
        "a segment across the ray must solve");
    assert(t == 1.0f, "a solution past the far endpoint must clamp to 1");

    // Closest approach before a -> clamps to 0.
    assert(closestOnSegmentToRay(o, d, Vec3(0.2f, 0, -5), Vec3(1, 0, -5), t),
        "the reversed segment must solve");
    assert(t == 0.0f, "a solution before the near endpoint must clamp to 0");

    // Zero-length segment -> degenerate.
    t = 0.5f;
    assert(!closestOnSegmentToRay(o, d, Vec3(1, 0, -5), Vec3(1, 0, -5), t),
        "a zero-length segment has no closest-approach parameter");
    assert(t == 0.0f, "a degenerate answer must be the documented t = 0");

    // Segment parallel to the ray -> degenerate (M vanishes).
    t = 0.5f;
    assert(!closestOnSegmentToRay(o, d, Vec3(1, 0, -2), Vec3(1, 0, -9), t),
        "a segment along the view ray has no distinguished parameter");
    assert(t == 0.0f, "a degenerate answer must be the documented t = 0");

    // Scaling `dir` must not move the answer — the normalise this function
    // omits is what would otherwise have to guarantee that.
    Vec3 dd = normalize(Vec3(0.3f, -0.2f, -1.0f));
    Vec3 a2 = Vec3(-1.0f, 0.5f, -3.0f), b2 = Vec3(2.0f, -0.5f, -12.0f);
    float t1, t2;
    assert(closestOnSegmentToRay(o, dd,        a2, b2, t1));
    assert(closestOnSegmentToRay(o, dd * 7.5f, a2, b2, t2));
    import std.math : abs;
    assert(abs(t1 - t2) < 1e-6f,
        "the elected parameter must be invariant under the ray direction's scale");
}

// ---------------------------------------------------------------------------
// THE POLYGON-SURFACE ELECTION'S PRIMITIVES (task 0588).
//
// The five functions below exist for one caller — `snap.d`'s
// `closestOnPolygonSurface` — and they are here rather than there because
// `rayPlaneIntersect`, `closestOnSegmentToRay` and `pointInPolygon2D`, the
// primitives the same function used to be built from, are here.
//
// The law they compose is: triangulate the polygon, and per triangle either
// intersect the cursor's eye ray with it or take the closest point OF THE
// TRIANGLE measured in a frame perpendicular to that ray. Interior, edge and
// corner therefore fall out of ONE operation instead of an interior test plus
// a boundary ring. See `closestOnPolygonSurface` for the whole law and for
// what it replaced.
// ---------------------------------------------------------------------------

// The view's WORLD UNITS PER PIXEL at its own scale. Returns 0 when the view
// is degenerate (zero height, zero/negative projection scale, eye sitting on
// the focus); every caller must treat 0 as "no scale available" rather than
// dividing by it.
//
// ORTHO is exact: `proj[5] == 1/halfH`, so the viewport spans `2/proj[5]`
// world units of height at EVERY depth, and one pixel is that over `height`.
//
// PERSPECTIVE IS AN INFERENCE, and it is the one judgement call in this file's
// half of the port. There is no single world-per-pixel in a perspective view —
// it is a function of depth — so "the view's own scale" has to name a depth,
// and the depth named here is the eye-to-focus distance, i.e. the radius the
// camera orbits at. That is the depth the geometry a user is working on sits
// at, and it makes the returned scale depend on the CAMERA alone, which is
// what a per-view scalar has to be. It is NOT the depth of the point being
// ranked: a rank built on this divisor is deliberately not depth-correct, and
// that asymmetry is the whole observable content of the polygon leg's rank.
float viewPixelScale(const ref Viewport vp) @safe pure nothrow @nogc
{
    if (vp.height <= 0) return 0.0f;
    immutable float f = vp.proj[5];
    if (!(f > 1e-9f)) return 0.0f;          // also rejects NaN
    float dist = 1.0f;
    if (!isOrtho(vp)) {
        // A DEFAULT-CONSTRUCTED `focus` IS NaN, NOT THE ORIGIN (see the field's
        // own note). Every real viewport sets it; headless fixtures that build
        // a Viewport by hand overwhelmingly do not, and a NaN here would
        // propagate to a NaN distance, fail the test below, and switch the
        // whole polygon-surface leg off silently rather than loudly. Reading an
        // unset focus AS the origin is what the field always claimed to do, and
        // it is the reading under which such a fixture's camera distance is its
        // eye's distance from the origin — which is what those fixtures mean.
        Vec3 fo = vp.focus;
        if (!isFinite(fo.x) || !isFinite(fo.y) || !isFinite(fo.z))
            fo = Vec3(0, 0, 0);
        immutable Vec3 e = vp.eye - fo;
        dist = sqrt(dot(e, e));
        if (!(dist > 1e-9f)) return 0.0f;
    }
    return (2.0f * dist) / (f * cast(float)vp.height);
}

// An orthonormal pair spanning the plane PERPENDICULAR to `dir`. Returns false
// when `dir` is degenerate. `u`, `v` and `dir/|dir|` form a right-handed
// frame; which of the infinitely many rotations about `dir` is produced does
// not matter to any caller here, because every quantity they take from it is
// a LENGTH in that plane, which is rotation-invariant.
bool perpendicularFrame(Vec3 dir, out Vec3 u, out Vec3 v) @safe pure nothrow @nogc
{
    u = Vec3(0, 0, 0);
    v = Vec3(0, 0, 0);
    immutable float len = sqrt(dot(dir, dir));
    if (!(len > 1e-9f)) return false;
    immutable Vec3 d = dir * (1.0f / len);
    // Cross with the axis LEAST aligned with `d`, so the cross product is the
    // best conditioned of the three available.
    immutable float ax = abs(d.x), ay = abs(d.y), az = abs(d.z);
    Vec3 helper = (ax <= ay && ax <= az) ? Vec3(1, 0, 0)
                : (ay <= az)             ? Vec3(0, 1, 0)
                                         : Vec3(0, 0, 1);
    Vec3 a = cross(d, helper);
    immutable float alen = sqrt(dot(a, a));
    if (!(alen > 1e-9f)) return false;
    u = a * (1.0f / alen);
    v = cross(d, u);            // unit already: |d| = |u| = 1 and d ⊥ u
    return true;
}

// Möller-Trumbore ray/triangle intersection, DOUBLE-SIDED (a back-facing
// triangle hits). `t` is along `dir` — NOT clamped to positive here, because
// the caller's behind-the-eye rule is its own decision and is stated at the
// call site. `u`/`v` are the barycentric coordinates of the hit:
//   hit == v0 + u*(v1 - v0) + v*(v2 - v0) == origin + t*dir.
// All three out-params are 0 on a miss.
bool rayTriangleIntersect(Vec3 origin, Vec3 dir, Vec3 v0, Vec3 v1, Vec3 v2,
                          out float t, out float u, out float v)
    @safe pure nothrow @nogc
{
    t = 0.0f; u = 0.0f; v = 0.0f;
    immutable Vec3 e1 = v1 - v0;
    immutable Vec3 e2 = v2 - v0;
    immutable Vec3 p  = cross(dir, e2);
    immutable float det = dot(e1, p);
    if (!(det > 1e-12f) && !(det < -1e-12f)) return false;   // also rejects NaN
    immutable float inv = 1.0f / det;
    immutable Vec3 s = origin - v0;
    immutable float uu = dot(s, p) * inv;
    if (uu < 0.0f || uu > 1.0f) return false;
    immutable Vec3 q = cross(s, e1);
    immutable float vv = dot(dir, q) * inv;
    if (vv < 0.0f || uu + vv > 1.0f) return false;
    t = dot(e2, q) * inv;
    u = uu;
    v = vv;
    return true;
}

// Squared distance from (px,py) to the SOLID triangle (a,b,c) in 2D, with the
// closest point returned in the triangle's own barycentric coordinates:
//   closest == a + u*(b - a) + v*(c - a).
//
// Written as "inside ⇒ zero, otherwise the best of the three edges" rather
// than as the Voronoi-region form, because that shape needs no guard for a
// zero-area triangle: a degenerate triangle is simply never "inside", and its
// three edges still answer correctly.
float closestPointOnTriangle2D(float px, float py,
                               float ax, float ay,
                               float bx, float by,
                               float cx, float cy,
                               out float u, out float v)
    @safe pure nothrow @nogc
{
    u = 0.0f; v = 0.0f;
    immutable float abx = bx - ax, aby = by - ay;
    immutable float acx = cx - ax, acy = cy - ay;
    immutable float apx = px - ax, apy = py - ay;

    immutable float d00 = abx*abx + aby*aby;
    immutable float d01 = abx*acx + aby*acy;
    immutable float d11 = acx*acx + acy*acy;
    immutable float den = d00*d11 - d01*d01;
    if (den > 1e-20f) {
        immutable float d20 = apx*abx + apy*aby;
        immutable float d21 = apx*acx + apy*acy;
        immutable float bu = (d11*d20 - d01*d21) / den;
        immutable float bv = (d00*d21 - d01*d20) / den;
        if (bu >= 0.0f && bv >= 0.0f && bu + bv <= 1.0f) {
            u = bu; v = bv;
            return 0.0f;
        }
    }

    // Local rather than `closestOnSegment2DSquared`, which is unannotated and
    // would cost this function every one of its four attributes. Same formula,
    // and the zero-length case clamps to the start point exactly as that one
    // does.
    static float seg(float qx, float qy, float sx0, float sy0,
                     float sx1, float sy1, out float t) @safe pure nothrow @nogc
    {
        immutable float ex = sx1 - sx0, ey = sy1 - sy0;
        immutable float len2 = ex*ex + ey*ey;
        t = 0.0f;
        if (len2 > 1e-20f) {
            t = ((qx - sx0)*ex + (qy - sy0)*ey) / len2;
            if (t < 0.0f) t = 0.0f;
            else if (t > 1.0f) t = 1.0f;
        }
        immutable float rx = qx - (sx0 + t*ex), ry = qy - (sy0 + t*ey);
        return rx*rx + ry*ry;
    }

    float best = float.infinity;
    float t;
    // AB: q = a + t*(b - a)  ->  (u, v) = (t, 0)
    float d2 = seg(px, py, ax, ay, bx, by, t);
    if (d2 < best) { best = d2; u = t;        v = 0.0f; }
    // AC: q = a + t*(c - a)  ->  (u, v) = (0, t)
    d2 = seg(px, py, ax, ay, cx, cy, t);
    if (d2 < best) { best = d2; u = 0.0f;     v = t; }
    // BC: q = b + t*(c - b) = a + (1-t)*(b-a) + t*(c-a)  ->  (1-t, t)
    d2 = seg(px, py, bx, by, cx, cy, t);
    if (d2 < best) { best = d2; u = 1.0f - t; v = t; }
    return best;
}

// Triangulate a simple polygon given as world positions, returning index
// triples into `poly`. Returns null for fewer than three vertices.
//
// EAR CLIPPING, NOT A FAN, and the distinction is the whole reason this exists
// rather than the `[0, i, i+1]` loop the rest of the codebase uses for display
// and for BVH build. A fan of a NON-CONVEX polygon emits triangles that cover
// the notch — area the polygon does not occupy — so a hit test built on a fan
// reports the cursor as being ON a polygon it is beside. The union of the
// triangles this returns is the polygon itself, which is the property every
// caller actually depends on.
//
// Non-planar polygons are triangulated in the plane of their Newell normal,
// which is the standard best-fit and is what makes the answer independent of
// the viewer. The triangles then keep their true 3D vertices, so a saddle quad
// yields two genuinely non-coplanar triangles rather than a flattened one.
//
// A polygon that is self-intersecting, or degenerate enough that no ear can be
// found, falls back to a fan for whatever remains: an answer that is wrong in
// the way the old code was wrong is still better than a hang.
uint[3][] triangulatePolygonEarClip(const(Vec3)[] poly)
{
    immutable size_t n = poly.length;
    if (n < 3) return null;
    if (n == 3) return [cast(uint[3])[0u, 1u, 2u]];

    // Newell normal — robust for non-planar and non-convex rings alike.
    Vec3 nrm = Vec3(0, 0, 0);
    foreach (i; 0 .. n) {
        const Vec3 a = poly[i];
        const Vec3 b = poly[(i + 1) % n];
        nrm.x += (a.y - b.y) * (a.z + b.z);
        nrm.y += (a.z - b.z) * (a.x + b.x);
        nrm.z += (a.x - b.x) * (a.y + b.y);
    }

    uint[3][] fan() {
        auto outTris = new uint[3][](n - 2);
        foreach (i; 0 .. n - 2)
            outTris[i] = [0u, cast(uint)(i + 1), cast(uint)(i + 2)];
        return outTris;
    }

    immutable float nlen = sqrt(dot(nrm, nrm));
    if (!(nlen > 1e-20f)) return fan();
    immutable Vec3 nhat = nrm * (1.0f / nlen);

    Vec3 e1, e2;
    if (!perpendicularFrame(nhat, e1, e2)) return fan();

    auto xs = new float[](n);
    auto ys = new float[](n);
    foreach (i; 0 .. n) {
        immutable Vec3 d = poly[i] - poly[0];
        xs[i] = dot(d, e1);
        ys[i] = dot(d, e2);
    }
    // `e2 = nhat x e1` makes (e1, e2) right-handed about the Newell normal, so
    // the projected ring is counter-clockwise. Measured rather than assumed —
    // a ring that comes out clockwise is flipped so the convexity test below
    // has one sign to test against.
    float area2 = 0.0f;
    foreach (i; 0 .. n) {
        immutable size_t j = (i + 1) % n;
        area2 += xs[i]*ys[j] - xs[j]*ys[i];
    }
    if (area2 < 0.0f) foreach (i; 0 .. n) ys[i] = -ys[i];

    static float cross2(float ox, float oy, float ax, float ay,
                        float bx, float by) @safe pure nothrow @nogc
    {
        return (ax - ox)*(by - oy) - (ay - oy)*(bx - ox);
    }

    auto idx = new uint[](n);
    foreach (i; 0 .. n) idx[i] = cast(uint)i;

    auto tris = new uint[3][](n - 2);
    size_t produced = 0;
    size_t guard    = 0;                       // bounds the whole clip loop
    immutable size_t guardMax = n * n + 4;

    while (idx.length > 3 && guard++ < guardMax) {
        bool clipped = false;
        foreach (k; 0 .. idx.length) {
            immutable size_t kp = (k + idx.length - 1) % idx.length;
            immutable size_t kn = (k + 1) % idx.length;
            immutable uint ip = idx[kp], ic = idx[k], inx = idx[kn];
            // Convex corner?
            if (!(cross2(xs[ip], ys[ip], xs[ic], ys[ic], xs[inx], ys[inx]) > 0.0f))
                continue;
            // No other remaining vertex inside the candidate ear.
            bool blocked = false;
            foreach (m; 0 .. idx.length) {
                immutable uint iq = idx[m];
                if (iq == ip || iq == ic || iq == inx) continue;
                immutable float c0 = cross2(xs[ip], ys[ip], xs[ic],  ys[ic],  xs[iq], ys[iq]);
                immutable float c1 = cross2(xs[ic], ys[ic], xs[inx], ys[inx], xs[iq], ys[iq]);
                immutable float c2 = cross2(xs[inx], ys[inx], xs[ip], ys[ip], xs[iq], ys[iq]);
                if (c0 >= 0.0f && c1 >= 0.0f && c2 >= 0.0f) { blocked = true; break; }
            }
            if (blocked) continue;
            tris[produced++] = [ip, ic, inx];
            idx = idx[0 .. k] ~ idx[k + 1 .. $];
            clipped = true;
            break;
        }
        if (!clipped) break;                   // no ear found — fall through
    }

    if (idx.length == 3) {
        tris[produced++] = [idx[0], idx[1], idx[2]];
        return tris[0 .. produced];
    }
    // Stalled (self-intersecting / degenerate ring): fan the remainder.
    foreach (i; 1 .. idx.length - 1) {
        if (produced >= tris.length) break;
        tris[produced++] = [idx[0], idx[i], idx[i + 1]];
    }
    return tris[0 .. produced];
}

unittest { // viewPixelScale — the two projections, and the NaN focus a hand-built
           // fixture leaves behind.
    Viewport vp;
    vp.width = 800; vp.height = 800;
    vp.eye = Vec3(0, 0, 5);
    vp.proj = perspectiveMatrix(cast(float)(PI / 2), 1.0f, 0.1f, 100.0f);
    vp.view = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));

    // proj[5] = 1/tan(45deg) = 1, so the view spans 2*dist world units of
    // height; dist = |eye - focus| = 5; 10 world units over 800 pixels.
    assert(vp.focus.x != vp.focus.x,
        "fixture premise: an unassigned Vec3 is NaN, not the origin — the whole "
        ~ "point of the fallback below");
    assert(abs(viewPixelScale(vp) - 0.0125f) < 1e-7f,
        "an unset focus must be read as the origin, giving the eye's own "
        ~ "distance as the view's scale");

    vp.focus = Vec3(0, 0, 0);
    assert(abs(viewPixelScale(vp) - 0.0125f) < 1e-7f,
        "and setting it to the origin explicitly must not change the answer");

    // Twice as far from the focus -> twice the world per pixel.
    vp.eye = Vec3(0, 0, 10);
    assert(abs(viewPixelScale(vp) - 0.025f) < 1e-7f,
        "the perspective scale is proportional to the eye-to-focus distance");

    // Ortho carries no distance term at all: 2*halfH over the pixel height.
    Viewport o;
    o.width = 800; o.height = 800;
    o.eye = Vec3(0, 0, 10); o.focus = Vec3(0, 0, 0);
    o.proj = orthographicMatrix(4.0f, 1.0f, 0.1f, 100.0f);
    assert(isOrtho(o), "fixture premise: this must be the ortho branch");
    assert(abs(viewPixelScale(o) - 0.01f) < 1e-7f,
        "ortho spans 2*halfH world units of height at every depth");
    o.eye = Vec3(0, 0, 40);
    assert(abs(viewPixelScale(o) - 0.01f) < 1e-7f,
        "...and moving the ortho eye must not change it, which is what makes "
        ~ "the distance term perspective-only");

    Viewport bad;
    bad.width = 800; bad.height = 0;
    bad.proj = perspectiveMatrix(cast(float)(PI / 2), 1.0f, 0.1f, 100.0f);
    assert(viewPixelScale(bad) == 0.0f, "a zero-height view has no scale");
}

unittest { // perpendicularFrame — orthonormal, spans the perpendicular plane,
           // and reports a degenerate direction rather than returning NaNs.
    Vec3 u, v;
    foreach (d; [Vec3(0, 0, -1), Vec3(1, 0, 0), Vec3(0, 1, 0),
                 Vec3(0.3f, -0.7f, 0.2f), Vec3(-5, 5, -5)]) {
        assert(perpendicularFrame(d, u, v), "a non-degenerate direction must solve");
        assert(abs(sqrt(dot(u, u)) - 1.0f) < 1e-5f, "u must be unit");
        assert(abs(sqrt(dot(v, v)) - 1.0f) < 1e-5f, "v must be unit");
        assert(abs(dot(u, v)) < 1e-5f, "u and v must be orthogonal");
        assert(abs(dot(u, d)) < 1e-5f * sqrt(dot(d, d)), "u must be perpendicular to d");
        assert(abs(dot(v, d)) < 1e-5f * sqrt(dot(d, d)), "v must be perpendicular to d");
    }
    assert(!perpendicularFrame(Vec3(0, 0, 0), u, v),
        "a zero direction spans no plane and must say so");

    // The property the caller actually buys: for a point off the line through
    // the origin along d, the length of its (u,v) coordinates IS its
    // perpendicular distance to that line.
    immutable Vec3 d = Vec3(0, 0, -1);
    assert(perpendicularFrame(d, u, v));
    immutable Vec3 p = Vec3(3, 4, -17);
    immutable float du = dot(p, u), dv = dot(p, v);
    assert(abs(sqrt(du*du + dv*dv) - 5.0f) < 1e-5f,
        "the frame's coordinates must measure the distance to the ray line");
}

unittest { // rayTriangleIntersect — hit, backface, miss, behind, and the
           // barycentric reconstruction agreeing with the parametric one.
    immutable Vec3 v0 = Vec3(0, 0, -5), v1 = Vec3(2, 0, -5), v2 = Vec3(0, 2, -5);
    float t, u, v;

    assert(rayTriangleIntersect(Vec3(0.5f, 0.5f, 0), Vec3(0, 0, -1), v0, v1, v2, t, u, v),
        "a ray through the interior must hit");
    assert(abs(t - 5.0f) < 1e-5f, "t is measured along dir, which is unit here");
    assert(abs(u - 0.25f) < 1e-5f && abs(v - 0.25f) < 1e-5f,
        "and the barycentrics must locate the hit inside the triangle");
    immutable Vec3 pPar = Vec3(0.5f, 0.5f, 0) + Vec3(0, 0, -1) * t;
    immutable Vec3 pBar = v0 + (v1 - v0) * u + (v2 - v0) * v;
    immutable Vec3 diff = pPar - pBar;
    assert(sqrt(dot(diff, diff)) < 1e-5f,
        "the two reconstructions of the hit must be the same point — the port "
        ~ "uses one on the hit arm and the other on the miss arm");

    // Back face: the same triangle from behind still hits. The reference's
    // polygon test has no front-face rule (the caller's `faceVisible` does).
    assert(rayTriangleIntersect(Vec3(0.5f, 0.5f, -10), Vec3(0, 0, 1), v0, v1, v2, t, u, v),
        "the test must be double-sided");
    assert(abs(t - 5.0f) < 1e-5f);

    // Outside the triangle, in the same plane.
    assert(!rayTriangleIntersect(Vec3(3, 3, 0), Vec3(0, 0, -1), v0, v1, v2, t, u, v),
        "a ray past the triangle must miss");

    // Behind the origin: still a HIT, with a negative t. Rejecting it is the
    // caller's rule, deliberately not this function's.
    assert(rayTriangleIntersect(Vec3(0.5f, 0.5f, -10), Vec3(0, 0, -1), v0, v1, v2, t, u, v),
        "a triangle behind the ray origin still intersects the ray LINE");
    assert(t < 0.0f, "and it must be reported by the sign of t, not by a false");

    // Degenerate triangle.
    assert(!rayTriangleIntersect(Vec3(0, 0, 0), Vec3(0, 0, -1),
                                 v0, v0, v0, t, u, v),
        "a zero-area triangle must not report a hit");
}

unittest { // closestPointOnTriangle2D — interior, each edge, each corner, and a
           // degenerate triangle, checked through the barycentrics rather than
           // through a second copy of the same arithmetic.
    immutable float ax = 0, ay = 0, bx = 4, by = 0, cx = 0, cy = 3;
    float u, v;

    float rebuiltDist2(float px, float py, float uu, float vv) {
        immutable float qx = ax + uu*(bx - ax) + vv*(cx - ax);
        immutable float qy = ay + uu*(by - ay) + vv*(cy - ay);
        return (px - qx)*(px - qx) + (py - qy)*(py - qy);
    }

    // Interior -> exactly zero, and the barycentrics locate the query point.
    assert(closestPointOnTriangle2D(1, 1, ax, ay, bx, by, cx, cy, u, v) == 0.0f,
        "a point inside must be at zero distance, exactly");
    assert(rebuiltDist2(1, 1, u, v) < 1e-8f,
        "and the barycentrics must rebuild the query point itself");

    // Beyond edge AB.
    float d2 = closestPointOnTriangle2D(2, -3, ax, ay, bx, by, cx, cy, u, v);
    assert(abs(d2 - 9.0f) < 1e-4f, "the foot is on AB, three units below");
    assert(abs(v) < 1e-6f, "on AB the C coefficient must vanish");
    assert(abs(rebuiltDist2(2, -3, u, v) - d2) < 1e-4f,
        "the returned distance and the returned point must agree");

    // Beyond corner B.
    d2 = closestPointOnTriangle2D(9, -1, ax, ay, bx, by, cx, cy, u, v);
    assert(abs(d2 - 26.0f) < 1e-3f, "the nearest point of the triangle is B");
    assert(abs(u - 1.0f) < 1e-5f && abs(v) < 1e-5f, "which is (u, v) = (1, 0)");

    // Beyond the hypotenuse BC.
    d2 = closestPointOnTriangle2D(4, 3, ax, ay, bx, by, cx, cy, u, v);
    assert(abs(rebuiltDist2(4, 3, u, v) - d2) < 1e-4f,
        "the hypotenuse case must be self-consistent too");
    assert(u > 0.0f && v > 0.0f && abs(u + v - 1.0f) < 1e-5f,
        "and its foot must lie ON BC, i.e. u + v == 1");

    // A degenerate (zero-area) triangle must still answer — this is the case
    // the Voronoi-region form needs a special guard for and this one does not.
    d2 = closestPointOnTriangle2D(0, 5, 0, 0, 4, 0, 2, 0, u, v);
    assert(abs(d2 - 25.0f) < 1e-4f,
        "a collapsed triangle is a segment, and the foot is still on it");
}

unittest { // triangulatePolygonEarClip — THE NON-CONVEX GUARD.
           //
           // The property is not "n-2 triangles come back"; it is that their
           // UNION is the polygon. The fixture is an L whose vertex 0 is chosen
           // so that a fan from it covers the notch — the test computes that
           // fan and asserts it DOES cover the notch, so the discriminator is
           // carried by the test rather than asserted in prose.
    immutable Vec3[6] L = [
        Vec3( 0,  2, 0),   // 0 — the fan pivot, and it cannot see the whole ring
        Vec3(-2,  2, 0),
        Vec3(-2, -2, 0),
        Vec3( 2, -2, 0),
        Vec3( 2,  0, 0),
        Vec3( 0,  0, 0),   // 5 — the reflex corner
    ];
    immutable float qx = 1.2f, qy = 0.5f;   // in the notch: outside the L

    static bool inTri(float px, float py, Vec3 a, Vec3 b, Vec3 c) {
        static float cr(float ox, float oy, float mx, float my, float nx, float ny) {
            return (mx - ox)*(ny - oy) - (my - oy)*(nx - ox);
        }
        immutable float c0 = cr(a.x, a.y, b.x, b.y, px, py);
        immutable float c1 = cr(b.x, b.y, c.x, c.y, px, py);
        immutable float c2 = cr(c.x, c.y, a.x, a.y, px, py);
        return (c0 >= 0 && c1 >= 0 && c2 >= 0) || (c0 <= 0 && c1 <= 0 && c2 <= 0);
    }

    // Premise 1: the probe really is outside the polygon.
    float[] xs, ys;
    foreach (p; L) { xs ~= p.x; ys ~= p.y; }
    assert(!pointInPolygon2D(qx, qy, xs, ys),
        "fixture: the probe must sit in the NOTCH, outside the L");

    // Premise 2: a fan from vertex 0 would cover it — this is the failure the
    // ear clip exists to avoid, computed here rather than claimed.
    bool fanCovers = false;
    foreach (i; 1 .. L.length - 1)
        if (inTri(qx, qy, L[0], L[i], L[i + 1])) { fanCovers = true; break; }
    assert(fanCovers,
        "fixture: a fan from vertex 0 must cover the notch, or this polygon "
        ~ "cannot tell a fan from a proper triangulation");

    auto tris = triangulatePolygonEarClip(L[]);
    assert(tris.length == L.length - 2,
        "a simple polygon must yield exactly n-2 triangles");
    foreach (t; tris)
        assert(!inTri(qx, qy, L[t[0]], L[t[1]], L[t[2]]),
            "NO ear-clipped triangle may cover the notch — a triangulation "
            ~ "whose union exceeds the polygon reports a cursor beside the "
            ~ "polygon as being on it");

    // And the union does cover a point that IS inside.
    bool covered = false;
    foreach (t; tris)
        if (inTri(-1.0f, -1.0f, L[t[0]], L[t[1]], L[t[2]])) { covered = true; break; }
    assert(covered, "the union must still cover the polygon's own interior");
}

unittest { // triangulatePolygonEarClip — the small arities and a non-planar quad.
    assert(triangulatePolygonEarClip([]) is null, "no polygon, no triangles");
    assert(triangulatePolygonEarClip([Vec3(0,0,0), Vec3(1,0,0)]) is null,
        "two vertices are not a polygon");

    auto t3 = triangulatePolygonEarClip([Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)]);
    assert(t3.length == 1 && t3[0] == [0u, 1u, 2u],
        "a triangle is its own triangulation, in its own order");

    // A saddle quad: the two triangles must stay genuinely non-coplanar, which
    // is what lets a hit test find the FOLD rather than a best-fit plane.
    immutable Vec3[4] saddle = [Vec3(-1,-1,0), Vec3(1,-1,0), Vec3(1,1,0), Vec3(-1,1,2)];
    auto t4 = triangulatePolygonEarClip(saddle[]);
    assert(t4.length == 2, "a quad yields two triangles");
    Vec3 nrmOf(uint[3] t) {
        return cross(saddle[t[1]] - saddle[t[0]], saddle[t[2]] - saddle[t[0]]);
    }
    immutable Vec3 n0 = nrmOf(t4[0]), n1 = nrmOf(t4[1]);
    immutable Vec3 c = cross(n0, n1);
    assert(sqrt(dot(c, c)) > 1e-3f,
        "the saddle's two triangles must have DIFFERENT normals — a flattened "
        ~ "triangulation would put both on one plane and lose the fold");
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

// planeForSlice — the interactive Slice tool's cut-plane law (task 0269, S3;
// owner-revised task 0284). The `axis` is an EXTRUSION DIRECTION, NOT the normal:
// the slice plane is the drawn Start→End line EXTRUDED along the axis direction,
// so it ALWAYS contains the line (both endpoints satisfy (X - start)·n == 0).
//   n = normalize(cross(end - start, axisDir))   (n ⟂ line, n ⟂ axisDir)
//   p = start                                     (any point on the line)
// This mirrors the drag construction exactly (drag = extrude along the work-plane
// normal), so every axis mode yields a plane CONTAINING both drawn points. The
// `axisMode` selects `axisDir`:
//   0 = Free/drag — axisDir = workplaneNormal (= planeFromLineAndWorkplane; the
//                   base/default behavior).
//   1 = X, 2 = Y, 3 = Z — axisDir = that WORLD axis.
//   4 = Custom          — axisDir = vector.
// Returns false (p, n undefined) when the mode has no well-defined plane: a
// zero-length `vector` in Custom, or — the degenerate guard — a line that is
// (near-)parallel to `axisDir` so cross ≈ 0 (the caller keeps the previous plane
// rather than building a garbage one). A degenerate / zero-length line likewise
// yields false through the shared construction.
bool planeForSlice(Vec3 start, Vec3 end, Vec3 workplaneNormal,
                   int axisMode, Vec3 vector, out Vec3 p, out Vec3 n,
                   float eps = 1e-6f)
{
    Vec3 axisDir;
    switch (axisMode) {
        case 1: axisDir = Vec3(1, 0, 0); break;   // X
        case 2: axisDir = Vec3(0, 1, 0); break;   // Y
        case 3: axisDir = Vec3(0, 0, 1); break;   // Z
        case 4:                                    // Custom
            if (vector.length < eps) { p = start; return false; }
            axisDir = vector;
            break;
        default:                                   // 0 = Free/drag
            axisDir = workplaneNormal;
            break;
    }
    // Extrude the drawn line along axisDir. planeFromLineAndWorkplane builds the
    // identical plane (n = normalize(cross(end-start, axisDir)), p = start) and
    // carries the degenerate guards: false for a zero-length line OR a line
    // parallel to axisDir (cross ≈ 0).
    return planeFromLineAndWorkplane(start, end, axisDir, p, n, eps);
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

unittest { // planeForSlice: X/Y/Z extrude the line along the axis ⇒ plane CONTAINS both endpoints
    Vec3 p, n;
    // axis=X: the plane is the drawn line extruded along world-X. It need NOT be
    // X-normal; the invariant is that BOTH endpoints lie in it (n ⟂ line).
    Vec3 s = Vec3(0, 0, -1), e = Vec3(0.3f, 0, 1);
    assert(planeForSlice(s, e, Vec3(0, 1, 0), 1, Vec3(0, 0, 0), p, n));
    assert(isClose(n.length, 1.0f, 1e-4f), "unit normal");
    assert(p.x == 0 && p.z == -1, "plane through Start");
    assert(isClose(dot(s - p, n), 0, 1e-5f, 1e-5f), "Start lies in the plane");
    assert(isClose(dot(e - p, n), 0, 1e-5f, 1e-5f), "End lies in the plane");
    assert(isClose(dot(n, Vec3(1, 0, 0)), 0, 1e-5f, 1e-5f), "n ⟂ the extrusion axis X");
    // axis=Z on a slanted line: plane still contains both endpoints.
    Vec3 s2 = Vec3(0, 0, 0), e2 = Vec3(1, 0.4f, 0);
    assert(planeForSlice(s2, e2, Vec3(0, 1, 0), 3, Vec3(0, 0, 0), p, n));
    assert(isClose(dot(s2 - p, n), 0, 1e-5f, 1e-5f), "Start in plane");
    assert(isClose(dot(e2 - p, n), 0, 1e-5f, 1e-5f), "End in plane");
    assert(isClose(dot(n, Vec3(0, 0, 1)), 0, 1e-5f, 1e-5f), "n ⟂ the extrusion axis Z");
}

unittest { // planeForSlice: Custom extrudes along normalize(vector); zero vector / degenerate → false
    Vec3 p, n;
    // Custom vector (2,0,0): extrude a Z-line along X. Plane contains both ends.
    Vec3 s = Vec3(0, 0, -1), e = Vec3(0.3f, 0, 1);
    assert(planeForSlice(s, e, Vec3(0, 1, 0), 4, Vec3(2, 0, 0), p, n));
    assert(isClose(n.length, 1.0f, 1e-4f), "unit normal");
    assert(isClose(dot(s - p, n), 0, 1e-5f, 1e-5f), "Start in plane");
    assert(isClose(dot(e - p, n), 0, 1e-5f, 1e-5f), "End in plane");
    assert(isClose(dot(n, Vec3(1, 0, 0)), 0, 1e-5f, 1e-5f), "n ⟂ the custom axis (2,0,0)");
    // Zero custom vector ⇒ no plane.
    assert(!planeForSlice(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0),
                          4, Vec3(0, 0, 0), p, n),
           "zero custom vector must be degenerate");
    // DEGENERATE GUARD: a line PARALLEL to the extrusion axis ⇒ cross ≈ 0 ⇒ false.
    assert(!planeForSlice(Vec3(-1, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0),
                          1, Vec3(0, 0, 0), p, n),
           "line ∥ axis X (extrusion axis) has no unique plane");
    assert(!planeForSlice(Vec3(0, 0, 0), Vec3(0, 0, 2), Vec3(0, 1, 0),
                          4, Vec3(0, 0, 5), p, n),
           "line ∥ custom axis has no unique plane");
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

// bevelArcPoints: Edge Bevel Round Level — TRUE CIRCULAR ARC generator
// (task 0391, capture-verified law: edge.bevel spec `behavior.round_level_law`).
//
// Given a cross-section root `center` (the ORIGINAL, un-beveled edge vertex)
// and two unit directions `dirA`/`dirB` (the flat L=0 chamfer-corner
// directions, e.g. the two adjacent-edge slide directions already used by
// `Mesh.bevelEdgesByMask`), returns `2^level + 1` points evenly spaced BY
// ANGLE on the circle of radius `radius` centered at `center`, sweeping from
// `center + dirA*radius` (t=0) to `center + dirB*radius` (t=2^level).
// `level == 0` returns exactly the 2 flat endpoints (today's straight-chord
// behavior — byte-identical, no rounding).
//
// Deliberately NOT the same law as poly.bevel's Segments (see
// `Mesh.bevelFacesByMask`'s segment-ring loop): Segments is a LINEAR lerp
// staircase, this is a geodesic angular sweep on a true circle — the two
// tools were independently capture-verified to use DIFFERENT laws
// (`vibe3d-divergence` note, doc/bevel_full_plan.md Phase 3).
//
// Degenerate fallback (dirA/dirB parallel or antiparallel, cross product
// too small to define a rotation axis): falls back to a linear lerp between
// the 2 endpoints (matches offsetMeetDir's own parallel-edge fallback
// convention above) rather than dividing by a near-zero axis length.
Vec3[] bevelArcPoints(Vec3 center, Vec3 dirA, Vec3 dirB, float radius, int level)
    @safe pure nothrow {
    import std.math : acos, sin, cos;
    immutable int n = 1 << level;   // segment count; n+1 points
    auto pts = new Vec3[](n + 1);

    Vec3 axis = cross(dirA, dirB);
    immutable float axisLen = axis.length;
    if (axisLen < 1e-9f) {
        // Parallel/antiparallel — no well-defined rotation plane; degrade to
        // a linear lerp between the two flat endpoints (never divides by
        // the near-zero axis length).
        foreach (t; 0 .. n + 1) {
            immutable float f = cast(float)t / cast(float)n;
            pts[t] = center + (dirA * (1.0f - f) + dirB * f) * radius;
        }
        return pts;
    }
    axis = axis / axisLen;

    float cosTheta = dot(dirA, dirB);
    if (cosTheta > 1.0f)  cosTheta = 1.0f;
    if (cosTheta < -1.0f) cosTheta = -1.0f;
    immutable float theta = acos(cosTheta);

    foreach (t; 0 .. n + 1) {
        immutable float ang = theta * (cast(float)t / cast(float)n);
        immutable float ct  = cos(ang), st = sin(ang);
        // Rodrigues' rotation of dirA about `axis` by `ang`; the third term
        // (axis * dot(axis,v) * (1-cosθ)) drops out because axis ⟂ dirA by
        // construction (axis = normalize(cross(dirA,dirB))).
        Vec3 rotated = dirA * ct + cross(axis, dirA) * st;
        pts[t] = center + rotated * radius;
    }
    return pts;
}

unittest { // bevelArcPoints: level=0 returns exactly the 2 flat endpoints
    Vec3 c = Vec3(0, 0, 0);
    auto pts = bevelArcPoints(c, Vec3(1, 0, 0), Vec3(0, 1, 0), 0.1f, 0);
    assert(pts.length == 2);
    assert(isClose(pts[0].x, 0.1f, 1e-5, 1e-5) && isClose(pts[0].y, 0.0f, 1e-5, 1e-5));
    assert(isClose(pts[1].x, 0.0f, 1e-5, 1e-5) && isClose(pts[1].y, 0.1f, 1e-5, 1e-5));
}

unittest { // bevelArcPoints: level=1, 90° sweep — midpoint lands EXACTLY at
           // the 45° bisector, at radius=width from center (capture-verified law).
    Vec3 c = Vec3(0, 0, 0);
    auto pts = bevelArcPoints(c, Vec3(1, 0, 0), Vec3(0, 1, 0), 0.1f, 1);
    assert(pts.length == 3);
    import std.math : SQRT1_2;
    immutable float s = 0.1f * SQRT1_2;
    assert(isClose(pts[1].x, s, 1e-5, 1e-5) && isClose(pts[1].y, s, 1e-5, 1e-5),
        "level=1 midpoint should sit at the 45° bisector, radius 0.1");
    // Every point must sit at exactly `radius` from `center`.
    foreach (p; pts) assert(isClose(p.length, 0.1f, 1e-5, 1e-5));
}

unittest { // bevelArcPoints: level=2, 90° sweep — 5 points at 0/22.5/45/67.5/90°
    import std.math : PI, cos, sin;
    Vec3 c = Vec3(0, 0, 0);
    auto pts = bevelArcPoints(c, Vec3(1, 0, 0), Vec3(0, 1, 0), 0.2f, 2);
    assert(pts.length == 5);
    foreach (i, p; pts) {
        immutable float ang = (PI / 2.0f) * (cast(float)i / 4.0f);
        assert(isClose(p.x, 0.2f * cos(ang), 1e-4, 1e-5));
        assert(isClose(p.y, 0.2f * sin(ang), 1e-4, 1e-5));
    }
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

// ---------------------------------------------------------------------------
// Orientation — the camera's rotational truth.
// ---------------------------------------------------------------------------

version (unittest) {
    // The pre-matrix camera built its basis this way: a spherical offset
    // direction, the world +Y as the up hint, and a bank applied by rotating
    // the orthonormal (right, up) pair about the forward axis. Kept here as
    // the INDEPENDENT oracle `Orientation.fromAngles` (a closed form) is
    // checked against, so the closed form is pinned to the arithmetic it
    // replaced rather than only to itself.
    private Orientation chartBasisByCrossProducts(float az, float el, float roll) {
        Vec3 b   = normalize(sphericalToCartesian(az, el, 1.0f));
        Vec3 f   = -b;
        Vec3 up0 = Vec3(0, 1, 0);
        if (roll != 0.0f) {
            Vec3 r0 = normalize(cross(f, up0));
            Vec3 u0 = cross(r0, f);
            up0 = u0 * cos(roll) + r0 * sin(roll);
        }
        Vec3 r = normalize(cross(f, up0));
        return Orientation.fromBasis(r, cross(r, f), b);
    }
}

unittest { // fromAngles reproduces the cross-product chain it replaced
    foreach (a; [-2.7f, -0.5040186f, 0.0f, 0.5f, 1.9f])
    foreach (e; [-1.4f, -0.4f, 0.0f, 0.4138754f, 1.4f])
    foreach (r; [-1.2f, 0.0f, 0.2055634f, 2.5f]) {
        Orientation got  = Orientation.fromAngles(a, e, r);
        Orientation want = chartBasisByCrossProducts(a, e, r);
        foreach (i; 0 .. 9)
            assert(abs(got.m[i] - want.m[i]) < 2e-6f,
                   "fromAngles must agree with the spherical cross-product basis");
    }
}

unittest { // the bank law: right.y == -sin(roll) * cos(elevation)
    // The identity that makes this `roll` the same quantity a reference
    // viewport reports as its bank, rather than merely some rotation about
    // the view axis. It is what lets a captured bank transfer as a number.
    foreach (a; [-1.1f, 0.0f, 0.9f])
    foreach (e; [-0.9f, 0.0f, 0.4138754f, 1.0f])
    foreach (r; [-1.2f, -0.2055634f, 0.0f, 0.2055634f, 1.2f]) {
        Orientation o = Orientation.fromAngles(a, e, r);
        assert(isClose(o.right().y, -sin(r) * cos(e), 2e-5f, 2e-5f),
               "screen-right.y must equal -sin(roll)*cos(elevation)");
    }
}

unittest { // fromAngles is a rotation everywhere INCLUDING the poles
    // The cross-product chain it replaced is 0/0 at |elevation| = 90 deg,
    // which is why the spherical camera had to clamp short of the pole. The
    // closed form is the analytic limit and stays a clean rotation there.
    foreach (a; [-2.7f, 0.0f, 0.5f, 1.9f])
    foreach (e; [-PI/2, -1.5f, 0.0f, 0.4138754f, 1.5f, PI/2])
    foreach (r; [-1.2f, 0.0f, 2.5f]) {
        Orientation o = Orientation.fromAngles(cast(float)a, cast(float)e, cast(float)r);
        assert(o.orthonormalityDefect() < 1e-5f,
               "fromAngles must be an orthonormal right-handed rotation, poles included");
    }
    // ...and specifically NOT NaN at the pole, which is the failure the chain had.
    Orientation pole = Orientation.fromAngles(0.7f, cast(float)(PI / 2), 0.3f);
    foreach (i; 0 .. 9)
        assert(pole.m[i] == pole.m[i], "a pole orientation must not be NaN");
}

unittest { // toAngles is the inverse of fromAngles, poles included
    foreach (a; [-2.7f, -0.5040186f, 0.0f, 0.5f, 1.9f])
    foreach (e; [-PI/2, -1.4f, 0.0f, 0.4138754f, 1.4f, PI/2])
    foreach (r; [-1.2f, 0.0f, 0.2055634f, 2.5f]) {
        Orientation o = Orientation.fromAngles(cast(float)a, cast(float)e, cast(float)r);
        float a2, e2, r2;
        o.toAngles(a2, e2, r2);
        Orientation back = Orientation.fromAngles(a2, e2, r2);
        foreach (i; 0 .. 9)
            assert(abs(o.m[i] - back.m[i]) < 4e-6f,
                   "matrix -> angles -> matrix must reproduce the orientation");
    }
}

unittest { // orthonormalized is IDEMPOTENT after doing REAL work — bit-exactly
    // This is what makes a serialisation round-trip bit-exact even though the
    // reader re-normalises everything it reads: the normalised form is a fixed
    // point, so writing it out and reading it back cannot move it.
    //
    // The samples below are DRIFTED on purpose, so the first call takes the
    // repair branch (the tolerance gate would otherwise return the input and
    // the fixed-point claim would be vacuous). Each is checked to be over the
    // gate going in and under it coming out.
    int repaired = 0;
    foreach (a; [-2.7f, -0.5040186f, 0.0f, 0.5f, 1.9f])
    foreach (e; [-PI/2, -1.4f, 0.0f, 0.4138754f, 1.4f, PI/2])
    foreach (r; [-1.2f, 0.0f, 0.2055634f, 2.5f]) {
        Orientation drift = Orientation.fromAngles(cast(float)a, cast(float)e,
                                                   cast(float)r);
        drift.m[0] += 0.013f; drift.m[4] -= 0.021f;
        drift.m[7] += 0.009f; drift.m[5] += 0.004f;
        assert(drift.orthonormalityDefect() > kOrientationTolerance,
               "the sample must actually need repair");
        Orientation once  = drift.orthonormalized();
        assert(once.orthonormalityDefect() <= kOrientationTolerance,
               "one pass must land inside the tolerance band — the fixed point "
               ~ "depends on it");
        Orientation twice = once.orthonormalized();
        assert(once.m == twice.m,
               "orthonormalized must be a fixed point — a round trip through it "
               ~ "would otherwise move the orientation every time it is read");
        repaired++;
    }
    assert(repaired == 120, "every sample must have exercised the repair branch");

    // And a cleanly-constructed orientation is returned bit-untouched, so a
    // save/load cycle on a normal camera moves nothing at all.
    Orientation clean = Orientation.fromAngles(0.5f, 0.4f, 0.2055634f);
    assert(clean.orthonormalized().m == clean.m,
           "a clean orientation must pass through the normalisation unchanged");
    Orientation c = Orientation.fromAngles(0.5f, 0.4f, 0.0f)
                        .rotatedAbout(Vec3(1, 0, 0), 0.3f)
                        .rotatedAbout(Vec3(0, 0, 1), -0.8f);
    assert(c.orthonormalized().m == c.m,
           "rotatedAbout already returns the normalised fixed point");
}

unittest { // orthonormalized REPAIRS a drifted matrix, and keeps the view axis
    Orientation o = Orientation.fromAngles(0.5f, 0.4f, 0.2f);
    Orientation drift = o;
    drift.m[0] += 0.02f; drift.m[4] -= 0.03f; drift.m[8] += 0.015f;
    drift.m[3] += 0.01f;
    assert(drift.orthonormalityDefect() > 1e-3f, "the drifted input must be measurably bad");
    Orientation fixed = drift.orthonormalized();
    assert(fixed.orthonormalityDefect() < 1e-6f, "orthonormalized must repair the drift");
    // Anchored on `back`: the direction the camera looks survives the repair.
    assert(isClose(dot(fixed.back(), normalize(drift.back())), 1.0f, 1e-6f),
           "the repair must not swing the view direction");
}

unittest { // degenerate columns produce a rotation, never NaN
    Orientation z; z.m = [0, 0, 0,  0, 0, 0,  0, 0, 0];
    assert(z.orthonormalized().orthonormalityDefect() < 1e-6f,
           "an all-zero matrix must normalise to some valid rotation");
    Orientation par; par.m = [1, 0, 0,  0, 0, 1,  0, 0, 1];  // up parallel to back
    assert(par.orthonormalized().orthonormalityDefect() < 1e-6f,
           "up parallel to back must fall back, not divide by zero");
}

unittest { // rotatedAbout carries a rotation the two-angle camera cannot hold
    // A pure spherical camera forces `right.y == 0` — screen-right can never
    // leave the world XZ plane. Composing an off-axis increment leaves it, and
    // that is the state the storage change exists to carry.
    Orientation level = Orientation.fromAngles(0.5f, 0.4f, 0.0f);
    assert(level.right().y == 0.0f, "an unbanked spherical camera has right.y exactly 0");
    Orientation tilted = level.rotatedAbout(normalize(Vec3(1, 0.3f, -0.7f)), 0.6f);
    assert(abs(tilted.right().y) > 1e-2f,
           "an off-axis composition must leave the level-horizon subspace");
    assert(tilted.orthonormalityDefect() < 1e-6f, "and stay a rotation");
    // Rotating back by the same axis/angle returns to the level camera.
    Orientation home = tilted.rotatedAbout(normalize(Vec3(1, 0.3f, -0.7f)), -0.6f);
    foreach (i; 0 .. 9)
        assert(abs(home.m[i] - level.m[i]) < 1e-5f,
               "rotatedAbout must be invertible by the negated angle");
}

unittest { // a stored orientation is the SAME camera lookAt built, to one ulp
    // Not bit-identical, and the gap is the point rather than a tolerance
    // granted to make this pass. `lookAt` derives its basis from
    // `normalize(center - eye)`, so the matrix it returns depends on the
    // DISTANCE (the offset it normalises is `distance` long, and normalising a
    // scaled vector rounds differently) and on the FOCUS (`center - eye`
    // re-rounds when the focus is far from the origin). Neither dependency is
    // real: a rotation has no distance and no position. Removing them costs
    // one ulp on the lanes, and the size is measured, not guessed: across a
    // 5x5x3 sweep of azimuth, elevation and distance the nine ROTATION lanes
    // differ by at most 1.2e-7 (one ulp at unit magnitude) and the three
    // TRANSLATION lanes, which carry the eye and therefore scale with the
    // distance, by at most 1.7e-7 of that distance.
    float worstRot = 0, worstTransRel = 0;
    foreach (a; [-2.7f, -0.5040186f, 0.0f, 0.5f, 1.9f])
    foreach (e; [-1.5f, -0.4f, 0.0f, 0.4138754f, 1.5f])
    foreach (d; [1.486323332f, 3.0f, 7.5f]) {
        immutable Vec3 focus = Vec3(0, 0, 0);
        Vec3 off = sphericalToCartesian(a, e, d);
        float[16] want = lookAt(focus + off, focus, Vec3(0, 1, 0));
        Orientation o = Orientation.fromAngles(a, e, 0.0f);
        float[16] got = viewMatrixFrom(o, focus + o.back() * d);
        foreach (i; [0, 1, 2, 4, 5, 6, 8, 9, 10]) {
            immutable float dd = abs(got[i] - want[i]);
            if (dd > worstRot) worstRot = dd;
        }
        foreach (i; [12, 13, 14]) {
            immutable float rel = abs(got[i] - want[i]) / d;
            if (rel > worstTransRel) worstTransRel = rel;
        }
    }
    assert(worstRot <= 1.2e-7f,
           "the view basis must reproduce lookAt's to one ulp");
    assert(worstTransRel <= 1.7e-7f,
           "the view translation must reproduce lookAt's to one ulp of the distance");
}

unittest { // the orientation no longer depends on distance or focus
    // The property the previous model did NOT have, and the reason the ulp
    // above is a correction rather than a regression: with `lookAt` the same
    // azimuth/elevation produced a DIFFERENT basis at a different zoom or a
    // different look-at point. That is measured here on the old construction,
    // then shown absent from the new one.
    int lookAtVaried = 0;
    foreach (a; [-2.7f, -0.5040186f, 0.5f, 1.9f])
    foreach (e; [-1.5f, -0.4f, 0.4138754f, 1.5f]) {
        // OLD: same rotation, two zooms and two look-at points -> four bases.
        float[16] m1 = lookAt(sphericalToCartesian(a, e, 3.0f), Vec3(0, 0, 0), Vec3(0,1,0));
        float[16] m2 = lookAt(sphericalToCartesian(a, e, 7.5f), Vec3(0, 0, 0), Vec3(0,1,0));
        Vec3 fc = Vec3(0.25f, -0.5f, 2.0f);
        float[16] m3 = lookAt(fc + sphericalToCartesian(a, e, 3.0f), fc, Vec3(0,1,0));
        foreach (i; [0, 4, 8, 1, 5, 9, 2, 6, 10])
            if (m1[i] != m2[i] || m1[i] != m3[i]) { lookAtVaried++; break; }

        // NEW: one rotation, one matrix, whatever the zoom or the focus.
        Orientation o = Orientation.fromAngles(a, e, 0.0f);
        assert(o.m == Orientation.fromAngles(a, e, 0.0f).m);
    }
    assert(lookAtVaried >= 12,
           "the eye/target construction really did vary its basis with zoom and "
           ~ "focus — if this stops being true the ulp above needs re-explaining");
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