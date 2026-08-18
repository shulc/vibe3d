module snap;

import std.math : sqrt, round, floor, isNaN;
import core.sync.mutex : Mutex;

import math : Vec3, Viewport, ModelSpace, projectionSpace, projectToWindowFull,
              frontFacingLocal,
              screenRay, screenPointToRay,
              rayPlaneIntersect, pointInPolygon2D,
              closestOnSegment2DSquared, closestOnSegmentToRay, cross, dot,
              closestPointOnLineToRay, isOrtho, viewPixelScale,
              perpendicularFrame, rayTriangleIntersect,
              closestPointOnTriangle2D, triangulatePolygonEarClip;
import mesh : Mesh;
import toolpipe.packets : SnapPacket, SnapType, SnapMode;
import toolpipe.guide   : SnapGuide, kGuidePrioritySeed;
import perf_probe : g_perf, Cat;
import constraint : BackgroundSource;
import snap_election : SnapElection;

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
    // The compiler's `==` over the config sub-struct, exactly as
    // `falloffPacketsEqual` does (task 0705, P8). The seven-way conjunction
    // this replaces was a sixth hand-written enumeration of the same field
    // names, and the one that fails SILENTLY: a config field left out here
    // makes a mid-run change to it invisible to the refire trigger.
    return a.config == b.config;
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

