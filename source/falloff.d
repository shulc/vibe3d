module falloff;

import std.algorithm : max, min;
import std.math      : sqrt;

import math : Vec3, Viewport, projectToWindowFull, dot;
import toolpipe.packets : FalloffPacket, FalloffType, FalloffShape;

// ---------------------------------------------------------------------------
// Falloff math — Phase 7.5 of doc/phase7_plan.md / doc/falloff_plan.md.
//
// Pure functions; no GL / no ImGui. Tools that consume falloff (Move /
// Rotate / Scale) call `evaluateFalloff(packet, vertWorld, vertIdx, vp)`
// per moving vertex and multiply their per-vertex transform by the
// returned weight ∈ [0, 1].
//
// Returns 1.0 unconditionally when `!packet.enabled` so callers don't
// need to short-circuit — matches the snap.d / SnapPacket convention.
//
// 7.5b implements only `FalloffType.Linear`. Subsequent subphases
// extend the dispatch:
//   7.5c — Radial
//   7.5d — Screen
//   7.5e — Lasso
// ---------------------------------------------------------------------------

/// Per-vertex falloff weight at world position `pos` (which is the
/// vertex's CURRENT world coord; tools should pass the live position
/// so a multi-frame drag sees the falloff move with the vertex).
///
/// `vertIdx` is reserved for future types that key on the vertex index
/// (Element, Vertex Map). `vp` provides the projection for screen-
/// space types.
float evaluateFalloff(const ref FalloffPacket cfg,
                      Vec3 pos,
                      int  vertIdx,
                      const ref Viewport vp)
{
    if (!cfg.enabled) return 1.0f;

    final switch (cfg.type) {
        case FalloffType.None:
            return 1.0f;
        case FalloffType.Linear:
            return linearWeight(cfg, pos);
        case FalloffType.Radial:
            return radialWeight(cfg, pos);
        case FalloffType.Screen:
        case FalloffType.Lasso:
            // Land in 7.5d / 7.5e. Until then, pretend the falloff is
            // full-influence everywhere so type-switch probes (e.g.
            // status-bar pulldown) don't make the selection vanish.
            return 1.0f;
    }
}

/// Linear falloff: weight is 1.0 at `start`, 0.0 at `end`, attenuated
/// across the line segment by `shape`. Past either endpoint along the
/// line direction the weight saturates (1.0 before start, 0.0 after
/// end). Off-line distance is ignored — Linear falloff in MODO is
/// "infinite plane-style", attenuating only along the line direction.
private float linearWeight(const ref FalloffPacket cfg, Vec3 pos) {
    Vec3  axis = cfg.end - cfg.start;
    float ax2  = dot(axis, axis);
    if (ax2 < 1e-12f) return 1.0f;   // degenerate line — full influence
    Vec3  rel  = pos - cfg.start;
    float t    = dot(rel, axis) / ax2;
    if (t <= 0.0f) return 1.0f;
    if (t >= 1.0f) return 0.0f;
    return applyShape(t, cfg.shape, cfg.in_, cfg.out_);
}

/// Radial (ellipsoid) falloff: weight is 1.0 at `center`, 0.0 on or
/// outside the ellipsoid surface defined by `center ± size` per axis,
/// attenuated across the volume by `shape`. `size` components ≤ 0
/// degenerate that axis to "no extent" — the corresponding factor is
/// dropped from the distance (so a flat `size = (1, 0, 1)` ellipsoid
/// becomes a 2D disc on the XZ plane that ignores Y).
private float radialWeight(const ref FalloffPacket cfg, Vec3 pos) {
    Vec3 d = pos - cfg.center;
    float sum = 0.0f;
    bool any = false;
    if (cfg.size.x > 1e-9f) {
        float u = d.x / cfg.size.x;
        sum += u * u;
        any = true;
    }
    if (cfg.size.y > 1e-9f) {
        float u = d.y / cfg.size.y;
        sum += u * u;
        any = true;
    }
    if (cfg.size.z > 1e-9f) {
        float u = d.z / cfg.size.z;
        sum += u * u;
        any = true;
    }
    if (!any) return 1.0f;       // degenerate ellipsoid — full influence everywhere
    float t = sqrt(sum);
    if (t <= 0.0f) return 1.0f;
    if (t >= 1.0f) return 0.0f;
    return applyShape(t, cfg.shape, cfg.in_, cfg.out_);
}

