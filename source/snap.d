module snap;

import std.math : sqrt, round, floor, isNaN;
import core.sync.mutex : Mutex;

import math : Vec3, Viewport, projectToWindowFull, screenRay, screenPointToRay,
              rayPlaneIntersect, pointInPolygon2D,
              closestOnSegment2DSquared, cross, dot,
              closestPointOnLineToRay;
import mesh : Mesh;
import toolpipe.packets : SnapPacket, SnapType, SnapMode;
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
    Vec3     worldPos      = Vec3(0, 0, 0); /// snapped position; equals input when !snapped
    Vec3     highlightPos  = Vec3(0, 0, 0); /// candidate within outerRange (for pre-snap UI)
    bool     snapped;            /// true iff input was within innerRange of a candidate
    bool     highlighted;        /// true iff any candidate within outerRange
    SnapType targetType    = SnapType.None; /// discrete type that fired (for feedback rendering)
    int      targetIndex   = -1;            /// mesh element index (vert/edge/face) or -1
    int      targetSource  = 0;             /// source slot the winner came from:
                                            /// 0 = active mesh (the `mesh` arg to
                                            /// snapCursor); 1..N = the background
                                            /// source `snapSource(targetSource)`
                                            /// (layers Stage 5). Default 0 ⇒ the
                                            /// single-layer / active-only path is
                                            /// byte-identical to pre-Stage-5: every
                                            /// winner is from slot 0 and reads as
                                            /// "active mesh".
    // Stage 2: constraint tier. Populated only when a constraint (LINE/PLANE)
    // produced the snapped position (the discrete tier did not snap). When the
    // discrete tier snapped, this stays None. The constraint owns the position
    // (worldPos) while targetType/targetIndex/highlightPos stay the discrete
    // highlight's (or None/-1 if no discrete highlight exists).
    SnapType constraintType = SnapType.None;
}

/// Config-equality for two SnapPackets — compares only the user-facing CONFIG
/// fields (the ones SnapStage.snapshotConfigToPacket round-trips), NOT the
/// derived workplane cache / gridStep (evaluate() re-derives those each frame
/// from the upstream WORK stage, so they would spuriously differ). Used by the
/// transform wrapper's refire trigger (P-C) to detect a mid-run snap-config
/// change, mirroring falloffPacketsEqual.
bool snapPacketsEqual(const ref SnapPacket a, const ref SnapPacket b)
    pure nothrow @nogc @safe
{
    return a.enabled       == b.enabled
        && a.enabledTypes  == b.enabledTypes
        && a.snapScope     == b.snapScope
        && a.innerRangePx  == b.innerRangePx
        && a.outerRangePx  == b.outerRangePx
        && a.fixedGrid     == b.fixedGrid
        && a.fixedGridSize == b.fixedGridSize;
}

// ---------------------------------------------------------------------------
// Background snap sources (layers Stage 5).
//
// `snapCursor` always treats the `mesh` argument as snap SOURCE 0 (the active
// layer) — that path is unchanged byte-for-byte. In a multi-layer document the
// app installs the *visible && background* layers' meshes here each frame, and
// snapCursor walks them as additional sources AFTER the active mesh. With a
// single-layer document (or any document with no visible background layer) this
// array is empty, so the extra-source loop never runs and the result is
// identical to pre-Stage-5.
//
// The candidate grids (below) are keyed per source SLOT so two layers' grids
// can never alias even when their meshes happen to share a mutationVersion —
// the address term added in Stage 2 is the additional belt-and-braces guard.
//
// Set on the main thread once per frame; read by snapCursor on either the main
// thread (interactive drags) or the HTTP server thread (`/api/snap` bridge), so
// the same g_vgridMutex that guards the grids guards the source list.
private __gshared const(Mesh)*[] g_snapSources;

/// Install the background snap sources (the *visible && background* layers'
/// meshes). The active mesh is NOT included — it is always source 0 via the
/// `mesh` argument to snapCursor. Pass an empty slice (or never call this) for
/// the single-layer common case. Copies into an owned buffer so the caller's
/// slice need not outlive the frame.
void setBackgroundSnapSources(const(Mesh)*[] sources) {
    synchronized (g_vgridMutex) {
        g_snapSources.length = sources.length;
        foreach (i, s; sources) g_snapSources[i] = s;
    }
}