// Parallel array (task 0617 Stage 4): g_snapSourceSpaces[i] is the
// `ModelSpace` of the layer `g_snapSources[i]` came from. Filled by the SAME
// call that installs g_snapSources, so the two can never drift apart. A
// background layer's own item transform is otherwise invisible to the walk
// (`m.vertices[]` are local, `vp` is the world camera) — without this, a
// moved/rotated/mirrored background layer would snap where it WAS, not where
// it is drawn, same defect §1 of the plan fixes for the primary.
private __gshared ModelSpace[] g_snapSourceSpaces;

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
/// `spaces` must be the SAME LENGTH as `sources` — `spaces[i]` is
/// `sources[i]`'s layer's `ModelSpace` (`ItemXform.modelSpace()`). Required,
/// not defaulted (§3.2's lesson): a caller that forgets it is a build error,
/// not a background layer that silently snaps at its identity pose.
///
/// `layerIndices`, when non-empty, must be the same length as `sources` —
/// `layerIndices[i]` is the Document-layer index `sources[i]` was read from
/// (app.d/panels.d fill this in document-layer index order, skipping
/// foreground/invisible layers, so it is generally NOT `i` itself). Callers
/// that don't track indices (or don't need the mapping) may omit it; the
/// mapping then reads back empty and consumers fall back to the bgSrc-order
/// index (see `backgroundSourceLayerIndices()`).
void setBackgroundSnapSources(const(Mesh)*[] sources, const(ModelSpace)[] spaces,
                              const(int)[] layerIndices = null) {
    assert(spaces.length == sources.length,
        "setBackgroundSnapSources: spaces/sources length mismatch");
    synchronized (g_vgridMutex) {
        g_snapSources.length = sources.length;
        foreach (i, s; sources) g_snapSources[i] = s;
        g_snapSourceSpaces.length = spaces.length;
        foreach (i, sp; spaces) g_snapSourceSpaces[i] = sp;
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

/// The `ModelSpace` of the layer `snapSource(slot)` came from — the transform
/// that decides where that source's LOCAL `vertices[]` are actually DRAWN
/// (task 0619). Reads `g_snapSourceSpaces`, the parallel array filled by the
/// same `setBackgroundSnapSources` call that installs `g_snapSources`, so the
/// mesh and its space can never drift apart.
///
/// Deliberately a `bool` + `out` rather than a plain `ModelSpace` return: the
/// two misses (slot 0, which is the ACTIVE mesh and is not held here, and an
/// out-of-range slot) have no space to report, and inventing an identity for
/// them would be exactly the placeholder this task bans — a caller that
/// silently projected a background layer's local vertices through the identity
/// is the defect being fixed, not a fallback. `false` means "no space here",
/// and every caller must then take the same fail-soft path it already takes
/// for `snapSource(slot) is null`.
///
/// NOTE `out ModelSpace` resets `ms` to `ModelSpace.init` (whose matrices are
/// float.init == NaN, NOT the identity) before the body runs, so a caller that
/// ignores the `false` and projects anyway gets NaN pixels rather than a
/// plausible-but-wrong position. That is intentional: a wrong answer here
/// should be loud.
bool snapSourceSpace(int slot, out ModelSpace ms) {
    if (slot <= 0) return false;
    synchronized (g_vgridMutex) {
        size_t i = cast(size_t)(slot - 1);
        if (i >= g_snapSourceSpaces.length) return false;
        ms = g_snapSourceSpaces[i];
        return true;
    }
}

// ---------------------------------------------------------------------------
// Item snap frames (Stage 3). One frame per visible layer, INCLUDING the
// active/primary layer (item snapping deliberately snaps to the active item's
// own pivot/box — unlike setBackgroundSnapSources which skips the primary).
//
// Install shape mirrors setBackgroundSnapSources exactly: the setItemSnapFrames
// CALL is unconditional every draw (ui/panels.d, next to
// setBackgroundSnapSources) so a /api/reset that collapses the document to one
// layer self-clears the prior test's multi-layer frames. Only the slice-fill
// loop may early-out. That draw is the SOLE installer as of task 0587 — the
// /api/snap provider used to install its own copy just-in-time, because it ran
// on the HTTP thread and would otherwise race this one.
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
/// The discrete types whose candidates are gated by the VISIBILITY MASK —
/// i.e. the ones `walkSource`'s `vertVisible` / `edgeVisible` / `faceVisible`
/// stand in front of. Exactly the Component bucket above, named once because
/// two readers want it: the scope filter, and the perf lane's non-vacuity
/// invariant (task 1350/1355), which has to tell "a mask-gated candidate won"
/// from "something else supplied the position while the mask rejected
/// everything". Grid / Workplane / the constraint types reach `SnapElection`
/// without ever consulting the mask, so a snap of those types proves nothing
/// about it.
bool isMaskGatedType(SnapType t)
    pure nothrow @nogc @safe
{
    return t == SnapType.Vertex     || t == SnapType.Edge         ||
           t == SnapType.EdgeCenter || t == SnapType.Polygon      ||
           t == SnapType.PolyCenter || t == SnapType.Intersection;
}

bool typeEligible(SnapType t, SnapMode snapScope_)
    pure nothrow @nogc @safe
{
    // Scope-independent guides pass in every mode.
    if (t == SnapType.Grid        || t == SnapType.Workplane   ||
        t == SnapType.WorldAxis   || t == SnapType.StraightLine ||
        t == SnapType.RightAngle)
        return true;

    bool isComponent = isMaskGatedType(t);
    bool isItem      = (t == SnapType.Pivot      || t == SnapType.Box);

    final switch (snapScope_) {
        case SnapMode.Global:    return true;
        case SnapMode.Component: return isComponent;
        case SnapMode.Item:      return isItem;
    }
}

// ---------------------------------------------------------------------------
// CROSS-TYPE CANDIDATE ARBITRATION — task 0551.
//
// Three of our discrete types do NOT compete on bare screen distance. The
// reference keeps one nearest-candidate accumulator per CLASS — vertex, edge,
// polygon — and merges them with a fixed cascade in that order, asking each
// class in turn "do you win?" and returning the first that says yes. The
// question is answered by `cascadeClassWins` below, which grants the class
// under test a distance TOLERANCE; the vertex class's tolerance is twice the
// other two's, which is what lets a vertex beat an edge that is geometrically
// nearer.
//
// This is not the same mechanism as the `guides` registry further down. That
// registry carries a per-GUIDE priority, and the reference's element-snap
// guide answers with ONE priority for vertex, edge and polygon alike — an
// immediate store with no branch on element type — so "vertex beats edge" is
// not expressible on that channel at all. Nothing per-type is therefore put
// into the registry, and it stays empty.
//
// The two mechanisms DO meet, and the meeting is not a no-op — an earlier
// revision of this block claimed the registry's behaviour was "unchanged",
// and that claim was false. The cascade ranks by distance and tolerance and
// reads no priority whatsoever, so a cascade asked BEFORE the priority is
// resolved silently drops a priority difference between two classes, in both
// directions. `foldCascadeChampion` therefore resolves priority FIRST and
// hands the cascade only the classes that survive at the top priority: the
// registry keeps its documented rule (higher priority wins outright, at any
// distance), and the cascade settles what the registry has left tied. That
// ordering is load-bearing, it is the reference's own nesting, and it is
// pinned by a two-class unittest that fails if the classes are cascaded
// before their priorities are compared.
//
// MEASURED (task 0551, static; corroborated independently by the press-pick
// lane a day earlier, which decoded the same comparator in a different
// consumer and reported the same two constants):
//   * the comparator, clause for clause, including the sentinel distance an
//     absent class carries and the order in which the three legs are asked;
//   * both constants, as `.rodata` fallbacks of two application-wide element-
//     picking preferences that the reporting user's saved profile does not
//     override;
//   * that the tolerance base is `min(callerRange, 8.0)`.
//
// MEASURED SINCE (task 0560, static, same disassembly lane): where the CENTRE
// types sit. The question "where do they rank" had a false premise — they do
// not rank. A centre never opens a candidate of its own; it refines the point
// on a leg the cascade has ALREADY elected. See `refineElectedLeg` in
// `snapCursor` for the rule and `cascadeClass` below for the consequence: a
// centre type carries its ELEMENT's class, because the leg it refines is the
// only thing that was ever ranked.
//
// STILL NOT MEASURED, and therefore not modelled: how these three rank against
// Grid / Workplane / Pivot / Box (a different arbitration layer — see
// `arbitrate`). Those keep the bare distance ranking they have always had.
//
// That unmeasured layer did MOVE under this change, and it is worth naming
// rather than discovering later. A centre-refined leg now meets Grid and the
// item types at its ELEMENT's distance, where it used to meet them at the
// centre's own. That is USUALLY the nearer of the two, so a centre now beats a
// grid point more often than it did — usually, not always, because the
// on-element distance is an approximation that can exceed the centre's own
// (see THE EDGE LEG in `snapCursor` for the case and its numbers).
// That is forced: "the centre inherits the leg's rank" is the measured half,
// and re-ranking the refined point to keep this layer's old outcomes would
// simply reinstate the contest the measurement removed. It is a consequence
// accepted with open eyes, not a second thing that was measured.
// ---------------------------------------------------------------------------

/// Upper bound on the cross-type tolerance base, in pixels. The base itself is
/// `min(acceptanceRange, this)`. MEASURED: it is the shipped default of an
/// application-wide element-picking size setting in the reference, and the
/// reporting user's saved configuration does not override it.
enum float kCandidateToleranceBasePx = 8.0f;

/// The vertex class's tolerance multiplier — the whole of "a vertex may beat a
/// nearer edge" is this number being greater than 1. MEASURED, and the
/// reference ships it as a user-visible setting whose own documentation
/// describes exactly the cursor-near-a-polygon-corner case this fixes.
enum float kVertexToleranceScale = 2.0f;

/// The distance an ABSENT class carries into the comparator. Not "infinity":
/// the comparator subtracts it (`d[i] - d[k]`), and the sentinel's finiteness
/// is load-bearing there — a class with no candidate makes that clause
/// vacuously true rather than NaN.
enum float kAbsentClassDist = 1e12f;

/// The three cascade classes, in the order the merge asks them.
enum int kCascadeVertex  = 0;
enum int kCascadeEdge    = 1;
enum int kCascadePolygon = 2;

/// Which cascade class a discrete snap type belongs to, or -1 for a type the
/// cascade does not model (Grid, Workplane, Pivot, Box, Intersection). A -1
/// type keeps the bare distance ranking.
///
/// A CENTRE TYPE CARRIES ITS ELEMENT'S CLASS, and that is the whole of the
/// measured model showing up in one place. `EdgeCenter` is not a fourth leg
/// competing with Vertex / Edge / Polygon on screen distance — it is the EDGE
/// leg, elected by the on-edge distance like any edge, whose point is then
/// moved to the midpoint (`refineElectedLeg`). The type tag is what the walk
/// reports to the caller; the class is what the cascade ranks. `PolyCenter` is
/// the same one leg over.
///
/// The distinction matters exactly where the two disagree, and they disagree
/// in the direction that was the reported defect: with the centre as its own
/// competitor, a centre on edge E2 could out-rank a Vertex candidate outright,
/// which no arrangement of the reference's code can produce.
int cascadeClass(SnapType t) pure nothrow @nogc @safe
{
    if (t == SnapType.Vertex)     return kCascadeVertex;
    if (t == SnapType.Edge)       return kCascadeEdge;
    if (t == SnapType.EdgeCenter) return kCascadeEdge;
    if (t == SnapType.Polygon)    return kCascadePolygon;
    if (t == SnapType.PolyCenter) return kCascadePolygon;
    return -1;
}

/// Does class `i` win the merge, given each class's nearest distance (`d`,
/// `kAbsentClassDist` where the class has no candidate), which classes have a
/// candidate at all (`has`), and class `i`'s own tolerance (`tol`)?
///
/// The clauses, and their order, are the measured ones:
///
///   1. no candidate of my class            -> lose
///   2. I am the only class with one        -> win
///   3. I am the nearest of the three       -> win
///   4. I am inside my OWN tolerance        -> win   <-- the type priority
///   5. I trail the next class by >= tol    -> lose
///   6. I trail the last class by <  tol    -> win
///   otherwise                              -> lose
///
/// Clauses 5 and 6 are the pair the reporting user is hitting: an edge
/// incident to a vertex is never farther from the cursor than that vertex is,
/// so under a bare "nearest wins" the vertex can only ever tie, never win.
/// Here it wins as long as it does not TRAIL by its whole tolerance — and its
/// tolerance is the doubled one.
///
/// Read as a whole, and given that our own distances are never negative and
/// that an absent class carries a huge finite sentinel, the seven lines reduce
/// to one sentence: **a class wins iff it trails each of the other two by less
/// than its own tolerance.** Clauses 2, 3 and 4 are then early-outs rather
/// than independent rules. They are ported verbatim anyway, for two reasons
/// that are not stylistic: clause 2 is a null-guard in the original and the
/// only clause that does not read a distance at all, and the reduction stops
/// holding the moment a distance can be negative or an exact tie meets a zero
/// tolerance — and a registered guide may answer with any `distPx` it likes,
/// including a negative one (`snapCursor`'s inverting test guide does exactly
/// that). A comparator that is correct only for the distances we happen to
/// produce today is the kind of thing this file has been bitten by before.
bool cascadeClassWins(int i, const ref bool[3] has, const ref float[3] d,
                      float tol) pure nothrow @nogc @safe
{
    if (!has[i]) return false;                       // 1
    immutable int j = (i + 1) % 3;
    immutable int k = (i + 2) % 3;
    if (!has[j] && !has[k]) return true;             // 2
    if (d[j] >= d[i] && d[k] >= d[i]) return true;   // 3
    if (tol >  d[i]) return true;                    // 4
    if (tol <= d[i] - d[j]) return false;            // 5
    if (tol >  d[i] - d[k]) return true;             // 6
    return false;
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

/// Point-in-time copy of the `ModelSpace` parallel to
/// `backgroundSourcesSnapshot()` (task 0617 Stage 4) — index i of this array
/// is `backgroundSourcesSnapshot()[i]`'s layer's transform. A caller that
/// needs the mesh AND its transform together should use
/// `backgroundSourcesFull()` below instead of pairing this with
/// `backgroundSourcesSnapshot()` — that is a SECOND lock and a SECOND
/// allocation on top of the first snapshot (review fix, task 0617 Stage 4:
/// the original design reasoned "a combined struct is for a caller nobody
/// has yet" — the CONS stage's background raycast turned out to be exactly
/// that caller). This accessor stays for a caller that genuinely wants only
/// the spaces.
const(ModelSpace)[] backgroundSourcesModelSpaces() {
    synchronized (g_vgridMutex) {
        if (g_snapSourceSpaces.length == 0) return null;
        return g_snapSourceSpaces.dup;
    }
}

/// Point-in-time copy of the Document-layer index parallel to
/// `backgroundSourcesSnapshot()` (topology-pen P0 NIT-3) — index i of this
/// array is the Document-layer index `backgroundSourcesSnapshot()[i]` was
/// installed from. May be SHORTER than (or empty relative to) the sources
/// snapshot when the installer didn't supply indices; callers must
/// bounds-check and fall back to the bgSrc-order index on a miss. See
/// `backgroundSourcesFull()` below for a caller that needs this together
/// with the mesh and/or the space.
const(int)[] backgroundSourceLayerIndices() {
    synchronized (g_vgridMutex) {
        if (g_snapSourceLayers.length == 0) return null;
        return g_snapSourceLayers.dup;
    }
}

/// Point-in-time copy of EVERY background source's mesh pointer, ModelSpace,
/// AND Document-layer index together, under ONE lock (task 0617 Stage 4
/// review fix). Equivalent to zipping `backgroundSourcesSnapshot()`,
/// `backgroundSourcesModelSpaces()`, and `backgroundSourceLayerIndices()`
/// together, except it is ONE lock acquisition and ONE allocation instead of
/// up to three of each — the shape a caller that needs more than one field
/// (the CONS stage's background-surface raycast; `snapCursor`'s own
/// background walk, below) should use instead of composing the three
/// single-field accessors itself. `BackgroundSource.layerIndex` is -1 when
/// the installer didn't supply an index for that slot (mirrors
/// `backgroundSourceLayerIndices()`'s existing "caller falls back to the
/// source-array index" contract). A caller that needs only ONE field should
/// keep using that field's own accessor above — this one is for a caller
/// that needs several, so the several reads can never drift apart the way
/// two separately-locked snapshots theoretically could.
const(BackgroundSource)[] backgroundSourcesFull() {
    synchronized (g_vgridMutex) {
        if (g_snapSources.length == 0) return null;
        auto r = new BackgroundSource[](g_snapSources.length);
        foreach (i, s; g_snapSources) {
            r[i].mesh  = s;
            r[i].space = i < g_snapSourceSpaces.length
                       ? g_snapSourceSpaces[i] : ModelSpace.world();
            r[i].layerIndex = i < g_snapSourceLayers.length
                             ? g_snapSourceLayers[i] : -1;
        }
        return r;
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
///
/// Priority remains the FIRST term of the key across the cross-type cascade
/// too. The cascade (`cascadeClassWins`) ranks Vertex / Edge / Polygon by
/// distance and tolerance and reads no priority at all, so it is asked only
/// about the classes that TIE at the top priority — a guide that outranks a
/// class removes it from the cascade rather than being overruled by it. With
/// an empty registry every class ties at 0 and nothing is removed.
// `ms` (task 0617 Stage 4) is the ACTIVE mesh's `ModelSpace` — snap.d has no
// `Document` of its own (same boundary as `gpu_select.d`/`bvh_pick.d`), so the
// caller resolves it (`primaryModelSpace()` at the one external call site) and
// hands it in, required, no default — the §3.2 lesson applied here too.
// Background sources get their OWN `ModelSpace` from `g_snapSourceSpaces`
// (installed alongside `g_snapSources`), not this one.
SnapResult snapCursor(Vec3 cursorWorld, int sx, int sy,
                      const ref Viewport vp,
                      const ref Mesh mesh,
                      const ModelSpace ms,
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

    if (!cfg.enabled) return SnapElection.passThrough(cursorWorld);

    // -----------------------------------------------------------------------
    // THE ELECTION (task 0721) — `SnapElection`, in snap_election.d.
    //
    // Two tiers, thirteen accumulator fields and the rules that move them all
    // moved there whole. The split is enumeration / election: this function
    // decides which candidates EXIST, `el` decides which one WINS and where
    // the winning point finally sits. Three calls are the entire seam —
    // `el.consider`, `el.considerConstraint`, `el.resolve`.
    //
    // The environment is bound once here rather than captured eleven times:
    // the closures this replaced shared thirteen mutable locals implicitly, so
    // nothing said which of them wrote the accumulator and which only read it.
    // -----------------------------------------------------------------------

    // The background snap sources, snapshotted ONCE under the grid lock and
    // then read without it. Hoisted above the walk (it used to be taken just
    // before the background loop) because the CENTRE refinement and the vertex
    // veto both run AFTER the walk and both need to resolve a winner's source
    // slot back to the mesh (and its ModelSpace) it came from — see
    // `sourceMesh`/`sourceModelSpace`.
    //
    // Snapshot-then-walk, not walk-under-lock — for lock-scope hygiene, not
    // deadlock avoidance (comment corrected, task 0678 P2: druntime's Mutex
    // is re-entrant — PTHREAD_MUTEX_RECURSIVE / CRITICAL_SECTION — so the
    // old "re-acquire deadlocks" claim here was false). The walk runs guide
    // callbacks and centre refinement whose cost does not belong under the
    // module lock. Empty in the single-layer common case ⇒ no extra work.
    //
    // ONE combined snapshot (task 0617 Stage 4 review fix), not a separate
    // `bgSources`+`bgSpaces` pair: `backgroundSourcesFull()` takes the lock
    // once and allocates once, where the mesh-only and mesh+space snapshots
    // taken separately used to cost two locks and two allocations for
    // exactly the same information.
    const(BackgroundSource)[] bgFull = backgroundSourcesFull();

    auto el = SnapElection(cursorWorld, sx, sy, vp, &mesh, ms, cfg,
                           admit, guides, bgFull);



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
    // `ms` (task 0617 Stage 4) is THIS SOURCE's `ModelSpace` — the primary's
    // for slot 0, the owning background layer's for slots 1..N. `vpLocal`
    // folds it into the viewport ONCE, for the broad-phase candidate-grid
    // projection ONLY (§3.3: forward projection composes exactly). The fine
    // phase below stays in WORLD space instead: `m.vertices[]`/`m.edges[]`
    // read as LOCAL and are transformed point-by-point via `ms.toWorldPoint`
    // where a metric (closest-point, triangle-rank) computation needs them,
    // so those computations run on the same coordinates as the world ray/eye
    // they are compared against — a minimum-distance election is NOT affine
    // invariant under a non-uniform scale the way a ray/plane intersection
    // parameter `t` is (see visibleVertices's doc comment), so local-space
    // math would elect the wrong point under such a transform. The one
    // exception is the front-facing SIGN test in `faceVisible`, which stays
    // local + a `vpLocal.eye` (no `ms.mirrored` correction — see
    // `ModelSpace.mirrored`'s doc comment in math.d for why one is not
    // needed). Since task 0832 that test and the one inside
    // `Mesh.visibleVertices` are not merely "identical" by inspection — they
    // are the SAME function, `math.frontFacingLocal`.
    void walkSource(const ref Mesh m, int slot, const(uint)[] exclude,
                    const ModelSpace ms) {
        const Viewport vpLocal = projectionSpace(vp, ms);
        // Visibility array for occlusion/front-face gating. Built when any
        // geometric type is enabled (faces present + at least one geo type active).
        bool needVis = m.faces.length > 0
            && (cfg.enabledTypes & (SnapType.Vertex | SnapType.Edge
                  | SnapType.EdgeCenter | SnapType.Polygon | SnapType.PolyCenter
                  | SnapType.Intersection));

        // ------------------------------------------------------------------
        // THE MASK, ON FIRST CONSULTATION (task 1350).
        //
        // It used to be computed HERE, unconditionally, whenever `needVis`.
        // Its three consumers below are called only for candidates the
        // candidate GRID returned and `kindExcluded` kept — and in the common
        // whole-mesh drag the moving set is every vertex, so `kindExcluded`
        // drops every candidate and NOT ONE consumer ever runs. The mask was
        // then an O(V+F) pass plus ~1.4 MB of fresh arrays per motion event
        // (~1.0 MB now that the write-only depth array is gone with it),
        // computed and thrown away: 46-66 ms per drag on a 100K mesh
        // (measured 2026-08-18, seven perf cases).
        //
        // It also does NOT make the mask cheap where it IS consulted: its
        // occlusion pass is O(V x |front faces|), so with the faces actually
        // facing the eye one query on that same mesh costs ~5.2 s. That is a
        // separate defect with its own task; laziness only stops paying for
        // an answer nobody asked for.
        //
        // Deferring it changes exactly one observable thing: a query that
        // consults nothing computes nothing. Every query that DOES consult
        // gets the same array from the same inputs at the same point in the
        // walk (nothing between here and the first consultation can move
        // `m`, `vp` or `ms` — they are `const ref` / by-value), so the
        // election is bit-identical by construction.
        //
        // WHY `visReady` AND NOT "is `visStore` empty". An EMPTY mask is a
        // MEANINGFUL value in this function: it is the sentinel for "nothing
        // can occlude, everything is visible", which is what the consumers
        // below still spell as `vis.length == 0` — it is reached when the
        // mesh has no faces, when no geometric type is enabled, and (via
        // `visibleVertices`) when the mesh has no vertices. If "not computed
        // yet" were spelled the same way, the two states would be one: every
        // consultation on such a mesh would re-enter the builder, and any
        // future reader that touched the array directly instead of calling
        // the accessor would silently read "everything visible" rather than
        // computing. The separate flag makes the two states distinct by
        // construction rather than by discipline.
        //
        // `visStore` therefore has EXACTLY ONE WRITER — this accessor — and
        // no reader outside it. Do not add a second one; take the slice the
        // accessor returns.
        bool[] visStore;      // do NOT read directly — call `visMask()`
        bool   visReady;      // "`visStore` is the answer", NOT "it is non-empty"
        const(bool)[] visMask() {
            if (!visReady) {
                if (needVis) {
                    visStore = m.visibleVertices(vp.eye, vp, ms);
                    g_perf.count(Cat.snapVisBuild, 1);
                }
                // SET AFTER the assignment it guards, not before (review fix,
                // task 1356). The flag's stated meaning is "`visStore` is the
                // answer", and between the two statements it was not one.
                // Nothing observes the window today — `visibleVertices`
                // neither re-enters this accessor nor throws — so this is not
                // a bug fix; it is the flag telling the truth at every point,
                // so the next reader does not have to establish those two
                // facts before trusting it.
                visReady = true;
            }
            g_perf.count(Cat.snapVisConsult, 1);
            return visStore;
        }

        // A consultation that came back NO (task 1355). Counted for exactly
        // one reason: a mask that admits everything and a mask that is not
        // consulted at all are the same measurement from outside, and the
        // perf lane needs to tell them apart — see invariant I7b in
        // `tools/perf/run.d`.
        //
        // What is NOT counted here, deliberately:
        //   * `faceVisible`'s hidden-face early-out — it returns BEFORE the
        //     consultation, so there is no answer to record;
        //   * `faceVisible`'s front-facing cull — that is
        //     `math.frontFacingLocal`, a different predicate that would keep
        //     rejecting back-facing faces even if the mask array were
        //     all-true. Counting it would let a case claim "the mask
        //     mattered" on the strength of a test that never read the mask.
        // So this counts MASK-ARRAY rejections only, and its name means that.
        bool visAdmit(bool ok) {
            if (!ok) g_perf.count(Cat.snapVisReject, 1);
            return ok;
        }

        bool vertVisible(uint vi) {
            const vis = visMask();
            return visAdmit(vis.length == 0 || (vi < vis.length && vis[vi]));
        }
        bool edgeVisible(uint a, uint b) {
            const vis = visMask();
            return visAdmit(vis.length == 0
                || (a < vis.length && b < vis.length && vis[a] && vis[b]));
        }
        bool faceVisible(size_t fi, const(uint)[] face) {
            // Hide (task 0613 S4). By INDEX, because the `vis[]` mask cannot
            // express it, and the case where that bites is narrower than it
            // first looks — worth writing down, because the first fixture
            // built for this guard could not reach it.
            //
            // Hide a face whose vertices belong to it ALONE and every one of
            // them derives hidden (§1.2), so `vis[v]` is already false for all
            // of them and the all-corners test below rejects the face without
            // any help. Hide a face in the MIDDLE of a surface — every corner
            // still touches three visible faces — and not one vertex derives
            // hidden. The mask says "visible" for all four corners, the
            // front-facing test says "front", and this line is the only thing
            // between the snap and a face that is not on screen.
            //
            // Vertices and edges need no equivalent guard: `visibleVertices`
            // drops hidden faces from its seed pass, so a derived-hidden
            // vertex is `vis[vi] == false` and a hidden edge has such an
            // endpoint by construction. Only the FACE plane can be hidden
            // while all of its vertices are visible.
            //
            // Placed inside the named gate rather than at its one call site so
            // a second caller inherits it.
            if (m.isFaceHidden(fi)) return false;
            const vis = visMask();
            if (vis.length == 0) return true;
            // FACING — task 0832. This line used to be a THIRD spelling of the
            // predicate (the first triangle's cross, in float, culled at
            // `>= 0`) which disagreed with the other two on a split face. It
            // is now `math.frontFacingLocal` — one home, carrying the
            // reference's rule. The `< 3` guard moved in there with it.
            //
            // Named for what it is: applying that rule to SNAP is an
            // ASSUMPTION. The capture (task 0726) drove the lasso, never a
            // snap gesture, so nobody has measured that the reference culls
            // this way here. See `frontFacingLocal`'s comment.
            if (!frontFacingLocal(m.vertices, face, vpLocal.eye)) return false;
            foreach (v; face)
                if (v >= vis.length || !vis[v]) return visAdmit(false);
            return true;
        }
        // Local -> world, only where the fine-phase math below needs a real
        // world point to compare against the world ray/eye. Identity-gated
        // so the common single-layer case pays a bool check, not a matmul.
        Vec3 toWorld(Vec3 vLocal) {
            return ms.isIdentity ? vLocal : ms.toWorldPoint(vLocal);
        }
        // Task 1069 — the snapper targets the DRAWN vertex, not the base.
        //
        // Labelled honestly: this is an ASSUMPTION, not a measurement. Phase 0
        // measured that the reference DRAWS base+delta and that its POLYGON
        // picking follows the draw; its snap gesture was never driven, so
        // nobody has measured that it snaps to the morphed position there. The
        // rule is applied because snapping to a point the user cannot see is a
        // defect on its own terms, and because snap's two legs (the
        // `visibleVertices` mask and the candidate positions here) must at
        // least agree with EACH OTHER. If snap is ever measured and answers
        // differently, THIS is the assumption to revisit.
        Vec3 vAt(size_t vi) {
            import morph_target : displayPosition;
            return toWorld(displayPosition(&m, vi));
        }

        if ((cfg.enabledTypes & SnapType.Vertex)
                && typeEligible(SnapType.Vertex, cfg.snapScope)) {
            auto cands = queryCandidateGrid(Kind.Vertex, slot, m, vpLocal, sx, sy,
                                            cfg.outerRangePx, exclude);
            foreach (vi; cands)
                if (vertVisible(vi))
                    el.consider(vAt(vi), cast(int)vi, SnapType.Vertex, slot);
        }

        // ------------------------------------------------------------------
        // THE EDGE LEG — enumerated when EITHER the Edge type or the
        // EdgeCenter type is on, and enumerated exactly once either way.
        //
        // A centre never opens a candidate of its own (see `refineElectedLeg`),
        // so the EdgeCenter type does not get a walk; what it gets is an edge
        // walk, because the leg it will refine has to be elected first. The
        // candidate offered to `consider` is the ON-EDGE point in both cases —
        // that is the point the leg is ranked on.
        //
        // WHAT THE ON-EDGE POINT IS — MEASURED (task 0567 / the edge-point
        // election read), and it is a two-stage law with two DIFFERENT metrics
        // on purpose:
        //
        //   1. the SEGMENT is elected in SCREEN space. For a straight edge
        //      that is one segment and the stage collapses to "does this edge
        //      project at all", which is the endpoint guard below. (The
        //      reference tessellates curved edges and really does pick among
        //      several segments here; our edges are straight, so the stage has
        //      nothing to choose between.)
        //   2. the POINT ON that segment is elected in 3D: the closest
        //      approach between the world segment and the cursor's eye RAY,
        //      clamped to [0, 1] — `closestOnSegmentToRay`.
        //   3. the RANK is the elected point's TRUE SCREEN distance, obtained
        //      by re-projecting it. Not the stage-1 metric and not the 3D
        //      distance. `consider` below already does exactly that, so the
        //      rank half of the law was never the missing half.
        //
        // The two-metric structure is the part a port gets wrong, because the
        // natural implementation ranks with whatever it elected with.
        //
        // WHAT THIS REPLACED, and why it was a defect rather than a parity
        // choice. The old code took the closest parameter on the PROJECTED
        // segment and applied it as a WORLD parameter, so `a + (b - a) * t`
        // was the nearest point only when the endpoints sat at equal depth.
        // Over 55 514 random near-cursor edges the old elected point sat a
        // median 12.58 px from the cursor with a tail to 593 px; this law's
        // sits a median 3.71 px away with a tail that stops at 13.6 px.
        //
        // NOT THE SCREEN-NEAREST POINT, and the distinction is the whole
        // reason this is written out. The perspective-correct screen-nearest
        // parameter `u = t*wa / ((1-t)*wb + t*wa)` is a THIRD law — it was the
        // one 0567 originally filed — and it is not this one. The two agree to
        // the last bit whenever the eye, the cursor ray and the edge are
        // COPLANAR, which is exactly the rig 0567 measured on; off that plane
        // they disagree by up to 0.61 in parameter, at the clamps, where one
        // wants a point past an endpoint and the other does not. So a test
        // written on a coplanar rig cannot tell the two apart and would pass
        // either way — the test that guards this line spans depth deliberately.
        // This form also needs no clip `w` at all, and is cheaper for it.
        //
        // WHAT HOLDS UNCHANGED is the reachability rule the centre model is
        // made of: A CENTRE IS REACHABLE EXACTLY WHEN ITS ELEMENT IS. A range
        // that cannot reach the edge cannot reach that edge's centre either —
        // including when the cursor is sitting on the centre's own pixel. That
        // is the measured shape (the reference queries the centre only inside
        // a branch that already holds a hit edge), it is what makes "the
        // centre inherits the leg's rank" a single rule instead of two, and it
        // is pinned by a test. It survives this fix because it never depended
        // on WHICH on-edge point was elected, only on the edge being elected
        // at all.
        //
        // THE POLYGON LEG DOES NOT RUN THIS LAW, and the reason is worth
        // keeping next to it. Its reference site turned out to be a different
        // function running a different algorithm — no boundary ring at all,
        // a triangulation and a ray/triangle test, and a rank that is not a
        // re-projection (task 0580's read, ported by 0588). So "the same fix
        // one leg over" was never available; see `closestOnPolygonSurface`.
        //
        // `legType` is what the walk REPORTS (it reaches the `admit`
        // predicate, and it is the `SnapResult.targetType` when no refinement
        // fires). With EdgeCenter alone it is EdgeCenter, so a client that
        // admits by type sees exactly the type it asked for, as before. With
        // both on it is Edge, and the contest inside `refineElectedLeg`
        // decides which of the two the result finally carries.
        //
        // `cascadeClass` maps both tags onto the edge class, so which tag is
        // used here never changes what is ranked against what.
        // ------------------------------------------------------------------
        immutable bool edgeTypeOn = (cfg.enabledTypes & SnapType.Edge) != 0
                                 && typeEligible(SnapType.Edge, cfg.snapScope);
        immutable bool edgeCtrOn  = (cfg.enabledTypes & SnapType.EdgeCenter) != 0
                                 && typeEligible(SnapType.EdgeCenter, cfg.snapScope);
        if (edgeTypeOn || edgeCtrOn) {
            immutable SnapType legType = edgeTypeOn ? SnapType.Edge
                                                    : SnapType.EdgeCenter;
            auto cands = queryCandidateGrid(Kind.Edge, slot, m, vpLocal, sx, sy,
                                            cfg.outerRangePx, exclude);
            // The cursor's eye ray — one per call, not one per edge. Built
            // from the WORLD `vp`, never `vpLocal` (§3.3 — screenPointToRay
            // treats the view's upper-3x3 as its own inverse, which a
            // composed scale/shear breaks silently).
            Vec3 rayOrig, rayDir;
            screenPointToRay(cast(float)sx, cast(float)sy, vp, rayOrig, rayDir);
            foreach (ei; cands) {
                auto edge = m.edges[ei];
                if (!edgeVisible(edge[0], edge[1])) continue;
                // WORLD, so the closest-approach election below (a metric
                // computation, NOT affine-invariant under non-uniform scale)
                // runs against the ray in the same space it was cast in.
                Vec3 a = vAt(edge[0]);
                Vec3 b = vAt(edge[1]);
                // STAGE 1, and the only thing left of it for a straight edge:
                // an edge with an endpoint behind the camera is not elected.
                // The candidate grid already drops those (`projectElementCells`
                // fails on the first behind-camera vertex), so this repeats the
                // grid on the normal path — but `queryCandidateGrid` returns
                // EVERY index unfiltered when the range is degenerate
                // (`outerRangePx <= 0`), and on that path this guard is the
                // only one there is.
                float px0, py0, ndcZ0, px1, py1, ndcZ1;
                if (!projectToWindowFull(a, vp, px0, py0, ndcZ0)) continue;
                if (!projectToWindowFull(b, vp, px1, py1, ndcZ1)) continue;
                // STAGE 2 — the election, in 3D. A degenerate answer (a
                // zero-length edge, or an edge pointing straight down the view
                // ray) leaves `t` at 0 and elects endpoint `a`: every point on
                // such an edge shares one pixel, so the rank is the same
                // whichever is chosen, and `consider` ranks it correctly either
                // way.
                float t;
                closestOnSegmentToRay(rayOrig, rayDir, a, b, t);
                // STAGE 3 — the rank. `consider` re-projects and measures the
                // true screen distance; that IS the reference's ranking metric.
                el.consider(a + (b - a) * t, cast(int)ei, legType, slot);
            }
        }

        // The POLYGON leg — the edge leg's rule one leg over, and the
        // reference's shape there is the same shape (a polygonCenter query
        // that only ever happens inside a branch already holding a polygon).
        // The candidate is the closest point on the face SURFACE; the centroid
        // arrives, if at all, in `refineElectedLeg`.
        immutable bool polyTypeOn = (cfg.enabledTypes & SnapType.Polygon) != 0
                                 && typeEligible(SnapType.Polygon, cfg.snapScope);
        immutable bool polyCtrOn  = (cfg.enabledTypes & SnapType.PolyCenter) != 0
                                 && typeEligible(SnapType.PolyCenter, cfg.snapScope);
        if (polyTypeOn || polyCtrOn) {
            immutable SnapType legType = polyTypeOn ? SnapType.Polygon
                                                    : SnapType.PolyCenter;
            auto cands = queryCandidateGrid(Kind.Polygon, slot, m, vpLocal, sx, sy,
                                            cfg.outerRangePx, exclude);
            // THE GATHER AND THE RANK ARE NOW DIFFERENT METRICS HERE, and the
            // seam is ours, not the reference's. `queryCandidateGrid` gathers
            // by SCREEN distance (that is the only thing a screen-space bucket
            // grid can guarantee), while the rank `closestOnPolygonSurface`
            // returns divides a WORLD distance by the view's single
            // world-per-pixel. The two agree exactly at the view's own scale
            // distance and diverge as `depth / scaleDistance` away from it, so
            // a face NEARER than that distance can rank inside `outerRangePx`
            // while its screen distance puts it outside the grid's 3x3 block —
            // and it is then never offered. The reference's own enumeration
            // cutoff is unread, so this is recorded as a limit of our broad
            // phase rather than claimed as agreement with theirs. Widening the
            // gather to cover it is a perf decision with no measurement behind
            // it yet, and is deliberately not taken here.
            foreach (fi; cands) {
                auto face = m.faces[fi];
                if (!faceVisible(fi, face)) continue;
                Vec3  hit;
                float rankPx;
                if (closestOnPolygonSurface(face, m, sx, sy, vp, ms, hit, rankPx))
                    el.consider(hit, cast(int)fi, legType, slot, rankPx);
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
            auto cands = queryCandidateGrid(Kind.Edge, slot, m, vpLocal, sx, sy,
                                            cfg.outerRangePx, exclude);
            for (size_t ia = 0; ia < cands.length; ++ia) {
                int eiA = cands[ia];
                auto edgeA = m.edges[eiA];
                if (!edgeVisible(edgeA[0], edgeA[1])) continue;
                float pxA0, pyA0, ndcA0, pxA1, pyA1, ndcA1;
                Vec3 a0 = vAt(edgeA[0]), a1 = vAt(edgeA[1]);
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
                    Vec3 b0 = vAt(edgeB[0]), b1 = vAt(edgeB[1]);
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
                    el.consider(world, eiA, SnapType.Intersection, slot);
                }
            }
        }
    }

    // Source 0 = the active layer (with the dragged-vertex exclusion).
    // Single-layer / no-visible-background documents stop here, byte-identical
    // to pre-Stage-5.
    walkSource(mesh, 0, excludeVerts, ms);

    // Sources 1..N = the visible background layers (layers Stage 5). A
    // background layer is never being dragged, so it carries no exclusion; its
    // grids live in slots 1.. so they never alias the active grid. `bgFull`
    // is the combined snapshot taken at the top of the function (it has to
    // be taken before the walk now, because the post-walk refinement reads
    // it too) — each entry's OWN `.space` (task 0617 Stage 4) goes straight
    // to `walkSource`, no separate bounds-guarded array lookup needed.
    foreach (i, e; bgFull)
        if (e.mesh !is null)
            walkSource(*e.mesh, cast(int)(i + 1), null, e.space);

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
            el.consider(snapped, -1, SnapType.Grid, 0);
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
            el.consider(hit, -1, SnapType.Workplane, 0);
    }

    // -----------------------------------------------------------------------
    // Stage 3: Pivot point targets — from item snap frames (discrete tier).
    // Item frames are installed per-frame by the draw (ui/panels.d) — that
    // is the only installer; the /api/snap provider's just-in-time copy of
    // it went away when that endpoint moved onto the main thread (task 0587).
    // Scope: Item bucket (+ Global).
    // -----------------------------------------------------------------------
    if ((cfg.enabledTypes & SnapType.Pivot)
            && typeEligible(SnapType.Pivot, cfg.snapScope)) {
        ItemSnapFrame[] frames;
        synchronized (g_vgridMutex) {
            if (g_itemSnapFrames.length > 0)
                frames = g_itemSnapFrames.dup;
        }
        foreach (fi, ref frame; frames)
            el.consider(frame.pivot, cast(int)fi, SnapType.Pivot, 0);
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
                el.consider(c, cast(int)ci, SnapType.Box, 0);

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
                    el.considerConstraint(hit, SnapType.Box);
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
            el.considerConstraint(hit, SnapType.WorldAxis);
        }
    }

    // -----------------------------------------------------------------------
    // Close the election (task 0721). The cascade fold, the centre refinement,
    // the vertex veto and the discrete/constraint merge rule all live in
    // `SnapElection.resolve` now; what is left here is the enumeration that
    // fed it.
    // -----------------------------------------------------------------------
    auto elected = el.resolve();
    // Task 1350 — the perf lane's non-vacuity half. A snap case can call
    // `snapCursor` on every motion event (that is all invariant I5 checks)
    // and still elect NOTHING on every one of them, which is what happens
    // when the camera leaves every face back-facing: the mask comes out
    // all-false and no geometric candidate is ever offered. Counting the
    // elections is what tells a case that measures the occlusion path from a
    // case that measures an empty one.
    if (elected.snapped) {
        g_perf.count(Cat.snapHit, 1);
        // ...and the SECOND counter, because the first one cannot carry that
        // claim alone (review fix, task 1355). `snapped` is also true when
        // the grid / workplane tier or a LINE/PLANE constraint supplied the
        // position, and NONE of those consult the visibility mask. So an
        // all-false mask — every geometric candidate rejected — still leaves
        // `snapHit` non-zero while `snapQuery` gets CHEAPER, which a
        // day-over-day gate then reports as an improvement. This counter
        // fires only when the discrete tier won (`constraintType == None`)
        // with a type the mask actually stood in front of, which is the
        // literal statement "a mask-gated candidate won".
        if (elected.constraintType == SnapType.None
            && isMaskGatedType(elected.targetType))
            g_perf.count(Cat.snapHitGeom, 1);
    }
    return elected;
}

// ---------------------------------------------------------------------------
// THE POLYGON-SURFACE ELECTION — the reference's law, ported whole (task 0588).
//
// Closest world-space point on a polygon's SURFACE to the cursor at screen
// pixel (sx, sy), together with the RANK that election is worth. Returns false
// when the face has fewer than three vertices, when the view has no usable
// pixel scale, or when no triangle survives the behind-the-eye guard — the
// caller then skips that face entirely.
//
// THE LAW, in the order it runs:
//
//   1. Triangulate the polygon.
//   2. Per triangle, intersect the cursor's eye ray with it. A hit at t >= 0
//      elects `origin + t*dir` and ranks it EXACTLY 0.0.
//   3. On a miss, build a frame perpendicular to the ray, project the three
//      vertices into it, take the closest point of the projected TRIANGLE to
//      the ray's own projection, rebuild that point in WORLD from the
//      barycentric coordinates it came back with, and rank it
//      `sqrt(d2) / viewPixelScale(vp)`.
//   4. Lowest rank wins; ties keep the earlier triangle.
//
// THERE IS NO BOUNDARY RING, and its absence is the structural half of the
// port. Interior, edge and corner are one operation: a cursor beside the
// polygon lands on whichever part of a triangle is nearest, which may be an
// edge point or a vertex, and nothing had to decide which of those it was.
//
// WHAT THIS REPLACED, in three parts, all of them measured against the
// reference statically and none of them a repair of the old code on its own
// terms:
//
//   D1 — THE INTERIOR TEST. Ours was point-in-polygon on the PROJECTED
//        outline, and the hit was against ONE plane through face[0] carrying
//        the normal of the first three vertices. That is exact for a planar
//        polygon and meaningless otherwise: on a NON-PLANAR face the elected
//        point sat on a plane the surface does not lie in, off the model by
//        however far the face folds. Per-triangle intersection has no such
//        plane to be wrong about. On a NON-CONVEX face the two agree only
//        because `pointInPolygon2D`'s crossing rule is itself correct about
//        notches — which is exactly why the triangulation here must be an EAR
//        CLIP and not the fan the display path uses: a fan would cover the
//        notch and report a cursor sitting beside the polygon as being on it,
//        i.e. it would be a regression against the code being replaced.
//
//   D2 — THE EXTERIOR POINT (fixed in 0587, subsumed here). The ring took the
//        closest parameter on the PROJECTED segment and applied it as a WORLD
//        parameter, which is the same point only when the endpoints sit at
//        equal depth. 0587 replaced that with a 3D election against the eye
//        ray. Both of those minimised distance-to-the-ray over ONE segment at
//        a time and then chose between segments by re-projected screen
//        distance; this law minimises the same quantity over the whole
//        triangle and chooses by the world distance itself. On a fixture where
//        one boundary edge is plainly the near one, all three agree — which is
//        why 0587's decisive block below still passes unchanged.
//
//   D3 — THE RANK. `consider()` re-projects a candidate and ranks it by true
//        screen distance, which is depth-correct. The reference does not: it
//        divides a world distance by the view's SINGLE world-per-pixel, so its
//        polygon ranks are stretched by `depth / scaleDistance` relative to
//        ours, and two faces at different depths can order the other way
//        round. And a ray hit ranks at a literal 0.0, not at "the screen
//        distance of a point that happens to sit on the cursor's pixel" —
//        so every polygon the cursor is over TIES.
//
// THE TIE IS FAITHFUL, AND WHAT IT DECIDES IS ITERATION ORDER, NOT A
// TIE-BREAK. `consider()` accumulates with a strict `<`, so among equal ranks
// the FIRST candidate offered keeps the slot; the polygon leg walks
// `queryCandidateGrid`'s ascending-index answer, so the lowest face index
// under the cursor wins. That is the reference's mechanism exactly — first in
// its own enumeration wins — and it is as far as fidelity can go: WHICH face
// its enumerator reaches first is a property of its spatial structures, not of
// this law, and inventing a tie-break to paper over that would replace a
// faithful indeterminacy with an unfaithful certainty. Under the old rank the
// same two faces did not tie at all; they differed in the last few bits of a
// re-projection, so the winner was decided by float noise. Deterministic-by-
// order is strictly more predictable than that, as well as being the port.
//
// ONE MORE BEHAVIOUR CHANGE, small and named: the old code returned false as
// soon as any face vertex failed to project, so a face with a single vertex
// behind the camera was not snappable at all. The reference has no such rule —
// it guards per elected POINT (`dot(dir, P - origin) < 0`, perspective only) —
// and neither does this. In practice nothing new becomes reachable, because
// `projectElementCells` drops such faces from the candidate grid before this
// is ever called.
// ---------------------------------------------------------------------------
private bool closestOnPolygonSurface(const(uint)[] face,
                                     const ref Mesh mesh,
                                     int sx, int sy,
                                     const ref Viewport vp,
                                     const ModelSpace ms,
                                     out Vec3 worldHit,
                                     out float rankPx)
{
    worldHit = Vec3(0, 0, 0);
    rankPx   = float.infinity;
    if (face.length < 3) return false;

    // No scale ⇒ no rank. Bailing is the only honest answer: a fallback
    // divisor would silently produce ranks in units nothing else shares.
    immutable float pixelScale = viewPixelScale(vp);
    if (!(pixelScale > 0.0f)) return false;

    Vec3 rayOrig, rayDir;
    screenPointToRay(cast(float)sx, cast(float)sy, vp, rayOrig, rayDir);
    Vec3 fu, fv;
    if (!perpendicularFrame(rayDir, fu, fv)) return false;

    // Task 0617 Stage 4: `pts` already existed (no new allocation) — folding
    // `ms` into its fill is the whole fix. Both the ray/triangle intersection
    // below and the closest-point-on-triangle miss arm need `pts` in the SAME
    // space as `rayOrig`/`rayDir` (WORLD): the intersection's `t` alone would
    // survive local space (an affine invariant, per `visibleVertices`'s doc
    // comment), but the miss arm's `d2`/`rank` is a perpendicular DISTANCE —
    // not affine-invariant under non-uniform scale — so the whole function
    // has to run in one consistent (world) space, not a mix of the two.
    auto pts = new Vec3[](face.length);
    foreach (i, vi; face)
        pts[i] = ms.isIdentity ? mesh.vertices[vi] : ms.toWorldPoint(mesh.vertices[vi]);

    auto tris = triangulatePolygonEarClip(pts);
    if (tris.length == 0) return false;

    // The behind-the-eye guard on the MISS arm is perspective-only, matching
    // the reference's view-type test. In an ortho view every point is "in
    // front" in the only sense the projection cares about.
    immutable bool perspective = !isOrtho(vp);

    bool  found = false;
    float best  = float.infinity;
    Vec3  bestP = Vec3(0, 0, 0);

    foreach (tri; tris) {
        immutable Vec3 v0 = pts[tri[0]];
        immutable Vec3 v1 = pts[tri[1]];
        immutable Vec3 v2 = pts[tri[2]];

        Vec3  p;
        float rank;
        float t, hu, hv;
        if (rayTriangleIntersect(rayOrig, rayDir, v0, v1, v2, t, hu, hv)) {
            if (t < 0.0f) continue;               // behind the eye
            p    = rayOrig + rayDir * t;
            rank = 0.0f;                          // a literal zero, not an epsilon
        } else {
            // The projection is RELATIVE TO THE RAY ORIGIN, so the ray itself
            // projects to (0, 0) and the 2D distance is the perpendicular
            // distance from the ray LINE — a world length, which is what makes
            // dividing it by a world-per-pixel produce pixels.
            float u, v;
            immutable Vec3 w0 = v0 - rayOrig, w1 = v1 - rayOrig, w2 = v2 - rayOrig;
            immutable float d2 = closestPointOnTriangle2D(
                0.0f, 0.0f,
                dot(w0, fu), dot(w0, fv),
                dot(w1, fu), dot(w1, fv),
                dot(w2, fu), dot(w2, fv),
                u, v);
            p    = v0 + (v1 - v0) * u + (v2 - v0) * v;
            rank = sqrt(d2) / pixelScale;
            if (perspective && dot(rayDir, p - rayOrig) < 0.0f) continue;
        }
        if (rank < best) { best = rank; bestP = p; found = true; }
    }

    if (!found) return false;
    worldHit = bestP;
    rankPx   = best;
    return true;
}

// Rank-discarding form. Kept so a caller that only wants the point does not
// have to declare a variable it will not read — and so the fixtures written
// against the election alone go on calling exactly what they called before.
private bool closestOnPolygonSurface(const(uint)[] face,
                                     const ref Mesh mesh,
                                     int sx, int sy,
                                     const ref Viewport vp,
                                     const ModelSpace ms,
                                     out Vec3 worldHit)
{
    float rankPx;
    return closestOnPolygonSurface(face, mesh, sx, sy, vp, ms, worldHit, rankPx);
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
//   - Vertex — POINT candidates: one projected screen point per element.
//     Bucketed into the single cell that point falls in.
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
//   is within outerRangePx is returned. (The segment exact test uses the
//   element's true closest point, which is <= the closest bbox point's
//   distance, so no in-range element is missed.) Exact superset.
//
// EXACT FOR EVERY KIND EXCEPT POLYGON, since task 0588. The guarantee above
// is stated in SCREEN distance because that is the only quantity a
// screen-space bucket grid holds. The polygon leg no longer accepts on a
// screen distance: `closestOnPolygonSurface` returns the reference's rank, a
// world distance over the view's single world-per-pixel, which relates to the
// screen distance by `depth / scaleDistance`. For a face at or beyond the
// view's scale distance the rank is >= the screen distance and the superset
// still holds outright; for a face NEARER than it the rank is smaller, so a
// face whose screen distance exceeds `outerRangePx` — and which this grid
// therefore never offers — could have ranked inside it. That is a real limit
// of this broad phase against that leg, it is bounded by how much nearer than
// the focus distance a face is, and widening the query to close it is a perf
// change with no measurement behind it. Recorded, not fixed. See the polygon
// block in `snapCursor`.
//
// CACHE KEY (per kind): (vp.view, vp.proj, viewport rect) +
// mesh.mutationVersion + element count + cellPx. All stable during a
// drag ⇒ built once at drag start, reused every frame. Topology / non-
// drag edits bump mutationVersion and force a rebuild.
//
// EXCLUDE IS QUERY-TIME, NOT KEY: every element is indexed at build
// time; the dragged set (excludeVerts) is applied at QUERY time. An
// element is excluded iff ANY of its incident verts is dragged — the
// source vert (Vertex) / either edge endpoint (Edge) / any face vert
// (Polygon). See `kindExcluded` for why ANY and not ALL.
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
// THREAD SAFETY (comment corrected, task 0678 P2): every caller runs on
// the MAIN thread — the drag path directly, and the `/api/snap` test
// endpoint via snapQueryBridge since task 0587 (the provider executes on
// main; see http_providers.d's bridge wiring — this comment used to claim
// the HTTP server thread called in here directly, which is no longer
// true). The module-level grid cache still takes g_vgridMutex around
// build + query so a future off-thread reader stays correct (queries are
// ~O(1) and builds rare, so the uncontended lock is negligible).
//
// CELL SIZE: `outerRangePx`. When degenerate (<= 0) the query falls back
// to returning ALL non-excluded element indices (index-ascending) so the
// caller's exact walk is a full — but still correct — linear scan; only
// ever reached for pathological configs.

// There is no EdgeCentre / PolyCentre kind, and its absence is the model
// rather than an omission: a centre is never enumerated, so it never needs a
// broad phase. The two grids that used to index midpoints and centroids were
// built and maintained per frame purely to feed candidate walks that no longer
// exist; a centre is now reached from its already-elected element, in O(1),
// with no grid at all. (The reference's own element enumerator has no centre
// entry in its type vocabulary either.)
private enum Kind { Vertex, Edge, Polygon }

private bool kindIsPoint(Kind k) {
    return k == Kind.Vertex;
}

// Number of elements of a kind present in the mesh.
private size_t kindCount(Kind k, const ref Mesh mesh) {
    final switch (k) {
        case Kind.Vertex:  return mesh.vertices.length;
        case Kind.Edge:    return mesh.edges.length;
        case Kind.Polygon: return mesh.faces.length;
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
// The first bullet reads as history now and is still load-bearing as a rule.
// A centre is no longer enumerated at all (task 0560 — it refines an elected
// element instead), so the centroid of a deforming edge or face cannot be a
// candidate on its own; what stops it is that its ELEMENT is excluded here and
// so is never elected, which is the same protection reached one step earlier.
// Deleting a case from this switch would restore the defect through the new
// route as surely as through the old one.
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
        case Kind.Edge: {
            auto e = mesh.edges[idx];
            return exV(e[0]) || exV(e[1]);
        }
        case Kind.Polygon: {
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
// excluded. Returns a per-call COPY (task 0678 P2): the collection runs in
// a module-scoped scratch under g_vgridMutex, but the pre-fix code returned
// that scratch itself after RELEASING the lock — the next query (any
// thread, or even the same walk re-entering for another source) would
// resize/reallocate it under the previous caller's slice. The candidates
// are the near-cursor handful, so the dup is cheap; the degenerate
// full-scan path below is the one all-indices exception (rare config).
// See the broad-phase contract + coverage guarantee in the section header.
private int[] queryCandidateGrid(Kind k, int slot, const ref Mesh mesh,
                                 const ref Viewport vp,
                                 int sx, int sy, float outerRangePx,
                                 const(uint)[] excludeVerts) {
    g_vgridMutex.lock();
    scope (exit) g_vgridMutex.unlock();

    g_candScratch.length = 0;
    size_t n = kindCount(k, mesh);
    if (n == 0) return null;

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
        return g_candScratch.dup;
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

    if (g.nCols == 0 || g.nRows == 0) return null;

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
    return g_candScratch.dup;
}

// Reusable candidate-list scratch + dedup seen-set, both guarded by
// g_vgridMutex via the query. `g_candScratch` is the WORKING buffer only —
// the query returns a per-call copy (see queryCandidateGrid's doc comment,
// task 0678 P2); `g_candSeenIdx` records which seen-set bits were
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
// Task 0833 — the candidate grid's `meshAddr` key term must be load-bearing.
//
// The grid table is GLOBAL and keyed by (slot, kind), not by mesh: the same
// slot 0 vertex grid serves whichever mesh the snapper is currently walking.
// Two different layers' meshes can sit at an equal `mutationVersion` (two
// cubes; or an undo that walks a background layer back onto a version another
// layer also holds), and they have equal `elemCount` too — so on a
// layer.select with no intervening mutation, `meshAddr` is the ONLY key term
// that separates them. Its absence is precisely the aliasing bug this class
// already produced once in this tree, which is why the term exists; the block
// below is what makes deleting it observable rather than a matter of reading
// the comment above the field.
//
// This block lives in source/snap.d rather than tests/unit/ because
// `queryCandidateGrid` and `CandidateGrid` are module-private — the same rule
// task 0706 applied when it moved the rest out. It is not `debug`-wrapped:
// a cache key is live in every build, unlike the `debug assert` guards this
// task's other half exercises.
// ---------------------------------------------------------------------------
unittest {
    import mesh                    : makeCube;
    import math                    : lookAt, perspectiveMatrix;
    import std.math                : PI, sqrt;
    import std.algorithm.searching : canFind;
    import std.conv                : to;

    invalidateSnapGrids();   // this block owns slot 0 for its duration

    Mesh a = makeCube();
    Mesh b = makeCube();
    // Direct position writes — no commitChange, so the two meshes stay at the
    // SAME mutationVersion (and the same vertex count).
    foreach (ref v; b.vertices) v = v + Vec3(3.0f, 0, 0);
    assert(a.mutationVersion == b.mutationVersion,
        "setup: the two meshes must collide on mutationVersion — that "
        ~ "collision IS the hazard, and with one layer it was invisible");
    assert(a.vertices.length == b.vertices.length,
        "setup: equal element counts, so `elemCount` cannot separate them "
        ~ "either");

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    immutable float gatherPx = SnapPacket.init.outerRangePx;

    float px, py, ndc;
    assert(projectToWindowFull(a.vertices[0], vp, px, py, ndc),
        "setup: mesh A's vertex 0 must project on-screen");

    // Build + populate slot 0's grid against mesh A.
    auto candsA = queryCandidateGrid(Kind.Vertex, 0, a, vp,
                                     cast(int)px, cast(int)py, gatherPx, null);
    assert(candsA.canFind(0),
        "sanity: A's vertex 0 must be a candidate at its own screen position");

    // Mesh B has no vertex anywhere near that pixel, so an honest rebuild
    // answers with nothing at all.
    foreach (i, v; b.vertices) {
        float qx, qy, qndc;
        assert(projectToWindowFull(v, vp, qx, qy, qndc),
            "setup: B's vertex " ~ i.to!string ~ " must project on-screen");
        immutable float dx = qx - px, dy = qy - py;
        assert(sqrt(dx * dx + dy * dy) > 3.0f * gatherPx,
            "setup: every B vertex must sit well outside the gather block "
            ~ "around A's vertex-0 pixel, or this proves nothing");
    }

    auto candsB = queryCandidateGrid(Kind.Vertex, 0, b, vp,
                                     cast(int)px, cast(int)py, gatherPx, null);
    assert(candsB.length == 0,
        "a second mesh at the SAME mutationVersion and element count must "
        ~ "force a grid rebuild, not answer out of the first mesh's buckets — "
        ~ "got " ~ candsB.length.to!string ~ " candidate(s); the grid's "
        ~ "(meshAddr, meshVersion, …) key has lost its address term and two "
        ~ "same-version layers are aliasing again");

    invalidateSnapGrids();   // leave the shared table as this block found it
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
    SnapResult bare = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg);
    assert(bare.snapped && bare.targetIndex == 0
        && bare.targetType == SnapType.Vertex && bare.targetSource == 0,
        "baseline: vertex 0 sits under the cursor");
    assert(sameVec(bare.worldPos, m.vertices[0]));

    // --- 1. EQUIVALENCE: the mirror guide changes nothing --------------------
    invalidateSnapGrids();
    auto mirror = new MirrorGuide(vp, sx, sy);
    SnapResult guided = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
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
    SnapResult admitted = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null,
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
    SnapResult flipped = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
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
    SnapResult none = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
                                 [refuses]);
    SnapPacket offCfg = cfg;
    offCfg.enabled = false;
    SnapResult disabled = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), offCfg);
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
    SnapResult elevated = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null,
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
    SnapResult elevatedNear = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null,
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
    SnapResult arb = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
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
    SnapResult arbSwapped = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null,
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
    SnapResult tiedPrio = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null,
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
    SnapResult tiedPrioSwapped = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg,
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
    SnapResult seeded = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
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

    SnapResult tieBare = snapCursor(cursorWorld, sx, sy, vp, tie, ModelSpace.world(), cfg);
    assert(tieBare.snapped && tieBare.targetIndex == 0,
        "the tie goes to the lower index");
    invalidateSnapGrids();
    auto tieMirror = new MirrorGuide(vp, sx, sy);
    SnapResult tieGuided = snapCursor(cursorWorld, sx, sy, vp, tie, ModelSpace.world(), cfg, null,
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

    SnapResult cBare = snapCursor(cursorWorld, cx, cy, vp, m, ModelSpace.world(), ccfg);
    assert(cBare.snapped && cBare.constraintType == SnapType.WorldAxis,
        "fixture: a world-axis constraint must fire at this pixel, otherwise "
        ~ "the constraint-tier assertions below are vacuous");

    invalidateSnapGrids();
    auto cMirror = new MirrorGuide(vp, cx, cy);
    SnapResult cGuided = snapCursor(cursorWorld, cx, cy, vp, m, ModelSpace.world(), ccfg, null,
                                    null, [cMirror]);
    assert(sameResult(cBare, cGuided),
        "S4 equivalence holds in the constraint tier too");

    invalidateSnapGrids();
    auto cRefuses = new MirrorGuide(vp, cx, cy);
    cRefuses.admitAll = false;
    SnapResult cNone = snapCursor(cursorWorld, cx, cy, vp, m, ModelSpace.world(), ccfg, null, null,
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
// TASK 0551 — THE REGISTRY MEETS THE CASCADE: PRIORITY IS STILL THE FIRST TERM.
//
// This block exists because the four S4 guide unittests above CANNOT observe
// this. Their fixture is `enabledTypes = SnapType.Vertex` over a vertices-only
// mesh — ONE cascade class — so no candidate of theirs can ever reach a second
// cascade slot, and they would have stayed green whatever the cascade did to
// priority between classes. Citing them as evidence that the registry is
// unaffected was a null control, and this is the test that could have failed.
//
// The two directions are asserted separately because a fold that reads no
// priority breaks BOTH, and each direction fails on its own:
//
//   * Elevate the EDGE over a vertex the cascade would have preferred.
//   * Elevate the VERTEX over an edge the cascade would have preferred.
//
// Each half first pins, with the SAME guide at a flat priority, that the
// cascade really does prefer the other class — otherwise "the higher priority
// won" would be indistinguishable from "the cascade happened to agree".
// ---------------------------------------------------------------------------
version (unittest) {
    /// A guide that answers with the service's own screen distance and a
    /// priority that depends on the candidate's TYPE.
    ///
    /// Deliberately not a knob on `MirrorGuide`: that guide keys its promotion
    /// on element INDEX, which is the one axis that cannot express "this class
    /// outranks that class", and it carries five other switches this block must
    /// be seen not to depend on.
    private class TypePriorityGuide : SnapGuide {
        Viewport vp;
        int      sx, sy;
        SnapType elevateType = SnapType.None;
        int      elevatePrio = 1;
        int      basePrio    = 0;

        this(Viewport v, int x, int y) { vp = v; sx = x; sy = y; }

        void limits(float i, float o) {}

        bool proximity(Vec3 candWorld, SnapType type, int idx, int slot,
                       out float distPx, ref int priority)
        {
            float qx, qy, qz;
            if (!projectToWindowFull(candWorld, vp, qx, qy, qz)) return false;
            immutable float dx = qx - cast(float)sx;
            immutable float dy = qy - cast(float)sy;
            distPx  = sqrt(dx * dx + dy * dy);
            priority = (type == elevateType) ? elevatePrio : basePrio;
            return true;
        }

        void setDrawState(GuideDrawState s) {}
        uint flags() const { return 0; }
    }
}

unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI, round;

    invalidateSnapGrids();

    // The same 80 px per world unit at z = 0 the behavioural test above uses:
    // screen = (400 + 80x, 400 - 80y).
    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    // Vertex 0 is the contested vertex; the edge runs out of it along +X, so
    // the edge's nearest point is always at least as close as the vertex.
    Mesh m;
    m.vertices = [ Vec3(0, 0, 0), Vec3(1, 0, 0) ];
    m.edges    = [ [0u, 1u] ];

    SnapPacket cfg;
    cfg.enabled      = true;
    cfg.enabledTypes = SnapType.Vertex | SnapType.Edge;   // TWO cascade classes

    immutable float base = kCandidateToleranceBasePx;
    immutable float tolV = kVertexToleranceScale * base;

    float[2] pixelOf(Vec3 w) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: every fixture point must project on-screen");
        return [qx, qy];
    }

    // Distances the two classes will carry into the cascade, for a cursor.
    void measure(Vec3 cursorWorld, out int sx, out int sy,
                 out float dVert, out float dEdge)
    {
        auto cpix = pixelOf(cursorWorld);
        sx = cast(int)round(cpix[0]);
        sy = cast(int)round(cpix[1]);
        auto a = pixelOf(m.vertices[0]);
        auto b = pixelOf(m.vertices[1]);
        dVert = sqrt((a[0] - sx) * (a[0] - sx) + (a[1] - sy) * (a[1] - sy));
        float t;
        dEdge = sqrt(closestOnSegment2DSquared(cast(float)sx, cast(float)sy,
                                               a[0], a[1], b[0], b[1], t));
    }

    // --- direction 1: the guide puts EDGE above the vertex the cascade wants -
    // Geometry is the reported case: the vertex trails by more than one base
    // and less than the doubled one, so the cascade prefers the VERTEX.
    {
        immutable Vec3 cursorWorld = Vec3(0.2f, 0.05f, 0);
        int sx, sy; float dVert, dEdge;
        measure(cursorWorld, sx, sy, dVert, dEdge);
        immutable float trail = dVert - dEdge;
        assert(dEdge < dVert && trail > base && trail < tolV,
            "fixture: the cascade must prefer the VERTEX here, or elevating "
            ~ "the edge would prove nothing about priority");

        // Control: the same guide at a FLAT priority must leave the cascade's
        // own answer standing. Without this line "the edge won" could be the
        // guide's mere presence rather than its priority.
        invalidateSnapGrids();
        auto flat = new TypePriorityGuide(vp, sx, sy);
        SnapResult f = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
                                  [flat]);
        assert(f.snapped && f.targetType == SnapType.Vertex,
            "control: at a flat priority the cascade decides, and it says "
            ~ "Vertex");

        invalidateSnapGrids();
        auto edgeUp = new TypePriorityGuide(vp, sx, sy);
        edgeUp.elevateType = SnapType.Edge;
        SnapResult r = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
                                  [edgeUp]);
        assert(r.snapped && r.targetType == SnapType.Edge && r.targetIndex == 0,
            "a guide that outranks the vertex class must WIN, even though the "
            ~ "cross-type cascade prefers the vertex on distance. Resolving "
            ~ "Vertex here means the cascade was asked before the priorities "
            ~ "were compared, and the registry's rule — higher priority wins "
            ~ "outright, at any distance — was silently dropped");
    }

    // --- direction 2: the guide puts VERTEX above the edge the cascade wants -
    // Same geometry, cursor further out along the edge: now the vertex trails
    // by MORE than its doubled tolerance, so the cascade prefers the EDGE.
    {
        immutable Vec3 cursorWorld = Vec3(0.28f, 0.05f, 0);
        int sx, sy; float dVert, dEdge;
        measure(cursorWorld, sx, sy, dVert, dEdge);
        immutable float trail = dVert - dEdge;
        assert(trail >= tolV,
            "fixture: the vertex must trail by its WHOLE doubled tolerance, or "
            ~ "the cascade would prefer it and elevating it would prove "
            ~ "nothing");
        assert(dVert <= cfg.innerRangePx,
            "fixture: and the vertex must still be inside the acceptance "
            ~ "range, or promoting it would produce a highlight and not a snap");

        invalidateSnapGrids();
        auto flat = new TypePriorityGuide(vp, sx, sy);
        SnapResult f = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
                                  [flat]);
        assert(f.snapped && f.targetType == SnapType.Edge,
            "control: at a flat priority the cascade decides, and at this "
            ~ "distance it says Edge");

        invalidateSnapGrids();
        auto vertUp = new TypePriorityGuide(vp, sx, sy);
        vertUp.elevateType = SnapType.Vertex;
        SnapResult r = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
                                  [vertUp]);
        assert(r.snapped && r.targetType == SnapType.Vertex
            && r.targetIndex == 0,
            "and the other direction: a guide that outranks the EDGE class "
            ~ "must win against the class the cascade prefers. The two "
            ~ "directions are asserted separately because a fold that reads no "
            ~ "priority at all breaks both, and neither one alone shows it");
    }

    invalidateSnapGrids();
}







