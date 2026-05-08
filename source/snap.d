module snap;

import std.math : sqrt;

import math : Vec3, Viewport, projectToWindowFull;
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
            if (excludeVerts.length > 0) {
                bool skip = false;
                foreach (ex; excludeVerts) {
                    if (ex == cast(uint)vi) { skip = true; break; }
                }
                if (skip) continue;
            }
            consider(v, cast(int)vi, SnapType.Vertex);
        }
    }

    // Other types land in 7.3b / 7.3c — see doc/snap_plan.md.

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
