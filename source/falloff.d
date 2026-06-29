module falloff;

import std.algorithm : max, min;
import std.json;
import std.math      : sqrt;

import math : Vec3, Viewport, projectToWindowFull, dot, cross,
              pointInPolygon2D, closestOnSegment2DSquared;
import toolpipe.packets : FalloffPacket, FalloffType, FalloffShape, FalloffMix,
                          ElementConnect;

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
            return screenWeight(cfg, pos, vp);
        case FalloffType.Lasso:
            return lassoWeight(cfg, pos, vp);
        case FalloffType.Cylinder:
            return cylinderWeight(cfg, pos);
        case FalloffType.Element:
            return elementWeight(cfg, pos, vertIdx);
        case FalloffType.Selection:
            return selectionWeight(cfg, vertIdx);
        case FalloffType.Composite:
            return compositeWeight(cfg, pos, vertIdx, vp);
        case FalloffType.VertexMap:
            return vertexMapWeight(cfg, vertIdx);
    }
}

/// Combine the Mix-Mode of two weights. `a` is the running accumulator,
/// `b` the next contributor's clamped weight. The first contributor's
/// `mix` is never consulted (it seeds `a`); only contributors i≥1 reach
/// here. Results are NOT clamped per-step — Add/Subtract can leave [0,1]
/// mid-accumulation and `compositeWeight` clamps once at the very end
/// (so e.g. (0.6 + 0.6) then *0.5 reads the true 1.2 sum, not a clamped
/// 1.0). Multiply/Max/Min already stay in-range for in-range inputs.
float applyMix(FalloffMix mix, float a, float b) {
    final switch (mix) {
        case FalloffMix.Multiply: return a * b;
        case FalloffMix.Add:      return a + b;
        case FalloffMix.Subtract: return a - b;
        case FalloffMix.Max:      return max(a, b);
        case FalloffMix.Min:      return min(a, b);
    }
}

/// Composite falloff: the multi-falloff combiner. Each contributor is a
/// stand-alone sub-packet (never itself Composite — the WGHT combiner
/// flattens on build). The first contributor SEEDS the accumulator with
/// its clamped weight; every later contributor folds its clamped weight
/// in via ITS OWN `mix`. The final accumulator is clamped to [0, 1]
/// (Add/Subtract can overshoot the range). An empty contributor set
/// degenerates to full influence (1.0) — matching the "no constraint"
/// contract every other falloff uses for its degenerate case.
private float compositeWeight(const ref FalloffPacket cfg,
                              Vec3 pos, int vertIdx, const ref Viewport vp)
{
    if (cfg.contributors.length == 0) return 1.0f;
    float accum = clamp01(evaluateFalloff(cfg.contributors[0], pos, vertIdx, vp));
    foreach (i; 1 .. cfg.contributors.length) {
        float w = clamp01(evaluateFalloff(cfg.contributors[i], pos, vertIdx, vp));
        accum = applyMix(cfg.contributors[i].mix, accum, w);
    }
    return clamp01(accum);
}

private float clamp01(float v) {
    if (v < 0.0f) return 0.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}

/// Selection falloff (D.7) — `falloff.selection`. The
/// per-vert BFS over `mesh.edges` happens inside FalloffStage.evaluate;
/// it bakes the weight array onto `cfg.selectionWeights` and we just
/// look up `vertIdx` here. An empty / undersized array degenerates to
/// 1.0 ("no constraint" — matches the empty-selection contract every
/// other falloff uses).
private float selectionWeight(const ref FalloffPacket cfg, int vertIdx) {
    if (vertIdx < 0) return 1.0f;
    auto arr = cfg.selectionWeights;
    if (cast(size_t)vertIdx >= arr.length) return 1.0f;
    return arr[cast(size_t)vertIdx];
}

/// VertexMap falloff: looks up the pre-baked `vertexMapWeights` slice at
/// `vertIdx`. Values are clamped to [0, 1] here (the buffer stores raw map
/// data). An empty / undersized / negative-index case degenerates to 1.0
/// (full influence — same degenerate contract as selectionWeight).
private float vertexMapWeight(const ref FalloffPacket cfg, int vertIdx) {
    if (vertIdx < 0) return 1.0f;
    auto arr = cfg.vertexMapWeights;
    if (cast(size_t)vertIdx >= arr.length) return 1.0f;
    return clamp01(arr[cast(size_t)vertIdx]);
}

/// Linear falloff: weight is 1.0 at `start`, 0.0 at `end`, attenuated
/// across the line segment by `shape`. Past either endpoint along the
/// line direction the weight saturates (1.0 before start, 0.0 after
/// end). Off-line distance is ignored — Linear falloff is
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

/// Cylinder falloff: same as Radial but with one axis collapsed —
/// the weight depends only on the perpendicular distance from the
/// `center` point along the cylinder axis. Used by xfrm.vortex (a
/// twist that rotates uniformly along its axis but attenuates with
/// radial distance from it). Falls back to Radial behaviour for a
/// degenerate axis (zero-length); cylinder size is taken from the
/// bigger of the two perpendicular `size` components (most setups
/// have an isotropic radial cross-section).
private float cylinderWeight(const ref FalloffPacket cfg, Vec3 pos) {
    Vec3 axis = cfg.normal;
    float al2 = dot(axis, axis);
    if (al2 < 1e-12f) return radialWeight(cfg, pos);  // degenerate → fall back
    Vec3 invAxis = axis * (1.0f / sqrt(al2));
    Vec3 d = pos - cfg.center;
    float along = dot(d, invAxis);
    Vec3 perp = d - invAxis * along;
    // Cylinder radius from `size`: the two non-aligned axes' size
    // components average to the radius in the simple isotropic case.
    // For now use the max of size.x/y/z (the cross-section is a disc
    // around the axis; a more sophisticated implementation could
    // pick the two non-axis components by axis index).
    float sx = cfg.size.x, sy = cfg.size.y, sz = cfg.size.z;
    float r  = sx;
    if (sy > r) r = sy;
    if (sz > r) r = sz;
    if (r <= 1e-9f) return 1.0f;
    float plen = sqrt(dot(perp, perp));
    float t = plen / r;
    if (t <= 0.0f) return 1.0f;
    if (t >= 1.0f) return 0.0f;
    return applyShape(t, cfg.shape, cfg.in_, cfg.out_);
}

