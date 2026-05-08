module snap;

import std.math : sqrt, round;

import math : Vec3, Viewport, projectToWindowFull, screenRay,
              rayPlaneIntersect, pointInPolygon2D,
              closestOnSegment2DSquared, cross, dot;
import mesh : Mesh;
import toolpipe.packets : SnapPacket, SnapType;

// ---------------------------------------------------------------------------
// Snap math — Phase 7.3 of doc/phase7_plan.md / doc/snap_plan.md.
//
// Tools that produce a world-space cursor position (Move drag, Pen
// click, primitive Create base/height drags) call `snapCursor()` on
// every motion event, passing the desired raw world position + the
// screen pixel where the cursor is. If the SnapPacket says snap is
// enabled, this function walks the enabled candidate types and picks
// the closest screen-space candidate; if it lies within
// `innerRangePx` the cursor "snaps" to that candidate's world
// position. Highlights (within `outerRangePx`) are reported alongside
// for visual feedback.
//
// 7.3a implements only `SnapType.Vertex`. The other types come in
// 7.3b / 7.3c — the function signature is the final shape so callers
// don't churn between subphases.
// ---------------------------------------------------------------------------

struct SnapResult {
    Vec3     worldPos;          /// snapped position; equals input when !snapped
    Vec3     highlightPos;      /// candidate within outerRange (for pre-snap UI)
    bool     snapped;           /// true iff input was within innerRange of a candidate
    bool     highlighted;       /// true iff any candidate within outerRange
    SnapType targetType;        /// which type fired (for feedback rendering)
    int      targetIndex;       /// mesh element index (vert/edge/face) or -1
}

