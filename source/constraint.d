module constraint;

import std.math : sqrt;

import math : Vec3, Viewport, dot, cross;
import mesh : Mesh;
import toolpipe.packets : ConstrainPacket, ConstrainGeom;

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
// `screen` and `vector` modes are capture-gated: they are accepted attrs
// that round-trip cleanly, but `constrainPoint` returns `movingPos`
// unchanged for those modes until Stage-0 captures resolve their direction.
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
// Finds the nearest forward hit across all source faces. Backs
// `vector`/`screen` modes (both capture-gated in Stage 4 — this function
// exists for completeness and Stage-5 wiring). Returns false when no
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
// constrainPoint
//
// Top-level dispatch called from xfrm_transform.d::applyTRS for each
// moved vertex's final position. Returns `movingPos` unchanged when:
//   * cfg.enabled == false,
//   * cfg.geom == Off,
//   * no background sources are present,
//   * the mode is screen/vector (capture-gated no-op in Stage 4).
//
// Parameters:
//   movingPos   — the vertex's final world-space position after applyFold.
//   motionDelta — overall translation delta (unused by `point` mode;
//                 reserved for `vector` mode once Stage-0 resolves the dir).
//   vp          — active viewport (unused by `point` mode; reserved for
//                 `screen` mode).
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

        case ConstrainGeom.Vector:
        case ConstrainGeom.Screen:
            // Capture-gated: projection direction is ambiguous from the
            // spec headers alone. Returns identity until Stage-0 captures
            // resolve the direction. Wire round-trips as "vector"/"screen"
            // for headless attr testing.
            return movingPos;
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

unittest { // constrainPoint — vector/screen modes return identity (capture-gated)
    import mesh : Mesh;
    auto m = new Mesh();
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,0,1)];
    m.faces    = [[0u,1u,2u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*)m];
    Viewport vp;
    Vec3 p = Vec3(0.3f, 5.0f, 0.3f);
    ConstrainPacket cfgVec;
    cfgVec.enabled = true;
    cfgVec.geom    = ConstrainGeom.Vector;
    Vec3 rv = constrainPoint(p, Vec3(0,0,0), vp, srcs, cfgVec);
    import std.math : fabs;
    assert(fabs(rv.y - 5.0f) < 1e-5f, "vector mode: no-op");
    ConstrainPacket cfgScr;
    cfgScr.enabled = true;
    cfgScr.geom    = ConstrainGeom.Screen;
    Vec3 rs = constrainPoint(p, Vec3(0,0,0), vp, srcs, cfgScr);
    assert(fabs(rs.y - 5.0f) < 1e-5f, "screen mode: no-op");
}