/// Element falloff: spherical attenuation around `pickedCenter`,
/// radius `pickedRadius`. weight = 1 at the centre, 0 at the sphere
/// boundary, shape-mapped in between. This is `falloff.element`
/// (the centre is normally the centroid of the user-clicked
/// component; `pickedRadius` is the `dist`/Range attr).
///
/// Connected-Elements gate (`cfg.connect`):
///   * Ignore          → no gate; pure geometric-distance falloff.
///   * UseConnectivity → verts outside the picked component (per
///                       `connectMask`) get weight 0; verts inside still
///                       attenuate by distance.
///   * Rigid           → verts inside the component get weight 1 (rigid,
///                       no attenuation); verts outside get 0.
///   * EdgeLoops       → anchorRing is the ordered quad edge-loop ring;
///                       non-ring verts attenuate by distance to the
///                       closed loop POLYLINE (no component zeroing gate).
/// With an empty `connectMask` (no anchor / Ignore) the gate is a no-op
/// and the unrestricted sphere applies.
private float elementWeight(const ref FalloffPacket cfg, Vec3 pos, int vi) {
    // Anchor ring (click-picked element's vert ring) short-circuits
    // to full weight regardless of the sphere math — drag the picked
    // element as a rigid unit with the cursor. Without this, clicks
    // on a typical face produce no motion because the corners sit at
    // distance > sphere radius from the centroid (e.g. cube face:
    // √2·0.5 ≈ 0.707 vs autoSized dist=0.5). `falloff.element`
    // does the same internally — see doc/unified_transform_plan.md
    // commit notes for the analysis. Checked BEFORE connectMask:
    // picked verts are by definition in the same component.
    if (cfg.anchorRing.length > 0 && vi >= 0) {
        foreach (av; cfg.anchorRing)
            if (cast(uint)vi == av) return 1.0f;
    }
    // Connected-Elements gate. `Ignore` skips the gate entirely (pure
    // geometric-distance falloff). The other modes consult `connectMask`
    // (BFS component of the picked element); an empty mask (no anchor /
    // headless without a ring) degrades to "unrestricted" so non-pick
    // scripted use still works. EdgeLoops is a documented stub that
    // currently behaves as UseConnectivity.
    // EdgeLoops is no longer a UseConnectivity stub: its anchorRing is the
    // ORDERED quad edge-loop ring (resolved upstream in FalloffStage /
    // transform.d), and non-ring verts attenuate by distance to the loop
    // POLYLINE (see distPointClosedPolyline below). So EdgeLoops must NOT
    // run the component zeroing gate — every vert attenuates by polyline
    // distance, with the ring verts pinned to weight 1 above.
    if (cfg.connect != ElementConnect.Ignore
     && cfg.connect != ElementConnect.EdgeLoops
     && cfg.connectMask.length > 0) {
        bool inComponent = vi >= 0
                        && vi < cast(int)cfg.connectMask.length
                        && cfg.connectMask[vi];
        if (!inComponent) return 0.0f;
        // Rigid Connections: the whole connected component moves rigidly
        // the full distance — no distance attenuation inside it.
        if (cfg.connect == ElementConnect.Rigid) return 1.0f;
        // UseConnectivity / EdgeLoops(stub): in-component verts fall
        // through to the geometric-distance attenuation below.
    }
    // pickedCenter drives the falloff sphere; pickedRadius (the
    // `dist` attr) is the radius. Non-anchor verts attenuate from
    // weight = 1 at the centre to 0 at the boundary, shape-mapped.
    if (cfg.pickedRadius <= 1e-9f) return 1.0f;  // degenerate radius → full
    // Distance is measured to the picked element's GEOMETRY (defined
    // by `anchorPos`, the world positions of the picked verts), not to
    // the single centroid `pickedCenter`. A vertex pick (1 anchor) ==
    // the point distance, so it stays bit-identical to the old centroid
    // path; an edge / polygon pick attenuates by distance to the
    // SEGMENT / FACE, matching the reference editor.
    float r;
    if (cfg.anchorPos.length == 0) {
        // No picked geometry (scripted / non-pick use) → fall back to
        // the centroid-point distance, preserving the prior behaviour.
        Vec3 d = pos - cfg.pickedCenter;
        r = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
    } else if (cfg.connect == ElementConnect.EdgeLoops && cfg.anchorPos.length >= 2) {
        // Edge Loops: the anchor positions are the ORDERED ring of the
        // detected quad edge-loop (closed band). Attenuate by distance to
        // the closed POLYLINE through the ring — NOT the filled-polygon
        // distance (distPointPolygon would treat the ring's interior as
        // distance-0, which is wrong for a loop band). The ring verts are
        // already weight-1 via the anchorRing short-circuit above.
        r = distPointClosedPolyline(pos, cfg.anchorPos);
    } else if (cfg.anchorPos.length == 1) {
        Vec3 d = pos - cfg.anchorPos[0];
        r = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
    } else if (cfg.anchorPos.length == 2) {
        r = distPointSegment(pos, cfg.anchorPos[0], cfg.anchorPos[1]);
    } else {
        r = distPointPolygon(pos, cfg.anchorPos);
    }
    float t = r / cfg.pickedRadius;
    if (t <= 0.0f) return 1.0f;
    if (t >= 1.0f) return 0.0f;
    return applyShape(t, cfg.shape, cfg.in_, cfg.out_);
}

