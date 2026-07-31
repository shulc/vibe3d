module snap;

import std.math : sqrt, round, floor, isNaN;
import core.sync.mutex : Mutex;

import math : Vec3, Viewport, projectToWindowFull, screenRay, screenPointToRay,
              rayPlaneIntersect, pointInPolygon2D,
              closestOnSegment2DSquared, cross, dot,
              closestPointOnLineToRay;
import mesh : Mesh;
import toolpipe.packets : SnapPacket, SnapType, SnapMode;
import toolpipe.guide   : SnapGuide, kGuidePrioritySeed;
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

// Parallel array (topology-pen P0 NIT-3): g_snapSourceLayers[i] is the
// Document-layer index (document.layers[N]) that g_snapSources[i] came
// from. Filled by the SAME call that installs g_snapSources — snap.d stays
// Document-free itself (it only stores plain ints), while the CONS stage's
// background raycast can resolve a bgSrc-order slot back to a real
// Document-layer index without either module importing `document`.
private __gshared int[] g_snapSourceLayers;

/// Install the background snap sources (the *visible && background* layers'
/// meshes). The active mesh is NOT included — it is always source 0 via the
/// `mesh` argument to snapCursor. Pass an empty slice (or never call this) for
/// the single-layer common case. Copies into an owned buffer so the caller's
/// slice need not outlive the frame.
///
/// `layerIndices`, when non-empty, must be the same length as `sources` —
/// `layerIndices[i]` is the Document-layer index `sources[i]` was read from
/// (app.d/panels.d fill this in document-layer index order, skipping
/// foreground/invisible layers, so it is generally NOT `i` itself). Callers
/// that don't track indices (or don't need the mapping) may omit it; the
/// mapping then reads back empty and consumers fall back to the bgSrc-order
/// index (see `backgroundSourceLayerIndices()`).
void setBackgroundSnapSources(const(Mesh)*[] sources, const(int)[] layerIndices = null) {
    synchronized (g_vgridMutex) {
        g_snapSources.length = sources.length;
        foreach (i, s; sources) g_snapSources[i] = s;
        g_snapSourceLayers.length = layerIndices.length;
        foreach (i, li; layerIndices) g_snapSourceLayers[i] = li;
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

/// Point-in-time copy of the Document-layer index parallel to
/// `backgroundSourcesSnapshot()` (topology-pen P0 NIT-3) — index i of this
/// array is the Document-layer index `backgroundSourcesSnapshot()[i]` was
/// installed from. May be SHORTER than (or empty relative to) the sources
/// snapshot when the installer didn't supply indices; callers must
/// bounds-check and fall back to the bgSrc-order index on a miss.
const(int)[] backgroundSourceLayerIndices() {
    synchronized (g_vgridMutex) {
        if (g_snapSourceLayers.length == 0) return null;
        return g_snapSourceLayers.dup;
    }
}

/// A client's per-candidate admission rule. Returns false to REJECT the
/// candidate before the distance compare — the client's policy layered over
/// the service's enumeration.
///
/// This is the seam that keeps "which elements are eligible" out of
/// `snapCursor`. The enumeration (which grids to query, how a candidate
/// projects, how the winner is ranked) belongs to this module and is shared
/// by every caller; the *admission* rule is the caller's, and differs
/// between them — a tool that welds only to border vertices and a tool that
/// welds to any vertex want the same walk and different eligibility.
/// Without this parameter such a rule has nowhere to live but a
/// reimplemented candidate loop inside the tool.
///
/// Arguments are the candidate's discrete `type`, its source-local element
/// index (`idx`; -1 where the candidate is not a mesh element — Grid,
/// Workplane, and every constraint candidate) and its source `slot`
/// (0 = active mesh, 1..N = background source, as `SnapResult.targetSource`).
///
/// `nothrow`: the walk runs inside a `synchronized`-adjacent hot path and
/// must not unwind through it; a predicate that needs to fail should reject.
alias SnapAdmit = bool delegate(SnapType type, int idx, int slot) nothrow;

/// Snap the world position `cursorWorld` corresponding to screen pixel
/// (sx, sy) according to `cfg`. `excludeVerts` lists vertex indices
/// the candidate walk must skip — typically the dragged element's own
/// indices, so a single-vert drag doesn't snap to itself (zero
/// distance). Returns the input pass-through when `cfg.enabled` is
/// false (no candidates considered).
///
/// `admit`, when non-null, is consulted once per enumerated candidate and
/// rejects it BEFORE the projection + distance compare — a rejected
/// candidate cannot win, cannot highlight, and cannot shrink the accumulator
/// that a later candidate must beat. A null `admit` (the default) admits
/// everything, so every call site that does not pass one takes exactly the
/// pre-existing path.
///
/// `guides`, when non-empty, replaces "nearest wins" with "(priority,
/// distance) wins" — see `arbitrate` inside. An EMPTY `guides` (the default)
/// leaves every candidate at priority 0 and its own screen distance, which is
/// the pre-existing ranking exactly; this is S4(a)'s neutrality argument
/// (technique N4 of doc/toolpipe_architecture_plan.md) and it is a statement
/// about reachability, not about agreement. That the two paths also AGREE,
/// for a guide that mirrors the distance rule, is proved by the unittest at
/// the bottom of this module, because that agreement is what phase (b) rests
/// on.
SnapResult snapCursor(Vec3 cursorWorld, int sx, int sy,
                      const ref Viewport vp,
                      const ref Mesh mesh,
                      const ref SnapPacket cfg,
                      const(uint)[] excludeVerts = null,
                      scope SnapAdmit admit = null,
                      scope SnapGuide[] guides = null)
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

    // ------------------------------------------------------------------
    // S4(a): the guide arbitration's half of the accumulator.
    //
    // `int.min` is the "nothing accumulated yet" sentinel, and it is chosen so
    // that the generalised comparison below REDUCES to the historical one when
    // no guide is registered, rather than merely agreeing with it:
    //
    //   with `guides` empty every candidate carries `prio == 0`, so
    //     first candidate : 0 > int.min                 -> accept
    //                       (old: d < float.infinity    -> accept)
    //     later candidates: 0 == 0 && d < bestDist      -> compare distance
    //                       (old: d < bestDist          -> compare distance)
    //
    // Those are the same two decisions, not two decisions that happen to
    // coincide on this fixture. A `bestPrio` initialised to 0 instead would
    // have silently dropped the first candidate whenever a guide returned a
    // negative priority, which is exactly the class of bug an "empty registry"
    // stage cannot catch by running.
    // ------------------------------------------------------------------
    int bestPrio  = int.min;
    int cBestPrio = int.min;

    // Ask the registered guides about one enumerated candidate. Returns false
    // when NO guide admits it, in which case the candidate is dropped as if it
    // had never been enumerated (the same contract `admit` has). When several
    // guides admit it, the HIGHEST-priority answer supplies both the ranking
    // distance and the priority; equal priorities are settled by registration
    // order (strict `>`), which is the only tie-break the registry can offer.
    //
    // The rule is now READ rather than header-derived: priority strictly
    // dominates, distance breaks ties only WITHIN one priority, and the
    // environment PRE-SEEDS the priority slot before every call — see
    // `kGuidePrioritySeed`, which is why `gp` below is seeded and not left to
    // the zero an `out` parameter would have supplied.
    //
    // The guide re-RANKS a candidate; it never introduces one. `candWorld`,
    // `type`, `idx` and `slot` are the enumeration's, and the winner's world
    // position is still the candidate's own — a guide that answers with a
    // different distance changes WHICH candidate wins, never WHERE it is.
    // This is also the one arbitration detail we know about and have NOT
    // adopted: the reference's proximity answer is a per-axis write mask,
    // naming which of x/y/z the winning guide may overwrite. A mask needs a
    // guide that supplies a POSITION to mask, and ours supplies only a
    // ranking — so there is nothing here for the bits to select. If a guide
    // ever answers with a point of its own, that is when the mask becomes a
    // thing we are missing rather than a thing we have no use for.
    bool arbitrate(Vec3 candWorld, SnapType type, int idx, int slot,
                   ref float distPx, ref int prio)
    {
        bool admitted = false;
        foreach (g; guides) {
            float gd;
            int   gp = kGuidePrioritySeed;
            if (!g.proximity(candWorld, type, idx, slot, gd, gp)) continue;
            if (!admitted || gp > prio) {
                admitted = true;
                distPx   = gd;
                prio     = gp;
            }
        }
        return admitted;
    }

    // `slot` identifies which snap SOURCE this candidate came from (0 = active
    // mesh, 1..N = background source). It is recorded on the winner so the
    // highlight renderer can resolve the element against the right mesh — a
    // source-local index alone is ambiguous across layers (layers Stage 5).
    void consider(Vec3 candWorld, int idx, SnapType type, int slot) {
        // The client's admission rule runs FIRST — before the projection and
        // before the distance compare. Order is load-bearing, not stylistic:
        // rejecting after the compare would let an inadmissible candidate
        // lower `bestDist` and so silently veto an admissible one further
        // away. A rejected candidate must be as if it were never enumerated.
        if (admit !is null && !admit(type, idx, slot)) return;
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
        // S4(a): the guide arbitration. The gather cutoff above stays ahead of
        // it deliberately — the candidate GRID is queried with `outerRangePx`
        // in the first place, so a candidate outside the gather range is one
        // no guide could have been offered anyway, and applying the cutoff to
        // a guide-supplied distance would let the ranking value masquerade as
        // a range test.
        //
        // KNOWN DIFFERENCE, deliberate. The reference's guide loop drops a
        // candidate at the INNER range, not the outer one — it is a
        // position-snapping loop with no notion of "highlighted but not
        // snapped", so for it inner IS the only range that can reject. We
        // gather at outer so a candidate can highlight without winning, and
        // then apply inner at the merge, which is the same acceptance with an
        // extra state in front of it. A guide sees candidates ours would only
        // highlight; none of them can snap.
        //
        // UNREACHABLE in phase (a): `guides` is empty at every call site, so
        // `prio` stays 0 and the comparison below is the historical one.
        int prio = 0;
        if (guides.length != 0 && !arbitrate(candWorld, type, idx, slot, d, prio))
            return;
        if (prio > bestPrio || (prio == bestPrio && d < bestDist)) {
            bestDist   = d;
            bestPrio   = prio;
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
        // Same admission seam, same order (see `consider`). A constraint
        // candidate is a line/plane hit, not a mesh element, so it carries no
        // element index and no source: the predicate sees (type, -1, 0), the
        // same pair `SnapResult` would report for it.
        if (admit !is null && !admit(type, -1, 0)) return;
        float pxs, pys, ndcZ;
        if (!projectToWindowFull(candWorld, vp, pxs, pys, ndcZ)) return;
        float dx = pxs - cast(float)sx;
        float dy = pys - cast(float)sy;
        float d  = sqrt(dx * dx + dy * dy);
        if (d > cfg.outerRangePx) return;
        // Same guide arbitration, same order (see `consider`). Extending it to
        // the constraint tier is OURS and unmeasured — the two-tier split is
        // ours, the reference has no analogue of it — but the alternative is
        // worse in a nameable way: a guide whose whole job is an admission
        // rule would reject every discrete candidate and then watch a
        // constraint hit sail past it. Uniform beats surprising.
        int prio = 0;
        if (guides.length != 0 && !arbitrate(candWorld, type, -1, 0, d, prio))
            return;
        if (prio > cBestPrio || (prio == cBestPrio && d < cBestDist)) {
            cBestDist  = d;
            cBestPrio  = prio;
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
// element is excluded iff ANY of its incident verts is dragged — the
// source vert (Vertex) / either edge endpoint (EdgeCenter, Edge) / any
// face vert (PolyCenter, Polygon). See `kindExcluded` for why ANY and
// not ALL.
//
// THAT RULE IS ALSO WHAT KEEPS THIS CACHE HONEST, and it is the reason the
// two paragraphs sit together. The key holds `mesh.mutationVersion`, which an
// interactive drag deliberately does NOT bump (see mesh.d's uploadVersion
// note), so the grid built at drag start is reused for the whole gesture while
// the dragged verts move underneath it — every dragged element's stored
// projection is stale from the second frame on. That is sound for exactly one
// reason: a stale entry is an entry the query drops before the caller ever
// sees it. Under ANY, "moves with the drag" and "excluded" are the SAME
// predicate, so no stale entry can survive into a result and no result can be
// stale. (Under the previous ALL rule they were different predicates, and
// every partially-dragged element — an edge with one moving endpoint, a face
// with one moving corner — was both stale AND returned.) A future change that
// narrows the exclusion narrows this guarantee with it.
//
// The non-active sources cannot go stale at all: background layers are never
// being dragged, so they pass an empty exclude and their projections stay
// valid by construction (`walkSource(*src, i+1, null)`).
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

// Does element `idx` of kind `k` MOVE with the drag — i.e. is ANY of its
// incident verts in the dragged (excluded) set?
//
// ANY, not ALL, and the difference is the whole point. The exclusion exists
// so a drag cannot snap to its own geometry ("a single-vert drag always snaps
// to its own (zero-distance) projected pixel", `move.d:applySnapToDelta`). An
// ALL rule delivers that for exactly one type — Vertex, where "all incident
// verts" IS the vertex — and delivers nothing for any other:
//
//   • a single-vertex drag left the CENTROIDS of every incident edge and face
//     live as candidates, and those centroids are recomputed from the MOVING
//     coordinates on every frame, so they chase the drag at 1/2 and 1/n of its
//     speed and the gizmo is pulled after its own tail;
//   • with `Edge` enabled the closest point on an incident edge IS the dragged
//     endpoint, at ~0 px, so the snap answered with the drag's own anchor and
//     the drag froze.
//
// An element with one dragged vert is not a rigid neighbour that happens to be
// near — it is part of the thing being dragged, deformed rather than
// translated, and it is self-reference either way. So: any incident vert
// dragged ⇒ the element is not a candidate.
//
// The cost shape is unchanged: an O(1) per-vertex membership bitset (`ex`,
// indexed by vertex id) so a whole-mesh drag's huge exclude list doesn't turn
// each test into an O(exclude) scan — which would reintroduce the very O(n²)
// blowup the grid removes (esp. for edge/polygon, where many candidates are
// tested). ANY is in fact the cheaper of the two: it short-circuits on the
// FIRST dragged vert rather than having to prove every one of them.
//
// The whole-mesh case is unaffected: an empty selection makes the moving set
// every vertex (`mesh.selectedVertexIndices*`), where ANY and ALL agree.
private bool kindExcluded(Kind k, int idx, const ref Mesh mesh,
                          const bool[] ex) {
    if (ex.length == 0) return false;
    bool exV(uint vi) { return vi < ex.length && ex[vi]; }
    final switch (k) {
        case Kind.Vertex:
            return exV(cast(uint)idx);
        case Kind.EdgeCenter: case Kind.Edge: {
            auto e = mesh.edges[idx];
            return exV(e[0]) || exV(e[1]);
        }
        case Kind.PolyCenter: case Kind.Polygon: {
            auto f = mesh.faces[idx];
            foreach (vi; f)
                if (exV(vi)) return true;
            return false;
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

// ---------------------------------------------------------------------------
// Task 0401 — the vertex candidate grid must not serve a stale (pre-edit)
// bucket layout after a VERSION-SILENT position edit. An interactive gizmo
// Move/Rotate/Scale mutates vertex positions via `mesh.noteChange(Position)`
// WITHOUT ever bumping `mutationVersion` — both on drag AND on commit (see
// the warning above SubpatchPreview.deactivate() in mesh.d for why that is
// deliberate) — so the grid's (meshAddr, meshVersion, ...) staleness key
// alone cannot see the edit. Reproduces that exact version-silent path
// directly rather than the scripted `/api/transform` path (which DOES bump
// mutationVersion).
// ---------------------------------------------------------------------------
unittest {
    import mesh                      : makeCube;
    import change_bus                : MeshEditScope;
    import math                      : lookAt, perspectiveMatrix;
    import std.math                  : PI;
    import std.algorithm.searching   : canFind;

    Mesh cube = makeCube();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    float px0, py0, ndc0;
    assert(projectToWindowFull(cube.vertices[0], vp, px0, py0, ndc0),
        "vertex 0 should project on-screen");

    // The gather range every query below runs at. NAMED, not a retyped 40.0f:
    // there is exactly one pair of snap ranges in this tree, `SnapStage`
    // declares it and publishes it on this packet, and a test that spells its
    // own copy of the number is a fourth place for that pair to drift to. The
    // grid's coverage proof is stated in terms of `outerRangePx` (see
    // `cellPx`), so reading the default from the packet is also the honest
    // statement of what this test is exercising.
    immutable float gatherPx = SnapPacket.init.outerRangePx;

    // Build + populate the grid at vertex 0's ORIGINAL screen position.
    auto cands0 = queryCandidateGrid(Kind.Vertex, 0, cube, vp,
                                     cast(int)px0, cast(int)py0, gatherPx, null);
    assert(cands0.canFind(0),
        "sanity: vertex 0 should be a candidate at its own screen position");

    ulong mutVerBefore = cube.mutationVersion;

    // Version-silent edit — exactly what an interactive gizmo drag/commit
    // does: move the vertex well clear of its old screen bucket, note the
    // Position change class, never bump mutationVersion.
    cube.vertices[0] = cube.vertices[0] + Vec3(2.0f, 0, 0);
    cube.noteChange(MeshEditScope.Position);
    assert(cube.mutationVersion == mutVerBefore,
        "test setup must stay version-silent to mirror the gizmo path");

    float px1, py1, ndc1;
    assert(projectToWindowFull(cube.vertices[0], vp, px1, py1, ndc1),
        "moved vertex 0 should still project on-screen");
    float dpx = px1 - px0, dpy = py1 - py0;
    assert(dpx * dpx + dpy * dpy > 100.0f * 100.0f,
        "test setup must move the vertex well clear of its old screen bucket");

    // OLD behaviour: without invalidateSnapGrids(), the grid's
    // (meshAddr, meshVersion, ...) key is unchanged, so querying at the
    // vertex's NEW screen position misses it — the grid is still bucketed
    // by the pre-edit projection. Asserting this first proves the repro is
    // real (guards against the test silently becoming a no-op).
    auto candsStale = queryCandidateGrid(Kind.Vertex, 0, cube, vp,
                                         cast(int)px1, cast(int)py1, gatherPx, null);
    assert(!candsStale.canFind(0),
        "sanity: without invalidateSnapGrids() the grid must reproduce the "
        ~ "historical stale-after-position-edit bug");

    // NEW behaviour: app.d's bus flush calls invalidateSnapGrids() whenever
    // meshChangedFlags carries Position this frame (task 0401) — simulate
    // that call directly.
    invalidateSnapGrids();
    auto candsFresh = queryCandidateGrid(Kind.Vertex, 0, cube, vp,
                                         cast(int)px1, cast(int)py1, gatherPx, null);
    assert(candsFresh.canFind(0),
        "task 0401: invalidateSnapGrids() must force a rebuild against the "
        ~ "moved vertex");

    assert(cube.mutationVersion == mutVerBefore,
        "invalidateSnapGrids()/queryCandidateGrid must never mutate the "
        ~ "mesh's mutationVersion (that counter's version-silence on a "
        ~ "position edit is the intentional contract this fix works "
        ~ "around, not papers over)");
}

// ---------------------------------------------------------------------------
// The client admission predicate: neutral when absent, and load-bearing in
// the one order that matters.
//
// `snapCursor`'s trailing `admit` is the seam between the SERVICE (which grids
// to query, how a candidate projects, how the winner is ranked — this module's,
// shared by every caller) and the CLIENT'S POLICY (which candidates are
// eligible at all — the caller's, and different between callers). Three
// obligations, one assertion block each:
//
//   1. NEUTRALITY. The same query with `admit` absent and with a permissive
//      `admit` must agree field-for-field. That is what makes this parameter a
//      no-op for every existing call site: none of them pass a predicate, so
//      all of them take the `admit is null` branch, which is the pre-existing
//      walk verbatim.
//   2. REJECTION. A predicate that admits nothing must produce the clean
//      pass-through — asserted here to be the SAME result a disabled snap
//      produces, field-for-field, which is the strongest available statement
//      of "as if no candidate had been enumerated".
//   3. ORDER. The rejection happens before the distance compare, not after the
//      winner is picked. Rejecting the nearest candidate must PROMOTE the
//      runner-up, never veto the snap: a rejected candidate that could still
//      lower the accumulator would silently suppress an admissible candidate
//      standing behind it. This is the assertion that would fail if the check
//      were moved past the `d < bestDist` accumulator.
//
// The fixture is four collinear vertices with NO faces, so `needVis` is false
// and no visibility gate can reorder the ranking: what the assertions observe
// is pure screen distance, which is the property under test.
// ---------------------------------------------------------------------------
unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI;

    // This module's other unittests populate the slot-0 grids from their own
    // meshes; a fresh local Mesh can land on a recycled stack address with the
    // same (zero) mutationVersion, so drop the grids rather than rely on the
    // staleness key noticing.
    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    Mesh m;
    m.vertices = [
        Vec3( 0.00f, 0, 0),   // 0 — directly under the cursor pixel
        Vec3( 0.25f, 0, 0),   // 1 — the runner-up, still inside acceptance
        Vec3( 0.50f, 0, 0),   // 2 — inside the gather range, outside acceptance
        Vec3(-3.00f, 0, 0),   // 3 — outside the gather range entirely
    ];

    // The cursor pixel is vertex 0's own projection, so its screen distance is
    // exactly zero and the ranking below is unambiguous.
    float px0, py0, ndc0;
    assert(projectToWindowFull(m.vertices[0], vp, px0, py0, ndc0),
        "fixture: vertex 0 must project on-screen");
    immutable int sx = cast(int)round(px0);
    immutable int sy = cast(int)round(py0);

    float pixDist(Vec3 w) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: every candidate must project on-screen");
        immutable float dx = qx - cast(float)sx;
        immutable float dy = qy - cast(float)sy;
        return sqrt(dx * dx + dy * dy);
    }

    SnapPacket cfg;
    cfg.enabled      = true;
    cfg.enabledTypes = SnapType.Vertex;   // discrete tier only, one type
    cfg.snapScope    = SnapMode.Global;
    cfg.innerRangePx = 30.0f;
    cfg.outerRangePx = 100.0f;

    // State the fixture's premises rather than trusting the arithmetic above:
    // strictly increasing distances, with the acceptance boundary falling
    // between vertex 1 and vertex 2 and the gather boundary between 2 and 3.
    immutable float d0 = pixDist(m.vertices[0]);
    immutable float d1 = pixDist(m.vertices[1]);
    immutable float d2 = pixDist(m.vertices[2]);
    immutable float d3 = pixDist(m.vertices[3]);
    assert(d0 < d1 && d1 < d2 && d2 < d3,
        "fixture: the four candidates must rank strictly by screen distance");
    assert(d1 < cfg.innerRangePx,
        "fixture: vertex 1 must be close enough to SNAP once 0 is rejected");
    assert(d2 > cfg.innerRangePx && d2 < cfg.outerRangePx,
        "fixture: vertex 2 must HIGHLIGHT but not snap once 0 and 1 are rejected");
    assert(d3 > cfg.outerRangePx,
        "fixture: vertex 3 must be out of the gather range in every case");

    // Deliberately not any vertex position: the pass-through assertions below
    // are only meaningful if the input is distinguishable from every candidate.
    immutable Vec3 cursorWorld = Vec3(7.5f, -3.25f, 1.125f);

    static bool sameVec(Vec3 a, Vec3 b) {
        return a.x == b.x && a.y == b.y && a.z == b.z;
    }
    // Field-for-field, spelled out rather than `a == b`, so a failure names
    // WHICH field diverged and so a later field added to SnapResult shows up
    // here as a compile-time-visible omission rather than silently unchecked.
    static bool sameResult(SnapResult a, SnapResult b) {
        return sameVec(a.worldPos, b.worldPos)
            && sameVec(a.highlightPos, b.highlightPos)
            && a.snapped        == b.snapped
            && a.highlighted    == b.highlighted
            && a.targetType     == b.targetType
            && a.targetIndex    == b.targetIndex
            && a.targetSource   == b.targetSource
            && a.constraintType == b.constraintType;
    }

    // --- baseline: no predicate at all, i.e. every existing call site --------
    SnapResult bare = snapCursor(cursorWorld, sx, sy, vp, m, cfg);
    assert(bare.snapped,        "baseline: vertex 0 sits under the cursor");
    assert(bare.targetType  == SnapType.Vertex);
    assert(bare.targetIndex == 0);
    assert(bare.targetSource == 0);
    assert(sameVec(bare.worldPos, m.vertices[0]));

    // --- 1. NEUTRALITY: permissive predicate == no predicate ----------------
    // The predicate doubles as an observation channel: it sees exactly what
    // the enumeration offered, which is how the count below is known.
    int offered;
    SnapResult permissive = snapCursor(cursorWorld, sx, sy, vp, m, cfg, null,
        (SnapType t, int i, int s) { ++offered; return true; });
    assert(sameResult(bare, permissive),
        "S1 neutrality: a predicate that admits everything must reproduce the "
        ~ "no-predicate result field-for-field");
    assert(offered >= 3,
        "the ordering assertions below are only meaningful if the enumeration "
        ~ "actually offered the runner-ups");

    // --- 2. REJECTION: admitting nothing == snapping switched off -----------
    SnapResult admitNone = snapCursor(cursorWorld, sx, sy, vp, m, cfg, null,
        (SnapType t, int i, int s) => false);
    SnapPacket offCfg = cfg;
    offCfg.enabled = false;
    SnapResult disabled = snapCursor(cursorWorld, sx, sy, vp, m, offCfg);
    assert(sameResult(admitNone, disabled),
        "S1 rejection: a predicate that admits nothing must be the same clean "
        ~ "pass-through as `cfg.enabled == false`");
    assert(sameVec(admitNone.worldPos, cursorWorld));
    assert(!admitNone.snapped && !admitNone.highlighted);
    assert(admitNone.targetIndex == -1);
    assert(admitNone.targetType == SnapType.None);

    // --- 3. ORDER: rejecting the winner promotes the runner-up --------------
    SnapResult noV0 = snapCursor(cursorWorld, sx, sy, vp, m, cfg, null,
        (SnapType t, int i, int s) => !(t == SnapType.Vertex && i == 0 && s == 0));
    assert(noV0.snapped,
        "S1 order: rejecting the nearest candidate must hand the snap to the "
        ~ "runner-up, not cancel it — a rejected candidate must not be able to "
        ~ "lower the accumulator it was rejected from");
    assert(noV0.targetIndex == 1);
    assert(sameVec(noV0.worldPos, m.vertices[1]));

    // ...and rejecting BOTH accepted candidates leaves the third, which is
    // inside the gather range and outside acceptance: highlight, no snap. The
    // accumulator was genuinely re-ranked, not merely filtered at the end.
    SnapResult noV01 = snapCursor(cursorWorld, sx, sy, vp, m, cfg, null,
        (SnapType t, int i, int s) =>
            !(t == SnapType.Vertex && (i == 0 || i == 1)));
    assert(!noV01.snapped && noV01.highlighted);
    assert(noV01.targetIndex == 2);
    assert(sameVec(noV01.highlightPos, m.vertices[2]));
    assert(sameVec(noV01.worldPos, cursorWorld),
        "a highlight-only result still passes the input position through");

    // --- the tie-break is part of "the same result" -------------------------
    // Two candidates at an exactly equal screen distance: `consider`'s strict
    // `<` gives the win to the first VISITED, and the grid hands candidates
    // over in ascending index order, so the lower index takes it. That rule is
    // as much a part of the result as the position is, so it gets stated on
    // both sides of the seam rather than left to the general equality above
    // (which the ranked fixture can never exercise).
    // Coincident vertices, not a mirrored pair: a mirrored pair is only a tie
    // up to floating-point luck in the projection, while two candidates at the
    // SAME world point tie by construction. It is also the honest case — an
    // unwelded duplicate is exactly where "which of these two wins" decides
    // what a weld does.
    Mesh tie;
    tie.vertices = [
        Vec3(0.25f, 0, 0),   // 0 — wins the tie by index
        Vec3(0.25f, 0, 0),   // 1 — the unwelded duplicate
    ];
    invalidateSnapGrids();
    assert(pixDist(tie.vertices[0]) == pixDist(tie.vertices[1]),
        "fixture: the two candidates must be an EXACT screen-distance tie, "
        ~ "otherwise this block tests ranking, not tie-breaking");
    assert(pixDist(tie.vertices[0]) < cfg.innerRangePx,
        "fixture: the tied pair must be close enough to snap");

    SnapResult tieBare = snapCursor(cursorWorld, sx, sy, vp, tie, cfg);
    assert(tieBare.snapped && tieBare.targetIndex == 0,
        "the tie goes to the lower index");
    SnapResult tiePermissive = snapCursor(cursorWorld, sx, sy, vp, tie, cfg, null,
        (SnapType t, int i, int s) => true);
    assert(sameResult(tieBare, tiePermissive),
        "S1 neutrality: a tie must break the same way with a permissive "
        ~ "predicate as with none");

    SnapResult tieNoV0 = snapCursor(cursorWorld, sx, sy, vp, tie, cfg, null,
        (SnapType t, int i, int s) => !(t == SnapType.Vertex && i == 0));
    assert(tieNoV0.snapped && tieNoV0.targetIndex == 1,
        "rejecting the side of the tie that won hands it to the other side");

    invalidateSnapGrids();

    // --- the constraint tier carries the same seam --------------------------
    // Constraint candidates are line/plane hits, not mesh elements, so the
    // predicate sees (type, -1, 0). Aimed at a pixel where a world axis is
    // exactly under the cursor and the view ray is not parallel to it.
    float pxa, pya, ndca;
    assert(projectToWindowFull(Vec3(1, 0, 0), vp, pxa, pya, ndca));
    immutable int ax = cast(int)round(pxa);
    immutable int ay = cast(int)round(pya);

    SnapPacket ccfg = cfg;
    ccfg.enabledTypes = SnapType.WorldAxis;   // constraint tier only

    SnapResult cBare = snapCursor(cursorWorld, ax, ay, vp, m, ccfg);
    assert(cBare.snapped && cBare.constraintType == SnapType.WorldAxis,
        "fixture: a world-axis constraint must fire at this pixel, otherwise "
        ~ "the constraint-tier assertions below are vacuous");

    SnapResult cPermissive = snapCursor(cursorWorld, ax, ay, vp, m, ccfg, null,
        (SnapType t, int i, int s) => true);
    assert(sameResult(cBare, cPermissive),
        "S1 neutrality holds in the constraint tier too");

    int constraintOffered;
    SnapResult cNone = snapCursor(cursorWorld, ax, ay, vp, m, ccfg, null,
        (SnapType t, int i, int s) {
            ++constraintOffered;
            assert(i == -1 && s == 0,
                "a constraint candidate has no element index and no source");
            return false;
        });
    assert(constraintOffered >= 1, "fixture: the axis lines must be offered");
    assert(!cNone.snapped);
    assert(cNone.constraintType == SnapType.None);
    assert(sameVec(cNone.worldPos, cursorWorld));
}

// ---------------------------------------------------------------------------
// S4(a) of doc/toolpipe_architecture_plan.md — the guide registry, and the
// equivalence that makes registering a real guide safe later.
//
// Phase (a) lands the interface, the registry and the arbitration path with
// the registry EMPTY, so the arbitration branch is unreachable and nothing in
// the tree ranks differently. That is a statement about REACHABILITY, and a
// test cannot observe it — the grep is the proof, not this block.
//
// What this block proves is the other half, the half phase (b) will rest on:
// that the two ranking paths AGREE. Four obligations:
//
//   1. EQUIVALENCE. A guide whose `proximity` mirrors the service's own
//      distance rule — same projection, same pixel difference, same sqrt,
//      priority 0 — must reproduce the no-guide result field for field,
//      INCLUDING the tie-break. If phase (b)'s first guide changes a fixture,
//      this block says the change came from the guide's policy and not from
//      the mechanism that carries it.
//   2. IDENTITY. The guide is offered exactly the candidates the enumeration
//      offers, with exactly the (type, index, slot) triple the sibling seam
//      `SnapAdmit` sees for the same query — cross-checked against a real
//      `admit` run rather than against a hand-written expectation. A design
//      that consulted the guide only about the WINNER would pass an
//      "equivalence" test and fails this one.
//   3. RE-RANK. The guide's `distPx` is the ranking value, not decoration: a
//      guide that inverts the distance order must hand the snap to the
//      FARTHEST candidate. This is the assertion that fails if the returned
//      distance is dropped and the service's own is ranked instead.
//   4. ARBITRATION. Between two guides that both admit a candidate, the higher
//      `priority` decides — and priority outranks distance, which is exactly
//      the rule phase (b) turns on.
//
// The fixture is collinear vertices with NO faces, so `needVis` is false and
// ranking is pure screen distance: what the assertions observe is the property
// under test and not the visibility gate.
// ---------------------------------------------------------------------------
version (unittest) {
    import toolpipe.guide : GuideDrawState;

    /// A guide that answers with the service's own rule: same projection, same
    /// pixel difference, same sqrt, priority 0, admits everything that
    /// projects. Registering it must change nothing.
    private class MirrorGuide : SnapGuide {
        Viewport vp;
        int      sx, sy;

        // Observation channel — the candidates this guide was offered, in
        // order, as a packed (type, idx, slot) key. Fixed storage: the walk is
        // hot and an allocating guide would be testing the allocator.
        long[256] seen;
        size_t    seenCount;

        // What the stage pushed in, and what it last asked us to draw.
        float          innerPx = -1, outerPx = -1;
        GuideDrawState draw    = GuideDrawState.Off;

        // The priority this guide answers with — 0 for the mirror, overridden
        // by the arbitration block below.
        int answerPrio = 0;
        // When true the guide INVERTS the ranking: near reads as far. The
        // inverted distance stays inside the acceptance range on purpose —
        // `bestDist` is what the merge tests against `innerRangePx`, so a
        // guide's answer decides acceptance as well as order, and an inverted
        // ranking that reported 900 px would prove nothing but a miss.
        bool  invert     = false;
        float invertBase = 0;
        // Types this guide refuses outright.
        bool admitAll = true;
        // One candidate promoted above the rest. This is the ONLY way to
        // exercise the accumulator's priority term: `arbitrate` settles which
        // GUIDE answers for a candidate, and if every candidate then comes
        // back at the same priority, "(priority, distance)" and "distance" are
        // the same rule. A guide that ranks one candidate above its
        // neighbours is what tells them apart.
        int elevateIdx  = -1;
        int elevatePrio = 1;
        // When true this guide never touches the priority slot at all, which
        // is how "did not say" is told apart from "said 0".
        bool silent = false;

        this(Viewport v, int x, int y) { vp = v; sx = x; sy = y; }

        // `nothrow` so the S1 predicate below — which is `nothrow` by its
        // alias — can call it and record the same sequence.
        static long key(SnapType t, int idx, int slot) pure nothrow @safe {
            return (cast(long)t << 40) | (cast(long)(idx + 2) << 8) | cast(long)slot;
        }

        void limits(float i, float o) { innerPx = i; outerPx = o; }

        bool proximity(Vec3 candWorld, SnapType type, int idx, int slot,
                       out float distPx, ref int priority)
        {
            if (seenCount < seen.length) seen[seenCount++] = key(type, idx, slot);
            if (!admitAll) return false;
            float qx, qy, qz;
            if (!projectToWindowFull(candWorld, vp, qx, qy, qz)) return false;
            immutable float dx = qx - cast(float)sx;
            immutable float dy = qy - cast(float)sy;
            immutable float d  = sqrt(dx * dx + dy * dy);
            distPx   = invert ? (invertBase - d) : d;
            // `silent` leaves the slot exactly as the caller seeded it — the
            // only way to observe that the seed exists.
            if (!silent) priority = (idx == elevateIdx) ? elevatePrio : answerPrio;
            return true;
        }

        void setDrawState(GuideDrawState s) { draw = s; }
        uint flags() const { return 0; }
    }
}

unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI;

    // Same reason as the S1 block above: this module's other unittests
    // populate the slot-0 grids, and a fresh local Mesh can land on a recycled
    // address with the same (zero) mutationVersion.
    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    Mesh m;
    m.vertices = [
        Vec3(0.00f, 0, 0),   // 0 — directly under the cursor pixel
        Vec3(0.15f, 0, 0),   // 1 — the runner-up
        Vec3(0.30f, 0, 0),   // 2 — the farthest, and still inside acceptance
    ];

    float px0, py0, ndc0;
    assert(projectToWindowFull(m.vertices[0], vp, px0, py0, ndc0),
        "fixture: vertex 0 must project on-screen");
    immutable int sx = cast(int)round(px0);
    immutable int sy = cast(int)round(py0);

    float pixDist(Vec3 w) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: every candidate must project on-screen");
        immutable float dx = qx - cast(float)sx;
        immutable float dy = qy - cast(float)sy;
        return sqrt(dx * dx + dy * dy);
    }

    SnapPacket cfg;
    cfg.enabled      = true;
    cfg.enabledTypes = SnapType.Vertex;   // discrete tier only, one type
    cfg.snapScope    = SnapMode.Global;
    cfg.innerRangePx = 30.0f;
    cfg.outerRangePx = 100.0f;

    immutable float d0 = pixDist(m.vertices[0]);
    immutable float d1 = pixDist(m.vertices[1]);
    immutable float d2 = pixDist(m.vertices[2]);
    assert(d0 < d1 && d1 < d2,
        "fixture: the three candidates must rank strictly by screen distance");
    assert(d2 < cfg.innerRangePx,
        "fixture: even the farthest candidate must be able to SNAP, so that a "
        ~ "re-ranking guide's winner is a snap and not a bare highlight");

    // The value an inverting guide reflects distances about: `invertBase - d`
    // reverses the order while keeping every answer inside acceptance, so what
    // the re-rank block observes is the ORDER changing and not the range test
    // failing.
    immutable float invertBase = d2 + 1.0f;
    assert(invertBase <= cfg.innerRangePx,
        "fixture: the whole reflected range must stay inside acceptance, or "
        ~ "the re-rank block would be testing the acceptance test");

    // Not any candidate's position: the pass-through assertions are only
    // meaningful if the input is distinguishable from every candidate.
    immutable Vec3 cursorWorld = Vec3(7.5f, -3.25f, 1.125f);

    static bool sameVec(Vec3 a, Vec3 b) {
        return a.x == b.x && a.y == b.y && a.z == b.z;
    }
    // Field for field rather than `a == b`, so a failure names WHICH field
    // diverged and a field added to SnapResult shows up here as an omission.
    static bool sameResult(SnapResult a, SnapResult b) {
        return sameVec(a.worldPos, b.worldPos)
            && sameVec(a.highlightPos, b.highlightPos)
            && a.snapped        == b.snapped
            && a.highlighted    == b.highlighted
            && a.targetType     == b.targetType
            && a.targetIndex    == b.targetIndex
            && a.targetSource   == b.targetSource
            && a.constraintType == b.constraintType;
    }

    // --- baseline: no guide at all, i.e. every call site in the tree ---------
    SnapResult bare = snapCursor(cursorWorld, sx, sy, vp, m, cfg);
    assert(bare.snapped && bare.targetIndex == 0
        && bare.targetType == SnapType.Vertex && bare.targetSource == 0,
        "baseline: vertex 0 sits under the cursor");
    assert(sameVec(bare.worldPos, m.vertices[0]));

    // --- 1. EQUIVALENCE: the mirror guide changes nothing --------------------
    invalidateSnapGrids();
    auto mirror = new MirrorGuide(vp, sx, sy);
    SnapResult guided = snapCursor(cursorWorld, sx, sy, vp, m, cfg, null, null,
                                   [mirror]);
    assert(sameResult(bare, guided),
        "S4 equivalence: a guide that mirrors the service's own distance rule "
        ~ "must reproduce the no-guide result field for field — this is the "
        ~ "pin that makes registering a REAL guide a change of policy and not "
        ~ "a change of mechanism");

    // --- 2. IDENTITY: the guide sees the enumeration, not the winner ---------
    // Cross-checked against the sibling seam rather than a hand-written list:
    // both are consulted per candidate, in the same walk, so the sequences
    // must be identical. A guide consulted only about the winner would have a
    // sequence of length 1 here.
    invalidateSnapGrids();
    long[256] admitSeen;
    size_t    admitCount;
    SnapResult admitted = snapCursor(cursorWorld, sx, sy, vp, m, cfg, null,
        (SnapType t, int i, int s) {
            if (admitCount < admitSeen.length)
                admitSeen[admitCount++] = MirrorGuide.key(t, i, s);
            return true;
        });
    assert(sameResult(bare, admitted), "sanity: the S1 seam is still neutral");
    assert(admitCount >= 3,
        "fixture: the enumeration must offer all three vertices, else the "
        ~ "sequence comparison below is vacuous");
    assert(mirror.seenCount == admitCount,
        "S4 identity: the guide must be offered exactly as many candidates as "
        ~ "the admission predicate is — the two seams sit in the same walk");
    assert(mirror.seen[0 .. mirror.seenCount] == admitSeen[0 .. admitCount],
        "S4 identity: and the same candidates, in the same order, with the "
        ~ "same (type, index, slot) triple");

    // --- 3. RE-RANK: the guide's distance is the ranking value ---------------
    invalidateSnapGrids();
    auto inverted = new MirrorGuide(vp, sx, sy);
    inverted.invert     = true;
    inverted.invertBase = invertBase;
    SnapResult flipped = snapCursor(cursorWorld, sx, sy, vp, m, cfg, null, null,
                                    [inverted]);
    assert(flipped.snapped && flipped.targetIndex == 2,
        "S4 re-rank: a guide that inverts the distance order must hand the "
        ~ "snap to the FARTHEST candidate — if the service ranked by its own "
        ~ "distance and merely asked the guide for permission, vertex 0 would "
        ~ "still win and nothing would announce it");
    assert(sameVec(flipped.worldPos, m.vertices[2]),
        "the guide re-ranks a candidate; it never moves one");

    // --- ...and rejecting everything is the clean pass-through --------------
    invalidateSnapGrids();
    auto refuses = new MirrorGuide(vp, sx, sy);
    refuses.admitAll = false;
    SnapResult none = snapCursor(cursorWorld, sx, sy, vp, m, cfg, null, null,
                                 [refuses]);
    SnapPacket offCfg = cfg;
    offCfg.enabled = false;
    SnapResult disabled = snapCursor(cursorWorld, sx, sy, vp, m, offCfg);
    assert(sameResult(none, disabled),
        "S4: a guide that admits nothing must be the same clean pass-through "
        ~ "as `cfg.enabled == false` — a rejected candidate must be as if it "
        ~ "had never been enumerated");

    // --- 4a. RANKING: priority outranks distance BETWEEN CANDIDATES ---------
    // One guide, mirroring the distance rule, that promotes the FARTHEST
    // candidate by one priority level. The promoted candidate must win even
    // though two nearer ones were offered first and were admitted.
    //
    // This is the block that separates "(priority, distance) wins" from
    // "nearest wins", and it is the only shape that can: `arbitrate` settles
    // which GUIDE answers for a candidate, so a fixture where every candidate
    // comes back at the same priority leaves the accumulator's priority term
    // dead and unobserved. Deleting the term must fail HERE.
    invalidateSnapGrids();
    auto elevator = new MirrorGuide(vp, sx, sy);
    elevator.elevateIdx  = 2;
    elevator.elevatePrio = 1;
    SnapResult elevated = snapCursor(cursorWorld, sx, sy, vp, m, cfg, null,
                                     null, [elevator]);
    assert(elevated.snapped && elevated.targetIndex == 2,
        "S4 ranking: a candidate at a higher priority beats a nearer one at a "
        ~ "lower priority — priority is the first term of the key, distance "
        ~ "only the second");
    assert(sameVec(elevated.worldPos, m.vertices[2]));

    // ...and the promotion must not be order-dependent: promoting the NEAREST
    // candidate changes nothing, because it already won on distance.
    invalidateSnapGrids();
    auto elevateNear = new MirrorGuide(vp, sx, sy);
    elevateNear.elevateIdx = 0;
    SnapResult elevatedNear = snapCursor(cursorWorld, sx, sy, vp, m, cfg, null,
                                         null, [elevateNear]);
    assert(sameResult(bare, elevatedNear),
        "promoting the candidate that already won on distance is a no-op — "
        ~ "the priority term must not reorder anything by itself");

    // --- 4. ARBITRATION: priority outranks distance --------------------------
    // Two guides over the same candidates. `low` mirrors the distance rule at
    // priority 0; `high` inverts it at priority 1. The higher priority must
    // decide, and it must decide AGAINST the nearer candidate — otherwise
    // "(priority, distance)" would be indistinguishable from "distance".
    invalidateSnapGrids();
    auto low  = new MirrorGuide(vp, sx, sy);
    auto high = new MirrorGuide(vp, sx, sy);
    high.invert     = true;
    high.invertBase = invertBase;
    high.answerPrio = 1;
    SnapResult arb = snapCursor(cursorWorld, sx, sy, vp, m, cfg, null, null,
                                [low, high]);
    assert(arb.snapped && arb.targetIndex == 2,
        "S4 arbitration: the higher-priority guide decides, even though the "
        ~ "lower-priority one reported a shorter distance");

    // Order of registration must not matter to the priority decision.
    invalidateSnapGrids();
    auto low2  = new MirrorGuide(vp, sx, sy);
    auto high2 = new MirrorGuide(vp, sx, sy);
    high2.invert     = true;
    high2.invertBase = invertBase;
    high2.answerPrio = 1;
    SnapResult arbSwapped = snapCursor(cursorWorld, sx, sy, vp, m, cfg, null,
                                       null, [high2, low2]);
    assert(sameResult(arb, arbSwapped),
        "S4 arbitration: priority decides, so registration order must not — "
        ~ "it settles EQUAL priorities and nothing else");

    // ...and when the priorities ARE equal, registration order is the whole
    // tie-break the registry can offer. Two guides at priority 0 that disagree
    // about distance: the FIRST registered must be the one heard.
    invalidateSnapGrids();
    auto firstMirror = new MirrorGuide(vp, sx, sy);
    auto secondFlip  = new MirrorGuide(vp, sx, sy);
    secondFlip.invert     = true;
    secondFlip.invertBase = invertBase;
    assert(firstMirror.answerPrio == secondFlip.answerPrio,
        "fixture: this block is about EQUAL priorities");
    SnapResult tiedPrio = snapCursor(cursorWorld, sx, sy, vp, m, cfg, null,
                                     null, [firstMirror, secondFlip]);
    assert(tiedPrio.snapped && tiedPrio.targetIndex == 0,
        "S4 arbitration: at equal priority the first-registered guide is "
        ~ "heard — a later guide must not be able to overrule a peer it does "
        ~ "not outrank");
    invalidateSnapGrids();
    auto firstFlip    = new MirrorGuide(vp, sx, sy);
    firstFlip.invert     = true;
    firstFlip.invertBase = invertBase;
    auto secondMirror = new MirrorGuide(vp, sx, sy);
    SnapResult tiedPrioSwapped = snapCursor(cursorWorld, sx, sy, vp, m, cfg,
                                            null, null,
                                            [firstFlip, secondMirror]);
    assert(tiedPrioSwapped.snapped && tiedPrioSwapped.targetIndex == 2,
        "and the same two guides in the other order give the other answer — "
        ~ "which is what makes the previous assertion about ORDER and not "
        ~ "about which guide happens to be right");

    // --- the PRE-SEEDED priority: "did not say" is not "said 0" -------------
    // MEASURED (kGuidePrioritySeed). A guide that never touches the priority
    // slot answers with the seed, so it OUTRANKS a guide that explicitly says
    // zero — and it does so from second place in the registry, where a
    // same-priority peer could not have overruled the first.
    //
    // FAILS ON AN `out` PARAMETER, which is what this used to be: the silent
    // guide's answer would zero itself, the two priorities would tie, and
    // registration order would hand the result to `saysZero` instead.
    invalidateSnapGrids();
    auto saysZero = new MirrorGuide(vp, sx, sy);
    assert(saysZero.answerPrio == 0, "fixture: the loud guide names zero");
    auto saysNothing = new MirrorGuide(vp, sx, sy);
    saysNothing.silent     = true;
    saysNothing.invert     = true;
    saysNothing.invertBase = invertBase;
    assert(kGuidePrioritySeed > saysZero.answerPrio,
        "fixture: the seed must outrank an explicit zero, or this proves nothing");
    SnapResult seeded = snapCursor(cursorWorld, sx, sy, vp, m, cfg, null, null,
                                   [saysZero, saysNothing]);
    assert(seeded.snapped && seeded.targetIndex == 2,
        "S4: the priority slot is PRE-SEEDED, so a guide that ignores it is heard at the "
        ~ "seed's rank and not at zero");

    // --- the tie-break survives the guide path ------------------------------
    // Two coincident vertices: a tie by construction (a mirrored ±x pair only
    // ties to within floating point, which is not a tie). The service breaks
    // it by ascending index under a strict `<`; the mirror guide, feeding the
    // same distances into the same comparison, must break it the same way.
    invalidateSnapGrids();
    Mesh tie;
    tie.vertices = [Vec3(0.25f, 0, 0), Vec3(0.25f, 0, 0)];
    assert(pixDist(tie.vertices[0]) == pixDist(tie.vertices[1]),
        "fixture: the two candidates must be an EXACT tie, otherwise this "
        ~ "block tests ranking and not tie-breaking");
    assert(pixDist(tie.vertices[0]) < cfg.innerRangePx,
        "fixture: the tied pair must be close enough to snap");

    SnapResult tieBare = snapCursor(cursorWorld, sx, sy, vp, tie, cfg);
    assert(tieBare.snapped && tieBare.targetIndex == 0,
        "the tie goes to the lower index");
    invalidateSnapGrids();
    auto tieMirror = new MirrorGuide(vp, sx, sy);
    SnapResult tieGuided = snapCursor(cursorWorld, sx, sy, vp, tie, cfg, null,
                                      null, [tieMirror]);
    assert(sameResult(tieBare, tieGuided),
        "S4 equivalence: the tie-break is part of the result, so it is part "
        ~ "of the equivalence — a guide path that compared with `<=` would "
        ~ "hand the tie to the higher index and pass every other assertion "
        ~ "in this block");

    // --- the constraint tier carries the same arbitration --------------------
    invalidateSnapGrids();
    float pxa, pya, ndca;
    assert(projectToWindowFull(Vec3(1, 0, 0), vp, pxa, pya, ndca));
    immutable int cx = cast(int)round(pxa);
    immutable int cy = cast(int)round(pya);

    SnapPacket ccfg = cfg;
    ccfg.enabledTypes = SnapType.WorldAxis;   // constraint tier only

    SnapResult cBare = snapCursor(cursorWorld, cx, cy, vp, m, ccfg);
    assert(cBare.snapped && cBare.constraintType == SnapType.WorldAxis,
        "fixture: a world-axis constraint must fire at this pixel, otherwise "
        ~ "the constraint-tier assertions below are vacuous");

    invalidateSnapGrids();
    auto cMirror = new MirrorGuide(vp, cx, cy);
    SnapResult cGuided = snapCursor(cursorWorld, cx, cy, vp, m, ccfg, null,
                                    null, [cMirror]);
    assert(sameResult(cBare, cGuided),
        "S4 equivalence holds in the constraint tier too");

    invalidateSnapGrids();
    auto cRefuses = new MirrorGuide(vp, cx, cy);
    cRefuses.admitAll = false;
    SnapResult cNone = snapCursor(cursorWorld, cx, cy, vp, m, ccfg, null, null,
                                  [cRefuses]);
    assert(cRefuses.seenCount >= 1,
        "fixture: the axis lines must be offered to the guide");
    assert(!cNone.snapped && cNone.constraintType == SnapType.None
        && sameVec(cNone.worldPos, cursorWorld),
        "S4: a guide that rejects must be able to veto a CONSTRAINT too — "
        ~ "otherwise a guide whose whole job is an admission rule would "
        ~ "reject every element and then watch a constraint hit sail past it");

    invalidateSnapGrids();
}

// ---------------------------------------------------------------------------
// THE SELF-REFERENCE RULE: no element that MOVES with the drag may be a snap
// candidate for it (`kindExcluded`, and the exclusion `move.d` builds at
// `applySnapToDelta`).
//
// The exclusion was written to stop one thing — "a single-vert drag always
// snaps to its own (zero-distance) projected pixel" — and the rule it was
// written as, "excluded iff ALL its incident verts are dragged", delivers that
// for the Vertex type ALONE. Everything below is a candidate the OLD rule kept
// live during a single-vertex drag, and every one of them is the same defect
// the exclusion exists to prevent, wearing a different type tag:
//
//   1. EDGE CENTRE of an incident edge — recomputed from the MOVING endpoint
//      every frame, so it trails the drag at half speed.
//   2. EDGE, as a segment — its closest point to the cursor IS the dragged
//      endpoint at ~0 px, so the snap answers with the drag's own anchor and
//      the drag freezes. `PolyCenter` is on by DEFAULT, so (1) ships; `Edge`
//      is a checkbox away, so (2) is one click from a user.
//   3. POLYGON CENTRE of an incident face — the default type set, at 1/n of
//      the drag speed.
//   4. POLYGON, as a surface — closest point on a face one of whose corners is
//      being dragged.
//
// Each block below is written to fail on the ALL rule and pass on ANY, and
// each carries its own positive control: the SAME query with an empty
// exclusion must still find the candidate. Without that control a block would
// also "pass" if the fixture simply never reached the candidate.
//
// The fixture keeps ONE type enabled at a time so a single candidate walk
// decides each assertion, and gives the excluded element a far-away sibling
// that is deliberately OUTSIDE the gather range — so "did not snap" means the
// exclusion dropped it, not that something else won.
// ---------------------------------------------------------------------------
unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI;

    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    // Not any candidate's position: a pass-through `worldPos` must be
    // distinguishable from a snapped one.
    immutable Vec3 cursorWorld = Vec3(7.5f, -3.25f, 1.125f);

    // The drag moves vertex 0 and nothing else — the single-vertex drag the
    // exclusion comment names.
    immutable uint[] dragged = [0u];

    int[2] pixelOf(Vec3 w) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: the probe point must project on-screen");
        return [cast(int)round(qx), cast(int)round(qy)];
    }

    // --- 1 + 2: EDGE CENTRE and EDGE, on a face-less wire ------------------
    // No faces ⇒ `needVis` is false ⇒ ranking is pure screen distance and the
    // occlusion gate cannot silently do the excluding for us.
    {
        Mesh m;
        m.vertices = [
            Vec3(0.0f, 0, 0),   // 0 — dragged
            Vec3(1.0f, 0, 0),   // 1
            Vec3(3.0f, 0, 0),   // 2
        ];
        m.edges = [[0u, 1u], [1u, 2u]];

        SnapPacket cfg;
        cfg.enabled      = true;
        cfg.snapScope    = SnapMode.Global;
        cfg.innerRangePx = 40.0f;
        cfg.outerRangePx = 40.0f;

        // --- 1. EDGE CENTRE ------------------------------------------------
        cfg.enabledTypes = SnapType.EdgeCenter;
        immutable Vec3 c01 = Vec3(0.5f, 0, 0);          // edge 0's centre
        auto pc = pixelOf(c01);

        invalidateSnapGrids();
        SnapResult ctl = snapCursor(cursorWorld, pc[0], pc[1], vp, m, cfg);
        assert(ctl.snapped && ctl.targetType == SnapType.EdgeCenter
            && ctl.targetIndex == 0,
            "positive control: with NOTHING excluded the cursor sits on edge "
            ~ "0's centre and must snap to it — otherwise the exclusion "
            ~ "assertion below would pass for the wrong reason");
        assert(pixelOf(Vec3(2.0f, 0, 0))[0] - pc[0] > cfg.outerRangePx,
            "fixture: edge 1's centre must be OUTSIDE the gather range, so a "
            ~ "miss below means the exclusion fired and not that a sibling won");

        invalidateSnapGrids();
        SnapResult r = snapCursor(cursorWorld, pc[0], pc[1], vp, m, cfg, dragged);
        assert(!r.snapped,
            "an edge with ONE dragged endpoint moves with the drag: its centre "
            ~ "is recomputed from the moving coordinate every frame and trails "
            ~ "the gizmo at half speed. It is the drag's own geometry and must "
            ~ "not be a candidate for it");
        assert(r.targetType == SnapType.None && r.targetIndex == -1,
            "...and it must not be offered as a HIGHLIGHT either: a rejected "
            ~ "candidate is as if it were never enumerated");

        // --- 2. EDGE as a segment — the freeze ------------------------------
        cfg.enabledTypes = SnapType.Edge;
        auto pv = pixelOf(m.vertices[0]);   // the cursor is ON the dragged vert

        invalidateSnapGrids();
        SnapResult ectl = snapCursor(cursorWorld, pv[0], pv[1], vp, m, cfg);
        assert(ectl.snapped && ectl.targetType == SnapType.Edge
            && ectl.targetIndex == 0
            && ectl.worldPos.x == m.vertices[0].x
            && ectl.worldPos.y == m.vertices[0].y
            && ectl.worldPos.z == m.vertices[0].z,
            "positive control, and the defect stated as a measurement: the "
            ~ "closest point on the incident edge IS the dragged vertex, so an "
            ~ "unexcluded edge answers the query with the drag's own anchor — "
            ~ "delta becomes zero and the drag freezes");

        invalidateSnapGrids();
        SnapResult er = snapCursor(cursorWorld, pv[0], pv[1], vp, m, cfg, dragged);
        assert(!er.snapped,
            "the freeze is what the exclusion is FOR: an edge incident to the "
            ~ "dragged vertex must not be able to hand the drag its own anchor "
            ~ "back");
        assert(er.worldPos.x == cursorWorld.x && er.worldPos.y == cursorWorld.y
            && er.worldPos.z == cursorWorld.z,
            "...and a miss passes the input through unchanged, so the caller's "
            ~ "delta survives");
    }

    // --- 3 + 4: POLYGON CENTRE and POLYGON, on a quad ----------------------
    {
        Mesh m;
        m.vertices = [
            Vec3(-1, -1, 0),   // 0 — dragged
            Vec3( 1, -1, 0),   // 1
            Vec3( 1,  1, 0),   // 2
            Vec3(-1,  1, 0),   // 3
        ];
        m.addFace([0u, 1u, 2u, 3u]);

        SnapPacket cfg;
        cfg.enabled      = true;
        cfg.snapScope    = SnapMode.Global;
        cfg.innerRangePx = 40.0f;
        cfg.outerRangePx = 40.0f;

        // The quad's centroid, i.e. the polygon centre AND a point on the
        // polygon surface — one cursor pixel serves both blocks.
        auto pc = pixelOf(Vec3(0, 0, 0));

        // --- 3. POLYGON CENTRE ---------------------------------------------
        cfg.enabledTypes = SnapType.PolyCenter;

        invalidateSnapGrids();
        SnapResult ctl = snapCursor(cursorWorld, pc[0], pc[1], vp, m, cfg);
        assert(ctl.snapped && ctl.targetType == SnapType.PolyCenter
            && ctl.targetIndex == 0,
            "positive control: the face is front-facing and unoccluded, so its "
            ~ "centre is a live candidate with nothing excluded");

        invalidateSnapGrids();
        SnapResult r = snapCursor(cursorWorld, pc[0], pc[1], vp, m, cfg, dragged);
        assert(!r.snapped,
            "PolyCenter is ON BY DEFAULT, so this is the case a user meets "
            ~ "without changing a setting: a face with one dragged corner has "
            ~ "a centroid that follows the drag at 1/n of its speed, and the "
            ~ "gizmo is pulled after its own tail");

        // --- 4. POLYGON as a surface ---------------------------------------
        cfg.enabledTypes = SnapType.Polygon;

        invalidateSnapGrids();
        SnapResult pctl = snapCursor(cursorWorld, pc[0], pc[1], vp, m, cfg);
        assert(pctl.snapped && pctl.targetType == SnapType.Polygon
            && pctl.targetIndex == 0,
            "positive control: the cursor is over the face's interior");

        invalidateSnapGrids();
        SnapResult pr = snapCursor(cursorWorld, pc[0], pc[1], vp, m, cfg, dragged);
        assert(!pr.snapped,
            "the surface of a face being deformed by the drag is the drag's "
            ~ "own geometry too — the rule is about MOVING, not about which "
            ~ "type tag the candidate carries");
    }

    // --- 5. …and the rule still admits everything that does NOT move -------
    // The exclusion must be a scalpel, not a curtain: dropping the whole mesh
    // whenever anything is dragged would also pass every assertion above.
    {
        Mesh m;
        m.vertices = [
            Vec3(0.0f, 0, 0),   // 0 — dragged
            Vec3(0.2f, 0, 0),   // 1 — shares edge 0 with the dragged vert
            Vec3(0.4f, 0, 0),   // 2 — shares NOTHING with it
            Vec3(0.6f, 0, 0),   // 3
        ];
        m.edges = [[0u, 1u], [2u, 3u]];

        SnapPacket cfg;
        cfg.enabled      = true;
        cfg.snapScope    = SnapMode.Global;
        cfg.innerRangePx = 200.0f;
        cfg.outerRangePx = 200.0f;
        cfg.enabledTypes = SnapType.EdgeCenter;

        auto pc = pixelOf(Vec3(0.1f, 0, 0));   // edge 0's centre: excluded

        invalidateSnapGrids();
        SnapResult r = snapCursor(cursorWorld, pc[0], pc[1], vp, m, cfg, dragged);
        assert(r.snapped && r.targetType == SnapType.EdgeCenter
            && r.targetIndex == 1,
            "edge 1 shares no vertex with the drag, so it does not move with "
            ~ "it and stays a candidate — the exclusion removes the drag's own "
            ~ "geometry and nothing else");

        // And a lone vertex that is not dragged is still a vertex candidate.
        cfg.enabledTypes = SnapType.Vertex;
        invalidateSnapGrids();
        SnapResult v = snapCursor(cursorWorld, pc[0], pc[1], vp, m, cfg, dragged);
        assert(v.snapped && v.targetType == SnapType.Vertex && v.targetIndex == 1,
            "the Vertex type is the one the old rule already protected, and it "
            ~ "must keep behaving exactly as it did: vertex 0 excluded, vertex "
            ~ "1 (the nearest survivor) wins");
    }

    invalidateSnapGrids();
}
