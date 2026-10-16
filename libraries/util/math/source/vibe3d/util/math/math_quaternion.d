module vibe3d.util.math.math_quaternion;

import vibe3d.util.math.math_vector;
import vibe3d.util.math.math_matrix;
import vibe3d.util.math.math_geometry;
import std.math : tan, sin, cos, sqrt, PI, abs, acos, asin, atan2, round, isFinite;
version (unittest) import std.math : isClose;


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

unittest { // Quat.identity is a unit quaternion w=1
    auto q = Quat.identity();
    assert(q.w == 1 && q.x == 0 && q.y == 0 && q.z == 0);
}