// THE POLYGON EXTERIOR-LEG ELECTION (task 0587) — when the cursor falls
// OUTSIDE a polygon's projected outline, the point returned on its boundary
// ring is elected in 3D against the cursor's eye ray, exactly as the edge leg
// above elects one. It is NOT the closest parameter on the PROJECTED ring
// segment applied as a world parameter, which is what this file used to do.
//
// TESTED ACROSS DEPTH, and that is the whole point of the fixture. The two
// laws are algebraically the same whenever the ring segment's endpoints sit at
// equal depth, so a fronto-parallel or coplanar polygon passes under either
// law and proves nothing. The CONTROL block below demonstrates that failure
// mode explicitly rather than asserting it in prose: on a fronto-parallel
// polygon the two laws land 0.0002 world units apart, which no useful
// tolerance can separate. The DECISIVE block spans a factor of ~20 in depth
// and separates them by 8.38 world units and 24.6 px.
//
// Calls the leg directly instead of driving snapCursor: the exterior leg is
// what changed, and a direct call cannot be confounded by backface culling,
// the candidate grid or the cascade's ranking. The wiring from snapCursor's
// polygon leg into this function is unchanged and covered elsewhere.
unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI;

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    float dist3(Vec3 p, Vec3 q) {
        immutable Vec3 d = p - q;
        return sqrt(dot(d, d));
    }
    float distPxAt(Vec3 w, int cx, int cy) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: the probe point must project on-screen");
        immutable float dx = qx - cast(float)cx;
        immutable float dy = qy - cast(float)cy;
        return sqrt(dx * dx + dy * dy);
    }
    // The cursor must be OUTSIDE the projected outline or the interior
    // (ray/plane) leg answers and the exterior leg never runs.
    void assertCursorOutside(const ref Mesh m, const(uint)[] face, int cx, int cy) {
        float[] xs, ys;
        foreach (vi; face) {
            float px, py, pz;
            assert(projectToWindowFull(m.vertices[vi], vp, px, py, pz),
                "fixture: every polygon vertex must project");
            xs ~= px; ys ~= py;
        }
        assert(!pointInPolygon2D(cast(float)cx, cast(float)cy, xs, ys),
            "fixture: the cursor must fall OUTSIDE the projected outline, or "
            ~ "this rig exercises the interior leg and says nothing about the "
            ~ "ring election");
    }

    immutable uint[3] tri = [0u, 1u, 2u];

    // -----------------------------------------------------------------------
    // DECISIVE — a boundary edge running from one unit in front of the camera
    // (z = 4) out to twenty units away (z = -15), with the cursor just off it.
    //
    //   3D election   -> t = 0.04498, world (0.073045, 0.068511, 3.145295),
    //                    which re-projects 0.79 px from the cursor
    //   projected-t   -> t = 0.48547, world (0.200785, -0.239826, -5.223855),
    //                    which re-projects 25.41 px away
    //
    // 8.38 world units apart. The third vertex is far to the +x side so the
    // cursor is outside the outline and the near edge is the elected one.
    // -----------------------------------------------------------------------
    {
        immutable int cx = 415, cy = 385;
        Mesh m;
        m.vertices = [ Vec3(0.06f,  0.10f,   4.0f),
                       Vec3(0.35f, -0.60f, -15.0f),
                       Vec3(6.0f,   2.0f,   -6.0f) ];

        immutable Vec3 pRay  = Vec3(0.073045f,  0.068511f,  3.145295f);
        immutable Vec3 pProj = Vec3(0.200785f, -0.239826f, -5.223855f);

        assertCursorOutside(m, tri[], cx, cy);
        // Premises, stated rather than trusted.
        assert(distPxAt(pRay,  cx, cy) < 1.5f,
            "fixture: the 3D-elected point must sit on the cursor's pixel");
        assert(distPxAt(pProj, cx, cy) > 20.0f,
            "fixture: the projected-parameter point must be far off it, or "
            ~ "this rig cannot tell which law ran");
        assert(dist3(pRay, pProj) > 5.0f,
            "fixture: and the two must be far apart in world space, so no "
            ~ "tolerance can blur them together");

        Vec3 hit;
        assert(closestOnPolygonSurface(tri[], m, cx, cy, vp, ModelSpace.world(), hit),
            "a well-formed polygon with the cursor beside it must elect a point");
        assert(dist3(hit, pRay) < 1e-3f,
            "the elected point must be the boundary ring's closest approach to "
            ~ "the cursor's eye ray");
        assert(dist3(hit, pProj) > 5.0f,
            "and must NOT be the projected parameter applied as a world one — "
            ~ "that point is 8.4 world units away and re-projects 25 px off "
            ~ "the cursor the user is pointing with");
    }

    // -----------------------------------------------------------------------
    // CONTROL — the same question on a FRONTO-PARALLEL polygon (all three
    // vertices at z = -6). Here the projected parameter and the 3D closest
    // approach coincide: the two laws land 0.000217 world units apart. This
    // block asserts that they agree, which is the honest way to record that a
    // rig like this one CANNOT distinguish them — had the decisive block above
    // been built at constant depth, it would have passed without the fix.
    // -----------------------------------------------------------------------
    {
        immutable int cx = 415, cy = 385;
        Mesh m;
        m.vertices = [ Vec3(0.06f,  0.10f, -6.0f),
                       Vec3(0.35f, -0.60f, -6.0f),
                       Vec3(6.0f,   2.0f,  -6.0f) ];

        immutable Vec3 pRay  = Vec3(0.470255f, 0.231227f, -6.0f);
        immutable Vec3 pProj = Vec3(0.470462f, 0.231293f, -6.0f);

        assertCursorOutside(m, tri[], cx, cy);
        assert(dist3(pRay, pProj) < 1e-3f,
            "fixture: at equal depth the two laws must coincide — that is the "
            ~ "property being documented");

        Vec3 hit;
        assert(closestOnPolygonSurface(tri[], m, cx, cy, vp, ModelSpace.world(), hit),
            "the fronto-parallel polygon must still elect a point");
        assert(dist3(hit, pRay) < 1e-3f,
            "and at equal depth it agrees with BOTH laws, which is exactly why "
            ~ "the decisive rig has to span depth");
    }
}