/// Distance from `p` to the segment [a, b] (clamped orthogonal
/// projection). Degenerate (a == b) reduces to the point distance.
private float distPointSegment(Vec3 p, Vec3 a, Vec3 b) {
    Vec3  ab  = b - a;
    float ab2 = dot(ab, ab);
    Vec3  ap  = p - a;
    float t   = (ab2 > 1e-12f) ? dot(ap, ab) / ab2 : 0.0f;
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    Vec3 d = ap - ab * t;
    return sqrt(dot(d, d));
}

/// Distance from `p` to the CLOSED polyline through `pts` (the minimum
/// distance to any segment pts[i] → pts[(i+1) % n]). Unlike
/// `distPointPolygon`, the polyline's interior is NOT distance-0 — this is
/// the loop-band distance used by Edge-Loops element falloff, where the
/// ring is a closed band of edges and points "inside" the band must still
/// attenuate by their distance to the nearest ring segment. A 1-point
/// input degenerates to the point distance; empty → +inf.
float distPointClosedPolyline(Vec3 p, const(Vec3)[] pts) {
    if (pts.length == 0) return float.infinity;
    if (pts.length == 1) {
        Vec3 d = p - pts[0];
        return sqrt(dot(d, d));
    }
    float best = float.infinity;
    foreach (i; 0 .. pts.length) {
        size_t j = (i + 1) % pts.length;
        float d = distPointSegment(p, pts[i], pts[j]);
        if (d < best) best = d;
    }
    return best;
}

/// Distance from `p` to the (convex-ish) polygon whose vertices are
/// `poly` (length ≥ 3). The face plane normal comes from the first
/// three verts; `p` is projected onto that plane. If the projection
/// falls inside the polygon (point-in-polygon in the plane's 2D
/// basis) the perpendicular plane distance is returned, otherwise the
/// minimum distance to any edge segment. A degenerate (collinear)
/// triangle falls back to the edge-segment minimum so the result is
/// always well-defined.
private float distPointPolygon(Vec3 p, const(Vec3)[] poly) {
    // Plane normal from the first three verts.
    Vec3 n = cross(poly[1] - poly[0], poly[2] - poly[0]);
    float nlen = sqrt(dot(n, n));
    if (nlen > 1e-9f) {
        n = n * (1.0f / nlen);
        // Signed perpendicular distance + projection onto the plane.
        float sd   = dot(p - poly[0], n);
        Vec3  proj = p - n * sd;
        // Build an in-plane 2D basis (u, v) to test containment.
        Vec3 u = poly[1] - poly[0];
        float ulen = sqrt(dot(u, u));
        if (ulen > 1e-9f) {
            u = u * (1.0f / ulen);
            Vec3 v = cross(n, u);   // already unit (n, u orthonormal)
            // Project polygon + the candidate point to (u, v) coords.
            float px = dot(proj - poly[0], u);
            float py = dot(proj - poly[0], v);
            bool inside = false;
            size_t j = poly.length - 1;
            foreach (i; 0 .. poly.length) {
                float xi = dot(poly[i] - poly[0], u);
                float yi = dot(poly[i] - poly[0], v);
                float xj = dot(poly[j] - poly[0], u);
                float yj = dot(poly[j] - poly[0], v);
                if (((yi > py) != (yj > py))
                 && (px < (xj - xi) * (py - yi) / (yj - yi) + xi))
                    inside = !inside;
                j = i;
            }
            if (inside) {
                float ad = sd < 0.0f ? -sd : sd;
                return ad;
            }
        }
    }
    // Outside the polygon (or degenerate plane) → min edge-segment dist.
    float best = float.infinity;
    size_t k = poly.length - 1;
    foreach (i; 0 .. poly.length) {
        float d = distPointSegment(p, poly[k], poly[i]);
        if (d < best) best = d;
        k = i;
    }
    return best;
}

/// Screen falloff: window-pixel disc at (screenCx, screenCy) radius
/// `screenSize`, projected as an infinite cylinder along the camera-
/// back axis. Weight = 1.0 at the disc centre, 0.0 at radius. When
/// `transparent == false`, verts behind the camera (projection failed)
/// get weight = 0 — facing-only semantics.
///
/// The radial attenuation is a FIXED LINEAR ramp (w = 1 - t), NOT the
/// `shape` preset: the reference editor's screen falloff has no shape
/// control — its disc profile is a fixed linear curve, confirmed by a
/// headless per-vertex weight capture (two independent drags both fit
/// 1 - t at RMS ~0.02; smooth/easeIn fit far worse). So screen ignores
/// `cfg.shape` and the Shape Preset row is hidden for the screen type
/// (FalloffStage.params()).
private float screenWeight(const ref FalloffPacket cfg, Vec3 pos,
                           const ref Viewport vp)
{
    float sx, sy, ndcZ;
    if (!projectToWindowFull(pos, vp, sx, sy, ndcZ))
        return cfg.transparent ? 1.0f : 0.0f;
    float dx = sx - cfg.screenCx;
    float dy = sy - cfg.screenCy;
    float dist = sqrt(dx * dx + dy * dy);
    if (cfg.screenSize < 1e-6f) return 1.0f;     // degenerate disc
    float t = dist / cfg.screenSize;
    if (t <= 0.0f) return 1.0f;
    if (t >= 1.0f) return 0.0f;
    return applyShape(t, FalloffShape.Linear, cfg.in_, cfg.out_);
}

