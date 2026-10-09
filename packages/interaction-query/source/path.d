module path;

import math : Vec3, normalize;
import mesh : Mesh;

// ---------------------------------------------------------------------------
// PathSource — lightweight ordered vertex-index list + closed flag.
// Held by PathStage (NOT stored on Mesh — zero .v3d/snapshot/undo blast
// radius). The stage resolves live world positions at evaluate() time
// through a mesh accessor delegate.
//
// vibe3d-divergence: vibe3d has no curve-polygon geometry type; a
// stage-held vertex-index list is the minimal viable foundation. Revisit
// when the pen tool or import paths grow real curve geometry.
//
// Known foundation limitation: knots are positional vertex-index references.
// Deleting or reordering mesh vertices silently re-targets or drops knots
// with no misalignment (resolveKnots skips out-of-range indices). Injected
// test sources only; no live editing interaction in this phase.
// ---------------------------------------------------------------------------

/// Ordered list of vertex indices forming a polyline, plus a closed flag.
struct PathSource {
    uint[] verts;
    bool   closed = false;
}

/// Resolve a PathSource to world-space knot positions by reading the live
/// mesh vertex array. Out-of-range indices are silently dropped. Returns
/// null when fewer than 2 valid knots remain (caller treats as disabled).
Vec3[] resolveKnots(const ref PathSource src, const Mesh* mesh) nothrow {
    if (mesh is null || src.verts.length == 0) return null;
    Vec3[] knots;
    knots.reserve(src.verts.length);
    foreach (vi; src.verts) {
        if (cast(size_t)vi >= mesh.vertices.length) continue;
        knots ~= mesh.vertices[vi];
    }
    if (knots.length < 2) return null;
    return knots;
}

// ---------------------------------------------------------------------------
// Pure linear (polyline) evaluator over a resolved Vec3[] knots array.
//
// t ∈ [0, 1] — arc-length normalised over the full polyline:
//   t = 0 → first knot; t = 1 → last knot (or first when closed).
//
// Foundation parameterisation: arc-length normalised, linear interpolation.
// Whether the reference editor uses arc-length vs knot-parameter for
// start/end/slide is CAPTURE-GATED and deferred to the consumer task. The
// equal-leg golden tests are parameterisation-independent by construction.
//
// All evaluators are allocation-free (two-pass over the knots slice).
// ---------------------------------------------------------------------------

/// Total arc length of the polyline.
float pathLengthTotal(const Vec3[] knots, bool closed)
    pure nothrow @safe @nogc
{
    if (knots.length < 2) return 0.0f;
    size_t n     = closed ? knots.length : knots.length - 1;
    float  total = 0.0f;
    foreach (i; 0 .. n) {
        size_t j = (i + 1) % knots.length;
        total += (knots[j] - knots[i]).length;
    }
    return total;
}

/// Arc length of the sub-range [t0, t1] (fraction of total length).
float pathLength(const Vec3[] knots, bool closed, float t0, float t1)
    pure nothrow @safe @nogc
{
    if (knots.length < 2) return 0.0f;
    float total = pathLengthTotal(knots, closed);
    if (total <= 0.0f) return 0.0f;
    return (t1 - t0) * total;
}

/// World-space position at arc-length-normalised t ∈ [0, 1].
Vec3 pathValue(const Vec3[] knots, bool closed, float t)
    pure nothrow @safe @nogc
{
    if (knots.length == 0) return Vec3(0, 0, 0);
    if (knots.length == 1) return knots[0];
    if (t <= 0.0f) return knots[0];
    if (t >= 1.0f) return closed ? knots[0] : knots[$ - 1];

    size_t n = closed ? knots.length : knots.length - 1;

    // Pass 1: compute total arc length.
    float total = 0.0f;
    foreach (i; 0 .. n) {
        size_t j = (i + 1) % knots.length;
        total += (knots[j] - knots[i]).length;
    }
    if (total <= 0.0f) return knots[0];

    // Pass 2: walk to the target arc distance.
    float target = t * total;
    float accum  = 0.0f;
    foreach (i; 0 .. n) {
        size_t j       = (i + 1) % knots.length;
        float  segLen  = (knots[j] - knots[i]).length;
        float  next    = accum + segLen;
        if (next >= target || i == n - 1) {
            float u = segLen > 0.0f ? (target - accum) / segLen : 0.0f;
            if (u < 0.0f) u = 0.0f;
            if (u > 1.0f) u = 1.0f;
            Vec3 a = knots[i];
            Vec3 b = knots[j];
            return Vec3(a.x + u * (b.x - a.x),
                        a.y + u * (b.y - a.y),
                        a.z + u * (b.z - a.z));
        }
        accum = next;
    }
    return knots[$ - 1];
}

/// Unit tangent direction at arc-length-normalised t.
/// At an exact interior knot the INCOMING segment direction is returned
/// (the segment whose endpoint equals the knot wins the `next >= target`
/// test; foundation default, tangent convention is capture-gated).
Vec3 pathTangent(const Vec3[] knots, bool closed, float t)
    pure nothrow @safe @nogc
{
    if (knots.length < 2) return Vec3(1, 0, 0);

    size_t n = closed ? knots.length : knots.length - 1;

    // Pass 1: total arc length.
    float total = 0.0f;
    foreach (i; 0 .. n) {
        size_t j = (i + 1) % knots.length;
        total += (knots[j] - knots[i]).length;
    }
    if (total <= 0.0f) return Vec3(1, 0, 0);

    float target = (t <= 0.0f) ? 0.0f : (t >= 1.0f ? total : t * total);

    // Pass 2: find the segment containing target arc distance.
    float accum = 0.0f;
    foreach (i; 0 .. n) {
        size_t j      = (i + 1) % knots.length;
        float  segLen = (knots[j] - knots[i]).length;
        float  next   = accum + segLen;
        if (next >= target || i == n - 1) {
            Vec3  dir = knots[j] - knots[i];
            float len = dir.length;
            return len > 0.0f ? normalize(dir) : Vec3(1, 0, 0);
        }
        accum = next;
    }
    return Vec3(1, 0, 0);
}

/// Bank angle at t — stub returning 0.
/// Bank/orientation frame semantics are capture-gated; deferred to the
/// consumer task.
float pathBank(const Vec3[] knots, bool closed, float t)
    pure nothrow @safe @nogc
{
    return 0.0f;
}

// ---------------------------------------------------------------------------
// Unit tests — run by `dub test --config=tests`. No running app needed.
// ---------------------------------------------------------------------------
