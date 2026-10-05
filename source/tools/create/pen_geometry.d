// The pen's one stroke builder: a PURE function of a stroke value that appends
// the stroke's world vertices and its faces/edges to a mesh. It is the ONLY
// producer of pen geometry — live preview, prepared parameter image, prepared
// deactivate candidate and live commit all call `appendPenGeometry`, so what
// the user sees while drawing is what Enter / tool drop commits. The census
// `tests/unit/pen_single_builder_census_test.d` keeps every mesh adder out of
// `pen.d`. Design: doc/pen_parity_wave_plan_2026-10-04.md §3.2 M-BUILD, §9.1.
module tools.create.pen_geometry;

import math : Vec3, Viewport, cross, dot, eyeVectorAt, faceNormalFirst3;
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
    bool  flip         = false;    // reverse the ring (decided by the tool at point 3)
    // Make Quads: after two anchor clicks every further pair of points closes
    // one quad of a strip, laid out [top0, bot0, top1, bot1, ...].
    bool  makeQuads    = false;
    // A gesture-placed point near an edited-mesh vertex shares it (wave plan S5).
    bool  merge        = true;
}
// Field sizes summed by hand (a field added must be added here and to the
// member pin in pen_geometry_test), rounded to 4: no interior padding.
static assert(PenParams.sizeof ==
    (2 * int.sizeof + 3 * float.sizeof + 3 * bool.sizeof + 3) / 4 * 4,
    "PenParams has interior padding that sameValueBytes would compare");

enum PenBuildPurpose : ubyte { Preview, Commit }

/// Everything the builder reads. Built only by `PenStroke.of`, from the tool's
/// live state or from a prepared image's copies of it.
struct PenStroke {
    const(Vec3)[] points;   // LOCAL workplane positions, click order
    // Per point: >= 0 = the index of the edited-mesh vertex it shares (S5
    // merge), else its own vertex. Empty = all own (a preview: its mesh holds
    // no scene vertex).
    const(int)[]  links;
    float[16]     toWorld;  // workplane local → world
    bool          flip;
    bool          quads;

    static PenStroke of(const(Vec3)[] pts, in float[16] toWorld,
            in PenParams p, const(int)[] links = null) nothrow @nogc {
        PenStroke s;
        s.points = pts; s.links = links; s.toWorld = toWorld;
        s.flip = p.flip; s.quads = p.makeQuads;
        return s;
    }
}

/// Fewest points that close the stroke's face shape: a triangle, or the
/// first quad of a strip.
size_t penFaceMinimum(bool quads) nothrow @nogc { return quads ? 4 : 3; }

/// The tool's facing decision (wave plan §9.4): flip when the triangle
/// (p0, p1, p2), wound in that order, faces away from the eye ray at p2 (per
/// point in perspective, the view forward in ortho). A collinear triple — the
/// display normal's own degeneracy bound — never flips. World positions.
bool penFacingFlip(Vec3 p0, Vec3 p1, Vec3 p2, const ref Viewport vp) {
    bool degenerate;
    const n = faceNormalFirst3(p0, p1, p2, degenerate);
    return !degenerate && dot(n, eyeVectorAt(vp, p2)) > 0;
}

/// The one ring order of a pen polygon (wave plan §9.4; fixture
/// pen_facing.json): indices into `v`. Corner normal N(i) = (v[i+1] − v[i]) ×
/// (v[i−1] − v[i]). Below 3 points: click order. Triangle: [0,1,2], reversed
/// keeping the first index iff `reverse`. From 4 points, when corners 0 and 1
/// agree the list starts at 1 (then backs off a degenerate first corner) and
/// is reversed iff `reverse`; when they disagree it is reversed iff NOT
/// `reverse`, and from 5 points starts at the first k in [2, n−3] agreeing
/// with corner 0.
uint[] penRingOrder(const(Vec3)[] v, bool reverse) {
    const n = v.length;
    uint[] ring;
    foreach (i; 0 .. n) ring ~= cast(uint)i;
    Vec3 corner(size_t i) {
        return cross(v[(i + 1) % n] - v[i], v[(i + n - 1) % n] - v[i]);
    }
    bool rev = reverse;
    if (n > 3) {
        if (dot(corner(0), corner(1)) >= 0) {
            ring = ring[1 .. $] ~ ring[0];
            foreach (_; 0 .. n) {
                if (corner(ring[0]).length > 1e-6f) break;
                ring = ring[$ - 1] ~ ring[0 .. $ - 1];
            }
        } else {
            rev = !reverse;
            foreach (k; 2 .. n - 2)
                if (dot(corner(0), corner(k)) >= 0) {
                    ring = ring[k .. $] ~ ring[0 .. k];
                    break;
                }
        }
    }
    if (rev)
        foreach (i; 1 .. (n + 1) / 2) {
            const t = ring[i]; ring[i] = ring[n - i]; ring[n - i] = t;
        }
    return ring;
}

/// Append the stroke to `dst`; returns `dst`'s vertex count before the call
/// (the index of the first new vertex, if any: a linked point appends no
/// vertex, its faces use the shared index).
///
/// At or above the face minimum: the strip's quads `[2k+1, 2k+3, 2k+2, 2k]`,
/// `[2k, 2k+2, 2k+3, 2k+1]` under `flip` (that order winds against the decision
/// triangle (p0, p1, p2), so the decided flip faces the camera either way; an
/// odd last point is left unused; interim until S7's strip rule), or one polygon of
/// all points in `penRingOrder`. Below it a Commit still makes one face of all
/// points (the two-point face a tool drop keeps) while a Preview shows the
/// open polyline as edges. Preview and Commit order every ring alike.
///
/// Precondition: a makeQuads Commit below 4 points yields ONE face of all
/// points, not a quad; callers keep it out by gating on `minDropCommitVerts`.
uint appendPenGeometry(ref Mesh dst, in PenStroke s, PenBuildPurpose purpose) {
    const uint base = cast(uint)dst.vertices.length;
    const uint n = cast(uint)s.points.length;
    auto world = new Vec3[n];
    auto idx = new uint[n];     // stroke point → mesh vertex
    foreach (i, p; s.points) {
        world[i] = transformPoint(s.toWorld, p);
        const bool linked = i < s.links.length && s.links[i] >= 0;
        idx[i] = linked ? cast(uint)s.links[i] : cast(uint)dst.vertices.length;
        if (!linked) dst.addVertex(world[i]);
    }

    const bool closed = n >= penFaceMinimum(s.quads);
    if (closed && s.quads) {
        foreach (k; 0 .. n / 2 - 1) {
            const uint a = idx[2*k],     b = idx[2*k + 2];
            const uint c = idx[2*k + 3], d = idx[2*k + 1];
            dst.addFace(s.flip ? [a, b, c, d] : [d, c, b, a]);
        }
    } else if (closed || purpose == PenBuildPurpose.Commit) {
        uint[] face = penRingOrder(world, s.flip);
        foreach (ref i; face) i = idx[i];
        dst.addFace(face);
    } else {
        foreach (i; 1 .. n) dst.addEdge(idx[i - 1], idx[i]);
    }
    return base;
}