/// Resolve a `SnapResult.targetSource` slot back to its source mesh, so the
/// snap highlight renderer can draw the target element against the geometry it
/// actually came from (layers Stage 5).
///
///   slot == 0      ⇒ null. Slot 0 is the active mesh, which is NOT held here
///                    (it is the `mesh` argument to snapCursor); the caller
///                    supplies it directly. Returning null keeps this accessor
///                    purely about the background sources.
///   slot 1..N      ⇒ `g_snapSources[slot-1]`, the SAME ordering the walk
///                    assigned (slot i+1 = the i-th visible-background source
///                    installed by setBackgroundSnapSources, which app.d fills
///                    in document-layer index order). Out of range ⇒ null.
///
/// Bounds-checked and fail-soft: any miss (the source list shrank between the
/// motion event that produced the result and this draw, e.g. a background layer
/// was hidden) returns null so the highlight is harmlessly skipped — the same
/// posture as the renderer's out-of-range index guard. Reads under g_vgridMutex
/// (the same lock setBackgroundSnapSources and the query path take); called on
/// the main thread by the renderer.
const(Mesh)* snapSource(int slot) {
    if (slot <= 0) return null;
    synchronized (g_vgridMutex) {
        size_t i = cast(size_t)(slot - 1);
        if (i >= g_snapSources.length) return null;
        return g_snapSources[i];
    }
}

// ---------------------------------------------------------------------------
// Item snap frames (Stage 3). One frame per visible layer, INCLUDING the
// active/primary layer (item snapping deliberately snaps to the active item's
// own pivot/box — unlike setBackgroundSnapSources which skips the primary).
//
// Install shape mirrors setBackgroundSnapSources exactly: the setItemSnapFrames
// CALL is unconditional every frame (app.d, next to setBackgroundSnapSources)
// so a /api/reset that collapses the document to one layer self-clears the
// prior test's multi-layer frames. Only the slice-fill loop may early-out.
// ---------------------------------------------------------------------------

/// Per-layer (item) snap frame: world pivot point + world-space AABB.
/// World pivot = layer.xform.pos + layer.xform.pivot (from composedMatrix
/// derivation — M = T(pos)·T(pivot)·R·S·T(-pivot) maps local pivot → pos+pivot).
/// World AABB = AABB of the 8 composedMatrix-transformed local AABB corners.
struct ItemSnapFrame {
    Vec3 pivot;              ///< world-space pivot point
    Vec3 bboxMin;            ///< world-space AABB min (only valid when hasBBox)
    Vec3 bboxMax;            ///< world-space AABB max (only valid when hasBBox)
    bool hasBBox;            ///< false when the layer mesh has no vertices
}

// Guarded by the same g_vgridMutex as g_snapSources.
private __gshared ItemSnapFrame[] g_itemSnapFrames;

/// Install the item snap frames for all visible layers. Unlike
/// setBackgroundSnapSources, this includes the active/primary layer.
/// Pass an empty slice for a document with no visible layers (unusual).
/// Copies into an owned buffer so the caller's slice need not outlive the call.
void setItemSnapFrames(ItemSnapFrame[] frames) {
    synchronized (g_vgridMutex) {
        g_itemSnapFrames.length = frames.length;
        foreach (i, ref f; frames) g_itemSnapFrames[i] = f;
    }
}