// ---------------------------------------------------------------------------
// D1 — THE INTERIOR TEST, on the shape that can tell the two laws apart
// (task 0588).
//
// A NON-PLANAR quad. The old law tested the cursor against the polygon's
// PROJECTED OUTLINE and, on a hit, intersected the eye ray with ONE plane —
// the plane through face[0] carrying the normal of the first three vertices.
// For this quad that plane is z = 0, and the fourth vertex is two units off
// it, so the surface the user can see is nowhere near the plane the old law
// answered with. The ported law intersects the eye ray with each TRIANGLE of
// the polygon's own triangulation, so it answers with a point that is on the
// model.
//
// WHY NON-PLANAR AND NOT NON-CONVEX. A planar non-convex polygon cannot
// separate these two: `pointInPolygon2D`'s crossing rule is already correct
// about a notch, and a planar polygon's one plane is already its surface, so
// old and new agree to the last bit. Non-convexity is a constraint on the
// TRIANGULATION, not on the interior test, and it is pinned as such in the
// block after this one. Non-planarity is what makes the interior test itself
// observable.
// ---------------------------------------------------------------------------
unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI, abs;

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.focus  = Vec3(0, 0, 0);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    float dist3(Vec3 p, Vec3 q) {
        immutable Vec3 d = p - q;
        return sqrt(dot(d, d));
    }

    Mesh m;
    m.vertices = [ Vec3(-1, -1, 0),
                   Vec3( 1, -1, 0),
                   Vec3( 1,  1, 0),
                   Vec3(-1,  1, 2) ];      // lifted 2 units toward the camera
    immutable uint[4] quad = [0u, 1u, 2u, 3u];
    immutable int cx = 350, cy = 400;

    // The two answers, stated before they are asked for.
    immutable Vec3 pPlane = Vec3(-0.625f, 0.0f, 0.0f);   // old: on the z = 0 plane
    immutable Vec3 pSurf  = Vec3(-0.5f,   0.0f, 1.0f);   // new: on the real surface

    // --- premises ----------------------------------------------------------
    {
        float[] xs, ys;
        foreach (vi; quad) {
            float px, py, pz;
            assert(projectToWindowFull(m.vertices[vi], vp, px, py, pz),
                "fixture: every vertex must project");
            xs ~= px; ys ~= py;
        }
        assert(pointInPolygon2D(cast(float)cx, cast(float)cy, xs, ys),
            "fixture: the cursor must be INSIDE the projected outline, or the "
            ~ "old law never took its interior branch and this rig says nothing "
            ~ "about the interior test");
    }
    // The quad really is non-planar: vertex 3 is off the plane of 0,1,2.
    assert(abs(m.vertices[3].z - m.vertices[0].z) > 1.0f,
        "fixture: a planar quad cannot distinguish the two interior tests");
    // The old answer is off the surface. The triangle the ray actually hits
    // spans v3, v0, v1 and lies in the plane z = y + 1.
    assert(abs(pPlane.z - (pPlane.y + 1.0f)) > 0.9f,
        "fixture: the plane point must NOT lie on the hit triangle's plane, or "
        ~ "the two laws agree here by accident");
    assert(abs(pSurf.z - (pSurf.y + 1.0f)) < 1e-5f,
        "fixture: the surface point must lie ON it");
    assert(dist3(pPlane, pSurf) > 1.0f,
        "fixture: and the two must be a world unit apart, so no tolerance can "
        ~ "blur them together");

    // --- the law -----------------------------------------------------------
    Vec3  hit;
    float rankPx;
    assert(closestOnPolygonSurface(quad[], m, cx, cy, vp, ModelSpace.world(), hit, rankPx),
        "a well-formed quad under the cursor must elect a point");
    assert(rankPx == 0.0f,
        "the cursor is OVER the polygon, so the eye ray hits a triangle and the "
        ~ "rank is the reference's literal zero");
    assert(dist3(hit, pSurf) < 1e-4f,
        "the elected point must be the ray/TRIANGLE intersection — a point on "
        ~ "the folded surface the user is looking at");
    assert(dist3(hit, pPlane) > 1.0f,
        "and must NOT be the ray/plane intersection against the first three "
        ~ "vertices' plane, which for this quad is a full world unit away from "
        ~ "anything the polygon occupies");
}

