module constraint;

import std.math : sqrt;

import math : Vec3, Viewport, dot, cross, normalize,
              projectToWindowFull, closestOnSegment2D;
import mesh : Mesh, edgeKey;
import toolpipe.packets : ConstrainPacket, ConstrainGeom, ConstrainHitPacket,
                          HoverTarget, HoverTargetKind;

// ---------------------------------------------------------------------------
// World-space geometry constraint math — Stage 3 of doc/cons_constraint_plan.md.
//
// All functions operate in world space; screen-space projection is handled
// by snap.d (screen-space cursor candidates). This module is purely
// computational — no toolpipe state, no global reads — so it is fully
// unit-testable under `dub test --config=modeling`.
//
// Working assumptions (unverified, revisit on Stage-0 captures):
//   * `point` mode uses nearest-foot (perpendicular closest-point) not
//     camera-ray (§6.5 of the plan).
//   * Application is per-vertex post-fold (§6.6 — per-delta is an
//     alternative that would move the hook to move.d:applySnapToDelta).
// Both assumptions are documented as non-verified in the plan's DoD.
//
// `vector` projects each vertex along the normalised per-vertex edit delta
// (motionDelta = finalPos − basePos); zero or near-zero delta returns the
// vertex unchanged (keep-on-miss). `screen` projects along the camera-forward
// axis extracted from the view matrix; a degenerate or uninitialised view
// matrix also returns unchanged. Both modes keep the position on a forward
// miss (no geometry hit in the projection direction).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// closestPointOnTriangle
//
// Standard Ericson barycentric closest-point (Real-Time Collision Detection
// §5.1.5). Pure, @nogc — safe to call from inside a per-vertex loop.
// ---------------------------------------------------------------------------
Vec3 closestPointOnTriangle(Vec3 p, Vec3 a, Vec3 b, Vec3 c)
    pure nothrow @nogc @safe
{
    Vec3 ab = b - a;
    Vec3 ac = c - a;
    Vec3 ap = p - a;

    float d1 = dot(ab, ap);
    float d2 = dot(ac, ap);
    if (d1 <= 0.0f && d2 <= 0.0f) return a;  // vertex region A

    Vec3 bp = p - b;
    float d3 = dot(ab, bp);
    float d4 = dot(ac, bp);
    if (d3 >= 0.0f && d4 <= d3) return b;    // vertex region B

    float vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0f && d1 >= 0.0f && d3 <= 0.0f) {
        float v = d1 / (d1 - d3);
        return a + ab * v;                    // edge region AB
    }

    Vec3 cp_ = p - c;
    float d5 = dot(ab, cp_);
    float d6 = dot(ac, cp_);
    if (d6 >= 0.0f && d5 <= d6) return c;    // vertex region C

    float vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0f && d2 >= 0.0f && d6 <= 0.0f) {
        float w = d2 / (d2 - d6);
        return a + ac * w;                    // edge region AC
    }

    float va = d3 * d6 - d5 * d4;
    if (va <= 0.0f && (d4 - d3) >= 0.0f && (d5 - d6) >= 0.0f) {
        float ww = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        return b + (c - b) * ww;             // edge region BC
    }

    // Interior of triangle
    float denom = 1.0f / (va + vb + vc);
    float vv = vb * denom;
    float wv = vc * denom;
    return a + ab * vv + ac * wv;
}

// ---------------------------------------------------------------------------
// closestPointOnMeshes
//
// Walk every triangulated face of every source mesh; return the globally
// nearest foot. Fan-triangulates polygons (vertex 0 as the fan pivot).
// `dblSided` is reserved for the capture-gated back-face rule — for now
// all faces are considered regardless.
// Returns false when sources is empty or has no faces (caller keeps
// movingPos unchanged).
// ---------------------------------------------------------------------------
bool closestPointOnMeshes(Vec3 p,
                          const(Mesh)*[] sources,
                          bool dblSided,
                          out Vec3 hit,
                          out Vec3 hitNormal,
                          out float dist2)
{
    bool found = false;
    float bestD2 = float.infinity;
    Vec3  bestPt = p;
    Vec3  bestN  = Vec3(0, 1, 0);

    foreach (src; sources) {
        if (src is null) continue;
        const verts = src.vertices;
        foreach (face; src.faces.range) {
            if (face.length < 3) continue;
            // Fan triangulation: (0,i,i+1) for i in [1, n-2]
            Vec3 a = verts[face[0]];
            for (size_t i = 1; i + 1 < face.length; ++i) {
                Vec3 b = verts[face[i]];
                Vec3 cc = verts[face[i + 1]];
                Vec3 cpt = closestPointOnTriangle(p, a, b, cc);
                Vec3 d = cpt - p;
                float d2 = dot(d, d);
                if (d2 < bestD2) {
                    bestD2 = d2;
                    bestPt = cpt;
                    // Face normal (unnormalised is fine for the direction)
                    Vec3 n = cross(b - a, cc - a);
                    float nlen = sqrt(dot(n, n));
                    bestN = (nlen > 1e-12f) ? n * (1.0f / nlen) : Vec3(0, 1, 0);
                    found = true;
                }
            }
        }
    }

    if (found) {
        hit      = bestPt;
        hitNormal = bestN;
        dist2    = bestD2;
    }
    return found;
}

