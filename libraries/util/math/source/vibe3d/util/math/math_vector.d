module vibe3d.util.math.math_vector;

import vibe3d.util.math.math_quaternion;
import vibe3d.util.math.math_matrix;
import vibe3d.util.math.math_geometry;
import std.math : tan, sin, cos, sqrt, PI, abs, acos, asin, atan2, round, isFinite;
version (unittest) import std.math : isClose;

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
// The replacement is `tools.create.create_common.screenToPlacementWorld`: the
// view work-plane anchor law, TOTAL — it returns a Vec3, so there is no
// boolean left to drop.
//
// Nothing is left here rather than a fixed version, deliberately: a helper
// whose DEFAULT argument is the degenerate plane is a trap that re-arms the
// moment someone calls it with the defaults again.

// Safe normalize — returns (0,1,0) for near-zero vectors.
Vec3 safeNormalize(Vec3 v) @safe pure nothrow @nogc {
    float len = v.length;
    return len > 1e-6f ? v / len : Vec3(0, 1, 0);
}