/// Lasso falloff: project the vert to window pixels; weight = 1.0 if
/// the projected point is inside the lasso polygon; otherwise the
/// pixel distance to the nearest polygon edge is mapped to weight via
/// `softBorderPx`. softBorderPx == 0 ⇒ binary inside/outside (1 / 0).
///
/// 7.5e ships only the Freehand style (polygon points in lassoPolyX/Y).
/// Rectangle / Circle / Ellipse styles fall through to "polygon
/// vertices only" — typical caller draws the rect/circle into the
/// polygon arrays during the lasso input gesture. Verts behind the
/// camera get weight = 0 unless `transparent` is set, mirroring the
/// Screen falloff convention.
private float lassoWeight(const ref FalloffPacket cfg, Vec3 pos,
                          const ref Viewport vp)
{
    if (cfg.lassoPolyX.length < 3
     || cfg.lassoPolyX.length != cfg.lassoPolyY.length)
        return 1.0f;     // unset / malformed lasso → no falloff
    float sx, sy, ndcZ;
    if (!projectToWindowFull(pos, vp, sx, sy, ndcZ))
        return cfg.transparent ? 1.0f : 0.0f;

    bool inside = pointInPolygon2D(sx, sy,
                                   cast(float[])cfg.lassoPolyX,
                                   cast(float[])cfg.lassoPolyY);
    if (inside) return 1.0f;
    if (cfg.softBorderPx <= 1e-6f) return 0.0f;

    // Closest screen-pixel distance to any polygon edge segment.
    float bestD2 = float.infinity;
    auto xs = cfg.lassoPolyX;
    auto ys = cfg.lassoPolyY;
    foreach (i; 0 .. xs.length) {
        size_t j = (i + 1) % xs.length;
        float t;
        float d2 = closestOnSegment2DSquared(sx, sy,
            xs[i], ys[i], xs[j], ys[j], t);
        if (d2 < bestD2) bestD2 = d2;
    }
    float d = sqrt(bestD2);
    float tt = d / cfg.softBorderPx;
    if (tt <= 0.0f) return 1.0f;
    if (tt >= 1.0f) return 0.0f;
    return applyShape(tt, cfg.shape, cfg.in_, cfg.out_);
}

/// Map a normalised distance `t ∈ [0, 1]` (0 = full influence, 1 = no
/// influence) to a weight `w ∈ [0, 1]` per the shape preset:
///
///   Linear  → 1 - t                  even attenuation
///   EaseIn  → 1 - t²                 stronger near full-influence
///   EaseOut → (1 - t)²               stronger near zero-influence
///   Smooth  → 1 - smoothstep(t)      S-curve (default)
///   Custom  → cubic Bezier from (0,1) to (1,0) with control points
///             P1 = (1/3, (2-out_)/3), P2 = (2/3, (1+in_)/3) — at
///             in_=out_=0 both control points lie on the linear
///             baseline so the curve degenerates to y=1-t. This is the
///             `falloff.linear` Custom shape.
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
            // Cubic Bezier from (0,1) to (1,0), control y-coords
            // (2-out_)/3 (P1) and (1+in_)/3 (P2). At in_=out_=0 both
            // control points sit on y=1-t and the curve collapses to
            // the linear baseline. Compact algebraic form:
            //   w(t) = (1-t) + in_·t²·(1-t) - out_·t·(1-t)²
            // in_  raises the curve in the second half (P2 above line)
            // out_ lowers the curve in the first half (P1 below line)
            float u = 1.0f - t;
            float w = u + in_ * t * t * u - out_ * t * u * u;
            // Clamp — extreme p0/p1 can still drive w outside [0, 1]
            // (the Bezier hull doesn't bound y when control points
            // stray above 1 or below 0).
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
    // Custom Bezier: at in=out=0 collapses to linear (P1, P2 sit on the
    // baseline).
    assert(isClose(applyShape(0.5f, FalloffShape.Custom, 0.0f, 0.0f), 0.5f));
    assert(isClose(applyShape(0.2f, FalloffShape.Custom, 0.0f, 0.0f), 0.8f));
    // in=1, out=0 lifts P2 → curve sits above linear (more weight in
    // the second half). t=0.5: w = 0.5 + 1·0.25·0.5 = 0.625.
    assert(isClose(applyShape(0.5f, FalloffShape.Custom, 1.0f, 0.0f), 0.625f));
    // in=0, out=1 lowers P1 → curve sits below linear. t=0.5:
    // w = 0.5 - 0.25·0.5 = 0.375.
    assert(isClose(applyShape(0.5f, FalloffShape.Custom, 0.0f, 1.0f), 0.375f));
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

unittest { // cylinder falloff: radial-perpendicular linear profile (axis-responsiveness)
    // Locks the cylinder kernel: weight decays linearly with radial distance
    // from the cylinder axis (measured perpendicular to it), reaching 0 at
    // r = max(size). Position along the axis is ignored entirely.
    //
    // The +Z sub-case proves axis-responsiveness: the same displacement that
    // produces w=0.3333 on the X component under +Y axis produces the same
    // weight on the Y component under +Z axis, and z-displacement (along the
    // axis) is ignored. This guards against any future "make it 1-D /
    // fixed-axis" regression that forgets to use cfg.normal.
    //
    // Golden values are analytic: r=0.75, shape=Linear, w = clamp(1-plen/r,0,1)
    // where plen = hypot of the two perpendicular-to-axis components.
    import std.math : isClose, sqrt;
    enum float tol = 1e-4f;

    // --- axis +Y: perpendicular plane is XZ ---
    FalloffPacket p;
    p.enabled = true;
    p.type    = FalloffType.Cylinder;
    p.shape   = FalloffShape.Linear;
    p.center  = Vec3(0, 0, 0);
    p.size    = Vec3(0.75f, 0.75f, 0.75f);
    p.normal  = Vec3(0, 1, 0);
    Viewport vp;

    // On-axis: plen=0 → w=1.0
    assert(isClose(evaluateFalloff(p, Vec3(0, 0.5f, 0), 0, vp), 1.0f, tol));
    // plen=0.5 → t=0.5/0.75=0.6667 → w=0.3333
    assert(isClose(evaluateFalloff(p, Vec3(0.5f, 0.5f, 0), 0, vp), 1.0f/3.0f, tol));
    // Same radius from a different XZ direction (plen=0.5 via Z) → same weight
    assert(isClose(evaluateFalloff(p, Vec3(0, 0.5f, 0.5f), 0, vp), 1.0f/3.0f, tol));
    // Diagonal: plen=sqrt(0.5)≈0.7071 → t≈0.9428 → w≈0.05719
    assert(isClose(evaluateFalloff(p, Vec3(0.5f, 0.5f, 0.5f), 0, vp),
                   1.0f - sqrt(0.5f)/0.75f, tol));
    // Outside (plen=0.8 > r=0.75) → w=0.0
    assert(isClose(evaluateFalloff(p, Vec3(0.8f, 0, 0), 0, vp), 0.0f, tol));

    // --- axis +Z: perpendicular plane is XY; z-displacement is ignored ---
    p.normal = Vec3(0, 0, 1);
    // On-axis (large z, plen=0) → w=1.0 regardless of z value
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 5.0f), 0, vp), 1.0f, tol));
    // plen from X only → same 0.3333
    assert(isClose(evaluateFalloff(p, Vec3(0.5f, 0, 0), 0, vp), 1.0f/3.0f, tol));
    // plen from Y only → same 0.3333
    assert(isClose(evaluateFalloff(p, Vec3(0, 0.5f, 0), 0, vp), 1.0f/3.0f, tol));
}