// ---------------------------------------------------------------------------
// projectAlongDirection
//
// Möller-Trumbore ray-triangle intersection along `dir` (world space).
// Finds the nearest forward hit across all source faces. Backs the
// `vector` and `screen` modes in constrainPoint. Returns false when no
// forward hit is found (caller keeps movingPos unchanged).
// ---------------------------------------------------------------------------
bool projectAlongDirection(Vec3 pos,
                           Vec3 dir,
                           const(Mesh)*[] sources,
                           bool dblSided,
                           out Vec3 hit,
                           out Vec3 hitNormal)
{
    float eps  = 1e-7f;
    float bestT = float.infinity;
    Vec3  bestPt = pos;
    Vec3  bestN  = Vec3(0, 1, 0);
    bool  found  = false;

    foreach (src; sources) {
        if (src is null) continue;
        const verts = src.vertices;
        foreach (face; src.faces.range) {
            if (face.length < 3) continue;
            Vec3 a = verts[face[0]];
            for (size_t i = 1; i + 1 < face.length; ++i) {
                Vec3 b = verts[face[i]];
                Vec3 cc = verts[face[i + 1]];
                // Möller-Trumbore
                Vec3 e1 = b - a;
                Vec3 e2 = cc - a;
                Vec3 h  = cross(dir, e2);
                float a_ = dot(e1, h);
                if (!dblSided && a_ < eps) continue;  // back-face or parallel
                if (a_ > -eps && a_ < eps) continue;  // parallel
                float f  = 1.0f / a_;
                Vec3 s   = pos - a;
                float u  = f * dot(s, h);
                if (u < 0.0f || u > 1.0f) continue;
                Vec3 q  = cross(s, e1);
                float v = f * dot(dir, q);
                if (v < 0.0f || u + v > 1.0f) continue;
                float t = f * dot(e2, q);
                if (t < eps || t >= bestT) continue;
                bestT  = t;
                bestPt = pos + dir * t;
                Vec3 n = cross(e1, e2);
                float nl = sqrt(dot(n, n));
                bestN = (nl > 1e-12f) ? n * (1.0f / nl) : Vec3(0, 1, 0);
                found = true;
            }
        }
    }

    if (found) { hit = bestPt; hitNormal = bestN; }
    return found;
}

// ---------------------------------------------------------------------------
// applyOffset
//
// Standoff along the surface normal by `offset` world units.
// Sign/direction are capture-gated (Stage 5); Stage 4 always calls with
// offset == 0, so this is an identity at that stage.
// ---------------------------------------------------------------------------
Vec3 applyOffset(Vec3 hitPos, Vec3 normal, float offset)
    pure nothrow @nogc @safe
{
    return hitPos + normal * offset;
}

// ---------------------------------------------------------------------------
// nearestFaceVertex / nearestFaceEdge / resolveHoverTarget — topology-pen
// P0/P1 (doc topopen_p0_plan.md, doc topopen_p1_plan.md). Pure derivation
// over an ALREADY-RESOLVED background-surface hit (face index + world
// point), read by the CONS stage's raycast branch
// (source/toolpipe/stages/constrain.d) to fill the "nearest element"
// fields of the published ConstrainHitPacket. No BVH / raycast here — that
// lives in bvh_pick.d (BvhPick.pickSurfaceRay); this module stays the
// pure-math layer per its existing doc comment.
//
// P0 shipped a standalone `ConstrainHit` struct here mirroring
// `ConstrainHitPacket` field-for-field, intended as this module's own
// "resolved hit" value type. It went unused (every caller passes the
// packet's fields directly to `nearestFaceVertex`/`nearestFaceEdge`) and is
// retired as of P1 (review REV-A) — `resolveHoverTarget` below takes
// `ConstrainHitPacket` directly rather than reintroducing a second,
// parallel struct.
// ---------------------------------------------------------------------------

/// Closest point on segment [a, b] to `p`. Small private helper backing
/// `nearestFaceEdge` — not exposed elsewhere (math.d already has a 2D
/// screen-space variant, `closestOnSegment2D`, for a different caller).
private Vec3 closestPointOnSegment3D(Vec3 p, Vec3 a, Vec3 b)
    pure nothrow @nogc @safe
{
    Vec3 ab = b - a;
    float len2 = dot(ab, ab);
    if (len2 < 1e-12f) return a;
    float t = dot(p - a, ab) / len2;
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    return a + ab * t;
}

