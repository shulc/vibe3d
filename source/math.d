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

/// Rodrigues rotation of the DIRECTION `v` about the axis `axis` by `angle`
/// radians, pivot at the origin. `axis` MUST already be unit length — nothing
/// here normalises it, and a non-unit axis silently scales the result. Callers
/// that accept an arbitrary axis normalise at their own boundary (the two
/// spellings in the tree differ: `normalize` throws away a zero axis as NaN,
/// `safeNormalize` returns a fallback, and that choice belongs to the caller).
///
/// This and `rotateAboutPivot` below are the single home for the formula: it
/// was written out six times across math.d / xform_kernels.d / rotate.d /
/// radial_array_tool.d / slice_tool.d / bevel.d, and audit №4 (T3) counted the
/// copies. The expression is kept in the exact association order the copies
/// used, so every migrated call site is bit-identical, not merely equal.
Vec3 rotateAboutAxis(Vec3 v, Vec3 axis, float angle) @safe pure nothrow @nogc {
    immutable float c = cos(angle), s = sin(angle);
    return v * c + cross(axis, v) * s + axis * (dot(axis, v) * (1.0f - c));
}

/// Rodrigues rotation of the POINT `v` about the line through `pivot` along the
/// unit `axis` — `rotateAboutAxis` applied to `v - pivot` and translated back.
/// Same unit-axis contract as above.
///
/// Written out rather than delegating on purpose: `pivot + p*c + pcr*s + …`
/// associates the sum left-to-right starting at `pivot`, which is what the
/// call sites this replaced computed. Delegating would re-associate the adds
/// and move results by an ulp.
Vec3 rotateAboutPivot(Vec3 v, Vec3 pivot, Vec3 axis, float angle) @safe pure nothrow @nogc {
    immutable float c = cos(angle), s = sin(angle);
    immutable Vec3 p = v - pivot;
    immutable float d = dot(p, axis);
    immutable Vec3 pcr = cross(axis, p);
    return pivot + p * c + pcr * s + axis * (d * (1.0f - c));
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

/// True when `m`'s LINEAR part (upper-left 3x3, column-major) reverses
/// handedness — `det < 0`. Transforming geometry through such a matrix MIRRORS
/// it, so a face whose vertex order was counter-clockwise (outward) in the
/// source space comes out clockwise (inward) in the target space: the points
/// move, the index order does not, and the normal flips. Whoever BAKES such a
/// matrix into points must therefore also reverse each face's vertex order (and
/// any per-CORNER attribute that rides along with it) to keep the surface
/// outward — see `tools/create/create_common.frameIsLeftHanded` (which now
/// forwards here) for the same rule at the primitive-creation boundary, and
/// `io/scene_ir.flattenDocument` / `io/lwo_export` / `io/scene_export` for it at
/// the export boundary.
///
/// Takes the whole 4x4 for call-site convenience; the translation column plays
/// no part in handedness.
bool matrixMirrorsWinding(const float[16] m) @safe pure nothrow @nogc {
    // det of the upper-left 3x3, column-major: element (row r, col c) is m[c*4+r].
    const float a = m[0], b = m[4], c = m[8];
    const float d = m[1], e = m[5], f = m[9];
    const float g = m[2], h = m[6], i = m[10];
    return a*(e*i - f*h) - b*(d*i - f*g) + c*(d*h - e*g) < 0;
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
    /// Local-space DIRECTION -> world-space direction: the LINEAR part of
    /// `m` only (no translation), the exact dual of `toLocalDir`. Like it,
    /// deliberately NOT normalized — a caller that needs a unit direction
    /// normalizes it itself, and one that is carrying a length (an edge
    /// vector, a ray parameter) needs it left alone.
    ///
    /// This is for a DIRECTION — a difference of two points. A NORMAL is not
    /// a direction under a non-uniform scale: use `toWorldNormal`.
    Vec3 toWorldDir(Vec3 localDir) const @safe pure nothrow @nogc {
        return Vec3(
            m[0]*localDir.x + m[4]*localDir.y + m[ 8]*localDir.z,
            m[1]*localDir.x + m[5]*localDir.y + m[ 9]*localDir.z,
            m[2]*localDir.x + m[6]*localDir.y + m[10]*localDir.z,
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

    /// Carry a WORLD-space affine map `F` into this space: the local map that
    /// does, to local coordinates, exactly what `F` does to the world ones.
    ///
    ///     conjugate(F) == L4^-1 . F . L4
    ///
    /// where `L4` is `m` with its TRANSLATION COLUMN ZEROED (the linear part
    /// alone) and `L4^-1` is `mInv` likewise. The zeroing is the whole trick,
    /// and it is not an approximation: for `A(x) = L x + p`, the composite
    /// `A^-1 . W . A` where `W(x) = c + F(x - c)` works out to
    ///
    ///     x |-> c' + (L^-1 F_lin L)(x - c') + L^-1 F_t,      c' = A^-1(c)
    ///
    /// i.e. the PIVOT takes the full affine inverse (`toLocalPoint`) while the
    /// map itself takes the linear one on both sides. Feeding the full `m` /
    /// `mInv` here instead would apply the item translation twice — once in
    /// the pivot and once inside the matrix — and a translate-only item
    /// transform would move the geometry by `2*pos` instead of leaving it
    /// where it was.
    ///
    /// The companion conversion is `toLocalPoint(centreWorld)`; the two are
    /// used together or not at all.
    ///
    /// Blend note: a per-vertex weight `w` applied as a LERP toward identity
    /// commutes with this conjugation exactly — `L4^-1 . ((1-w)I + wF) . L4
    /// == (1-w)I + w(L4^-1 F L4)` — so conjugating the composed matrix once,
    /// before the per-vertex blend, is equivalent to conjugating every
    /// blended result. That equivalence is what makes this a ONE-PLACE
    /// conversion. It does NOT hold for a non-linear blend (a slerp) under a
    /// non-similarity `L`; there the conjugated form stays exact at `w == 0`
    /// and `w == 1` and is a declared reading in between.
    float[16] conjugate(const float[16] f) const @safe pure nothrow @nogc {
        if (isIdentity || !invertible) return f;
        float[16] lin    = m;
        float[16] linInv = mInv;
        lin[12] = 0;    lin[13] = 0;    lin[14] = 0;
        linInv[12] = 0; linInv[13] = 0; linInv[14] = 0;
        return matMul4(linInv, matMul4(f, lin));
    }
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

unittest { // conjugate() + toLocalPoint() reproduce "do it in world, write it
    // in local", to the last bit, for an arbitrary invertible space.
    //
    // The ONE claim: for any world-space map `W(x) = c + F(x - c)`, applying
    // W in world and converting back must equal applying the conjugated map
    // about the converted centre, in local. This is the identity the transform
    // apply path rests on, so it is asserted against an INDEPENDENT
    // construction (round-trip through world) rather than against itself.
    ModelSpace ms;
    rotNonUniformSpace(ms);
    ms.m[12] = 5.0f; ms.m[13] = -2.0f; ms.m[14] = 3.0f;    // + a translation
    // mInv's translation column = -L^-1 * p
    Vec3 lp = Vec3(
        ms.mInv[0]*5.0f + ms.mInv[4]*(-2.0f) + ms.mInv[ 8]*3.0f,
        ms.mInv[1]*5.0f + ms.mInv[5]*(-2.0f) + ms.mInv[ 9]*3.0f,
        ms.mInv[2]*5.0f + ms.mInv[6]*(-2.0f) + ms.mInv[10]*3.0f);
    ms.mInv[12] = -lp.x; ms.mInv[13] = -lp.y; ms.mInv[14] = -lp.z;

    // A world map with BOTH a linear part and a translation part, so a
    // conjugation that drops either term is caught.
    float[16] F = matMul4(pivotScaleMatrix(Vec3(0,0,0), 1.3f, 0.7f, 2.1f),
                          translationMatrix(Vec3(0.9f, -1.4f, 0.5f)));
    Vec3 cWorld = Vec3(-0.4f, 2.45f, -0.23f);

    Vec3 vLocal = Vec3(1.2f, 1.1f, -1.8f);
    // Truth: local -> world, apply about the world centre, world -> local.
    Vec3 truth = ms.toLocalPoint(
        cWorld + applyAffine(F, ms.toWorldPoint(vLocal) - cWorld));
    // Under test: the one-place conversion.
    Vec3 cLocal = ms.toLocalPoint(cWorld);
    Vec3 got    = cLocal + applyAffine(ms.conjugate(F), vLocal - cLocal);
    assert((got - truth).length < 1e-4f,
        "conjugate(F) about toLocalPoint(c) must equal the world-space map "
        ~ "carried back into local space");

    // ANTI-VACUITY, the exact mistake the doc comment names: conjugating with
    // the FULL m / mInv (translation column left in) instead of their linear
    // parts. It must read a DIFFERENT point here, or this fixture proves
    // nothing about which of the two matrices the conjugation uses.
    float[16] wrong = matMul4(ms.mInv, matMul4(F, ms.m));
    Vec3 gotWrong   = cLocal + applyAffine(wrong, vLocal - cLocal);
    assert((gotWrong - truth).length > 1e-2f,
        "fixture is vacuous: the full-affine conjugation lands on the same "
        ~ "point, so this cannot tell the two apart");

    // The identity space is a pass-through, bit for bit — the fast path every
    // existing rig takes.
    auto id = ModelSpace.world();
    auto passthrough = id.conjugate(F);
    foreach (i; 0 .. 16) assert(passthrough[i] == F[i],
        "an identity ModelSpace must return the matrix untouched");
}

unittest { // conjugate() commutes with the lerp-toward-identity blend — the
    // property that lets the apply path conjugate ONCE, before the per-vertex
    // falloff weight is applied, instead of per vertex.
    ModelSpace ms;
    rotNonUniformSpace(ms);
    float[16] F = matMul4(pivotScaleMatrix(Vec3(0,0,0), 1.3f, 0.7f, 2.1f),
                          translationMatrix(Vec3(0.9f, -1.4f, 0.5f)));
    enum float w = 0.375f;
    float[16] blendedThenConjugated;
    foreach (i; 0 .. 16)
        blendedThenConjugated[i] = (1.0f - w) * identityMatrix[i] + w * F[i];
    blendedThenConjugated = ms.conjugate(blendedThenConjugated);

    float[16] cj = ms.conjugate(F);
    float[16] conjugatedThenBlended;
    foreach (i; 0 .. 16)
        conjugatedThenBlended[i] = (1.0f - w) * identityMatrix[i] + w * cj[i];

    foreach (i; 0 .. 16)
        assert(isClose(blendedThenConjugated[i], conjugatedThenBlended[i],
                       1e-4f, 1e-5f),
            "conjugation must commute with the matrix lerp toward identity");
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
        return fromBasis(rotateAboutAxis(right(), k, angle),
                         rotateAboutAxis(up(),    k, angle),
                         rotateAboutAxis(back(),  k, angle)).orthonormalized();
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
    private ModelSpace ms_;          // the space `vp_` was composed FROM
    private this(Viewport v, ModelSpace m) @safe pure nothrow @nogc {
        vp_ = v; ms_ = m;
    }
    /// The composed viewport, for handing to `projectToWindow*`.
    @property ref const(Viewport) vp() const return @safe pure nothrow @nogc {
        return vp_;
    }
    /// The `ModelSpace` this aim space was built from — i.e. the item
    /// transform of the geometry whose LOCAL coordinates are meant to be
    /// projected through `vp`.
    ///
    /// **Task 0659.** Kept alongside the composed viewport because the
    /// composition is lossy in the direction we need: `proj·view·M` cannot
    /// be taken apart again to recover `M`, yet a caller holding an aim
    /// space and a local vertex frequently needs that vertex's WORLD
    /// coordinate — falloff is the case that forced this (its weight is a
    /// world-space quantity, measured; see doc/tasks/…/0644-evidence).
    /// Carrying `ms` here means the caller states the layer ONCE, at the
    /// same `aimSpace(vp, ms)` call that already names it, and both the
    /// pixel-space and the world-space readings of the same vertex come
    /// out of one argument that cannot disagree with itself.
    @property ref const(ModelSpace) space() const return @safe pure nothrow @nogc {
        return ms_;
    }
    /// The world coordinate of a LOCAL point in this aim space's layer.
    /// Convenience for `space.toWorldPoint(p)`; identity-cheap.
    Vec3 toWorld(Vec3 localP) const @safe pure nothrow @nogc {
        return ms_.isIdentity ? localP : ms_.toWorldPoint(localP);
    }
}

/// Build the aiming space for `ms`: `projectionSpace(vp, ms)` in an
/// `AimViewport` wrapper. Adds a TYPE, not a behaviour — the composed
/// viewport is field-identical to `projectionSpace`'s, identity fast path
/// included. A stack copy plus (off the identity path) one `matMul4`: cheap
/// once per query, unacceptable per vertex — hoist it out of O(V) loops.
AimViewport aimSpace(const ref Viewport vp, const ModelSpace ms) @safe pure nothrow @nogc {
    return AimViewport(projectionSpace(vp, ms), ms);
}

unittest { // AimViewport.toWorld agrees with the ModelSpace it was built from,
           // and the identity fast path is not a different answer.
    import std.math : isClose;
    Viewport vp;
    ModelSpace ms;
    rotNonUniformSpace(ms);
    auto aim = aimSpace(vp, ms);
    Vec3 p = Vec3(0.3f, -1.25f, 2.0f);
    Vec3 a = aim.toWorld(p);
    Vec3 b = ms.toWorldPoint(p);
    assert(isClose(a.x, b.x) && isClose(a.y, b.y) && isClose(a.z, b.z),
           "AimViewport.toWorld must equal its ModelSpace's toWorldPoint");
    // Identity: toWorld is the identity map, not merely close to it.
    auto aimId = aimSpace(vp, ModelSpace.world());
    Vec3 c = aimId.toWorld(p);
    assert(c.x == p.x && c.y == p.y && c.z == p.z,
           "identity aim space must return the point unchanged");
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

// ---------------------------------------------------------------------------
// THE FACING PREDICATE — one rule, one home (task 0832).
//
// "Is this face turned away from the eye" used to be written out THREE times,
// and audit 4 (§P1) measured that they were not three copies of one rule but
// three DIFFERENT rules: the plane of the first triangle in double
// (`Mesh.visibleVertices`), the cross of the first triangle in float
// (`snap.d`'s `faceVisible`), and a Newell sum over the whole ring (`app.d`'s
// lasso). They part company on exactly the face an edge split leaves behind —
// so the snapper and the lasso could disagree about the same polygon, and
// nothing in the tree said which answer was right.
//
// THE RULE BELOW IS THE REFERENCE EDITOR'S, and it is here for PARITY. It was
// read under a debugger at the reference's own compute site (task 0726 — the
// arguments at the call, matched against offline arithmetic to the last
// printed digit), and the owner adopted it on 2026-08-15:
//
//     N = cross(v1 - v0, v[n-1] - v0)   the corner triangle at the FIRST ring
//                                       vertex; the third point is the LAST
//                                       ring entry, NOT the second
//     cull  iff  dot(N, v0 - eye) > 0   strictly, against a literal 0
//
// THE BILL, measured and accepted deliberately. Write it down here so nobody
// later reads any of it as an oversight and "repairs" it:
//
//   * N depends on the ring's STARTING VERTEX. Four rotations of one quad give
//     four different normals; only the rotation is different, the polygon is
//     the same polygon.
//   * On a planar polygon whose ring STARTS at a reflex corner, N is turned
//     180° from the surface it belongs to, so the face answers backwards.
//   * On the face an edge split leaves, when the inserted midpoint lands at
//     ring index 0, its two ring neighbours are collinear with it and N is
//     EXACTLY the zero vector — and such a polygon is then front-facing from
//     BOTH sides, because `dot(0, anything) > 0` is false.
//
// That last line is why the comparison is strict and why "N == 0 is never
// culled" needs no clause of its own: it falls out of `> 0`. The rule our tree
// used before culled at `>= 0`, which is the opposite answer for every
// zero-normal and every exactly-edge-on face.
//
// `Mesh.faceNormal` (Newell, area-weighted over the whole ring) is strictly
// more robust than this and disagreed with the reference on 19 of 72 measured
// cells. It stays where it is for GEOMETRY (bevels, workplanes, UV projection);
// it is deliberately NOT what decides facing. Do not "fix" this predicate by
// reaching for it — that would be neither parity nor honesty.
//
// LOCAL SPACE. `eyeLocal` is the eye in the same space `verts` are expressed
// in (`projectionSpace(vp, ms).eye`, i.e. `M⁻¹·eyeWorld`). A front-facing test
// done ENTIRELY in local space needs no `ms.mirrored` correction, mirrored or
// not — see `ModelSpace.mirrored`'s doc comment above for the identity, and for
// the flip that used to be XOR'd onto all three copies of this test and was
// wrong. Do not reintroduce it here.
//
// PRECISION. The cross and the dot are carried in DOUBLE while the positions
// stay float, the same choice `Mesh.visibleVertices`'s depth gate already
// documents. Products of float32 values are exact in double, so the sign this
// returns is the correctly-rounded sign of the exact float32 arithmetic — and,
// the part that matters for the rule above, a truly collinear corner yields an
// EXACT zero rather than float noise with an arbitrary sign. That is a
// property of evaluating this formula, not a different formula: the three
// sites disagreed on precision too (double / float / float), and one home has
// to pick one.
//
// WHERE THIS IS USED, and where it deliberately is not:
//
//   * lasso over polygons (`app.d`) — MEASURED. This is the gesture task 0726
//     drove, and the rule is the reference's answer for it.
//   * snap (`Mesh.visibleVertices` and `snap.d`'s `faceVisible`) — AN
//     ASSUMPTION, and it is named as one on purpose. The capture never drove a
//     snap gesture in the reference; nobody has measured that the reference
//     uses THIS rule there. It is applied here because snap's two legs (the
//     vertex/edge mask from `visibleVertices`, the face gate in `faceVisible`)
//     must at least agree with EACH OTHER, and because a predicate with more
//     than one implementation is the defect this function exists to remove.
//     If snap is ever measured and the reference turns out to do something
//     else there, this is the assumption to revisit — split it out under its
//     own name, do not quietly widen this one.
//   * single click — NOT this rule and not any rule. Our click path has no
//     facing term at all (pinned by task 0576: `bvh_pick.pickFace` is a
//     nearest-hit ray-cast; `gpu_select` decides by depth). The reference does
//     cull there, but by a per-triangle determinant sign that never touches the
//     polygon normal — so giving click a facing term is a separate behaviour
//     change, not a consequence of this one.
//
/// True when the face `ring` (indices into `verts`) faces `eyeLocal` — i.e.
/// when it is NOT culled. `ring` shorter than 3 is not a face and answers
/// false. All coordinates are in ONE space; `eyeLocal` must be in that space.
bool frontFacingLocal(const(Vec3)[] verts, const(uint)[] ring, Vec3 eyeLocal)
    @safe pure nothrow @nogc
{
    if (ring.length < 3) return false;
    const Vec3 v0 = verts[ring[0]];
    const Vec3 v1 = verts[ring[1]];
    const Vec3 vL = verts[ring[$ - 1]];
    // N = cross(v1 - v0, vL - v0), in double (see PRECISION above).
    const double ux = cast(double)v1.x - v0.x,
                 uy = cast(double)v1.y - v0.y,
                 uz = cast(double)v1.z - v0.z;
    const double wx = cast(double)vL.x - v0.x,
                 wy = cast(double)vL.y - v0.y,
                 wz = cast(double)vL.z - v0.z;
    const double nx = uy * wz - uz * wy,
                 ny = uz * wx - ux * wz,
                 nz = ux * wy - uy * wx;
    const double dx = cast(double)v0.x - eyeLocal.x,
                 dy = cast(double)v0.y - eyeLocal.y,
                 dz = cast(double)v0.z - eyeLocal.z;
    // Strictly `> 0` culls. Equality — a zero N, or a face exactly edge-on —
    // is kept, which is the whole of the "N == 0 is never culled" clause.
    return !(nx * dx + ny * dy + nz * dz > 0.0);
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


// `screenToWorkPlane` WAS HERE AND IS DELETED (task 0661). It projected a
// pixel onto the world FLOOR — the X-Z plane at Y = planeY, normal (0,1,0) —
// with the plane handed in as two DEFAULTED parameters, and returned false
// when the ray was parallel to it.
//
// Both of its callers were written `if (screenToWorkPlane(...)) setIt(hit);`
// with no else, and neither ever passed a normal, so:
//
//   * the plane did not follow the view. In Front / Back / Left / Right the
//     camera looks horizontally and the click ray lies exactly IN the floor,
//     so there was no intersection at all;
//   * and the refusal was silent — "could not" arrived as "kept the previous
//     value", which is indistinguishable from success at the only place the
//     user can see it.
//
// The replacement is `tools.create.create_common.screenToConstructionPlane`:
// it reads the plane from `WorkplaneStage` (camera-most-facing principal axis
// through the camera focus in auto mode, the user's full frame when pinned),
// and it is TOTAL — it returns a Vec3, so there is no boolean left to drop.
//
// Nothing is left here rather than a fixed version, deliberately: a helper
// whose DEFAULT argument is the degenerate plane is a trap that re-arms the
// moment someone calls it with the defaults again.

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

// bevelMiterPoint: where an EDGE bevel puts the vertex at a face corner whose
// BOTH ring edges are bevelled. Task 1170; the law is measured, not derived.
//
// THE PLANE IS THE TWO EDGES, AND NO FACE NORMAL DECIDES IT. This is the
// whole content of the finding (divergence-ledger row 1, toolcard
// `edge_bevel_offset_normal`, 53 cells / 520 created vertices / 117 mitred
// corners, worst residual 1.53e-5 x inset — the reference's float32 vertex
// storage floor). The point is the one in `span{ePrev, eNext}` at
// perpendicular distance `wPrev` from the ePrev line and `wNext` from the
// eNext line:
//
//     p = jv + sign * (wPrev*eNext + wNext*ePrev) / sin(theta)
//
// (write p = alpha*eNext + beta*ePrev; the distance from the ePrev line is
// |alpha|*sin(theta), so alpha = wPrev/sin(theta), and symmetrically. With
// wPrev == wNext == inset this is exactly the measured
// `inset * (a + b) / sin(theta)`, the bisector at length inset/sin(theta/2).)
//
// `ringNormal` — Newell over the WHOLE ring — appears in exactly ONE place:
// the branch. Both `+(...)` and `-(...)` sit at those two distances, and the
// engine takes the one pointing into the face:
//
//     sign = +1  iff  dot(cross(eNext, ePrev), ringNormal) > 0     (strict)
//
// i.e. "is this corner convex with respect to its own ring's normal". That
// scored 117/117 overall and 16/16 on the corners built reflex to separate
// the sign candidates, while the rule that owns the PLANE (the corner
// triangle at the moving vertex) is the WORST rule for the branch at 106/117.
// Plane and branch are two different questions and are ported as two — do not
// collapse them back into one normal. The operand order in that cross product
// is load-bearing and was pinned by data, not by derivation: `cross(eNext,
// ePrev)` reproduces all 117 corners and `cross(ePrev, eNext)` reproduces 0.
//
// NOT `offsetMeet` — and deliberately not a change TO it. `offsetMeet`
// intersects the two offset LINES by projecting along `faceNorm`, so on a
// non-planar face its answer lies in no plane at all (the measured 4.86 deg
// of direction error, 8 % of the bevel width). It stays as it is because
// poly.bevel's `insetCorner` is its other caller and answers to a separately
// measured law. On a PLANAR face the two functions agree identically by
// construction (offsetMeet's own offset directions cross(faceNorm, -+e) are
// the same orientation convention as `sign` here), which is why the mitres on
// planar faces do not move.
//
// Degenerate corner (the two edges collinear — a straight-through "pipe"
// corner, sin(theta) ~ 0): there is no unique such point, and the reference
// was never measured there. Delegates to `offsetMeet`, whose own degenerate
// branch then answers exactly as it does today.
Vec3 bevelMiterPoint(Vec3 jv, Vec3 ePrev, Vec3 eNext, Vec3 ringNormal,
                     float wPrev, float wNext) @safe pure nothrow @nogc {
    Vec3  n    = cross(eNext, ePrev);
    float sinT = n.length;              // |a x b| = sin(theta) for unit a, b
    if (sinT < 1e-6f)
        return offsetMeet(jv, ePrev, eNext, ringNormal, wPrev, wNext);
    immutable float sign = dot(n, ringNormal) > 0 ? 1.0f : -1.0f;
    return jv + (eNext * wPrev + ePrev * wNext) * (sign / sinT);
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




// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) import std.math : isClose;

unittest { // Quat.identity is a unit quaternion w=1
    auto q = Quat.identity();
    assert(q.w == 1 && q.x == 0 && q.y == 0 && q.z == 0);
}







// ---- Cumulative-euler ZYX helpers ----

























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