// ---------------------------------------------------------------------------
// D1 — THE TRIANGULATION MUST BE AN EAR CLIP, on a NON-CONVEX polygon
// (task 0588).
//
// This block does not separate the ported law from the one it replaced: on a
// PLANAR non-convex polygon the two agree, because `pointInPolygon2D` is
// already right about a notch. What it separates is the ported law from the
// cheapest way of writing it. Every other triangulation in this codebase —
// the display VBO, the BVH build, the surface constraint — is a FAN from
// vertex 0, and a fan of a non-convex polygon covers the notch. Reusing one
// here would have reported a cursor sitting BESIDE the polygon as being ON
// it, i.e. it would have made the ported law worse than what it replaced.
//
// The fixture is an L whose vertex 0 is deliberately the one a fan cannot be
// built from, and the block computes that fan and asserts it covers the probe
// before asserting that the shipped law does not.
// ---------------------------------------------------------------------------
unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI, abs;

    Viewport vp;
    vp.eye    = Vec3(0, 0, 10);
    vp.focus  = Vec3(0, 0, 0);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    float dist3(Vec3 p, Vec3 q) {
        immutable Vec3 d = p - q;
        return sqrt(dot(d, d));
    }

    Mesh m;
    m.vertices = [ Vec3( 0,  2, 0),   // 0 — the fan pivot that cannot see the ring
                   Vec3(-2,  2, 0),
                   Vec3(-2, -2, 0),
                   Vec3( 2, -2, 0),
                   Vec3( 2,  0, 0),
                   Vec3( 0,  0, 0) ]; // 5 — the reflex corner
    immutable uint[6] ell = [0u, 1u, 2u, 3u, 4u, 5u];

    // The probe sits in the notch — the quadrant the L does not occupy.
    immutable Vec3 notch = Vec3(1.2f, 0.5f, 0.0f);
    immutable int cx = 448, cy = 380;         // == the projection of `notch`

    static bool inTri(Vec3 q, Vec3 a, Vec3 b, Vec3 c) {
        static float cr(Vec3 o, Vec3 mm, Vec3 nn) {
            return (mm.x - o.x)*(nn.y - o.y) - (mm.y - o.y)*(nn.x - o.x);
        }
        immutable float c0 = cr(a, b, q), c1 = cr(b, c, q), c2 = cr(c, a, q);
        return (c0 >= 0 && c1 >= 0 && c2 >= 0) || (c0 <= 0 && c1 <= 0 && c2 <= 0);
    }

    // --- premises ----------------------------------------------------------
    {
        float qx, qy, qz;
        assert(projectToWindowFull(notch, vp, qx, qy, qz),
            "fixture: the notch probe must project");
        assert(abs(qx - cx) < 0.75f && abs(qy - cy) < 0.75f,
            "fixture: the cursor pixel must be the notch probe's own pixel");
        float[] xs, ys;
        foreach (vi; ell) { xs ~= m.vertices[vi].x; ys ~= m.vertices[vi].y; }
        assert(!pointInPolygon2D(notch.x, notch.y, xs, ys),
            "fixture: the probe must be OUTSIDE the L");
        bool fanCovers = false;
        foreach (i; 1 .. ell.length - 1)
            if (inTri(notch, m.vertices[ell[0]], m.vertices[ell[i]],
                      m.vertices[ell[i + 1]])) { fanCovers = true; break; }
        assert(fanCovers,
            "fixture: a fan from vertex 0 must COVER the notch, or this polygon "
            ~ "cannot tell a fan from a proper triangulation");
    }

    // --- the law -----------------------------------------------------------
    Vec3  hit;
    float rankPx;
    assert(closestOnPolygonSurface(ell[], m, cx, cy, vp, ModelSpace.world(), hit, rankPx),
        "the L must elect a point for a cursor beside it");
    assert(rankPx > 1.0f,
        "the cursor is in the NOTCH, so no triangle may be hit and the rank "
        ~ "must not be the interior zero — a fan would hand back 0 here");
    assert(abs(rankPx - 19.975f) < 0.05f,
        "and the rank is the notch depth over one world-per-pixel: 0.4994 "
        ~ "world units at 0.025 world/px");
    assert(dist3(hit, Vec3(1.19701f, 0.0f, 0.0f)) < 1e-3f,
        "the elected point must sit on the L's own boundary, on the edge that "
        ~ "bounds the notch");
    assert(dist3(hit, notch) > 0.4f,
        "and must NOT be the ray/plane hit at the cursor, which is where a fan "
        ~ "triangulation would have put it");
}