/// Nearest vertex of `face` (an index into `m.faces`) to world point `p` —
/// argmin |p - vert|. Pure, best-effort: returns -1 when `face` is out of
/// range or empty (never throws / asserts — a raycast hit against a face
/// that has since been mutated out from under the caller degrades to "no
/// nearest element" rather than crashing).
int nearestFaceVertex(const ref Mesh m, int face, Vec3 p)
    pure nothrow @safe
{
    if (face < 0 || face >= cast(int)m.faces.length) return -1;
    const f = m.faces[face];
    int best = -1;
    float bestD2 = float.infinity;
    foreach (vi; f) {
        if (vi >= m.vertices.length) continue;
        Vec3 d = m.vertices[vi] - p;
        float d2 = dot(d, d);
        if (d2 < bestD2) { bestD2 = d2; best = cast(int)vi; }
    }
    return best;
}

/// Nearest edge of `face` (an index into `m.faces`) to world point `p` —
/// argmin point-to-segment distance over the face's boundary edges,
/// resolved to a `m.edges` index via `edgeKey`/`edgeIndexMap`. Best-effort:
/// returns -1 when `face` is out of range, has fewer than 2 vertices, or
/// `m.edgeIndexMap` is not currently valid/built (P0 accepts -1 here
/// rather than forcing a rebuild from a `const` reference — see
/// doc/topopen_p0_plan.md risk R6). NOT `pure` — `Mesh.edgeMapUsable()`
/// isn't itself annotated pure.
int nearestFaceEdge(const ref Mesh m, int face, Vec3 p) {
    if (face < 0 || face >= cast(int)m.faces.length) return -1;
    if (!m.edgeMapUsable()) return -1;
    const f = m.faces[face];
    if (f.length < 2) return -1;

    int best = -1;
    float bestD2 = float.infinity;
    foreach (i; 0 .. f.length) {
        uint a = f[i];
        uint b = f[(i + 1) % f.length];
        if (a >= m.vertices.length || b >= m.vertices.length) continue;
        Vec3 cp = closestPointOnSegment3D(p, m.vertices[a], m.vertices[b]);
        Vec3 d  = cp - p;
        float d2 = dot(d, d);
        if (d2 >= bestD2) continue;
        if (auto ep = edgeKey(a, b) in m.edgeIndexMap) {
            bestD2 = d2;
            best   = cast(int)*ep;
        }
    }
    return best;
}

// PLACEHOLDER radius for `resolveHoverTarget`'s Vertex/Edge snap test, in
// screen pixels. This is NOT the reference editor's real snap threshold —
// that (and the real vertex/edge/face precedence, including snapping
// against the PRIMARY layer's own new topology, which P1 does not resolve
// at all) is DEFERRED-CAPTURE (topology-pen C2 -> P4, doc/topopen_p1_plan.md).
enum float kTopoPenSnapPx = 12.0f;

/// PINNED shape, PLACEHOLDER precedence: pure screen-space resolution of
/// the hover's place-target from an already-published `ConstrainHitPacket`
/// (the CONS stage's background-surface raycast result — see
/// `source/toolpipe/stages/constrain.d`'s `raycastBackground`). No mesh
/// access, no cursor input — every input is carried on `h` (world
/// positions of the raycast hit and its candidate nearest vert/edge) so
/// `/api/surface-raycast` and `TopologyPenTool` compute IDENTICALLY from
/// the same packet (REV-A: this lives in the constraint layer, mirroring
/// `nearestFaceVertex`/`nearestFaceEdge` above, NOT in the CONS stage or
/// the tool).
///
/// Precedence Vertex > Edge > Face at a single fixed pixel radius
/// (`thPx`) is an explicit PLACEHOLDER (see `kTopoPenSnapPx`'s doc
/// comment) — NOT a claim that this matches the reference editor's real
/// snap precedence. `h.hit == false` (no surface hit at all) resolves to
/// `HoverTargetKind.None`; a hit that is behind the camera when projected
/// (should not normally happen — the hit itself came from a ray through
/// the same viewport) also degrades to `None` rather than asserting.
HoverTarget resolveHoverTarget(const ref ConstrainHitPacket h,
                               const ref Viewport vp, float thPx)
{
    HoverTarget r;                      // {None, -1, -1}
    if (!h.hit) return r;               // no surface hit -> no target

    r.kind = HoverTargetKind.Face;      // hit, but unsnapped default
    float ax, ay, az;
    if (!projectToWindowFull(h.point, vp, ax, ay, az)) return r;

    // Vertex candidate — priority 1.
    if (h.nearestVert >= 0) {
        float vx, vy, vz;
        if (projectToWindowFull(h.nearestVertPos, vp, vx, vy, vz)) {
            float dx = vx - ax, dy = vy - ay;
            if (dx * dx + dy * dy <= thPx * thPx) {
                r.kind = HoverTargetKind.Vertex;
                r.vert = h.nearestVert;
                return r;
            }
        }
    }

    // Edge candidate — priority 2.
    if (h.nearestEdge >= 0) {
        float ea0, ea1, ea2, eb0, eb1, eb2;
        if (projectToWindowFull(h.nearestEdgeA, vp, ea0, ea1, ea2)
         && projectToWindowFull(h.nearestEdgeB, vp, eb0, eb1, eb2)) {
            float t;
            if (closestOnSegment2D(ax, ay, ea0, ea1, eb0, eb1, t) <= thPx) {
                r.kind = HoverTargetKind.Edge;
                r.edge = h.nearestEdge;
                return r;
            }
        }
    }

    return r;                           // Face
}

