module snap;

import std.math : sqrt, round, floor, isNaN;
import core.sync.mutex : Mutex;

import math : Vec3, Viewport, projectToWindowFull, screenRay,
              rayPlaneIntersect, pointInPolygon2D,
              closestOnSegment2DSquared, cross, dot;
import mesh : Mesh;
import toolpipe.packets : SnapPacket, SnapType;
import perf_probe : g_perf, Cat;

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
    Vec3     worldPos     = Vec3(0, 0, 0); /// snapped position; equals input when !snapped
    Vec3     highlightPos = Vec3(0, 0, 0); /// candidate within outerRange (for pre-snap UI)
    bool     snapped;           /// true iff input was within innerRange of a candidate
    bool     highlighted;       /// true iff any candidate within outerRange
    SnapType targetType  = SnapType.None;  /// which type fired (for feedback rendering)
    int      targetIndex = -1;             /// mesh element index (vert/edge/face) or -1
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
    // One coarse scope per call — snapCursor is invoked once per drag
    // frame (not per vertex), so this captures the WHOLE geometric
    // candidate walk (the real per-frame snap cost) in one timer. Zero
    // cost in the default modeling build (perf_probe is a no-op there).
    auto z = g_perf.scope_(Cat.snapQuery);

    SnapResult res;
    res.worldPos     = cursorWorld;
    res.highlightPos = cursorWorld;
    res.targetType   = SnapType.None;
    res.targetIndex  = -1;
    if (!cfg.enabled) return res;

    // Best (closest) candidate across all enabled types. Screen-space
    // distance — a pixel-range semantic.
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

    // Vertex candidates (7.3a). Backed by a screen-space bucket grid
    // (built once per view, queried ~O(1)) instead of an O(verts)
    // per-frame projection scan. The grid query returns the SAME
    // winning vertex the old linear scan did: the in-`outerRangePx`
    // vertex with the smallest cursor pixel distance, ties broken by
    // lowest vertex index (matching the old strict-`<` ascending walk).
    // The winner is funneled back through `consider()` so the
    // cross-type min (vertex vs edge vs grid …) is byte-for-byte the
    // same as before.
    if (cfg.enabledTypes & SnapType.Vertex) {
        int    vWinIdx;
        Vec3   vWinWorld;
        if (queryVertexGrid(mesh, vp, sx, sy, cfg.outerRangePx,
                            excludeVerts, vWinIdx, vWinWorld))
            consider(vWinWorld, vWinIdx, SnapType.Vertex);
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

// ---------------------------------------------------------------------------
// Screen-space vertex bucket grid (perf — see top-of-file note + the
// vertex-candidate block in snapCursor).
//
// WHY: the vertex snap target used to project EVERY mesh vertex with
// `projectToWindowFull` on every drag frame (O(verts) × ~40 flops). At
// 100K verts that is ~50ms/frame. The camera + viewport are static for
// the whole duration of a drag, and interactive drags do NOT bump
// `mesh.mutationVersion` (the moving verts are passed in `excludeVerts`
// instead — see mesh.d's uploadVersion note). So we can project all
// vertices ONCE at drag start into a uniform screen-space bucket grid
// and answer each frame's "nearest in-range vertex" with a 3×3 cell
// scan.
//
// CACHE KEY: a signature of (vp.view, vp.proj) + mesh.mutationVersion.
// Both are stable during a drag, so the grid is built once at drag
// start and reused every subsequent frame. Topology / non-drag
// geometry edits bump mutationVersion and force a rebuild.
//
// EXCLUDE IS QUERY-TIME, NOT KEY: every vertex is indexed at build
// time; excluded verts are skipped at QUERY time. The exclude list is
// the small dragged set and changes within a single drag (it stays
// constant per drag, but is not part of the cache key on purpose).
// Keeping it out of the key means the moving verts' stored projections
// go stale as they move — but they are excluded from results anyway,
// so the cache stays valid across the whole drag.
//
// THREAD SAFETY: snapCursor's drag callers run on the main thread, but
// the `/api/snap` test bridge (app.d) calls snapCursor directly on the
// HTTP server thread. A module-level cache is therefore shared across
// two threads; a mutex serializes build + query (queries are O(1) and
// builds rare, so contention is negligible).
//
// CELL SIZE: `outerRangePx` (the vertex-snap max pixel range). With a
// cell that wide, any vertex within `outerRangePx` of the cursor lands
// in the cursor's cell or one of its 8 neighbors, so the 3×3 scan is
// exact. When outerRangePx is degenerate (<= 0) we fall back to a
// linear scan of all indexed verts (still correct, same O(verts) as
// the old path — only ever hit for pathological configs).

private struct VertexGrid {
    // Cache identity.
    ulong  meshVersion = ulong.max;
    float[16] view;
    float[16] proj;
    int    vpW, vpH, vpX, vpY;
    float  cellPx = 0;          // grid cell size (== outerRangePx at build)
    size_t vertCount = 0;

    // Bucket extents in screen-space cell coordinates.
    int    minCx, minCy, nCols, nRows;

    // CSR-style bucket layout: `cellStart[c .. c+1]` indexes a contiguous
    // run in `items`. An item is (sx, sy, vi). ndcZ is unused (no depth
    // tie-break in the linear scan it replaces).
    int[]  cellStart;           // length nCols*nRows + 1
    struct Item { float sx, sy; int vi; }
    Item[] items;

    bool valid;
}

private __gshared VertexGrid g_vgrid;
private __gshared Mutex      g_vgridMutex;

shared static this() { g_vgridMutex = new Mutex(); }

private bool sameViewport(const ref VertexGrid g, const ref Viewport vp) {
    if (g.vpW != vp.width || g.vpH != vp.height
     || g.vpX != vp.x     || g.vpY != vp.y) return false;
    foreach (i; 0 .. 16) {
        if (g.view[i] != vp.view[i]) return false;
        if (g.proj[i] != vp.proj[i]) return false;
    }
    return true;
}

// Build (or rebuild) the grid for `mesh` under viewport `vp`, cell size
// `cellPx`. Indexes ALL vertices (exclusion happens at query time).
private void buildVertexGrid(const ref Mesh mesh, const ref Viewport vp,
                             float cellPx) {
    g_vgrid.meshVersion = mesh.mutationVersion;
    g_vgrid.view[]      = vp.view[];
    g_vgrid.proj[]      = vp.proj[];
    g_vgrid.vpW = vp.width;  g_vgrid.vpH = vp.height;
    g_vgrid.vpX = vp.x;      g_vgrid.vpY = vp.y;
    g_vgrid.cellPx    = cellPx;
    g_vgrid.vertCount = mesh.vertices.length;
    g_vgrid.valid     = false;

    // Pass 1: project every vertex, record screen pos + cell, and track
    // the cell-coordinate bounding box of the projected (front-facing)
    // verts.
    static struct Proj { float sx, sy; int cx, cy; int vi; bool ok; }
    Proj[] projs = new Proj[](mesh.vertices.length);
    bool any = false;
    int loCx, loCy, hiCx, hiCy;
    float inv = 1.0f / cellPx;
    foreach (vi, ref v; mesh.vertices) {
        float pxs, pys, ndcZ;
        if (!projectToWindowFull(v, vp, pxs, pys, ndcZ)) {
            projs[vi].ok = false;
            continue;
        }
        int cx = cast(int)floor(pxs * inv);
        int cy = cast(int)floor(pys * inv);
        projs[vi] = Proj(pxs, pys, cx, cy, cast(int)vi, true);
        if (!any) {
            loCx = hiCx = cx; loCy = hiCy = cy; any = true;
        } else {
            if (cx < loCx) loCx = cx; if (cx > hiCx) hiCx = cx;
            if (cy < loCy) loCy = cy; if (cy > hiCy) hiCy = cy;
        }
    }

    if (!any) {
        // Nothing projects in front of the camera — empty grid.
        g_vgrid.minCx = g_vgrid.minCy = 0;
        g_vgrid.nCols = g_vgrid.nRows = 0;
        g_vgrid.cellStart = [0];
        g_vgrid.items = null;
        g_vgrid.valid = true;
        return;
    }

    g_vgrid.minCx = loCx;
    g_vgrid.minCy = loCy;
    g_vgrid.nCols = hiCx - loCx + 1;
    g_vgrid.nRows = hiCy - loCy + 1;
    size_t nCells = cast(size_t)g_vgrid.nCols * g_vgrid.nRows;

    // CSR counting sort into buckets.
    auto counts = new int[](nCells + 1);
    foreach (ref p; projs) {
        if (!p.ok) continue;
        size_t c = cast(size_t)(p.cy - loCy) * g_vgrid.nCols
                 + (p.cx - loCx);
        counts[c + 1]++;
    }
    foreach (i; 1 .. nCells + 1) counts[i] += counts[i - 1];
    g_vgrid.cellStart = counts;

    int total = counts[nCells];
    g_vgrid.items = new VertexGrid.Item[](total);
    // Walk verts in ascending index so within each bucket items stay
    // index-ascending — lets the query's strict-`<` tie-break pick the
    // lowest vertex index, matching the old linear scan exactly.
    auto cursor = new int[](nCells);
    foreach (i; 0 .. nCells) cursor[i] = counts[i];
    foreach (ref p; projs) {
        if (!p.ok) continue;
        size_t c = cast(size_t)(p.cy - loCy) * g_vgrid.nCols
                 + (p.cx - loCx);
        g_vgrid.items[cursor[c]++] =
            VertexGrid.Item(p.sx, p.sy, p.vi);
    }
    g_vgrid.valid = true;
}

// Find the nearest non-excluded vertex within `outerRangePx` of cursor
// pixel (sx, sy). Returns true + (outIdx, outWorld) on a hit. Result is
// identical to the old linear `consider()` walk over SnapType.Vertex:
// min pixel distance within range, ties → lowest vertex index.
private bool queryVertexGrid(const ref Mesh mesh, const ref Viewport vp,
                             int sx, int sy, float outerRangePx,
                             const(uint)[] excludeVerts,
                             out int outIdx, out Vec3 outWorld) {
    if (mesh.vertices.length == 0) return false;

    g_vgridMutex.lock();
    scope (exit) g_vgridMutex.unlock();

    // Degenerate range → linear scan fallback (preserves exact result;
    // only reached for pathological configs where the bucket cell size
    // would be non-positive).
    if (!(outerRangePx > 0)) {
        float bd = float.infinity; int bi = -1;
        foreach (vi, ref v; mesh.vertices) {
            if (isVertExcluded(cast(uint)vi, excludeVerts)) continue;
            float pxs, pys, ndcZ;
            if (!projectToWindowFull(v, vp, pxs, pys, ndcZ)) continue;
            float dx = pxs - cast(float)sx, dy = pys - cast(float)sy;
            float d = sqrt(dx*dx + dy*dy);
            if (d > outerRangePx) continue;
            if (d < bd) { bd = d; bi = cast(int)vi; }
        }
        if (bi < 0) return false;
        outIdx = bi; outWorld = mesh.vertices[bi];
        return true;
    }

    // (Re)build if stale.
    if (!g_vgrid.valid
     || g_vgrid.meshVersion != mesh.mutationVersion
     || g_vgrid.vertCount   != mesh.vertices.length
     || g_vgrid.cellPx      != outerRangePx
     || !sameViewport(g_vgrid, vp))
        buildVertexGrid(mesh, vp, outerRangePx);

    if (g_vgrid.nCols == 0 || g_vgrid.nRows == 0) return false;

    // O(1) exclusion membership. The old linear scan was fine when the
    // dragged set was tiny, but a whole-mesh move makes excludeVerts
    // span every vertex — turning the per-item `isVertExcluded` linear
    // scan back into O(verts) and reintroducing the bottleneck. A
    // reusable bool[] keyed by vertex index gives O(1) lookup; it is
    // module-scoped (guarded by the same mutex) so it isn't reallocated
    // every frame.
    bool[] ex = excludeMembership(excludeVerts, mesh.vertices.length);
    scope (exit) clearExcludeMembership(excludeVerts);

    float inv = 1.0f / g_vgrid.cellPx;
    int ccx = cast(int)floor(cast(float)sx * inv);
    int ccy = cast(int)floor(cast(float)sy * inv);

    float bestDist = float.infinity;
    int   bestIdx  = -1;
    foreach (gy; ccy - 1 .. ccy + 2) {
        int ly = gy - g_vgrid.minCy;
        if (ly < 0 || ly >= g_vgrid.nRows) continue;
        foreach (gx; ccx - 1 .. ccx + 2) {
            int lx = gx - g_vgrid.minCx;
            if (lx < 0 || lx >= g_vgrid.nCols) continue;
            size_t c = cast(size_t)ly * g_vgrid.nCols + lx;
            int s = g_vgrid.cellStart[c];
            int e = g_vgrid.cellStart[c + 1];
            foreach (k; s .. e) {
                auto it = g_vgrid.items[k];
                if (it.vi < cast(int)ex.length && ex[it.vi])
                    continue;
                float dx = it.sx - cast(float)sx;
                float dy = it.sy - cast(float)sy;
                float d  = sqrt(dx*dx + dy*dy);
                if (d > outerRangePx) continue;
                // Strict-`<` keeps the FIRST item at a tied distance.
                // Items within a bucket are index-ascending, but two
                // tied verts can live in different buckets scanned in
                // an arbitrary order — so add an explicit lowest-index
                // tie-break to guarantee parity with the old ascending
                // linear walk.
                if (d < bestDist
                 || (d == bestDist && it.vi < bestIdx)) {
                    bestDist = d;
                    bestIdx  = it.vi;
                }
            }
        }
    }

    if (bestIdx < 0) return false;
    outIdx   = bestIdx;
    outWorld = mesh.vertices[bestIdx];
    return true;
}

// Reusable exclude-membership scratch (guarded by g_vgridMutex via the
// query). `excludeMembership` sets the bits for `exclude` and returns
// the buffer (sized to `vertCount`); `clearExcludeMembership` resets
// only the bits it set (O(exclude)) so the buffer stays reusable
// without an O(verts) memset each frame.
private __gshared bool[] g_excludeScratch;

private bool[] excludeMembership(const(uint)[] exclude, size_t vertCount) {
    if (g_excludeScratch.length < vertCount)
        g_excludeScratch.length = vertCount;
    foreach (e; exclude)
        if (e < vertCount) g_excludeScratch[e] = true;
    return g_excludeScratch[0 .. vertCount];
}

private void clearExcludeMembership(const(uint)[] exclude) {
    foreach (e; exclude)
        if (e < g_excludeScratch.length) g_excludeScratch[e] = false;
}