// ---------------------------------------------------------------------------
// D3 — THE RANK, and the winner it changes (task 0588).
//
// TWO polygons, both beside the cursor, at very different depths. The rank
// this port introduces divides a WORLD distance by ONE world-per-pixel — the
// view's own, at its scale distance — instead of re-projecting the elected
// point and measuring on screen. The two metrics differ by exactly
// `depth / scaleDistance`, so a face NEARER than the view's scale distance
// ranks better than it looks and a face beyond it ranks worse.
//
// Here the deep face is the nearer one ON SCREEN (7.0 px against 18.0 px) and
// the near face is the nearer one BY RANK (4.5 against 14). The old law elects
// the deep one; this one elects the near one. The block asserts both halves,
// so it pins a BEHAVIOUR — which polygon a user snaps to — and not a number.
//
// The winner is also asserted under BOTH declaration orders, which is what
// distinguishes "the rank decided" from "the enumeration decided".
// ---------------------------------------------------------------------------
unittest {
    import math     : lookAt, perspectiveMatrix, viewPixelScale;
    import std.math : PI, abs;

    Viewport vp;
    vp.eye    = Vec3(0, 0, 20);
    vp.focus  = Vec3(0, 0, 0);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    assert(abs(viewPixelScale(vp) - 0.05f) < 1e-7f,
        "fixture: the view's scale is 0.05 world per pixel; every rank below "
        ~ "is a world distance over that number");

    immutable int cx = 400, cy = 400;      // the screen centre: the ray is -Z

    // Face DEEP: z = -20, i.e. twice the scale distance from the eye. Its
    // nearest point is 0.7 world from the ray -> 7.0 px on screen, rank 14.
    immutable Vec3[4] deep = [ Vec3(0.7f, -0.1f, -20), Vec3(0.9f, -0.1f, -20),
                               Vec3(0.9f,  0.1f, -20), Vec3(0.7f,  0.1f, -20) ];
    // Face NEAR: z = +15, a quarter of the scale distance from the eye. Its
    // nearest point is 0.225 world from the ray -> 18 px on screen, rank 4.5.
    immutable Vec3[4] near = [ Vec3(0.225f, -0.025f, 15), Vec3(0.275f, -0.025f, 15),
                               Vec3(0.275f,  0.025f, 15), Vec3(0.225f,  0.025f, 15) ];

    float screenDist(Vec3 w) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: the probe must project");
        return sqrt((qx - cx)*(qx - cx) + (qy - cy)*(qy - cy));
    }

    // --- premises: the two metrics order these two faces OPPOSITELY ---------
    Mesh probe;
    probe.vertices = (deep[] ~ near[]).dup;
    probe.addFace([0u, 1u, 2u, 3u]);
    probe.addFace([4u, 5u, 6u, 7u]);

    Vec3  hD, hN;
    float rD, rN;
    assert(closestOnPolygonSurface(probe.faces[0], probe, cx, cy, vp, ModelSpace.world(), hD, rD));
    assert(closestOnPolygonSurface(probe.faces[1], probe, cx, cy, vp, ModelSpace.world(), hN, rN));
    assert(abs(screenDist(hD) - 7.0f) < 0.05f && abs(screenDist(hN) - 18.0f) < 0.05f,
        "fixture: ON SCREEN the deep face is much the nearer of the two — that "
        ~ "is what the law being replaced ranked by, and it would elect it");
    assert(screenDist(hD) < screenDist(hN),
        "fixture, stated as the comparison the old rank actually made");
    assert(abs(rD - 14.0f) < 0.05f && abs(rN - 4.5f) < 0.05f,
        "fixture: BY THE PORTED RANK the order reverses");
    assert(rN < rD,
        "fixture, stated as the comparison the new rank makes — the two "
        ~ "disagree, which is the only reason this rig can measure anything");

    // --- the behaviour -----------------------------------------------------
    SnapPacket cfg;
    cfg.enabled      = true;
    cfg.snapScope    = SnapMode.Global;
    cfg.enabledTypes = SnapType.Polygon;
    cfg.innerRangePx = 40.0f;
    cfg.outerRangePx = 40.0f;

    // Declared deep-first.
    {
        Mesh m;
        m.vertices = (deep[] ~ near[]).dup;
        m.addFace([0u, 1u, 2u, 3u]);       // 0 = deep
        m.addFace([4u, 5u, 6u, 7u]);       // 1 = near
        invalidateSnapGrids();
        SnapResult r = snapCursor(Vec3(99, 99, 99), cx, cy, vp, m, ModelSpace.world(), cfg);
        assert(r.snapped && r.targetType == SnapType.Polygon,
            "both faces are in range under both metrics; one must win");
        assert(r.targetIndex == 1,
            "the NEAR face wins, because the ported rank divides by one "
            ~ "world-per-pixel instead of re-projecting — the old, "
            ~ "depth-correct rank elected the deep face at 7 px");
    }
    // Declared near-first: same winner, so it is the rank and not the order.
    {
        Mesh m;
        m.vertices = (deep[] ~ near[]).dup;
        m.addFace([4u, 5u, 6u, 7u]);       // 0 = near
        m.addFace([0u, 1u, 2u, 3u]);       // 1 = deep
        invalidateSnapGrids();
        SnapResult r = snapCursor(Vec3(99, 99, 99), cx, cy, vp, m, ModelSpace.world(), cfg);
        assert(r.snapped && r.targetIndex == 0,
            "the near face still wins when it is enumerated first, so this "
            ~ "block measures the RANK and not the iteration order");
    }
}