// ---------------------------------------------------------------------------
// constrainPoint
//
// Top-level dispatch called from xfrm_transform.d::applyTRS for each
// moved vertex's final position. Returns `movingPos` unchanged when:
//   * cfg.enabled == false,
//   * cfg.geom == Off,
//   * no background sources are present,
//   * vector mode: motionDelta is zero or near-zero (no meaningful direction),
//   * screen mode: the view matrix is degenerate or uninitialised,
//   * any mode: projectAlongDirection finds no forward hit (keep-on-miss).
//
// Parameters:
//   movingPos   — the vertex's final world-space position after applyFold.
//   motionDelta — per-vertex edit delta (finalPos − basePos); consumed by
//                 `vector` mode as the projection direction; unused by `point`.
//   vp          — active viewport; consumed by `screen` mode to extract the
//                 camera-forward axis; unused by `point`.
//   sources     — background-mesh source list from snap.backgroundSourcesSnapshot().
//   cfg         — live ConstrainPacket published by ConstrainStage.
// ---------------------------------------------------------------------------
Vec3 constrainPoint(Vec3 movingPos,
                    Vec3 motionDelta,
                    Viewport vp,
                    const(Mesh)*[] sources,
                    const ref ConstrainPacket cfg)
{
    if (!cfg.enabled) return movingPos;
    if (sources.length == 0) return movingPos;

    final switch (cfg.geom) {
        case ConstrainGeom.Off:
            return movingPos;

        case ConstrainGeom.Point: {
            Vec3 hit, hitN;
            float d2;
            if (!closestPointOnMeshes(movingPos, sources, cfg.dblSided,
                                      hit, hitN, d2))
                return movingPos;
            return applyOffset(hit, hitN, cfg.offset);
        }

        case ConstrainGeom.Vector: {
            // Project along the normalized per-vertex edit direction.
            Vec3 dir = motionDelta;
            float lenSq = dot(dir, dir);
            if (!(lenSq > 1e-12f)) return movingPos;  // zero / near-zero delta → identity
            dir = normalize(dir);
            Vec3 hit, hitN;
            if (!projectAlongDirection(movingPos, dir, sources, cfg.dblSided, hit, hitN))
                return movingPos;                      // forward miss → keep position
            return applyOffset(hit, hitN, cfg.offset);
        }

        case ConstrainGeom.Screen: {
            // Project along the camera view axis (into the scene).
            if (vp.width == 0 || vp.height == 0) return movingPos;  // headless / uninitialised
            // Extract camFwd from view matrix column-major layout: -f at m[2], m[6], m[10].
            // (axis.d:336 reads the same indices, though the guard there covers the right-vector
            // magnitude rather than the forward-vector magnitude checked below.)
            Vec3 fwdVec = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
            float lenSq = dot(fwdVec, fwdVec);
            if (!(lenSq > 1e-6f)) return movingPos;   // degenerate / NaN view matrix
            Vec3 camFwd = normalize(fwdVec);
            Vec3 hit, hitN;
            if (!projectAlongDirection(movingPos, camFwd, sources, cfg.dblSided, hit, hitN))
                return movingPos;                      // forward miss → keep position
            return applyOffset(hit, hitN, cfg.offset);
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests — run under `dub test --config=modeling`.
// (MANDATORY for core math modules: the HTTP test suite silently skips
// unittest blocks in modules not imported by the test binary.)
// ---------------------------------------------------------------------------

unittest { // closestPointOnTriangle — interior
    // Point above the centroid of a unit triangle in XZ plane.
    Vec3 a = Vec3(0, 0, 0);
    Vec3 b = Vec3(1, 0, 0);
    Vec3 c = Vec3(0, 0, 1);
    Vec3 p = Vec3(0.25f, 5.0f, 0.25f);  // above centroid
    Vec3 r = closestPointOnTriangle(p, a, b, c);
    // Foot is perpendicular drop: Y collapses to 0, XZ unchanged
    import std.math : fabs;
    assert(fabs(r.x - 0.25f) < 1e-5f, "interior x");
    assert(fabs(r.y - 0.0f)  < 1e-5f, "interior y");
    assert(fabs(r.z - 0.25f) < 1e-5f, "interior z");
}

unittest { // closestPointOnTriangle — vertex region
    Vec3 a = Vec3(0, 0, 0);
    Vec3 b = Vec3(1, 0, 0);
    Vec3 c = Vec3(0, 0, 1);
    // Point far "above" vertex A → foot is A
    Vec3 r = closestPointOnTriangle(Vec3(-1.0f, 0, -1.0f), a, b, c);
    import std.math : fabs;
    assert(fabs(r.x) < 1e-5f && fabs(r.y) < 1e-5f && fabs(r.z) < 1e-5f,
           "vertex region A");
}

unittest { // closestPointOnTriangle — edge region
    Vec3 a = Vec3(0, 0, 0);
    Vec3 b = Vec3(2, 0, 0);
    Vec3 c = Vec3(1, 0, 2);
    // Point directly above midpoint of AB
    Vec3 p = Vec3(1, 3.0f, -1.0f);
    Vec3 r = closestPointOnTriangle(p, a, b, c);
    import std.math : fabs;
    assert(fabs(r.x - 1.0f) < 1e-4f, "edge AB midpoint x");
    assert(fabs(r.y - 0.0f) < 1e-4f, "edge AB midpoint y");
    assert(fabs(r.z - 0.0f) < 1e-4f, "edge AB midpoint z");
}

unittest { // closestPointOnMeshes — vert projects onto unit quad at y=0
    import mesh : Mesh;
    // Build a two-triangle quad in XZ at Y=0: verts (0,0,0) (1,0,0)
    // (1,0,1) (0,0,1), faces [(0,1,2), (0,2,3)].
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.faces    = [[0u,1u,2u], [0u,2u,3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*)m];
    Vec3 p = Vec3(0.5f, 3.0f, 0.5f);  // above centre of quad
    Vec3 hit, hitN;
    float d2;
    bool ok = closestPointOnMeshes(p, srcs, false, hit, hitN, d2);
    assert(ok, "closestPointOnMeshes should find a hit");
    import std.math : fabs;
    assert(fabs(hit.x - 0.5f) < 1e-4f, "hit x on quad");
    assert(fabs(hit.y - 0.0f) < 1e-4f, "hit y = 0 on quad");
    assert(fabs(hit.z - 0.5f) < 1e-4f, "hit z on quad");
}

unittest { // constrainPoint — point mode projects onto plane
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(-5,0,-5), Vec3(5,0,-5), Vec3(5,0,5), Vec3(-5,0,5)];
    m.faces    = [[0u,1u,2u], [0u,2u,3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*)m];
    ConstrainPacket cfg;
    cfg.enabled = true;
    cfg.geom    = ConstrainGeom.Point;
    cfg.offset  = 0.0f;
    Viewport vp;  // zero-init, unused for point mode
    Vec3 moved = Vec3(1.0f, 2.5f, 1.0f);
    Vec3 result = constrainPoint(moved, Vec3(0,0,0), vp, srcs, cfg);
    import std.math : fabs;
    assert(fabs(result.x - 1.0f) < 1e-4f, "x preserved");
    assert(fabs(result.y - 0.0f) < 1e-4f, "y projected to 0");
    assert(fabs(result.z - 1.0f) < 1e-4f, "z preserved");
}

unittest { // constrainPoint — disabled → identity
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,0,1)];
    m.faces    = [[0u,1u,2u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*)m];
    ConstrainPacket cfg;
    cfg.enabled = false;
    cfg.geom    = ConstrainGeom.Point;
    Viewport vp;
    Vec3 p = Vec3(0.3f, 7.0f, 0.3f);
    Vec3 r = constrainPoint(p, Vec3(0,0,0), vp, srcs, cfg);
    import std.math : fabs;
    assert(fabs(r.y - 7.0f) < 1e-5f, "disabled: y unchanged");
}