unittest { // screen falloff: behind-camera handling
    import std.math : isClose;
    // Default Viewport has zero matrices; projectToWindowFull returns
    // false. Verifies the transparent / facing-only branch.
    FalloffPacket p;
    p.enabled    = true;
    p.type       = FalloffType.Screen;
    p.shape      = FalloffShape.Linear;
    p.screenCx   = 100;
    p.screenCy   = 100;
    p.screenSize = 50;
    Viewport vp;
    p.transparent = false;
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 0), 0, vp), 0.0f));
    p.transparent = true;
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 0), 0, vp), 1.0f));
}

unittest { // screen falloff: LINEAR profile (locks the curve; w = 1 - t)
    // Capture-verified against the reference engine: a Soft-Drag haul in an
    // ortho-top view on a flat grid yields a LINEAR screen attenuation
    // (RMS 0.003 vs 1-t; a Smooth curve would sit ~0.09 higher mid-ramp).
    // This guards screenWeight against silently switching shapes.
    //
    // Identity view+proj so world maps to the window predictably:
    //   projectToWindowFull → px = (x*0.5+0.5)*width.  With width=200 the
    //   origin lands at px=100 and a point at x=Δ lands at px=100+Δ*100
    //   (screen-distance Δ*100 from the disc centre).
    import std.math : isClose;
    Viewport vp;
    vp.view   = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    vp.proj   = vp.view;
    vp.width  = 200;
    vp.height = 200;
    FalloffPacket p;
    p.enabled    = true;
    p.type       = FalloffType.Screen;
    p.shape      = FalloffShape.Linear;
    p.screenCx   = 100;
    p.screenCy   = 100;
    p.screenSize = 100;        // screen-distance Δ*100 → t = Δ
    // t=0.25 → linear 0.75 (a Smooth profile would give ~0.844 — distinguishes it).
    assert(isClose(evaluateFalloff(p, Vec3(0.25f, 0, 0), 0, vp), 0.75f, 0.01f));
    // t=0.75 → linear 0.25 (Smooth → ~0.156).
    assert(isClose(evaluateFalloff(p, Vec3(0.75f, 0, 0), 0, vp), 0.25f, 0.01f));
    assert(isClose(evaluateFalloff(p, Vec3(0,    0, 0), 0, vp), 1.0f));  // centre
    assert(isClose(evaluateFalloff(p, Vec3(1.5f, 0, 0), 0, vp), 0.0f));  // beyond the disc
}

unittest { // lasso: empty / unset polygon falls through to weight = 1
    import std.math : isClose;
    FalloffPacket p;
    p.enabled    = true;
    p.type       = FalloffType.Lasso;
    p.transparent = true;
    Viewport vp;
    // No polygon → no-op falloff (matches plan: "unset / malformed → 1").
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 0), 0, vp), 1.0f));
}

unittest { // lasso: inside→1, outside→0, soft-border ramp via applyShape
    // Identity view+proj (width=height=200): origin→(100,100); x=Δ→px=100+Δ*100.
    // Lasso = a screen-pixel square [50,150]². Inside→1, outside→0; with a
    // soft border the outside weight ramps in via the (verified) shape curve.
    import std.math : isClose;
    Viewport vp;
    vp.view   = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    vp.proj   = vp.view;
    vp.width  = 200;
    vp.height = 200;
    FalloffPacket p;
    p.enabled    = true;
    p.type       = FalloffType.Lasso;
    p.shape      = FalloffShape.Linear;
    p.lassoPolyX = [50.0f, 150.0f, 150.0f,  50.0f];
    p.lassoPolyY = [50.0f,  50.0f, 150.0f, 150.0f];
    // origin → (100,100) inside → 1.
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 0), 0, vp), 1.0f));
    // x=0.6 → (160,100), 10px past the right edge; hard border → 0.
    p.softBorderPx = 0.0f;
    assert(isClose(evaluateFalloff(p, Vec3(0.6f, 0, 0), 0, vp), 0.0f));
    // same point with a 20px soft border → t = 10/20 = 0.5 → linear 0.5.
    p.softBorderPx = 20.0f;
    assert(isClose(evaluateFalloff(p, Vec3(0.6f, 0, 0), 0, vp), 0.5f, 0.02f));
}