// ---------------------------------------------------------------------------
// Scope filter (Stage 5). Total predicate over all SnapType values.
// Component bucket: Vertex|Edge|EdgeCenter|Polygon|PolyCenter|Intersection.
// Item bucket:      Pivot|Box.
// Scope-independent (always eligible): Grid|Workplane|WorldAxis|
//                                      StraightLine|RightAngle.
// Under Global all types pass; under Component only Component + guides;
// under Item only Item + guides.
// ---------------------------------------------------------------------------
bool typeEligible(SnapType t, SnapMode snapScope_)
    pure nothrow @nogc @safe
{
    // Scope-independent guides pass in every mode.
    if (t == SnapType.Grid        || t == SnapType.Workplane   ||
        t == SnapType.WorldAxis   || t == SnapType.StraightLine ||
        t == SnapType.RightAngle)
        return true;

    bool isComponent = (t == SnapType.Vertex    || t == SnapType.Edge        ||
                        t == SnapType.EdgeCenter || t == SnapType.Polygon     ||
                        t == SnapType.PolyCenter || t == SnapType.Intersection);
    bool isItem      = (t == SnapType.Pivot      || t == SnapType.Box);

    final switch (snapScope_) {
        case SnapMode.Global:    return true;
        case SnapMode.Component: return isComponent;
        case SnapMode.Item:      return isItem;
    }
}