unittest { // constrainPoint — off mode → identity even when enabled
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,0,1)];
    m.faces    = [[0u,1u,2u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*)m];
    ConstrainPacket cfg;
    cfg.enabled = true;
    cfg.geom    = ConstrainGeom.Off;
    Viewport vp;
    Vec3 p = Vec3(0.3f, 7.0f, 0.3f);
    Vec3 r = constrainPoint(p, Vec3(0,0,0), vp, srcs, cfg);
    import std.math : fabs;
    assert(fabs(r.y - 7.0f) < 1e-5f, "off mode: y unchanged");
}

unittest { // constrainPoint — empty sources → identity
    const(Mesh)*[] srcs = [];
    ConstrainPacket cfg;
    cfg.enabled = true;
    cfg.geom    = ConstrainGeom.Point;
    Viewport vp;
    Vec3 p = Vec3(1.0f, 2.0f, 3.0f);
    Vec3 r = constrainPoint(p, Vec3(0,0,0), vp, srcs, cfg);
    import std.math : fabs;
    assert(fabs(r.x - 1.0f) < 1e-5f
        && fabs(r.y - 2.0f) < 1e-5f
        && fabs(r.z - 3.0f) < 1e-5f,
        "empty sources: position unchanged");
}

unittest { // constrainPoint — vector mode: downward delta hits +Y plane at Y=0
    import mesh : Mesh;
    import std.math : fabs;
    // Build a Y=0 quad wound for +Y normal: face [0,2,1] and [0,3,2].
    // v0=(0,0,0) v1=(1,0,0) v2=(1,0,1) v3=(0,0,1)
    // face [0,2,1]: e1=v2-v0=(1,0,1), e2=v1-v0=(1,0,0) → n=cross(e1,e2)=(0,1,0) +Y ✓
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.faces    = [[0u,2u,1u], [0u,3u,2u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*)m];
    ConstrainPacket cfg;
    cfg.enabled  = true;
    cfg.geom     = ConstrainGeom.Vector;
    cfg.dblSided = false;
    cfg.offset   = 0.0f;
    Viewport vp;  // unused by vector mode

    // Forward hit: delta (0,-1,0) from (0.5,2,0.5) → hits Y=0 at (0.5,0,0.5)
    Vec3 result = constrainPoint(Vec3(0.5f, 2.0f, 0.5f), Vec3(0,-1,0), vp, srcs, cfg);
    assert(fabs(result.x - 0.5f) < 1e-4f, "vector hit: x preserved");
    assert(fabs(result.y - 0.0f) < 1e-4f, "vector hit: y projected to 0");
    assert(fabs(result.z - 0.5f) < 1e-4f, "vector hit: z preserved");
}