unittest { // Selection (D.7): empty packet → all verts weight = 1
    import std.math : isClose;
    FalloffPacket p;
    p.enabled = true;
    p.type    = FalloffType.Selection;
    // selectionWeights left empty → "no constraint" path: every
    // vertIdx returns 1.0 regardless of position. Matches the
    // empty-selection-means-move-everything contract.
    Viewport vp;
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 0),    0, vp), 1.0f));
    assert(isClose(evaluateFalloff(p, Vec3(1, 2, 3),    7, vp), 1.0f));
}

unittest { // Selection (D.7): explicit weights array honored per-vert
    import std.math : isClose;
    FalloffPacket p;
    p.enabled = true;
    p.type    = FalloffType.Selection;
    // 4 verts: 2 selected (weight 1.0), 2 at decay positions.
    float[] w = [1.0f, 1.0f, 0.5f, 0.0f];
    p.selectionWeights = w;
    Viewport vp;
    assert(isClose(evaluateFalloff(p, Vec3.init, 0, vp), 1.0f));
    assert(isClose(evaluateFalloff(p, Vec3.init, 1, vp), 1.0f));
    assert(isClose(evaluateFalloff(p, Vec3.init, 2, vp), 0.5f));
    assert(isClose(evaluateFalloff(p, Vec3.init, 3, vp), 0.0f));
    // Out-of-range vertIdx degenerates to "no constraint" → 1.0.
    assert(isClose(evaluateFalloff(p, Vec3.init, 4,  vp), 1.0f));
    assert(isClose(evaluateFalloff(p, Vec3.init, -1, vp), 1.0f));
}

unittest { // Composite: empty contributor set → full influence
    import std.math : isClose;
    FalloffPacket p;
    p.enabled = true;
    p.type    = FalloffType.Composite;
    Viewport vp;
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 0), 0, vp), 1.0f));
}

unittest { // Composite math: Linear × Radial under each Mix Mode
    import std.math : isClose;
    Viewport vp;

    // Contributor A — Linear along +Y, weight 0.75 at y=0.25 (linear shape).
    FalloffPacket a;
    a.enabled = true;
    a.type    = FalloffType.Linear;
    a.shape   = FalloffShape.Linear;
    a.start   = Vec3(0, 0, 0);
    a.end     = Vec3(0, 1, 0);

    // Contributor B — Radial unit sphere (linear shape), weight 0.5 at
    // ellipsoid distance 0.5 from the center.
    FalloffPacket b;
    b.enabled = true;
    b.type    = FalloffType.Radial;
    b.shape   = FalloffShape.Linear;
    b.center  = Vec3(0, 0, 0);
    b.size    = Vec3(1, 1, 1);

    // Sample point: y=0.25 (A→0.75, Linear ignores off-line x) AND a radial
    // distance of 0.5 (B→0.5). Radial measures the full vector, so x is chosen
    // as √(0.5² − 0.25²) = √0.1875 to land the sphere distance exactly on 0.5.
    // Confirm the standalone weights first so the combine asserts rest on known wᵢ.
    Vec3 sample = Vec3(sqrt(0.1875f), 0.25f, 0);
    immutable float wA = evaluateFalloff(a, sample, 0, vp);  // 0.75
    immutable float wB = evaluateFalloff(b, sample, 0, vp);  // 0.5
    assert(isClose(wA, 0.75f));
    assert(isClose(wB, 0.5f));

    FalloffPacket comp;
    comp.enabled = true;
    comp.type    = FalloffType.Composite;

    // Helper: build a 2-contributor composite where B carries `m`.
    FalloffPacket build(FalloffMix m) {
        FalloffPacket c = comp;
        FalloffPacket bb = b;
        bb.mix = m;
        c.contributors = [a, bb];   // a seeds (its mix ignored)
        return c;
    }

    // evaluateFalloff takes `ref const` — bind each composite to a local.
    float evalMix(FalloffMix m) {
        auto c = build(m);
        return evaluateFalloff(c, sample, 0, vp);
    }
    // Multiply (default): 0.75 * 0.5 = 0.375
    assert(isClose(evalMix(FalloffMix.Multiply), 0.375f));
    // Add: 0.75 + 0.5 = 1.25 → clamp01 → 1.0
    assert(isClose(evalMix(FalloffMix.Add), 1.0f));
    // Subtract: 0.75 - 0.5 = 0.25
    assert(isClose(evalMix(FalloffMix.Subtract), 0.25f));
    // Max: max(0.75, 0.5) = 0.75
    assert(isClose(evalMix(FalloffMix.Max), 0.75f));
    // Min: min(0.75, 0.5) = 0.5
    assert(isClose(evalMix(FalloffMix.Min), 0.5f));
}

unittest { // Composite: single contributor == that contributor (byte-stable)
    import std.math : isClose;
    Viewport vp;
    FalloffPacket lin;
    lin.enabled = true;
    lin.type    = FalloffType.Linear;
    lin.shape   = FalloffShape.Linear;
    lin.start   = Vec3(0, 0, 0);
    lin.end     = Vec3(0, 1, 0);

    FalloffPacket comp;
    comp.enabled = true;
    comp.type    = FalloffType.Composite;
    comp.contributors = [lin];

    foreach (yi; 0 .. 5) {
        float y = yi * 0.25f;
        Vec3 pos = Vec3(0, y, 0);
        // Composite of one == the lone contributor, weight-for-weight.
        assert(isClose(evaluateFalloff(comp, pos, 0, vp),
                       evaluateFalloff(lin,  pos, 0, vp)));
    }
}