/// Return a point-in-time copy of the background snap sources under the
/// grid lock, for use by the CONS stage's post-pass projection loop
/// (xfrm_transform.d::applyTRS). Reuses the same g_snapSources the snap
/// walk uses — no separate CONS registry, no leak class.
///
/// Returns null / empty slice when there are no background layers, so the
/// caller's `sources.length == 0` early-out produces a no-op in the
/// single-layer common case.
const(Mesh)*[] backgroundSourcesSnapshot() {
    synchronized (g_vgridMutex) {
        if (g_snapSources.length == 0) return null;
        return g_snapSources.dup;
    }
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
    res.targetSource = 0;
    if (!cfg.enabled) return res;

    // -----------------------------------------------------------------------
    // Two-tier accumulators (Stage 2 / D2).
    //
    // DISCRETE tier: existing geometric types (Vertex/Edge/EdgeCenter/Polygon/
    // PolyCenter) + new point types (Pivot/Box corners/Intersection) + the
    // Grid and Workplane (which stay in the discrete tier per D2).
    //
    // CONSTRAINT tier: LINE (WorldAxis, StraightLine) and PLANE (box face-
    // planes, RightAngle) constraints. Populated only when the discrete tier
    // did NOT snap (D2 rule: discrete beats constraint).
    //
    // Workplane is INTENTIONALLY EXEMPT from the constraint tier and stays
    // in the discrete tier (it keeps its always-wins behaviour; its distance
    // to the cursor pixel is ~0, so it beats everything in the discrete walk).
    // -----------------------------------------------------------------------

    // Discrete tier accumulator.
    float    bestDist   = float.infinity;
    Vec3     bestWorld  = cursorWorld;
    int      bestIdx    = -1;
    int      bestSource = 0;
    SnapType bestType   = SnapType.None;

    // Constraint tier accumulator (Stage 2).
    float    cBestDist  = float.infinity;
    Vec3     cBestWorld = cursorWorld;
    SnapType cBestType  = SnapType.None;

    // `slot` identifies which snap SOURCE this candidate came from (0 = active
    // mesh, 1..N = background source). It is recorded on the winner so the
    // highlight renderer can resolve the element against the right mesh — a
    // source-local index alone is ambiguous across layers (layers Stage 5).
    void consider(Vec3 candWorld, int idx, SnapType type, int slot) {
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
            bestDist   = d;
            bestWorld  = candWorld;
            bestIdx    = idx;
            bestSource = slot;
            bestType   = type;
        }
    }

    // Constraint-tier consider — same screen-distance check but into a
    // separate accumulator. Constraints own POSITION only; targetType/
    // targetIndex/highlightPos stay the discrete tier's (Stage 2 merge rule).
    void considerConstraint(Vec3 candWorld, SnapType type) {
        float pxs, pys, ndcZ;
        if (!projectToWindowFull(candWorld, vp, pxs, pys, ndcZ)) return;
        float dx = pxs - cast(float)sx;
        float dy = pys - cast(float)sy;
        float d  = sqrt(dx * dx + dy * dy);
        if (d > cfg.outerRangePx) return;
        if (d < cBestDist) {
            cBestDist  = d;
            cBestWorld = candWorld;
            cBestType  = type;
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
    // Shared visibility gate (front-facing + unoccluded), computed once per
    // call and consulted by every GEOMETRIC snap type so snap never cements to
    // hidden back-facing / occluded geometry (the reported "snaps to invisible
    // vertex" bug, and the same hole for edges / centers / faces). It's the
    // CPU front-facing + occlusion test the selection path used before the GPU
    // id-buffer. Empty when the mesh has no faces (nothing can occlude) so
    // point/edge-only geometry snaps unfiltered.
    // Per-source geometric candidate walk (layers Stage 5). `slot` keys this
    // source's candidate grids so two layers' grids never alias; `exclude`
    // is the dragged-vertex set (active source only — a background layer is
    // never being dragged, so it passes an empty exclude). The body is the
    // pre-Stage-5 walk verbatim, parameterised on the mesh + grid slot.
    void walkSource(const ref Mesh m, int slot, const(uint)[] exclude) {
        // Visibility array for occlusion/front-face gating. Built when any
        // geometric type is enabled (faces present + at least one geo type active).
        bool[] vis;
        bool needVis = m.faces.length > 0
            && (cfg.enabledTypes & (SnapType.Vertex | SnapType.Edge
                  | SnapType.EdgeCenter | SnapType.Polygon | SnapType.PolyCenter
                  | SnapType.Intersection));
        if (needVis) vis = m.visibleVertices(vp.eye, vp);

        bool vertVisible(uint vi) {
            return vis.length == 0 || (vi < vis.length && vis[vi]);
        }
        bool edgeVisible(uint a, uint b) {
            return vis.length == 0
                || (a < vis.length && b < vis.length && vis[a] && vis[b]);
        }
        bool faceVisible(const(uint)[] face) {
            if (vis.length == 0) return true;
            if (face.length < 3) return false;
            Vec3 fn = cross(m.vertices[face[1]] - m.vertices[face[0]],
                            m.vertices[face[2]] - m.vertices[face[0]]);
            if (dot(fn, m.vertices[face[0]] - vp.eye) >= 0) return false;
            foreach (v; face) if (v >= vis.length || !vis[v]) return false;
            return true;
        }

        if ((cfg.enabledTypes & SnapType.Vertex)
                && typeEligible(SnapType.Vertex, cfg.snapScope)) {
            auto cands = queryCandidateGrid(Kind.Vertex, slot, m, vp, sx, sy,
                                            cfg.outerRangePx, exclude);
            foreach (vi; cands)
                if (vertVisible(vi))
                    consider(m.vertices[vi], cast(int)vi, SnapType.Vertex, slot);
        }

        if ((cfg.enabledTypes & SnapType.Edge)
                && typeEligible(SnapType.Edge, cfg.snapScope)) {
            auto cands = queryCandidateGrid(Kind.Edge, slot, m, vp, sx, sy,
                                            cfg.outerRangePx, exclude);
            foreach (ei; cands) {
                auto edge = m.edges[ei];
                if (!edgeVisible(edge[0], edge[1])) continue;
                float px0, py0, ndcZ0, px1, py1, ndcZ1;
                Vec3 a = m.vertices[edge[0]];
                Vec3 b = m.vertices[edge[1]];
                if (!projectToWindowFull(a, vp, px0, py0, ndcZ0)) continue;
                if (!projectToWindowFull(b, vp, px1, py1, ndcZ1)) continue;
                float t;
                closestOnSegment2DSquared(cast(float)sx, cast(float)sy,
                                           px0, py0, px1, py1, t);
                consider(a + (b - a) * t, cast(int)ei, SnapType.Edge, slot);
            }
        }

        if ((cfg.enabledTypes & SnapType.EdgeCenter)
                && typeEligible(SnapType.EdgeCenter, cfg.snapScope)) {
            auto cands = queryCandidateGrid(Kind.EdgeCenter, slot, m, vp, sx, sy,
                                            cfg.outerRangePx, exclude);
            foreach (ei; cands) {
                auto edge = m.edges[ei];
                if (!edgeVisible(edge[0], edge[1])) continue;
                Vec3 mid = (m.vertices[edge[0]] + m.vertices[edge[1]]) * 0.5f;
                consider(mid, cast(int)ei, SnapType.EdgeCenter, slot);
            }
        }

        if ((cfg.enabledTypes & SnapType.Polygon)
                && typeEligible(SnapType.Polygon, cfg.snapScope)) {
            auto cands = queryCandidateGrid(Kind.Polygon, slot, m, vp, sx, sy,
                                            cfg.outerRangePx, exclude);
            foreach (fi; cands) {
                auto face = m.faces[fi];
                if (!faceVisible(face)) continue;
                Vec3 hit;
                if (closestOnPolygonSurface(face, m, sx, sy, vp, hit))
                    consider(hit, cast(int)fi, SnapType.Polygon, slot);
            }
        }

        if ((cfg.enabledTypes & SnapType.PolyCenter)
                && typeEligible(SnapType.PolyCenter, cfg.snapScope)) {
            auto cands = queryCandidateGrid(Kind.PolyCenter, slot, m, vp, sx, sy,
                                            cfg.outerRangePx, exclude);
            foreach (fi; cands) {
                auto face = m.faces[fi];
                if (face.length == 0) continue;
                if (!faceVisible(face)) continue;
                consider(m.faceCentroid(cast(uint)fi), cast(int)fi, SnapType.PolyCenter, slot);
            }
        }

        // Stage 6: Intersection — screen-space edge crossings (discrete tier).
        // Pairs of mesh edges that share no vertex and cross in screen space.
        // World point = midpoint of the two edges at their crossing parameters.
        // Restricted to the near-cursor edge set (same grid as Edge type) for
        // O(near²) cost. Deterministic lowest-(eiA,eiB) tie-break via ascending
        // iteration + consider()'s strict-< distance accumulator.
        if ((cfg.enabledTypes & SnapType.Intersection)
                && typeEligible(SnapType.Intersection, cfg.snapScope)) {
            auto cands = queryCandidateGrid(Kind.Edge, slot, m, vp, sx, sy,
                                            cfg.outerRangePx, exclude);
            for (size_t ia = 0; ia < cands.length; ++ia) {
                int eiA = cands[ia];
                auto edgeA = m.edges[eiA];
                if (!edgeVisible(edgeA[0], edgeA[1])) continue;
                float pxA0, pyA0, ndcA0, pxA1, pyA1, ndcA1;
                Vec3 a0 = m.vertices[edgeA[0]], a1 = m.vertices[edgeA[1]];
                if (!projectToWindowFull(a0, vp, pxA0, pyA0, ndcA0)) continue;
                if (!projectToWindowFull(a1, vp, pxA1, pyA1, ndcA1)) continue;

                for (size_t ib = ia + 1; ib < cands.length; ++ib) {
                    int eiB = cands[ib];
                    auto edgeB = m.edges[eiB];
                    // Skip pairs sharing a vertex.
                    if (edgeB[0] == edgeA[0] || edgeB[0] == edgeA[1] ||
                        edgeB[1] == edgeA[0] || edgeB[1] == edgeA[1]) continue;
                    if (!edgeVisible(edgeB[0], edgeB[1])) continue;
                    float pxB0, pyB0, ndcB0, pxB1, pyB1, ndcB1;
                    Vec3 b0 = m.vertices[edgeB[0]], b1 = m.vertices[edgeB[1]];
                    if (!projectToWindowFull(b0, vp, pxB0, pyB0, ndcB0)) continue;
                    if (!projectToWindowFull(b1, vp, pxB1, pyB1, ndcB1)) continue;

                    // 2D segment-segment intersection test.
                    float dAx = pxA1 - pxA0, dAy = pyA1 - pyA0;
                    float dBx = pxB1 - pxB0, dBy = pyB1 - pyB0;
                    float wx  = pxB0 - pxA0, wy  = pyB0 - pyA0;
                    float denom = dAx * dBy - dAy * dBx;
                    import std.math : fabs;
                    if (fabs(denom) < 1e-6f) continue; // parallel
                    float tA = (wx * dBy - wy * dBx) / denom;
                    float tB = (wx * dAy - wy * dAx) / denom;
                    if (tA < 0 || tA > 1 || tB < 0 || tB > 1) continue;

                    Vec3 wA    = a0 + (a1 - a0) * tA;
                    Vec3 wB    = b0 + (b1 - b0) * tB;
                    Vec3 world = (wA + wB) * 0.5f;
                    consider(world, eiA, SnapType.Intersection, slot);
                }
            }
        }
    }

    // Source 0 = the active layer (with the dragged-vertex exclusion).
    // Single-layer / no-visible-background documents stop here, byte-identical
    // to pre-Stage-5.
    walkSource(mesh, 0, excludeVerts);

    // Sources 1..N = the visible background layers (layers Stage 5). A
    // background layer is never being dragged, so it carries no exclusion; its
    // grids live in slots 1.. so they never alias the active grid.
    //
    // Snapshot the source-list under the lock into a local, then walk OUTSIDE
    // the lock: queryCandidateGrid re-acquires g_vgridMutex (a non-recursive
    // Mutex), so calling walkSource while holding it would deadlock. The
    // snapshot is empty in the single-layer common case ⇒ no extra work.
    const(Mesh)*[] bgSources;
    synchronized (g_vgridMutex) {
        if (g_snapSources.length > 0)
            bgSources = g_snapSources.dup;
    }
    foreach (i, src; bgSources)
        if (src !is null)
            walkSource(*src, cast(int)(i + 1), null);

    // Grid candidate (7.3c). Scope-independent.
    if (cfg.enabledTypes & SnapType.Grid) {
        Vec3 snapOrig1, ray;
        screenPointToRay(cast(float)sx, cast(float)sy, vp, snapOrig1, ray);
        Vec3 hit;
        if (rayPlaneIntersect(snapOrig1, ray,
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
            consider(snapped, -1, SnapType.Grid, 0);
        }
    }

    // Workplane candidate (7.3c). Stays in discrete tier (always-wins;
    // intentionally EXEMPT from the discrete-beats-constraint rule — D2).
    if (cfg.enabledTypes & SnapType.Workplane) {
        Vec3 snapOrig2, ray;
        screenPointToRay(cast(float)sx, cast(float)sy, vp, snapOrig2, ray);
        Vec3 hit;
        if (rayPlaneIntersect(snapOrig2, ray,
                              cfg.workplaneCenter, cfg.workplaneNormal, hit))
            consider(hit, -1, SnapType.Workplane, 0);
    }

    // -----------------------------------------------------------------------
    // Stage 3: Pivot point targets — from item snap frames (discrete tier).
    // Item frames are installed per-frame by app.d and just-in-time by
    // the /api/snap provider. Scope: Item bucket (+ Global).
    // -----------------------------------------------------------------------
    if ((cfg.enabledTypes & SnapType.Pivot)
            && typeEligible(SnapType.Pivot, cfg.snapScope)) {
        ItemSnapFrame[] frames;
        synchronized (g_vgridMutex) {
            if (g_itemSnapFrames.length > 0)
                frames = g_itemSnapFrames.dup;
        }
        foreach (fi, ref frame; frames)
            consider(frame.pivot, cast(int)fi, SnapType.Pivot, 0);
    }

    // -----------------------------------------------------------------------
    // Stage 4: Box corners (discrete tier) + face planes (constraint tier).
    // Corners = 8 AABB corner points. Face planes = 6 axis-aligned planes.
    // Scope: Item bucket (+ Global).
    // -----------------------------------------------------------------------
    if ((cfg.enabledTypes & SnapType.Box)
            && typeEligible(SnapType.Box, cfg.snapScope)) {
        ItemSnapFrame[] frames;
        synchronized (g_vgridMutex) {
            if (g_itemSnapFrames.length > 0)
                frames = g_itemSnapFrames.dup;
        }
        Vec3 snapOrig3, ray;
        screenPointToRay(cast(float)sx, cast(float)sy, vp, snapOrig3, ray);

        foreach (ref frame; frames) {
            if (!frame.hasBBox) continue;
            Vec3 mn = frame.bboxMin, mx = frame.bboxMax;

            // 8 AABB corners — discrete tier.
            Vec3[8] corners = [
                Vec3(mn.x, mn.y, mn.z), Vec3(mx.x, mn.y, mn.z),
                Vec3(mn.x, mx.y, mn.z), Vec3(mx.x, mx.y, mn.z),
                Vec3(mn.x, mn.y, mx.z), Vec3(mx.x, mn.y, mx.z),
                Vec3(mn.x, mx.y, mx.z), Vec3(mx.x, mx.y, mx.z),
            ];
            foreach (ci, c; corners)
                consider(c, cast(int)ci, SnapType.Box, 0);

            // 6 axis-aligned face planes — constraint tier.
            // Centers and inward-pointing normals for the 6 AABB faces.
            float mxm = (mn.x + mx.x) * 0.5f;
            float mym = (mn.y + mx.y) * 0.5f;
            float mzm = (mn.z + mx.z) * 0.5f;
            Vec3[6] fpC = [
                Vec3(mn.x, mym,  mzm),  Vec3(mx.x, mym,  mzm),
                Vec3(mxm,  mn.y, mzm),  Vec3(mxm,  mx.y, mzm),
                Vec3(mxm,  mym,  mn.z), Vec3(mxm,  mym,  mx.z),
            ];
            Vec3[6] fpN = [
                Vec3(-1, 0, 0), Vec3(1, 0, 0),
                Vec3( 0,-1, 0), Vec3(0, 1, 0),
                Vec3( 0, 0,-1), Vec3(0, 0, 1),
            ];
            foreach (fpi; 0 .. 6) {
                Vec3 hit;
                if (rayPlaneIntersect(snapOrig3, ray, fpC[fpi], fpN[fpi], hit))
                    considerConstraint(hit, SnapType.Box);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Stage 2: WorldAxis LINE constraints (constraint tier).
    // Three infinite lines through origin along world X, Y, Z.
    // Scope-independent (pass in all scope modes).
    //
    // vibe3d-divergence: this path anchors the lines at world origin (0,0,0),
    // making it a transform-tool-scoped constraint available under any tool
    // that calls snapCursor with the WorldAxis bit. The reference scopes
    // worldAxis to Pen (and Mirror), anchored on the PRIOR vertex; that
    // Pen-scoped variant lives in source/tools/pen.d (applyPenGuide). Both
    // paths coexist: Pen suppresses this bit via snapLocalHit's excludeTypes
    // so origin-based and prior-vertex-based worldAxis never double-apply.
    // -----------------------------------------------------------------------
    if ((cfg.enabledTypes & SnapType.WorldAxis)
            && typeEligible(SnapType.WorldAxis, cfg.snapScope)) {
        Vec3 snapOrig4, ray;
        screenPointToRay(cast(float)sx, cast(float)sy, vp, snapOrig4, ray);
        immutable Vec3[3] axes = [Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1)];
        immutable Vec3 origin  = Vec3(0, 0, 0);
        foreach (ax; axes) {
            Vec3 hit = closestPointOnLineToRay(origin, ax, snapOrig4, ray);
            considerConstraint(hit, SnapType.WorldAxis);
        }
    }

    // -----------------------------------------------------------------------
    // Stage 2: Result merge rule (D2).
    //
    // Priority: discrete snap > constraint snap > discrete highlight only.
    // Workplane (always-wins by ~0 screen distance) is in the discrete tier
    // so it keeps its existing behaviour unchanged.
    // -----------------------------------------------------------------------
    bool discreteSnapped     = bestDist  <= cfg.innerRangePx;
    bool discreteHighlighted = bestDist  <= cfg.outerRangePx;
    bool constraintSnapped   = cBestDist <= cfg.innerRangePx;

    if (discreteSnapped) {
        // Discrete wins entirely — byte-identical to pre-Stage-2 for the
        // existing 7 targets (position + highlight + targetType/Index/Source).
        res.snapped      = true;
        res.worldPos     = bestWorld;
        res.highlighted  = true;
        res.highlightPos = bestWorld;
        res.targetType   = bestType;
        res.targetIndex  = bestIdx;
        res.targetSource = bestSource;
        // res.constraintType stays None
    } else if (constraintSnapped) {
        // Constraint provides the position; discrete highlight (if any) stays
        // for visual feedback — the user sees the nearby element hinted at.
        res.snapped        = true;
        res.worldPos       = cBestWorld;
        res.constraintType = cBestType;
        if (discreteHighlighted) {
            res.highlighted  = true;
            res.highlightPos = bestWorld;
            res.targetType   = bestType;
            res.targetIndex  = bestIdx;
            res.targetSource = bestSource;
        }
        // When no discrete highlight: targetType stays None, constraintType
        // carries the identity of what constrained the position.
    } else if (discreteHighlighted) {
        // Discrete only highlighted (not snapped) — no constraint snap.
        res.highlighted  = true;
        res.highlightPos = bestWorld;
        res.targetType   = bestType;
        res.targetIndex  = bestIdx;
        res.targetSource = bestSource;
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
        Vec3 snapOrig5, ray;
        screenPointToRay(cast(float)sx, cast(float)sy, vp, snapOrig5, ray);
        return rayPlaneIntersect(snapOrig5, ray, v0, n, worldHit);
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
    // Mesh ADDRESS is part of the key (layers Stage 2): two different layers'
    // meshes can sit at the same `mutationVersion` (e.g. right after a
    // layer.select swaps the snap source with no intervening mutation, or when
    // an undo reverts a background layer back to a version another layer also
    // holds). With one layer this term is constant ⇒ invisible. `size_t.max`
    // forces a rebuild on first use.
    size_t meshAddr = size_t.max;
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

// One grid set (Kind.max+1 grids) PER SNAP SOURCE SLOT (layers Stage 5).
// Slot 0 is the active layer; slots 1.. are the visible background layers. The
// outer array grows on demand as more sources appear; in the single-layer
// common case it has exactly one row, so the layout is the pre-Stage-5
// `g_grids[Kind]` with one extra level of indirection that never reallocates.
private alias GridSet = CandidateGrid[Kind.max + 1];
private __gshared GridSet[] g_gridSets;
private __gshared Mutex      g_vgridMutex;

shared static this() {
    g_vgridMutex = new Mutex();
    g_gridSets.length = 1;   // slot 0 (active) always present
}

// Return the grid for (slot, kind), growing the slot table as needed. Caller
// holds g_vgridMutex.
private CandidateGrid* gridFor(int slot, Kind k) {
    if (slot >= g_gridSets.length)
        g_gridSets.length = slot + 1;
    return &g_gridSets[slot][k];
}

/// Force every snap candidate grid to rebuild on next query. Belt-and-braces
/// companion to the address-keyed staleness check (layers Stage 2): the
/// active-layer-switch hook calls this so a grid built against the prior
/// layer is never reused. The address key in CandidateGrid is the PRIMARY
/// defense (it also covers undo re-populating a background layer's colliding
/// key); this blanket drop is the secondary one. Stage 5: this now drops every
/// source slot's grids, not just the active one.
void invalidateSnapGrids() {
    synchronized (g_vgridMutex)
        foreach (ref set; g_gridSets)
            foreach (ref g; set) g.valid = false;
}

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
            return accumulate(mesh.faceCentroid(cast(uint)idx));
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
private void buildCandidateGrid(Kind k, int slot, const ref Mesh mesh,
                                const ref Viewport vp, float cellPx) {
    auto g = gridFor(slot, k);
    g.meshAddr    = cast(size_t)&mesh;
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
private int[] queryCandidateGrid(Kind k, int slot, const ref Mesh mesh,
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

    auto g = gridFor(slot, k);

    // (Re)build if stale.
    if (!g.valid
     || g.meshAddr    != cast(size_t)&mesh
     || g.meshVersion != mesh.mutationVersion
     || g.elemCount   != n
     || g.cellPx      != outerRangePx
     || !sameViewport(*g, vp)) {
        buildCandidateGrid(k, slot, mesh, vp, outerRangePx);
        g = gridFor(slot, k);   // table may have reallocated on grow
    }

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