unittest { // constrainPoint — vector mode: upward delta misses +Y plane → identity
    import mesh : Mesh;
    import std.math : fabs;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.faces    = [[0u,2u,1u], [0u,3u,2u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*)m];
    ConstrainPacket cfg;
    cfg.enabled  = true;
    cfg.geom     = ConstrainGeom.Vector;
    cfg.dblSided = false;
    cfg.offset   = 0.0f;
    Viewport vp;
    Vec3 pos    = Vec3(0.5f, 2.0f, 0.5f);
    // Upward ray: forward direction is away from the plane → miss → keep pos
    Vec3 result = constrainPoint(pos, Vec3(0,1,0), vp, srcs, cfg);
    assert(fabs(result.y - 2.0f) < 1e-4f, "vector miss: y unchanged (keep-on-miss)");
}

unittest { // constrainPoint — vector mode: zero delta → identity
    import mesh : Mesh;
    import std.math : fabs;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,0,1)];
    m.faces    = [[0u,1u,2u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*)m];
    ConstrainPacket cfg;
    cfg.enabled = true;
    cfg.geom    = ConstrainGeom.Vector;
    Viewport vp;
    Vec3 pos    = Vec3(0.3f, 5.0f, 0.3f);
    Vec3 result = constrainPoint(pos, Vec3(0,0,0), vp, srcs, cfg);
    assert(fabs(result.y - 5.0f) < 1e-5f, "vector zero-delta: identity");
}

unittest { // constrainPoint — screen mode: top-down view hits +Y plane at Y=0
    import mesh : Mesh;
    import std.math : fabs;
    // Same +Y quad as the vector test.
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.faces    = [[0u,2u,1u], [0u,3u,2u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*)m];
    ConstrainPacket cfg;
    cfg.enabled  = true;
    cfg.geom     = ConstrainGeom.Screen;
    cfg.dblSided = false;
    cfg.offset   = 0.0f;
    // Build a Viewport with camFwd = (0,-1,0) (top-down).
    // Column-major lookAt convention: -f stored at m[2],m[6],m[10].
    // f=(0,-1,0) → -f=(0,1,0) → view[2]=0, view[6]=1, view[10]=0.
    // Right vector r=(1,0,0) at view[0]=1,view[4]=0,view[8]=0 (rLenSq=1>1e-6).
    Viewport vp;
    vp.width  = 800;
    vp.height = 600;
    vp.view[0]  = 1.0f;  // r.x
    vp.view[2]  = 0.0f;  // -f.x
    vp.view[6]  = 1.0f;  // -f.y  (f.y = -1 → -f.y = 1)
    vp.view[10] = 0.0f;  // -f.z
    // camFwd = normalize(-view[2],-view[6],-view[10]) = (0,-1,0) ✓

    Vec3 result = constrainPoint(Vec3(0.5f, 2.0f, 0.5f), Vec3(0,0,0), vp, srcs, cfg);
    assert(fabs(result.x - 0.5f) < 1e-4f, "screen hit: x preserved");
    assert(fabs(result.y - 0.0f) < 1e-4f, "screen hit: y projected to 0");
    assert(fabs(result.z - 0.5f) < 1e-4f, "screen hit: z preserved");
}

unittest { // constrainPoint — screen mode: zero-width viewport → identity
    import mesh : Mesh;
    import std.math : fabs;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,0,1)];
    m.faces    = [[0u,1u,2u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*)m];
    ConstrainPacket cfg;
    cfg.enabled = true;
    cfg.geom    = ConstrainGeom.Screen;
    Viewport vp;   // zero-init: width=0, height=0
    Vec3 pos    = Vec3(0.3f, 5.0f, 0.3f);
    Vec3 result = constrainPoint(pos, Vec3(0,0,0), vp, srcs, cfg);
    assert(fabs(result.y - 5.0f) < 1e-5f, "screen degenerate-view: identity");
}