unittest { // Composite: three contributors fold left-to-right via per-elem mix
    import std.math : isClose;
    Viewport vp;
    // Three radial spheres of different sizes give three distinct weights
    // at one sample; we only need deterministic wᵢ to check the fold ORDER.
    FalloffPacket mk(float sz) {
        FalloffPacket p;
        p.enabled = true;
        p.type    = FalloffType.Radial;
        p.shape   = FalloffShape.Linear;
        p.center  = Vec3(0, 0, 0);
        p.size    = Vec3(sz, sz, sz);
        return p;
    }
    Vec3 sample = Vec3(0.5f, 0, 0);
    auto c0 = mk(1.0f);   // t=0.5 → 0.5
    auto c1 = mk(2.0f);   // t=0.25 → 0.75
    auto c2 = mk(4.0f);   // t=0.125 → 0.875
    assert(isClose(evaluateFalloff(c0, sample, 0, vp), 0.5f));
    assert(isClose(evaluateFalloff(c1, sample, 0, vp), 0.75f));
    assert(isClose(evaluateFalloff(c2, sample, 0, vp), 0.875f));

    // accum = 0.5; +0.75 = 1.25; *0.875 (no clamp mid-fold) = 1.09375;
    // final clamp01 → 1.0. Proves per-step is UNCLAMPED, final IS clamped.
    c1.mix = FalloffMix.Add;
    c2.mix = FalloffMix.Multiply;
    FalloffPacket comp;
    comp.enabled = true;
    comp.type    = FalloffType.Composite;
    comp.contributors = [c0, c1, c2];
    assert(isClose(evaluateFalloff(comp, sample, 0, vp), 1.0f));

    // Reorder so the product happens first: accum=0.5; *0.875=0.4375;
    // +0.75=1.1875 → clamp01 → 1.0. (Different intermediate, same clamp.)
    // Use a smaller seed to land inside [0,1] and prove order matters.
    auto d0 = mk(1.0f);          // 0.5
    auto d1 = mk(4.0f); d1.mix = FalloffMix.Multiply;  // 0.875
    auto d2 = mk(2.0f); d2.mix = FalloffMix.Subtract;  // 0.75
    // accum=0.5; *0.875=0.4375; -0.75=-0.3125 → clamp01 → 0.0
    FalloffPacket comp2;
    comp2.enabled = true;
    comp2.type    = FalloffType.Composite;
    comp2.contributors = [d0, d1, d2];
    assert(isClose(evaluateFalloff(comp2, sample, 0, vp), 0.0f));
}

// ---------------------------------------------------------------------------
// falloffPacketsEqual — field-by-field equality check used by
// CommandWrapperTool and the transform tools to detect live falloff
// changes (panel slider edits, type swap, endpoint drag) so the
// preview can re-apply on the next frame.
//
// Hoisted here in the operator-refactor cleanup so the same equality
// implementation is shared by all consumers. Two earlier copies
// (source/tools/transform.d:449 and source/tools/command_wrapper.d)
// had diverged: the wrapper-side copy was missing lassoStyle /
// softBorderPx / lassoPolyX / lassoPolyY checks, so Lasso falloff
// edits would not refresh the preview while a CommandWrapperTool
// was active.
// ---------------------------------------------------------------------------
bool falloffPacketsEqual(const ref FalloffPacket a, const ref FalloffPacket b) {
    if (a.enabled != b.enabled) return false;
    if (a.type    != b.type)    return false;
    if (a.shape   != b.shape)   return false;
    if (a.mix     != b.mix)     return false;
    if (a.in_     != b.in_)     return false;
    if (a.out_    != b.out_)    return false;
    if (a.start.x  != b.start.x  || a.start.y  != b.start.y  || a.start.z  != b.start.z)  return false;
    if (a.end.x    != b.end.x    || a.end.y    != b.end.y    || a.end.z    != b.end.z)    return false;
    if (a.center.x != b.center.x || a.center.y != b.center.y || a.center.z != b.center.z) return false;
    if (a.size.x   != b.size.x   || a.size.y   != b.size.y   || a.size.z   != b.size.z)   return false;
    if (a.screenCx     != b.screenCx)     return false;
    if (a.screenCy     != b.screenCy)     return false;
    if (a.screenSize   != b.screenSize)   return false;
    if (a.transparent  != b.transparent)  return false;
    if (a.lassoStyle   != b.lassoStyle)   return false;
    if (a.softBorderPx != b.softBorderPx) return false;
    if (a.lassoPolyX.length != b.lassoPolyX.length) return false;
    if (a.lassoPolyY.length != b.lassoPolyY.length) return false;
    foreach (i; 0 .. a.lassoPolyX.length)
        if (a.lassoPolyX[i] != b.lassoPolyX[i]) return false;
    foreach (i; 0 .. a.lassoPolyY.length)
        if (a.lassoPolyY[i] != b.lassoPolyY[i]) return false;
    // Composite contributors — refire correctness: a multi-falloff edit
    // (a contributor's config / mix changed, or one added/removed) must
    // be detected so the preview re-applies. Recurse field-wise; the
    // contributors are flat (never themselves Composite) so this bottoms
    // out in one level.
    if (a.contributors.length != b.contributors.length) return false;
    foreach (i; 0 .. a.contributors.length)
        if (!falloffPacketsEqual(a.contributors[i], b.contributors[i]))
            return false;
    return true;
}

// ---------------------------------------------------------------------------
// IFalloffAware — Phase 4 of doc/operator_refactor_plan.md. Marker
// interface that lets the /api/command dispatcher push a FalloffPacket
// into a Command without the cast-chain (MeshSmooth/MeshJitter/MeshQuantize).
// Any future convolve Command that wants HTTP-injected falloff just
// implements this interface — single cast at the dispatcher.
//
// Long-term plan: when Phase 6 cleanup removes Command.apply() and
// switches the dispatcher to Operator.evaluate(vts), this interface
// goes away — commands pull falloff from vts directly.
// ---------------------------------------------------------------------------
interface IFalloffAware {
    void setFalloff(FalloffPacket fp);
}

