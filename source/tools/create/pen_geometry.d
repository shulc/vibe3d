// The pen's one stroke builder: a PURE function of a stroke value that appends
// the stroke's world vertices and its faces/edges to a mesh. It is the ONLY
// producer of pen geometry — live preview, prepared parameter image, prepared
// deactivate candidate and live commit all call `appendPenGeometry`, so what
// the user sees while drawing is what Enter / tool drop commits. The census
// `tests/unit/pen_single_builder_census_test.d` keeps every mesh adder out of
// `pen.d`. Design: doc/pen_parity_wave_plan_2026-10-04.md §3.2 M-BUILD, §9.1.
module tools.create.pen_geometry;

import math : Vec3, Viewport, cross, dot, eyeVectorAt, faceNormalFirst3, normalize;
import mesh : Mesh;
import symmetry : mirrorPosition;
import toolpipe.packets : SymmetryPacket;
import tools.create.create_common : WorkplaneFrame, transformDir, transformPoint;

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
    // Make Quads: every click after the first two adds a strip quad (penStripQuad).
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
    // merge); -1 = its own vertex; <= -2 = it shares the vertex of the mirror
    // image of point j = -2 - link (S6; j = itself: the point is its own
    // mirror). Empty = all own.
    const(int)[]  links;
    float[16]     toWorld;  // workplane local → world
    bool          flip;
    bool          quads;
    // The latched symmetry (S6): `enabled`, `planePoint`, `planeNormal` read.
    SymmetryPacket mirror;

    static PenStroke of(const(Vec3)[] pts, in float[16] toWorld, in PenParams p,
            const(int)[] links = null, in SymmetryPacket mirror = SymmetryPacket.init)
            nothrow @nogc {
        PenStroke s;
        s.points = pts; s.links = links; s.toWorld = toWorld;
        s.flip = p.flip; s.quads = p.makeQuads; s.mirror = penMirror(mirror);
        return s;
    }
}

/// A symmetry packet's config and plane, without its per-vertex pairing: the
/// value a stroke latches and its images carry.
SymmetryPacket penMirror(in SymmetryPacket sp) nothrow @nogc {
    SymmetryPacket m;
    m.config = sp.config; m.planePoint = sp.planePoint; m.planeNormal = sp.planeNormal;
    return m;
}

/// The mirror plane of symmetry axis `axis` (offset `offset`) "in the work
/// plane" `wp` (wave plan S6, fixture pen_symmetry.json A5-symWP / A5-symWP2):
/// the axis plane mapped by the work plane's transform W TWICE — normal
/// R·R·e_axis through W(W(offset·e_axis)). Captured (X axis, offset 0); a
/// probable reference defect copied by owner decision. `axis` is the stage's
/// 0 / 1 / 2 (its only writers parse x / y / z).
void penWorkplaneMirrorPlane(int axis, float offset, in WorkplaneFrame wp,
                             out Vec3 point, out Vec3 normal) {
    Vec3 e = Vec3(axis == 0 ? 1 : 0, axis == 1 ? 1 : 0, axis == 2 ? 1 : 0);
    normal = normalize(transformDir(wp.toWorld, transformDir(wp.toWorld, e)));
    point = transformPoint(wp.toWorld, transformPoint(wp.toWorld, e * offset));
}

/// Fewest points that close the stroke's face shape: a triangle, or the
/// first quad of a strip.
size_t penFaceMinimum(bool quads) nothrow @nogc { return quads ? 4 : 3; }

/// Quad `k` of a Make Quads strip as point indices [L1, L0, c, a], click order
/// (wave plan S7; fixture pen_quads.json strip_7_clicks): the first two clicks
/// seed the leading edge (L0, L1) = (c1, c0); a later click c is stored with
/// its automatic corner a = L1 + (c - L0) right after it, and (c, a) becomes
/// the next (L0, L1).
uint[4] penStripQuad(size_t k) nothrow @nogc {
    const uint c = cast(uint)(2 * k + 2);
    if (k == 0) return [0, 1, 2, 3];
    return [c - 1, c - 2, c, c + 1];
}