// ---------------------------------------------------------------------------
// P0 (topology-pen) unit tests: nearestFaceVertex / nearestFaceEdge.
// ---------------------------------------------------------------------------

unittest { // nearestFaceVertex — 4 corners of a unit quad each resolve exactly
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.addFace([0u,1u,2u,3u]);   // addFace incrementally builds edges + edgeIndexMap
    m.buildLoops();

    // A point offset slightly toward each corner resolves to that corner's
    // vertex index — clearly closer than any other corner.
    assert(nearestFaceVertex(*m, 0, Vec3(-0.1f, 0.05f, -0.1f)) == 0, "corner 0");
    assert(nearestFaceVertex(*m, 0, Vec3( 1.1f, 0.05f, -0.1f)) == 1, "corner 1");
    assert(nearestFaceVertex(*m, 0, Vec3( 1.1f, 0.05f,  1.1f)) == 2, "corner 2");
    assert(nearestFaceVertex(*m, 0, Vec3(-0.1f, 0.05f,  1.1f)) == 3, "corner 3");
}

unittest { // nearestFaceVertex — out-of-range face -> -1 (best-effort, never throws)
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.addFace([0u,1u,2u,3u]);   // addFace incrementally builds edges + edgeIndexMap
    m.buildLoops();
    assert(nearestFaceVertex(*m, 7, Vec3(0,0,0)) == -1, "face index too high");
    assert(nearestFaceVertex(*m, -1, Vec3(0,0,0)) == -1, "negative face index");
}

unittest { // nearestFaceEdge — 4 edge midpoints of a unit quad each resolve to
           // the CORRECT mesh.edges index, looked up via edgeKey (not a
           // hardcoded assumption about buildLoops' edge ordering).
    import mesh : Mesh, edgeKey;
    import std.conv : to;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.addFace([0u,1u,2u,3u]);   // addFace incrementally builds edges + edgeIndexMap
    m.buildLoops();

    uint[2][4] pairs = [[0,1], [1,2], [2,3], [3,0]];
    Vec3[4] mids = [
        Vec3(0.5f,  0.05f, -0.05f),  // near edge (0,1) midpoint (0.5,0,0)
        Vec3(1.05f, 0.05f,  0.5f),   // near edge (1,2) midpoint (1,0,0.5)
        Vec3(0.5f,  0.05f,  1.05f),  // near edge (2,3) midpoint (0.5,0,1)
        Vec3(-0.05f,0.05f,  0.5f),   // near edge (3,0) midpoint (0,0,0.5)
    ];
    foreach (i; 0 .. 4) {
        int got = nearestFaceEdge(*m, 0, mids[i]);
        auto expPtr = edgeKey(pairs[i][0], pairs[i][1]) in m.edgeIndexMap;
        assert(expPtr !is null, "edgeIndexMap missing pair " ~ i.to!string);
        assert(got == cast(int)*expPtr,
            "edge midpoint " ~ i.to!string ~ ": expected " ~ (*expPtr).to!string
            ~ ", got " ~ got.to!string);
    }
}

unittest { // nearestFaceEdge — miss cases: out-of-range face, and a mesh whose
           // edgeIndexMap was never built (best-effort -1, no crash).
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.addFace([0u,1u,2u,3u]);   // addFace incrementally builds edges + edgeIndexMap
    m.buildLoops();
    assert(nearestFaceEdge(*m, 9, Vec3(0.5f, 0, 0)) == -1, "out-of-range face");

    auto m2 = new Mesh();   // never buildLoops()'d — edgeIndexMap stale/empty
    m2.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m2.faces    = [[0u,1u,2u,3u]];
    assert(nearestFaceEdge(*m2, 0, Vec3(0.5f, 0, 0)) == -1,
        "edgeIndexMap not built -> best-effort -1");
}

unittest { // nearestFaceEdge — grazing case: a point at a shared CORNER is
           // equidistant-ish from its two incident edges; the argmin must
           // still resolve to SOME valid edge (no crash, no spurious -1).
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.addFace([0u,1u,2u,3u]);   // addFace incrementally builds edges + edgeIndexMap
    m.buildLoops();
    int got = nearestFaceEdge(*m, 0, Vec3(1.0f, 0.05f, 0.0f));  // corner (1,0,0)
    assert(got >= 0 && got < cast(int)m.edges.length,
        "grazing corner case should still resolve to a valid edge index");
}