// ---------------------------------------------------------------------------
// JSON → FalloffPacket parser. Used by the HTTP /api/command dispatch to
// hand a falloff config to commands that opt in (mesh.smooth / mesh.jitter
// / mesh.quantize). Schema:
//
//   { "type": "linear" | "radial" | "cylinder",
//     "shape": "linear" | "easeIn" | "easeOut" | "smooth" | "custom",
//     "start": [x,y,z], "end": [x,y,z],          // linear
//     "center": [x,y,z], "size": [x,y,z],        // radial / cylinder
//     "axis": [x,y,z],                            // cylinder (defaults +Y)
//     "in": 0.5, "out": 0.5                       // custom shape tangents
//   }
//
// Element / Screen / Lasso / Selection falloff are not parsed here —
// those need viewport / pick state that's outside the HTTP envelope.
// ---------------------------------------------------------------------------
FalloffPacket parseFalloffJson(ref std.json.JSONValue j) {
    import std.json : JSONType;

    FalloffPacket fp;
    fp.enabled = true;
    fp.shape   = FalloffShape.Linear;

    string typeStr = "linear";
    if (auto pt = "type" in j.object) {
        if (pt.type == JSONType.string) typeStr = pt.str;
    }
    switch (typeStr) {
        case "none":     fp.type = FalloffType.None;     fp.enabled = false; break;
        case "linear":   fp.type = FalloffType.Linear;   break;
        case "radial":   fp.type = FalloffType.Radial;   break;
        case "cylinder": fp.type = FalloffType.Cylinder; break;
        case "screen":
        case "lasso":
            // These types require live viewport context (camera matrices
            // + window pixels). The /api/command path runs headlessly
            // and passes a default-initialised Viewport; using Screen
            // or Lasso falloff here would silently return wrong weights.
            // Use the toolpipe (`tool.pipe.attr falloff type screen ...`)
            // for those instead.
            throw new Exception(
                "falloff.type '" ~ typeStr ~ "' requires viewport context — "
                ~ "use the live toolpipe via tool.pipe.attr, not /api/command");
        default:
            throw new Exception(
                "falloff.type '" ~ typeStr ~ "' unsupported via HTTP");
    }

    if (auto ps = "shape" in j.object) {
        if (ps.type == JSONType.string) {
            switch (ps.str) {
                case "linear":  fp.shape = FalloffShape.Linear;  break;
                case "easeIn":  fp.shape = FalloffShape.EaseIn;  break;
                case "easeOut": fp.shape = FalloffShape.EaseOut; break;
                case "smooth":  fp.shape = FalloffShape.Smooth;  break;
                case "custom":  fp.shape = FalloffShape.Custom;  break;
                default:
                    throw new Exception(
                        "falloff.shape '" ~ ps.str ~ "' unknown");
            }
        }
    }

    Vec3 readVec3(string key, Vec3 fallback) {
        auto pv = key in j.object;
        if (pv is null || pv.type != JSONType.array || pv.array.length != 3)
            return fallback;
        float r(std.json.JSONValue v) {
            if (v.type == JSONType.float_)    return cast(float)v.floating;
            if (v.type == JSONType.integer)   return cast(float)v.integer;
            if (v.type == JSONType.uinteger)  return cast(float)v.uinteger;
            return 0.0f;
        }
        return Vec3(r(pv.array[0]), r(pv.array[1]), r(pv.array[2]));
    }
    float readFloat(string key, float fallback) {
        auto pv = key in j.object;
        if (pv is null) return fallback;
        if (pv.type == JSONType.float_)    return cast(float)pv.floating;
        if (pv.type == JSONType.integer)   return cast(float)pv.integer;
        if (pv.type == JSONType.uinteger)  return cast(float)pv.uinteger;
        return fallback;
    }

    fp.start  = readVec3("start",  fp.start);
    fp.end    = readVec3("end",    fp.end);
    fp.center = readVec3("center", fp.center);
    fp.size   = readVec3("size",   fp.size);
    fp.normal = readVec3("axis",   fp.normal);
    fp.in_    = readFloat("in",  fp.in_);
    fp.out_   = readFloat("out", fp.out_);
    return fp;
}

unittest {
    // Linear falloff round-trip: {start, end} → packet with weight 0.5 mid-line.
    import std.json : parseJSON;
    import std.math : isClose;
    auto j = parseJSON(`{"type":"linear","shape":"linear",
                         "start":[0,1,0],"end":[0,-1,0]}`);
    auto fp = parseFalloffJson(j);
    assert(fp.enabled);
    assert(fp.type == FalloffType.Linear);
    assert(fp.shape == FalloffShape.Linear);
    Viewport vp;
    assert(isClose(evaluateFalloff(fp, Vec3(0,  1, 0), 0, vp), 1.0f));
    assert(isClose(evaluateFalloff(fp, Vec3(0,  0, 0), 0, vp), 0.5f));
    assert(isClose(evaluateFalloff(fp, Vec3(0, -1, 0), 0, vp), 0.0f));
}

unittest { // vertexMapWeight: lookup + clamp + degenerate cases
    import std.math : isClose;
    FalloffPacket fp;
    fp.enabled = true;
    fp.type    = FalloffType.VertexMap;
    Viewport vp;

    // empty slice → full influence
    assert(isClose(evaluateFalloff(fp, Vec3(0, 0, 0), 0, vp), 1.0f));

    float[3] raw = [0.0f, 0.5f, 1.5f]; // last entry above 1 → clamped to 1
    fp.vertexMapWeights = raw[];
    assert(isClose(evaluateFalloff(fp, Vec3(0, 0, 0), 0, vp), 0.0f));
    assert(isClose(evaluateFalloff(fp, Vec3(0, 0, 0), 1, vp), 0.5f));
    assert(isClose(evaluateFalloff(fp, Vec3(0, 0, 0), 2, vp), 1.0f)); // clamped
    // out-of-range → full influence
    assert(isClose(evaluateFalloff(fp, Vec3(0, 0, 0), 5, vp), 1.0f));
    // negative vertIdx → full influence
    assert(isClose(evaluateFalloff(fp, Vec3(0, 0, 0), -1, vp), 1.0f));
}