// ---------------------------------------------------------------------------
// D3 — THE INTERIOR RANK IS A LITERAL ZERO, AND THE TIE IS THE POINT
// (task 0588).
//
// Every polygon the cursor is over ranks at exactly 0.0. Two of them therefore
// TIE, `consider()`'s strict `<` keeps whichever arrived first, and the winner
// is decided by ITERATION ORDER — here, by which face was declared first, since
// the candidate grid answers index-ascending.
//
// WHAT THIS BLOCK IS AND IS NOT. It is not a winner FLIP against the old law:
// measured on this rig, the old law's two interior points re-project to the
// cursor's own pixel and both come back at exactly 0.0 px too, so it would tie
// here as well. The difference the port makes is that ours now ties BY
// CONSTRUCTION rather than by two re-projections happening to round the same
// way — off the screen centre the old law's two ranks differ in their last
// bits, and the winner is then decided by float noise. The winner FLIP that
// the rank's divisor produces is measured in the block above; what is measured
// here is that the zero is exact and that order, not geometry, resolves it.
//
// The faces are stacked 35 world units apart along the view ray, and the
// FARTHER one wins whenever it is declared first. That will read as wrong to
// anyone expecting the nearer surface, and it is what the reference does: its
// rank carries no depth term at all inside the hit arm, so depth cannot break
// the tie. Which face ITS enumerator reaches first is a property of its
// spatial structures and is not reproducible here; the mechanism — first
// offered keeps the slot — is, and that is what is pinned.
// ---------------------------------------------------------------------------
unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI, abs;

    Viewport vp;
    vp.eye    = Vec3(0, 0, 20);
    vp.focus  = Vec3(0, 0, 0);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    immutable int cx = 400, cy = 400;
    // Small and near: it covers the cursor but none of the big face's corners.
    immutable Vec3[4] nearQ = [ Vec3(-0.1f, -0.1f, 15), Vec3(0.1f, -0.1f, 15),
                                Vec3( 0.1f,  0.1f, 15), Vec3(-0.1f, 0.1f, 15) ];
    // Big and far: its corners project 20 px out, clear of the near face's
    // 8 px silhouette, so the occlusion gate keeps BOTH faces live.
    immutable Vec3[4] farQ  = [ Vec3(-2, -2, -20), Vec3(2, -2, -20),
                                Vec3( 2,  2, -20), Vec3(-2, 2, -20) ];

    // --- the ranks are the same number, exactly ----------------------------
    {
        Mesh m;
        m.vertices = (nearQ[] ~ farQ[]).dup;
        m.addFace([0u, 1u, 2u, 3u]);
        m.addFace([4u, 5u, 6u, 7u]);
        Vec3  h0, h1;
        float r0, r1;
        assert(closestOnPolygonSurface(m.faces[0], m, cx, cy, vp, ModelSpace.world(), h0, r0));
        assert(closestOnPolygonSurface(m.faces[1], m, cx, cy, vp, ModelSpace.world(), h1, r1));
        assert(r0 == 0.0f && r1 == 0.0f,
            "an interior hit ranks at the reference's literal zero — not at a "
            ~ "small number, which is what a re-projection would give");
        assert(r0 == r1,
            "so two polygons under one cursor TIE, and nothing about their "
            ~ "geometry can separate them");
        assert(abs(h0.z - 15.0f) < 1e-4f && abs(h1.z + 20.0f) < 1e-4f,
            "fixture: and they are 35 world units apart along the ray, so a "
            ~ "depth-aware rank could not possibly have tied");
    }

    SnapPacket cfg;
    cfg.enabled      = true;
    cfg.snapScope    = SnapMode.Global;
    cfg.enabledTypes = SnapType.Polygon;
    cfg.innerRangePx = 40.0f;
    cfg.outerRangePx = 40.0f;

    // --- so the declaration order decides, in both directions ---------------
    {
        Mesh m;
        m.vertices = (nearQ[] ~ farQ[]).dup;
        m.addFace([0u, 1u, 2u, 3u]);       // 0 = near
        m.addFace([4u, 5u, 6u, 7u]);       // 1 = far
        invalidateSnapGrids();
        SnapResult r = snapCursor(Vec3(99, 99, 99), cx, cy, vp, m, ModelSpace.world(), cfg);
        assert(r.snapped && r.targetIndex == 0 && abs(r.worldPos.z - 15.0f) < 1e-4f,
            "declared first, the near face keeps the tie");
    }
    {
        Mesh m;
        m.vertices = (nearQ[] ~ farQ[]).dup;
        m.addFace([4u, 5u, 6u, 7u]);       // 0 = far
        m.addFace([0u, 1u, 2u, 3u]);       // 1 = near
        invalidateSnapGrids();
        SnapResult r = snapCursor(Vec3(99, 99, 99), cx, cy, vp, m, ModelSpace.world(), cfg);
        assert(r.snapped && r.targetIndex == 0 && abs(r.worldPos.z + 20.0f) < 1e-4f,
            "declared first, the FAR face keeps it instead — 35 units behind "
            ~ "the other one and directly occluded by it in every ordinary "
            ~ "sense. Nothing but the enumeration order changed between these "
            ~ "two cases, which is exactly the claim");
    }
}