// ---------------------------------------------------------------------------
// resolveHoverTarget — topology-pen P1 (doc/topopen_p1_plan.md). GL-free
// pure unittests: a synthetic Viewport (identity-ish lookAt at Z=5, 90°
// symmetric perspective, 800x800) makes the projected-pixel math a plain
// scale by a hand-derivable constant, so every expected pixel distance
// below is independently computed (not round-tripped through the function
// under test) — same rigor as the HTTP fixture's threshold-flip cases
// (topo_pen_hover_target.json #5/#6).
//
// Camera: eye=(0,0,5), lookAt origin, up=(0,1,0), fovY=90 deg (f = 1/tan(45)
// = 1), aspect=1, width=height=800. Both the hit point and every candidate
// below sit at world Z=0 (same depth as the lookAt target), so the
// perspective divide's w is constant (== distance == 5) across all of
// them, and the projection collapses to a PURE uniform scale + centering:
//   screenX = 400 + S*worldX,  screenY = 400 - S*worldY,  S = f*0.5*height/eye.z
//           = 1 * 0.5*800/5 = 80 px per world unit.
// (This is the SAME derivation the topo_pen_hover_target.json fixture's
// provenance uses for its az=0/el=0 cube cases — see that file's notes.)
// ---------------------------------------------------------------------------
version (unittest) private Viewport makeHoverTestViewport() {
    import math : lookAt, perspectiveMatrix;
    import std.math : PI;
    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    vp.x = 0;
    vp.y = 0;
    return vp;
}

unittest { // resolveHoverTarget — no hit -> None (default packet)
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;   // hit == false by default
    auto t = resolveHoverTarget(h, vp, kTopoPenSnapPx);
    assert(t.kind == HoverTargetKind.None, "no hit must resolve to None");
    assert(t.vert == -1 && t.edge == -1);
}

unittest { // resolveHoverTarget — vertex within threshold wins (S=80 px/unit;
           // a 0.1-world-unit offset at Z=0 depth projects to exactly 8px)
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit           = true;
    h.point         = Vec3(0, 0, 0);          // projects to (400,400)
    h.nearestVert   = 3;
    h.nearestVertPos = Vec3(0.1f, 0, 0);      // projects to (408,400): 8px away
    h.nearestEdge   = -1;                     // no edge candidate this case

    auto wide = resolveHoverTarget(h, vp, 12.0f);     // 8 <= 12
    assert(wide.kind == HoverTargetKind.Vertex, "8px within a 12px radius must snap to Vertex");
    assert(wide.vert == 3);

    auto narrow = resolveHoverTarget(h, vp, 4.0f);    // 8 > 4
    assert(narrow.kind == HoverTargetKind.Face, "8px outside a 4px radius must fall through to Face");
}

unittest { // resolveHoverTarget — edge wins when the vertex candidate is far
           // but the edge segment passes through the hit's projected pixel
           // (vert offset (2,0,0) -> 160px away; edge endpoints (0,+-0.1,0)
           // -> a vertical segment straddling (400,400) exactly, 0px).
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit         = true;
    h.point       = Vec3(0, 0, 0);
    h.nearestVert = 1;
    h.nearestVertPos = Vec3(2.0f, 0, 0);      // 160px away — outside any sane radius
    h.nearestEdge = 5;
    h.nearestEdgeA = Vec3(0,  0.1f, 0);       // projects to (400, 392)
    h.nearestEdgeB = Vec3(0, -0.1f, 0);       // projects to (400, 408)

    auto t = resolveHoverTarget(h, vp, kTopoPenSnapPx);
    assert(t.kind == HoverTargetKind.Edge, "vertex far / edge through the hit pixel must resolve to Edge");
    assert(t.edge == 5);
}

unittest { // resolveHoverTarget — neither candidate in range -> Face
           // (vert offset (2,0,0) -> 160px; edge same offset -> also far)
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit         = true;
    h.point       = Vec3(0, 0, 0);
    h.nearestVert = 0;
    h.nearestVertPos = Vec3(2.0f, 0, 0);
    h.nearestEdge = 0;
    h.nearestEdgeA = Vec3(2.0f,  0.1f, 0);
    h.nearestEdgeB = Vec3(2.0f, -0.1f, 0);

    auto t = resolveHoverTarget(h, vp, kTopoPenSnapPx);
    assert(t.kind == HoverTargetKind.Face, "no candidate within the default radius must resolve to Face");
    assert(t.vert == -1 && t.edge == -1);
}

unittest { // resolveHoverTarget — threshold boundary, independently computed:
           // a 0.15-world-unit offset at S=80px/unit projects to EXACTLY
           // 12.0px (0.15*80=12), matching kTopoPenSnapPx exactly. The
           // comparison is `<=`, so thPx==12.0 must snap (boundary
           // inclusive) and thPx==11.999 (just under the exact distance)
           // must not.
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit           = true;
    h.point         = Vec3(0, 0, 0);
    h.nearestVert   = 7;
    h.nearestVertPos = Vec3(0.15f, 0, 0);     // exactly 12.0px from the hit
    h.nearestEdge   = -1;

    auto atBoundary = resolveHoverTarget(h, vp, 12.0f);
    assert(atBoundary.kind == HoverTargetKind.Vertex,
        "distance == thPx must snap (inclusive boundary)");

    auto justUnder = resolveHoverTarget(h, vp, 11.999f);
    assert(justUnder.kind == HoverTargetKind.Face,
        "distance just over thPx must NOT snap");
}
