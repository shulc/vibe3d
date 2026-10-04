// The pen's one stroke builder: a PURE function of a stroke value that appends
// the stroke's world vertices and its faces/edges to a mesh. It is the ONLY
// producer of pen geometry — live preview, prepared parameter image, prepared
// deactivate candidate and live commit all call `appendPenGeometry`, so what
// the user sees while drawing is what Enter / tool drop commits. The census
// `tests/unit/pen_single_builder_census_test.d` keeps every mesh adder out of
// `pen.d`. Design: doc/pen_parity_wave_plan_2026-10-04.md §3.2 M-BUILD, §9.1.
module tools.create.pen_geometry;

import math : Vec3;
import mesh : Mesh;
import tools.create.create_common : transformPoint;

/// The pen tool's wire schema (panel / `tool.attr` values). Compared with
/// `memcmp` by the prepared images, so it must stay plain data: 4-byte fields
/// first, then `bool`s, so no interior padding exists (wave plan §7).
struct PenParams {
    int   type         = 0;        // 0 = polygons (the only type so far)
    // Per-gesture point-edit proxies: currentPoint = -1 means "no vertex
    // selected"; posX/Y/Z mirror vertices_[currentPoint] and are written back
    // through onParamChanged.
    int   currentPoint = -1;
    float posX = 0.0f, posY = 0.0f, posZ = 0.0f;
    bool  flip         = false;    // reverse the winding on commit
    // Make Quads: after two anchor clicks every further pair of points closes
    // one quad of a strip, laid out [top0, bot0, top1, bot1, ...].
    bool  makeQuads    = false;
}
static assert(PenParams.sizeof == () {
    size_t sum;
    static foreach (T; typeof(PenParams.tupleof)) sum += T.sizeof;
    return (sum + 3) / 4 * 4;
}(), "PenParams has interior padding that sameValueBytes would compare");

enum PenBuildPurpose : ubyte { Preview, Commit }

/// Everything the builder reads. Built only by `PenStroke.of`, from the tool's
/// live state or from a prepared image's copies of it.
struct PenStroke {
    const(Vec3)[] points;   // LOCAL workplane positions, click order
    float[16]     toWorld;  // workplane local → world
    bool          flip;
    bool          quads;

    static PenStroke of(const(Vec3)[] pts, in float[16] toWorld,
            in PenParams p) nothrow @nogc {
        PenStroke s;
        s.points = pts; s.toWorld = toWorld;
        s.flip = p.flip; s.quads = p.makeQuads;
        return s;
    }
}

/// Fewest points that close the stroke's face shape: a triangle, or the
/// first quad of a strip.
size_t penFaceMinimum(bool quads) nothrow @nogc { return quads ? 4 : 3; }

/// Append the stroke to `dst`; returns the index of its first new vertex.
///
/// At or above the face minimum: the strip's quads `[2k, 2k+2, 2k+3, 2k+1]`
/// (an odd last point is left unused), or one polygon of all points. Below it
/// a Commit still makes one face of all points (the two-point face a tool drop
/// keeps) while a Preview shows the open polyline as edges. Flip reverses the
/// winding on Commit only: the preview stays un-flipped so it is never
/// back-face culled away (transitional until the tool computes flip).
///
/// Precondition: a makeQuads Commit below 4 points yields ONE face of all
/// points, not a quad; callers keep it out by gating on `minDropCommitVerts`.
uint appendPenGeometry(ref Mesh dst, in PenStroke s, PenBuildPurpose purpose) {
    const uint base = cast(uint)dst.vertices.length;
    const uint n = cast(uint)s.points.length;
    foreach (p; s.points) dst.addVertex(transformPoint(s.toWorld, p));

    const bool flip = purpose == PenBuildPurpose.Commit && s.flip;
    const bool closed = n >= penFaceMinimum(s.quads);
    if (closed && s.quads) {
        foreach (k; 0 .. n / 2 - 1) {
            const uint a = base + 2*k,     b = base + 2*k + 2;
            const uint c = base + 2*k + 3, d = base + 2*k + 1;
            dst.addFace(flip ? [d, c, b, a] : [a, b, c, d]);
        }
    } else if (closed || purpose == PenBuildPurpose.Commit) {
        uint[] face; face.length = n;
        foreach (i; 0 .. n) face[i] = base + (flip ? n - 1 - i : i);
        dst.addFace(face);
    } else {
        foreach (i; 1 .. n) dst.addEdge(base + i - 1, base + i);
    }
    return base;
}