/// Map a normalised distance `t ∈ [0, 1]` (0 = full influence, 1 = no
/// influence) to a weight `w ∈ [0, 1]` per the shape preset:
///
///   Linear  → 1 - t                  even attenuation
///   EaseIn  → 1 - t²                 stronger near full-influence
///   EaseOut → (1 - t)²               stronger near zero-influence
///   Smooth  → 1 - smoothstep(t)      S-curve (default)
///   Custom  → cubic Hermite interp from (0,1) to (1,0) with
///             tangents -in_ at t=0 and -out_ at t=1
float applyShape(float t, FalloffShape shape, float in_, float out_) {
    if (t <= 0.0f) return 1.0f;
    if (t >= 1.0f) return 0.0f;
    final switch (shape) {
        case FalloffShape.Linear:
            return 1.0f - t;
        case FalloffShape.EaseIn:
            return 1.0f - t * t;
        case FalloffShape.EaseOut: {
            float u = 1.0f - t;
            return u * u;
        }
        case FalloffShape.Smooth: {
            // smoothstep(t) = 3t² - 2t³; we want the falling
            // complement so the curve starts at 1 and ends at 0.
            float s = t * t * (3.0f - 2.0f * t);
            return 1.0f - s;
        }
        case FalloffShape.Custom: {
            // Cubic Hermite from (t=0, w=1) to (t=1, w=0). Tangents:
            //   m0 = -in_   (negative because the curve is descending)
            //   m1 = -out_
            // w(t) = h00*1 + h10*m0 + h01*0 + h11*m1
            //      = h00 - in_*h10 - out_*h11
            float t2 = t * t;
            float t3 = t2 * t;
            float h00 = 2.0f * t3 - 3.0f * t2 + 1.0f;
            float h10 = t3 - 2.0f * t2 + t;
            float h11 = t3 - t2;
            float w = h00 - in_ * h10 - out_ * h11;
            // Clamp — extreme tangents can overshoot [0, 1].
            if (w < 0.0f) w = 0.0f;
            if (w > 1.0f) w = 1.0f;
            return w;
        }
    }
}

unittest { // applyShape endpoints + linear midpoint
    import std.math : isClose;
    assert(isClose(applyShape(0.0f, FalloffShape.Linear,  0.5f, 0.5f), 1.0f));
    assert(isClose(applyShape(1.0f, FalloffShape.Linear,  0.5f, 0.5f), 0.0f));
    assert(isClose(applyShape(0.5f, FalloffShape.Linear,  0.5f, 0.5f), 0.5f));
    assert(isClose(applyShape(0.5f, FalloffShape.EaseIn,  0.5f, 0.5f), 0.75f));
    assert(isClose(applyShape(0.5f, FalloffShape.EaseOut, 0.5f, 0.5f), 0.25f));
    assert(isClose(applyShape(0.5f, FalloffShape.Smooth,  0.5f, 0.5f), 0.5f));
}

unittest { // linear falloff: vert at start = 1, at end = 0
    import std.math : isClose;
    FalloffPacket p;
    p.enabled = true;
    p.type    = FalloffType.Linear;
    p.shape   = FalloffShape.Linear;
    p.start   = Vec3(0, 0, 0);
    p.end     = Vec3(0, 1, 0);
    Viewport vp;
    assert(isClose(evaluateFalloff(p, Vec3(0, 0,    0), 0, vp), 1.0f));
    assert(isClose(evaluateFalloff(p, Vec3(0, 1,    0), 0, vp), 0.0f));
    assert(isClose(evaluateFalloff(p, Vec3(0, 0.25f, 0), 0, vp), 0.75f));
    assert(isClose(evaluateFalloff(p, Vec3(0, 0.75f, 0), 0, vp), 0.25f));
    // Past start, full influence; past end, none.
    assert(isClose(evaluateFalloff(p, Vec3(0, -2,   0), 0, vp), 1.0f));
    assert(isClose(evaluateFalloff(p, Vec3(0,  3,   0), 0, vp), 0.0f));
    // Off-axis distance ignored — projects onto the line.
    assert(isClose(evaluateFalloff(p, Vec3(5, 0.5f, 0), 0, vp), 0.5f));
}

unittest { // disabled packet returns 1.0 regardless of type
    import std.math : isClose;
    FalloffPacket p;
    p.enabled = false;
    p.type    = FalloffType.Linear;
    Viewport vp;
    assert(isClose(evaluateFalloff(p, Vec3(0, 1, 0), 0, vp), 1.0f));
}

unittest { // radial falloff: center = 1, surface = 0, outside = 0
    import std.math : isClose;
    FalloffPacket p;
    p.enabled = true;
    p.type    = FalloffType.Radial;
    p.shape   = FalloffShape.Linear;
    p.center  = Vec3(0, 0, 0);
    p.size    = Vec3(1, 1, 1);
    Viewport vp;
    assert(isClose(evaluateFalloff(p, Vec3(0,    0, 0), 0, vp), 1.0f));
    assert(isClose(evaluateFalloff(p, Vec3(1,    0, 0), 0, vp), 0.0f));
    assert(isClose(evaluateFalloff(p, Vec3(0.5f, 0, 0), 0, vp), 0.5f));
    // Outside the unit sphere → 0.
    assert(isClose(evaluateFalloff(p, Vec3(2,    0, 0), 0, vp), 0.0f));
    // Anisotropic ellipsoid: size=(2,1,1), point at x=1.
    p.size = Vec3(2, 1, 1);
    assert(isClose(evaluateFalloff(p, Vec3(1, 0, 0), 0, vp), 0.5f));
    assert(isClose(evaluateFalloff(p, Vec3(0, 1, 0), 0, vp), 0.0f));
}