/// Snap the world position `cursorWorld` corresponding to screen pixel
/// (sx, sy) according to `cfg`. `excludeVerts` lists vertex indices
/// the candidate walk must skip — typically the dragged element's own
/// indices, so a single-vert drag doesn't snap to itself (zero
/// distance). Returns the input pass-through when `cfg.enabled` is
/// false (no candidates considered).
SnapResult snapCursor(Vec3 cursorWorld, int sx, int sy,
                      const ref Viewport vp,
                      const ref Mesh mesh,
                      const ref SnapPacket cfg,
                      const(uint)[] excludeVerts = null)
{
    SnapResult res;
    res.worldPos     = cursorWorld;
    res.highlightPos = cursorWorld;
    res.targetType   = SnapType.None;
    res.targetIndex  = -1;
    if (!cfg.enabled) return res;

    // Best (closest) candidate across all enabled types. Screen-space
    // distance — matches MODO's pixel-range semantic.
    float    bestDist  = float.infinity;
    Vec3     bestWorld = cursorWorld;
    int      bestIdx   = -1;
    SnapType bestType  = SnapType.None;

    void consider(Vec3 candWorld, int idx, SnapType type) {
        float pxs, pys, ndcZ;
        // projectToWindowFull rejects behind-camera (w<=0) but does NOT
        // clip to the screen rectangle, which is exactly what we want
        // — a snap target a few pixels off-screen should still snap if
        // the cursor is also off-screen near it (e.g. dragging out
        // beyond a viewport edge).
        if (!projectToWindowFull(candWorld, vp, pxs, pys, ndcZ)) return;
        float dx = pxs - cast(float)sx;
        float dy = pys - cast(float)sy;
        float d  = sqrt(dx * dx + dy * dy);
        if (d > cfg.outerRangePx) return;
        if (d < bestDist) {
            bestDist  = d;
            bestWorld = candWorld;
            bestIdx   = idx;
            bestType  = type;
        }
    }

    // Vertex candidates (7.3a).
    if (cfg.enabledTypes & SnapType.Vertex) {
        foreach (vi, ref v; mesh.vertices) {
            if (isVertExcluded(cast(uint)vi, excludeVerts)) continue;
            consider(v, cast(int)vi, SnapType.Vertex);
        }
    }

    // Edge candidates (7.3b) — closest point on each edge segment in
    // screen space. Skipped when both endpoints are part of the
    // dragged set (the entire edge is moving with the cursor).
    if (cfg.enabledTypes & SnapType.Edge) {
        foreach (ei, edge; mesh.edges) {
            if (isVertExcluded(edge[0], excludeVerts)
             && isVertExcluded(edge[1], excludeVerts)) continue;
            float px0, py0, ndcZ0, px1, py1, ndcZ1;
            Vec3 a = mesh.vertices[edge[0]];
            Vec3 b = mesh.vertices[edge[1]];
            if (!projectToWindowFull(a, vp, px0, py0, ndcZ0)) continue;
            if (!projectToWindowFull(b, vp, px1, py1, ndcZ1)) continue;
            float t;
            // Screen-space-closest t. The world point at the SAME
            // parametric t is what we publish — strictly speaking
            // perspective division means re-projecting that world
            // point doesn't land exactly on the screen-closest pixel,
            // but for typical viewports the deviation is sub-pixel
            // and `consider()` will compute its actual screen
            // distance against the cursor anyway.
            closestOnSegment2DSquared(cast(float)sx, cast(float)sy,
                                       px0, py0, px1, py1, t);
            consider(a + (b - a) * t, cast(int)ei, SnapType.Edge);
        }
    }

    // EdgeCenter candidates (7.3b) — midpoint of each edge.
    if (cfg.enabledTypes & SnapType.EdgeCenter) {
        foreach (ei, edge; mesh.edges) {
            if (isVertExcluded(edge[0], excludeVerts)
             && isVertExcluded(edge[1], excludeVerts)) continue;
            Vec3 mid = (mesh.vertices[edge[0]] + mesh.vertices[edge[1]]) * 0.5f;
            consider(mid, cast(int)ei, SnapType.EdgeCenter);
        }
    }

    // Polygon candidates (7.3b) — closest point on the polygon
    // surface. Cursor inside the screen-projected polygon ⇒ ray-plane
    // hit on the face. Outside ⇒ closest point on the boundary
    // (= closest segment of the face's edge ring).
    if (cfg.enabledTypes & SnapType.Polygon) {
        foreach (fi, face; mesh.faces) {
            if (isFaceFullyExcluded(face, excludeVerts)) continue;
            Vec3 hit;
            if (closestOnPolygonSurface(face, mesh, sx, sy, vp, hit))
                consider(hit, cast(int)fi, SnapType.Polygon);
        }
    }

    // PolyCenter candidates (7.3b) — face centroid (average of verts).
    if (cfg.enabledTypes & SnapType.PolyCenter) {
        foreach (fi, face; mesh.faces) {
            if (isFaceFullyExcluded(face, excludeVerts)) continue;
            if (face.length == 0) continue;
            Vec3 c = Vec3(0, 0, 0);
            foreach (vi; face) c += mesh.vertices[vi];
            c = c / cast(float)face.length;
            consider(c, cast(int)fi, SnapType.PolyCenter);
        }
    }

    // Grid candidate (7.3c). The grid lies on the workplane plane.
    // Project the cursor ray onto the workplane to get a 3D hit, snap
    // its workplane-local (axis1, axis2) coords to the nearest grid
    // step, then re-construct the world point. Step is published as
    // `cfg.gridStep` (= fixedGridSize when fixedGrid, else 1.0 to
    // match vibe3d's visible grid).
    if (cfg.enabledTypes & SnapType.Grid) {
        Vec3 ray = screenRay(cast(float)sx, cast(float)sy, vp);
        Vec3 hit;
        if (rayPlaneIntersect(vp.eye, ray,
                              cfg.workplaneCenter, cfg.workplaneNormal, hit))
        {
            Vec3 d = hit - cfg.workplaneCenter;
            float a1 = dot(d, cfg.workplaneAxis1);
            float a2 = dot(d, cfg.workplaneAxis2);
            float step = cfg.gridStep > 1e-9f ? cfg.gridStep : 1.0f;
            float sa1 = round(a1 / step) * step;
            float sa2 = round(a2 / step) * step;
            Vec3 snapped = cfg.workplaneCenter
                         + cfg.workplaneAxis1 * sa1
                         + cfg.workplaneAxis2 * sa2;
            consider(snapped, -1, SnapType.Grid);
        }
    }

    // Workplane candidate (7.3c). The cursor ray's intersection with
    // the workplane plane. Re-projects to exactly the cursor pixel
    // (modulo float precision), so this candidate's screen distance
    // is ~0 — geometric / grid candidates with smaller projected-
    // pixel distance still take priority because they're considered
    // first and `consider()`'s tie-break is strict less-than.
    if (cfg.enabledTypes & SnapType.Workplane) {
        Vec3 ray = screenRay(cast(float)sx, cast(float)sy, vp);
        Vec3 hit;
        if (rayPlaneIntersect(vp.eye, ray,
                              cfg.workplaneCenter, cfg.workplaneNormal, hit))
            consider(hit, -1, SnapType.Workplane);
    }

    if (bestDist <= cfg.outerRangePx) {
        res.highlighted  = true;
        res.highlightPos = bestWorld;
        res.targetType   = bestType;
        res.targetIndex  = bestIdx;
        if (bestDist <= cfg.innerRangePx) {
            res.snapped  = true;
            res.worldPos = bestWorld;
        }
    }
    return res;
}