/// Reverse a ring in place, keeping its first index: [a, b, c, d] → [a, d, c, b].
void revKeepFirst(uint[] ring) nothrow @nogc {
    foreach (i; 1 .. (ring.length + 1) / 2) {
        const t = ring[i]; ring[i] = ring[$ - i]; ring[$ - i] = t;
    }
}

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
    if (rev) revKeepFirst(ring);
    return ring;
}

/// Append the stroke to `dst`; returns `dst`'s vertex count before the call
/// (the index of the first new vertex, if any: a linked point appends no
/// vertex, its faces use the shared index).
///
/// At or above the face minimum: the strip's quads `penStripQuad(k)`, reversed
/// keeping the first index under `flip` like every pen ring (fixture
/// pen_quads.json: [L1, a, c, L0] under flip 1, the flag read here, at build
/// time, so a later write turns every quad; an odd last point is left unused),
/// or one polygon of all points in `penRingOrder`. Below it a Commit still makes one face of all
/// points (the two-point face a tool drop keeps) while a Preview shows the
/// open polyline as edges. Preview and Commit order every ring alike.
///
/// A polygon point linking the vertex its predecessor (click order) links adds
/// no corner: [V, V, F] commits [V, F] (fixture `cells_k_b10`). The closing
/// pair (last = first), quads strips and a ring left below 2 corners (no face)
/// are not captured — gap rows 545, 549, 550.
///
/// Symmetry (wave plan S6, fixture pen_symmetry.json): the reflections follow
/// the originals in click order and take the same shape with the reverse
/// decision toggled. A point linked to the mirror image of point j shares that
/// image's vertex and its own image shares j's; their positions are the mirror
/// images, written last (A7). A point that is its own mirror adds no image.
///
/// Precondition: a makeQuads Commit below 4 points yields ONE face of all
/// points, not a quad; callers keep it out by gating on `minDropCommitVerts`.
uint appendPenGeometry(ref Mesh dst, in PenStroke s, PenBuildPurpose purpose) {
    const uint base = cast(uint)dst.vertices.length;
    const size_t n = s.points.length, slots = s.mirror.enabled ? 2 * n : n;
    auto world = new Vec3[2 * n];   // originals, then their mirror images
    foreach (i, p; s.points) {
        world[i] = transformPoint(s.toWorld, p);
        world[n + i] = mirrorPosition(s.mirror, world[i]);
    }
    auto pos = world.dup;
    auto sharedWith = new int[2 * n];   // slot → the original slot whose vertex it takes
    sharedWith[] = -1;
    foreach (i; 0 .. n) {
        const l = i < s.links.length ? s.links[i] : -1, j = -2 - l;
        if (l > -2 || j >= n) continue;
        sharedWith[n + j] = cast(int)i; sharedWith[n + i] = j;
        if (j != i) { pos[i] = world[n + j]; pos[j] = world[n + i]; }
    }
    auto idx = new uint[2 * n];     // slot → mesh vertex
    foreach (k; 0 .. slots) {
        if (k < s.links.length && s.links[k] >= 0) idx[k] = cast(uint)s.links[k];
        else if (sharedWith[k] >= 0) idx[k] = idx[sharedWith[k]];
        else { idx[k] = cast(uint)dst.vertices.length; dst.addVertex(pos[k]); }
    }

    const bool closed = n >= penFaceMinimum(s.quads);
    void shape(Vec3[] w, uint[] ix, bool reverse) {
        if (closed && s.quads) {
            foreach (k; 0 .. n / 2 - 1) {
                uint[4] q = penStripQuad(k);
                if (reverse) revKeepFirst(q[]);
                foreach (ref i; q) i = ix[i];
                dst.addFace(q[]);
            }
        } else if (closed || purpose == PenBuildPurpose.Commit) {
            size_t m;
            foreach (i; 0 .. n)
                if (i == 0 || ix[i] != ix[i - 1]) {
                    w[m] = w[i]; ix[m] = ix[i]; ++m;
                }
            if (m < 2) return;
            uint[] face = penRingOrder(w[0 .. m], reverse);
            foreach (ref i; face) i = ix[i];
            dst.addFace(face);
        } else {
            foreach (i; 1 .. n) dst.addEdge(ix[i - 1], ix[i]);
        }
    }
    shape(world[0 .. n], idx[0 .. n], s.flip);
    if (slots > n) shape(world[n .. $], idx[n .. $], !s.flip);
    return base;
}
