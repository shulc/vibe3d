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
    // per-frame projection scan. The grid query returns an
    // index-ASCENDING list of every non-excluded vertex whose
    // projected pixel could be within `outerRangePx` of the cursor
    // (a superset); each is funneled through the UNCHANGED `consider()`
    // walk, so visiting them in ascending index order with consider()'s
    // strict-`<` reproduces the old linear scan's winner + tie-break
    // (smallest pixel distance, ties → lowest index) byte-for-byte.
    if (cfg.enabledTypes & SnapType.Vertex) {
        auto cands = queryCandidateGrid(Kind.Vertex, mesh, vp, sx, sy,
                                        cfg.outerRangePx, excludeVerts);
        foreach (vi; cands)
            consider(mesh.vertices[vi], cast(int)vi, SnapType.Vertex);
    }

    // Edge candidates (7.3b) — closest point on each edge segment in
    // screen space. Skipped when both endpoints are part of the
    // dragged set (the entire edge is moving with the cursor).
    //
    // Broad-phase: a per-edge screen-bbox bucket grid (Kind.Edge)
    // returns only edges whose projected bbox overlaps the cursor's
    // 3×3 cell block; each is then run through the UNCHANGED exact
    // segment-distance + consider() math below, so the winner is
    // byte-identical to the old O(edges) scan. Exclusion (both
    // endpoints dragged) is applied at query time.
    if (cfg.enabledTypes & SnapType.Edge) {
        auto cands = queryCandidateGrid(Kind.Edge, mesh, vp, sx, sy,
                                        cfg.outerRangePx, excludeVerts);
        foreach (ei; cands) {
            auto edge = mesh.edges[ei];
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

    // EdgeCenter candidates (7.3b) — midpoint of each edge. Point
    // candidate ⇒ Kind.EdgeCenter point grid; same 3×3 query as Vertex.
    if (cfg.enabledTypes & SnapType.EdgeCenter) {
        auto cands = queryCandidateGrid(Kind.EdgeCenter, mesh, vp, sx, sy,
                                        cfg.outerRangePx, excludeVerts);
        foreach (ei; cands) {
            auto edge = mesh.edges[ei];
            Vec3 mid = (mesh.vertices[edge[0]] + mesh.vertices[edge[1]]) * 0.5f;
            consider(mid, cast(int)ei, SnapType.EdgeCenter);
        }
    }

    // Polygon candidates (7.3b) — closest point on the polygon
    // surface. Cursor inside the screen-projected polygon ⇒ ray-plane
    // hit on the face. Outside ⇒ closest point on the boundary
    // (= closest segment of the face's edge ring).
    //
    // Broad-phase: per-face screen-bbox bucket grid (Kind.Polygon).
    // The expensive `closestOnPolygonSurface` (which projects all face
    // verts + allocates) now runs ONLY on near faces.
    if (cfg.enabledTypes & SnapType.Polygon) {
        auto cands = queryCandidateGrid(Kind.Polygon, mesh, vp, sx, sy,
                                        cfg.outerRangePx, excludeVerts);
        foreach (fi; cands) {
            auto face = mesh.faces[fi];
            Vec3 hit;
            if (closestOnPolygonSurface(face, mesh, sx, sy, vp, hit))
                consider(hit, cast(int)fi, SnapType.Polygon);
        }
    }

    // PolyCenter candidates (7.3b) — face centroid (average of verts).
    // Point candidate ⇒ Kind.PolyCenter point grid.
    if (cfg.enabledTypes & SnapType.PolyCenter) {
        auto cands = queryCandidateGrid(Kind.PolyCenter, mesh, vp, sx, sy,
                                        cfg.outerRangePx, excludeVerts);
        foreach (fi; cands) {
            auto face = mesh.faces[fi];
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
// Screen-space candidate bucket grid (perf — see top-of-file note + the
// candidate blocks in snapCursor).
//
// WHY: each per-element snap type used to project + test EVERY element
// of its kind on every drag frame (O(verts) for Vertex/EdgeCenter,
// O(edges) for Edge, O(faces) × per-face allocation for Polygon, etc).
// At n=64 (4K verts) the geometric types cost ~150ms/frame; at 100K
// they are catastrophic. The camera + viewport are static for the whole
// duration of a drag, and interactive drags do NOT bump
// `mesh.mutationVersion` (the moving verts are passed in `excludeVerts`
// instead — see mesh.d's uploadVersion note). So we can project all
// elements of a kind ONCE at drag start into a uniform screen-space
// bucket grid and answer each frame's candidate query with a 3×3 cell
// scan.
//
// ONE GENERIC GRID, FIVE KINDS: `Kind` selects which per-element
// projection feeds the grid:
//   - Vertex / EdgeCenter / PolyCenter — POINT candidates: one projected
//     screen point per element. Bucketed into the single cell that point
//     falls in.
//   - Edge / Polygon — EXTENT candidates: the element's PROJECTED
//     screen-space bounding box (edge = both endpoints; face = all
//     verts). Bucketed into EVERY cell its bbox overlaps, so a long edge
//     or large face is reachable from any cell near it.
// Each enabled kind keeps its own cached grid (`g_grids[kind]`); only
// the grids for the types actually queried in a given snapCursor call
// are ever built. The grids are independent so an Edge-only drag never
// pays to index faces, etc.
//
// BROAD-PHASE CONTRACT + COVERAGE GUARANTEE: queryCandidateGrid is a
// SUPERSET filter. It returns (index-ascending, deduplicated) every
// element whose closest screen-space point COULD lie within
// `outerRangePx` of the cursor; the caller then runs the UNCHANGED exact
// distance math (consider() / segment distance / closestOnPolygonSurface)
// on only those, and consider()'s own `d > outerRangePx` reject + best
// tracking produces the identical winner the linear scan did. Because
// candidates are visited in ascending index order with consider()'s
// strict-`<`, the lowest-index-wins tie-break is preserved byte-for-byte.
//
// The coverage guarantee with cell size == outerRangePx and a 3×3 query:
//   POINT kinds: a point within `outerRangePx` (= one cell width) of the
//   cursor is at most one cell away in each axis, so it lies in the
//   cursor cell or an 8-neighbor — the 3×3 block. Exact.
//   EXTENT kinds: let P be the screen point on the element closest to
//   the cursor; if |P - cursor| <= outerRangePx then P is within one
//   cell of the cursor, so P's cell is inside the 3×3 block. P lies
//   inside the element's screen bbox, and the element was inserted into
//   EVERY cell its bbox overlaps — so it was inserted into P's cell, and
//   the 3×3 scan finds it. Hence any element whose closest screen point
//   is within outerRangePx is returned. (The segment/polygon exact tests
//   use the element's true closest point, which is <= the closest bbox
//   point's distance, so no in-range element is missed.) Exact superset.
//
// CACHE KEY (per kind): (vp.view, vp.proj, viewport rect) +
// mesh.mutationVersion + element count + cellPx. All stable during a
// drag ⇒ built once at drag start, reused every frame. Topology / non-
// drag edits bump mutationVersion and force a rebuild.
//
// EXCLUDE IS QUERY-TIME, NOT KEY: every element is indexed at build
// time; the dragged set (excludeVerts) is applied at QUERY time. An
// element is excluded iff ALL its incident verts are dragged — for
// points: the source vert (Vertex) / both edge endpoints (EdgeCenter) /
// all face verts (PolyCenter); for extents: both endpoints (Edge) / all
// face verts (Polygon) — matching the original linear loops' skip rule
// exactly. The moving elements' stored projections go stale as they
// move, but they are excluded from results anyway, so the cache stays
// valid across the whole drag.
//
// THREAD SAFETY: snapCursor's drag callers run on the main thread, but
// the `/api/snap` test bridge (app.d) calls snapCursor directly on the
// HTTP server thread. The module-level grid cache is shared across two
// threads; g_vgridMutex serializes build + query for ALL kinds (queries
// are ~O(1) and builds rare, so contention is negligible).
//
// CELL SIZE: `outerRangePx`. When degenerate (<= 0) the query falls back
// to returning ALL non-excluded element indices (index-ascending) so the
// caller's exact walk is a full — but still correct — linear scan; only
// ever reached for pathological configs.

private enum Kind { Vertex, EdgeCenter, PolyCenter, Edge, Polygon }

private bool kindIsPoint(Kind k) {
    return k == Kind.Vertex || k == Kind.EdgeCenter || k == Kind.PolyCenter;
}

// Number of elements of a kind present in the mesh.
private size_t kindCount(Kind k, const ref Mesh mesh) {
    final switch (k) {
        case Kind.Vertex:                      return mesh.vertices.length;
        case Kind.EdgeCenter: case Kind.Edge:  return mesh.edges.length;
        case Kind.PolyCenter: case Kind.Polygon: return mesh.faces.length;
    }
}

private struct CandidateGrid {
    // Cache identity.
    ulong  meshVersion = ulong.max;
    float[16] view;
    float[16] proj;
    int    vpW, vpH, vpX, vpY;
    float  cellPx = 0;          // grid cell size (== outerRangePx at build)
    size_t elemCount = 0;

    // Bucket extents in screen-space cell coordinates.
    int    minCx, minCy, nCols, nRows;

    // CSR-style bucket layout: `cellStart[c .. c+1]` indexes a contiguous
    // run in `items`. An item is just the element index — the caller
    // re-projects for the exact test, and points re-derive trivially.
    int[]  cellStart;           // length nCols*nRows + 1
    int[]  items;               // element indices, possibly duplicated
                                // across cells for EXTENT kinds.
    bool valid;
}

private __gshared CandidateGrid[Kind.max + 1] g_grids;
private __gshared Mutex      g_vgridMutex;

shared static this() { g_vgridMutex = new Mutex(); }

private bool sameViewport(const ref CandidateGrid g, const ref Viewport vp) {
    if (g.vpW != vp.width || g.vpH != vp.height
     || g.vpX != vp.x     || g.vpY != vp.y) return false;
    foreach (i; 0 .. 16) {
        if (g.view[i] != vp.view[i]) return false;
        if (g.proj[i] != vp.proj[i]) return false;
    }
    return true;
}

// Project the screen-space cell-coord bbox [loCx..hiCx]×[loCy..hiCy] of
// element `idx` of kind `k`. Returns false (element skipped) when any
// required vertex is behind the camera or the element is degenerate.
private bool projectElementCells(Kind k, int idx, const ref Mesh mesh,
                                 const ref Viewport vp, float inv,
                                 out int loCx, out int loCy,
                                 out int hiCx, out int hiCy) {
    // Helper: project a single world point into a cell, expanding bbox.
    bool first = true;
    bool accumulate(Vec3 w) {
        float pxs, pys, ndcZ;
        if (!projectToWindowFull(w, vp, pxs, pys, ndcZ)) return false;
        int cx = cast(int)floor(pxs * inv);
        int cy = cast(int)floor(pys * inv);
        if (first) {
            loCx = hiCx = cx; loCy = hiCy = cy; first = false;
        } else {
            if (cx < loCx) loCx = cx; if (cx > hiCx) hiCx = cx;
            if (cy < loCy) loCy = cy; if (cy > hiCy) hiCy = cy;
        }
        return true;
    }

    final switch (k) {
        case Kind.Vertex:
            return accumulate(mesh.vertices[idx]);
        case Kind.EdgeCenter: {
            auto e = mesh.edges[idx];
            Vec3 mid = (mesh.vertices[e[0]] + mesh.vertices[e[1]]) * 0.5f;
            return accumulate(mid);
        }
        case Kind.PolyCenter: {
            auto f = mesh.faces[idx];
            if (f.length == 0) return false;
            Vec3 c = Vec3(0, 0, 0);
            foreach (vi; f) c += mesh.vertices[vi];
            c = c / cast(float)f.length;
            return accumulate(c);
        }
        case Kind.Edge: {
            auto e = mesh.edges[idx];
            if (!accumulate(mesh.vertices[e[0]])) return false;
            if (!accumulate(mesh.vertices[e[1]])) return false;
            return true;
        }
        case Kind.Polygon: {
            auto f = mesh.faces[idx];
            if (f.length == 0) return false;
            foreach (vi; f)
                if (!accumulate(mesh.vertices[vi])) return false;
            return true;
        }
    }
}

// Build (or rebuild) the grid for kind `k` of `mesh` under viewport
// `vp`, cell size `cellPx`. Indexes ALL elements (exclusion happens at
// query time). EXTENT kinds insert each element into every cell its
// projected bbox overlaps; POINT kinds insert into a single cell.
private void buildCandidateGrid(Kind k, const ref Mesh mesh,
                                const ref Viewport vp, float cellPx) {
    auto g = &g_grids[k];
    g.meshVersion = mesh.mutationVersion;
    g.view[]      = vp.view[];
    g.proj[]      = vp.proj[];
    g.vpW = vp.width;  g.vpH = vp.height;
    g.vpX = vp.x;      g.vpY = vp.y;
    g.cellPx    = cellPx;
    g.elemCount = kindCount(k, mesh);
    g.valid     = false;

    size_t n = g.elemCount;
    float inv = 1.0f / cellPx;

    // Pass 1: project every element's cell bbox; track overall bbox.
    static struct Box { int loCx, loCy, hiCx, hiCy; bool ok; }
    Box[] boxes = new Box[](n);
    bool any = false;
    int loCx, loCy, hiCx, hiCy;
    foreach (i; 0 .. n) {
        Box b;
        b.ok = projectElementCells(k, cast(int)i, mesh, vp, inv,
                                   b.loCx, b.loCy, b.hiCx, b.hiCy);
        boxes[i] = b;
        if (!b.ok) continue;
        if (!any) {
            loCx = b.loCx; hiCx = b.hiCx; loCy = b.loCy; hiCy = b.hiCy;
            any = true;
        } else {
            if (b.loCx < loCx) loCx = b.loCx;
            if (b.hiCx > hiCx) hiCx = b.hiCx;
            if (b.loCy < loCy) loCy = b.loCy;
            if (b.hiCy > hiCy) hiCy = b.hiCy;
        }
    }

    if (!any) {
        // Nothing projects in front of the camera — empty grid.
        g.minCx = g.minCy = 0;
        g.nCols = g.nRows = 0;
        g.cellStart = [0];
        g.items = null;
        g.valid = true;
        return;
    }

    g.minCx = loCx;
    g.minCy = loCy;
    g.nCols = hiCx - loCx + 1;
    g.nRows = hiCy - loCy + 1;
    size_t nCells = cast(size_t)g.nCols * g.nRows;

    // CSR counting sort into buckets. EXTENT kinds contribute one entry
    // per overlapped cell.
    auto counts = new int[](nCells + 1);
    foreach (ref b; boxes) {
        if (!b.ok) continue;
        foreach (cy; b.loCy .. b.hiCy + 1)
            foreach (cx; b.loCx .. b.hiCx + 1) {
                size_t c = cast(size_t)(cy - loCy) * g.nCols + (cx - loCx);
                counts[c + 1]++;
            }
    }
    foreach (i; 1 .. nCells + 1) counts[i] += counts[i - 1];
    g.cellStart = counts;

    int total = counts[nCells];
    g.items = new int[](total);
    // Walk elements in ascending index so within each bucket items stay
    // index-ascending. The query merges the 3×3 block's buckets and
    // returns a deduplicated, index-ascending candidate list — matching
    // the old linear scans' ascending element order exactly.
    auto cursor = new int[](nCells);
    foreach (i; 0 .. nCells) cursor[i] = counts[i];
    foreach (i; 0 .. n) {
        Box b = boxes[i];
        if (!b.ok) continue;
        foreach (cy; b.loCy .. b.hiCy + 1)
            foreach (cx; b.loCx .. b.hiCx + 1) {
                size_t c = cast(size_t)(cy - loCy) * g.nCols + (cx - loCx);
                g.items[cursor[c]++] = cast(int)i;
            }
    }
    g.valid = true;
}

// Is element `idx` of kind `k` fully part of the dragged (excluded) set?
// Mirrors the original per-type linear loop skip rule exactly, but uses
// an O(1) per-vertex membership bitset (`ex`, indexed by vertex id) so a
// whole-mesh drag's huge exclude list doesn't turn each test into an
// O(exclude) scan — which would reintroduce the very O(n²) blowup the
// grid removes (esp. for edge/polygon, where many candidates are tested).
private bool kindExcluded(Kind k, int idx, const ref Mesh mesh,
                          const bool[] ex) {
    if (ex.length == 0) return false;
    bool exV(uint vi) { return vi < ex.length && ex[vi]; }
    final switch (k) {
        case Kind.Vertex:
            return exV(cast(uint)idx);
        case Kind.EdgeCenter: case Kind.Edge: {
            auto e = mesh.edges[idx];
            return exV(e[0]) && exV(e[1]);
        }
        case Kind.PolyCenter: case Kind.Polygon: {
            auto f = mesh.faces[idx];
            if (f.length == 0) return false;
            foreach (vi; f)
                if (!exV(vi)) return false;
            return true;
        }
    }
}

// Query the kind-`k` grid: return the index-ASCENDING, deduplicated list
// of candidate element indices whose closest screen point could lie
// within `outerRangePx` of cursor pixel (sx, sy), with the dragged set
// excluded. The list is a reusable module-scoped scratch buffer (valid
// until the next query) — the caller iterates it immediately. See the
// broad-phase contract + coverage guarantee in the section header.
private int[] queryCandidateGrid(Kind k, const ref Mesh mesh,
                                 const ref Viewport vp,
                                 int sx, int sy, float outerRangePx,
                                 const(uint)[] excludeVerts) {
    g_vgridMutex.lock();
    scope (exit) g_vgridMutex.unlock();

    g_candScratch.length = 0;
    size_t n = kindCount(k, mesh);
    if (n == 0) return g_candScratch;

    // O(1) per-vertex exclude membership (indexed by vertex id), built
    // once per query and cleared in O(exclude) — keeps kindExcluded O(1).
    bool[] ex = excludeMembership(excludeVerts, mesh.vertices.length);
    scope (exit) clearExcludeMembership(excludeVerts);

    // Degenerate range → return every non-excluded index (ascending).
    // The caller's exact walk then degrades to a correct linear scan.
    if (!(outerRangePx > 0)) {
        foreach (i; 0 .. n)
            if (!kindExcluded(k, cast(int)i, mesh, ex))
                g_candScratch ~= cast(int)i;
        return g_candScratch;
    }

    auto g = &g_grids[k];

    // (Re)build if stale.
    if (!g.valid
     || g.meshVersion != mesh.mutationVersion
     || g.elemCount   != n
     || g.cellPx      != outerRangePx
     || !sameViewport(*g, vp))
        buildCandidateGrid(k, mesh, vp, outerRangePx);

    if (g.nCols == 0 || g.nRows == 0) return g_candScratch;

    float inv = 1.0f / g.cellPx;
    int ccx = cast(int)floor(cast(float)sx * inv);
    int ccy = cast(int)floor(cast(float)sy * inv);

    // Collect the 3×3 block's bucketed indices. EXTENT kinds can emit an
    // element from multiple cells of the block, so dedup via a seen-set
    // keyed by element index (reused scratch, cleared O(emitted) after).
    bool[] seen = candSeen(n);
    scope (exit) clearCandSeen();

    foreach (gy; ccy - 1 .. ccy + 2) {
        int ly = gy - g.minCy;
        if (ly < 0 || ly >= g.nRows) continue;
        foreach (gx; ccx - 1 .. ccx + 2) {
            int lx = gx - g.minCx;
            if (lx < 0 || lx >= g.nCols) continue;
            size_t c = cast(size_t)ly * g.nCols + lx;
            int s = g.cellStart[c];
            int e = g.cellStart[c + 1];
            foreach (kk; s .. e) {
                int idx = g.items[kk];
                if (seen[idx]) continue;
                seen[idx] = true;
                g_candSeenIdx ~= idx;   // remember to clear this bit
                if (kindExcluded(k, idx, mesh, ex)) continue;
                g_candScratch ~= idx;
            }
        }
    }

    // The buckets are index-ascending within each cell, but the 3×3 scan
    // visits cells in row-major order, so the merged list is NOT globally
    // ascending. Sort to restore the linear scan's ascending element
    // order (cheap — only the near-cursor candidates, typically a handful).
    import std.algorithm.sorting : sort;
    sort(g_candScratch);
    return g_candScratch;
}

// Reusable candidate-list scratch + dedup seen-set, both guarded by
// g_vgridMutex via the query. `g_candScratch` holds the returned
// candidate indices; `g_candSeenIdx` records which seen-set bits were
// set this query so they can be cleared in O(emitted) rather than an
// O(n) memset.
private __gshared int[]  g_candScratch;
private __gshared bool[] g_candSeen;
private __gshared int[]  g_candSeenIdx;

private bool[] candSeen(size_t n) {
    if (g_candSeen.length < n) g_candSeen.length = n;
    g_candSeenIdx.length = 0;
    return g_candSeen[0 .. n];
}

private void clearCandSeen() {
    // g_candSeenIdx records every index whose `seen` bit we set (incl.
    // excluded ones that never made it into g_candScratch); clear in
    // O(emitted) rather than an O(n) memset so the buffer stays reusable.
    foreach (idx; g_candSeenIdx)
        if (idx >= 0 && idx < g_candSeen.length) g_candSeen[idx] = false;
}

// Reusable per-vertex exclude-membership scratch (guarded by
// g_vgridMutex via the query). `excludeMembership` sets the bits for
// `exclude` and returns the buffer (sized to `vertCount`);
// `clearExcludeMembership` resets only the bits it set (O(exclude)) so
// the buffer stays reusable without an O(verts) memset each frame.
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