private bool isVertExcluded(uint vi, const(uint)[] exclude) {
    foreach (ex; exclude)
        if (ex == vi) return true;
    return false;
}

private bool isFaceFullyExcluded(const(uint)[] face,
                                  const(uint)[] exclude) {
    if (exclude.length == 0) return false;
    foreach (vi; face)
        if (!isVertExcluded(vi, exclude)) return false;
    return true;
}

// Closest world-space point on a polygon's surface to the cursor at
// screen pixel (sx, sy). Cursor inside the screen-projected polygon
// ⇒ ray-plane hit (face's plane, normal from first 3 verts). Outside
// ⇒ closest point along the polygon's boundary edge ring. Returns
// false on degenerate faces (< 3 verts, behind-camera vert, zero-area
// normal) — caller skips that face.
private bool closestOnPolygonSurface(const(uint)[] face,
                                     const ref Mesh mesh,
                                     int sx, int sy,
                                     const ref Viewport vp,
                                     out Vec3 worldHit)
{
    if (face.length < 3) return false;

    float[] xs = new float[](face.length);
    float[] ys = new float[](face.length);
    foreach (i, vi; face) {
        float pxs, pys, ndcZ;
        if (!projectToWindowFull(mesh.vertices[vi], vp, pxs, pys, ndcZ))
            return false;
        xs[i] = pxs;
        ys[i] = pys;
    }

    Vec3 v0 = mesh.vertices[face[0]];
    Vec3 v1 = mesh.vertices[face[1]];
    Vec3 v2 = mesh.vertices[face[2]];
    Vec3 n  = cross(v1 - v0, v2 - v0);
    float nlen = sqrt(n.x*n.x + n.y*n.y + n.z*n.z);
    if (nlen < 1e-9f) return false;
    n = n / nlen;

    if (pointInPolygon2D(cast(float)sx, cast(float)sy, xs, ys)) {
        Vec3 ray = screenRay(cast(float)sx, cast(float)sy, vp);
        return rayPlaneIntersect(vp.eye, ray, v0, n, worldHit);
    }

    // Outside polygon — walk the boundary edge ring.
    float bestT     = 0;
    int   bestEi    = -1;
    float bestDist2 = float.infinity;
    foreach (i; 0 .. face.length) {
        size_t j = (i + 1) % face.length;
        float t;
        float d2 = closestOnSegment2DSquared(
            cast(float)sx, cast(float)sy,
            xs[i], ys[i], xs[j], ys[j], t);
        if (d2 < bestDist2) {
            bestDist2 = d2;
            bestT     = t;
            bestEi    = cast(int)i;
        }
    }
    if (bestEi < 0) return false;
    Vec3 a = mesh.vertices[face[bestEi]];
    Vec3 b = mesh.vertices[face[(bestEi + 1) % face.length]];
    worldHit = a + (b - a) * bestT;
    return true;
}