// ---------------------------------------------------------------------------
// CONTROL — a planar convex quad at the view's own scale distance (task 0588).
//
// Both halves of the port vanish on this rig, and the block records that by
// asserting the agreement rather than by asserting a new number:
//
//   * the polygon is CONVEX, so a fan and an ear clip produce the same
//     triangulation and the notch question cannot arise;
//   * it is PLANAR, so the one plane the old interior test used IS the
//     surface;
//   * its depth equals the view's scale distance, so `worldDistance /
//     pixelScale` and the re-projected screen distance are the same number.
//
// A decisive test built on a rig like this would have passed before the port
// and after it, which is the failure mode this block exists to name. The two
// blocks above deliberately break each of these three properties in turn.
// ---------------------------------------------------------------------------
unittest {
    import math     : lookAt, perspectiveMatrix, viewPixelScale;
    import std.math : PI, abs;

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.focus  = Vec3(0, 0, 0);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    immutable int cx = 400, cy = 400;
    Mesh m;
    m.vertices = [ Vec3(0.25f, -1, 0), Vec3(2, -1, 0),
                   Vec3(2,      1, 0), Vec3(0.25f, 1, 0) ];
    immutable uint[4] quad = [0u, 1u, 2u, 3u];

    Vec3  hit;
    float rankPx;
    assert(closestOnPolygonSurface(quad[], m, cx, cy, vp, ModelSpace.world(), hit, rankPx),
        "the control quad must elect a point");

    // The election: the nearest point of the quad to the eye ray is the middle
    // of its near edge, and BOTH laws say so.
    immutable Vec3 d = hit - Vec3(0.25f, 0, 0);
    assert(sqrt(dot(d, d)) < 1e-4f,
        "on a planar convex quad the ported election and the boundary-ring one "
        ~ "it replaced land on the same point");

    // The rank: at the view's scale distance the two metrics coincide exactly.
    float qx, qy, qz;
    assert(projectToWindowFull(hit, vp, qx, qy, qz));
    immutable float screenPx = sqrt((qx - cx)*(qx - cx) + (qy - cy)*(qy - cy));
    assert(abs(screenPx - 20.0f) < 0.05f,
        "fixture: the elected point sits 20 px from the cursor");
    assert(abs(rankPx - screenPx) < 0.05f,
        "and the ported rank agrees with the re-projected screen distance it "
        ~ "replaced, BECAUSE the polygon sits at the depth the view's single "
        ~ "world-per-pixel was measured at. Any rig built here would have been "
        ~ "blind to the whole of D3");
    assert(abs(rankPx - 0.25f / viewPixelScale(vp)) < 1e-3f,
        "...and it is still computed the ported way: a world distance over the "
        ~ "view's own scale");
}
