module toolpipe.stages.constrain;

import toolpipe.stage   : Stage, TaskCode, ordCons;
import toolpipe.packets : ConstrainPacket, ConstrainGeom, ConstrainHitPacket,
                          SubjectPacket;
import operator         : Operator, Task, VectorStack, PacketKind;
import popup_state      : setStatePath;
import params           : Param, IntEnumEntry, wireTagForValue;
import bvh_pick         : BvhPick, SurfaceHit;
import constraint        : BackgroundSource;

// Single-sourced geometry-mode token<->value table (task 0184 / audit-2 C2):
// fullParams()'s IntEnum Param, the parse leg (via the base Stage.setAttr ->
// parseInto), and publishState()'s stringify all read this ONE table instead
// of three separate hand-written geom<->token switches.
private static immutable IntEnumEntry[] constrainGeomEntries = [
    IntEnumEntry(cast(int)ConstrainGeom.Off,    "off",    "Off"),
    IntEnumEntry(cast(int)ConstrainGeom.Screen, "screen", "Screen"),
    IntEnumEntry(cast(int)ConstrainGeom.Vector, "vector", "Vector"),
    IntEnumEntry(cast(int)ConstrainGeom.Point,  "point",  "Point"),
];

// ---------------------------------------------------------------------------
// ConstrainStage — tool-pipe CONS slot (ordinal 0x41, after SNAP 0x40).
//
// Publishes a ConstrainPacket with the master enable flag and the four
// geometry-mode attrs (off/screen/vector/point). The projection itself
// runs as a post-pass loop in xfrm_transform.d::applyTRS after
// applyFold writes the final per-vertex positions.
//
// Functional scope (topology-pen placement-seed fix, a live cross-engine
// differential against the reference editor —
// toolcards/topology_pen/cross_engine_differential.md — supersedes P2's
// doc/topopen_p2_plan.md derivation below, which itself superseded the
// earlier Stage-0 "working assumption" comment):
//   * `point` mode  — background-surface PLACEMENT: the camera-ray∩bg-
//                     surface hit under the cursor. CONFIRMED by the live
//                     differential (6 live placements, all landed on
//                     the ray-struck face at 3-12x the distance a
//                     work-plane-cursor nearest-foot would have predicted)
//                     — the P2 derivation (work-plane∩cursor SEED) was
//                     wrong. This is the Topology Pen's mode; see
//                     `pointNearestFootBackground` below for why
//                     nearest-foot-of-the-ray-hit collapses to the ray-hit
//                     itself for an over-surface click (the reference
//                     editor's background-constraint Point/nearest-foot
//                     doc-semantics still apply to an edit-time DRAG, a
//                     later phase).
//   * `screen` mode — camera-ray∩surface (search perpendicular to the
//                     view); the camera-ray sibling mode
//                     (see `screenRaycastBackground` below, unchanged from
//                     the original P0 raycast — now SHARES its BVH
//                     raycast with Point mode via `bgSurfaceRayHit`).
//   * `vector` mode — accepted attrs, round-trips cleanly, but currently
//                     no-op (no per-vertex motion delta exists for a
//                     placement click; out of scope until a drag-based
//                     consumer needs it).
//   * `offset`, `handle`, `dblSided` — accepted attrs, round-trip;
//                     `offset` is honored by both raycast branches via
//                     `constraint.applyOffset`; `handle`/`dblSided` remain
//                     no-op pending a later phase.
//
// HTTP setAttr keys (via tool.pipe.attr constrain <name> <value>):
//   `enabled`  : "true" / "false"
//   `geometry` : "off" / "screen" / "vector" / "point"
//   `offset`   : float, world units (default 0)
//   `handle`   : "true" / "false" (default true)
//   `dblSided` : "true" / "false" (default false)
// ---------------------------------------------------------------------------

class ConstrainStage : Stage, Operator {
private:
    ConstrainPacket _publishedPacket;

    // --- Background-surface raycast (topology-pen P0) -----------------------
    // One BvhPick per background-layer mesh, keyed by mesh ADDRESS (the
    // stage stays Document-free — it only needs
    // `snap.backgroundSourcesSnapshot()`, mirroring how the CONS post-pass
    // projection in xfrm_transform.d already consumes that same snapshot).
    // Pruned each evaluate() so a removed/hidden background layer's BVH is
    // freed (mirrors app.d's `bgGpuByLayer` prune pattern).
    BvhPick[size_t]    _bgBvh;
    ConstrainHitPacket _hitPkt;

public:
    // --- Operator interface -------------------------------------------------
    Task task() const { return Task.Cons; }
    PacketKind[] requiredPackets() const { return [PacketKind.Subject]; }

    bool evaluate(ref VectorStack vts) {
        if (!enabled) return false;
        ConstrainPacket pkt;
        pkt.enabled  = enabled;
        pkt.geom     = geom;
        pkt.offset   = offset;
        pkt.handle   = handle;
        pkt.dblSided = dblSided;
        _publishedPacket = pkt;
        vts.put(&_publishedPacket);

        // Background-surface constraint: gated on Point OR Screen mode —
        // both produce a hit packet (topology-pen P2, doc/topopen_p2_plan.md
        // P2a-2; Vector/Off publish none) — AND a THREAD-SAFE cursor.
        // `subj.cursorValid` is stamped true ONLY on the main-thread
        // mouse-event dispatch path (app.d's buildToolVts) and the
        // main-thread-bridged /api/surface-raycast provider — every
        // HTTP-thread evaluate() caller (/api/toolpipe, /api/snap,
        // /api/constrain, /api/path) leaves it false, so this branch never
        // mutates `_bgBvh` off the main thread (R1 of doc/topopen_p0_plan.md).
        if (geom == ConstrainGeom.Point || geom == ConstrainGeom.Screen) {
            auto subj = vts.get!SubjectPacket();
            if (subj !is null && subj.cursorValid && subj.viewport.width > 0)
                constrainBackground(*subj, vts);
        }
        return true;
    }

    // Mode dispatch (topology-pen P2, doc/topopen_p2_plan.md P2a-2; neutral
    // name replacing P0's `raycastBackground`, which only ever did the
    // camera-ray search now split out as `screenRaycastBackground` below).
    // Point = camera-ray∩bg-surface hit, refined through the nearest-foot
    // machinery (`pointNearestFootBackground` — CONFIRMED by a live
    // cross-engine differential against the reference editor to be the
    // correct seed, superseding P2's work-plane-cursor derivation); Screen
    // = the SAME camera-ray hit, published directly
    // (`screenRaycastBackground`, unchanged from the original P0 body).
    // Off/Vector are unreachable through the evaluate()
    // gate above — kept here only so the `final switch` stays exhaustive.
    private void constrainBackground(ref SubjectPacket subj, ref VectorStack vts) {
        final switch (geom) {
            case ConstrainGeom.Point:
                pointNearestFootBackground(subj, vts);
                return;
            case ConstrainGeom.Screen:
                screenRaycastBackground(subj, vts);
                return;
            case ConstrainGeom.Off:
            case ConstrainGeom.Vector:
                return;
        }
    }

    // Shared BVH raycast — cast a ray from the current cursor pixel through
    // every background layer's mesh, each folded through ITS OWN ModelSpace
    // (task 0617 Stage 4), keep the globally nearest hit (world-space).
    // Reuses BvhPick/pickSurface (source/bvh_pick.d) — no new raycast
    // machinery, per the topology-pen P0 layering rule. Shared by BOTH mode
    // branches below: Screen mode (`screenRaycastBackground`) publishes
    // this hit directly as the placement; Point mode
    // (`pointNearestFootBackground`) uses it as the placement SEED — see
    // that function's doc comment for why a live cross-engine differential
    // against the reference editor proved Point mode's placement IS this
    // same camera-ray hit, not a work-plane-cursor nearest-foot.
    //
    // `bgFull` is the caller's OWN combined snapshot
    // (`snap.backgroundSourcesFull()`) — this function used to take a
    // second, independent lock+allocation here (review fix, task 0617
    // Stage 4: `backgroundSourcesModelSpaces()` on top of the caller's
    // existing `backgroundSourcesSnapshot()`); it now reads the space
    // straight off the same entry the caller already resolved the mesh
    // from, so the two can never drift apart and there is nothing extra to
    // allocate.
    //
    // `_bgBvh` cache entries are pruned here (once per call) so a
    // removed/hidden background layer's BVH is freed regardless of which
    // mode is driving the prune.
    private bool bgSurfaceRayHit(ref SubjectPacket subj, const(BackgroundSource)[] bgFull,
                                 out SurfaceHit outHit, out size_t outSrcIdx) {
        bool[size_t] live;
        foreach (bg; bgFull)
            if (bg.mesh !is null) live[cast(size_t)bg.mesh] = true;
        size_t[] stale;
        foreach (addr, bp; _bgBvh)
            if ((addr in live) is null) stale ~= addr;
        foreach (addr; stale) _bgBvh.remove(addr);

        float bestT = float.infinity;
        bool  found = false;
        foreach (i, bg; bgFull) {
            if (bg.mesh is null) continue;
            size_t addr = cast(size_t)bg.mesh;
            auto pp = addr in _bgBvh;
            BvhPick bp;
            if (pp is null) {
                bp = new BvhPick();
                _bgBvh[addr] = bp;
            } else {
                bp = *pp;
            }
            SurfaceHit sh;
            if (!bp.pickSurface(subj.cursorX, subj.cursorY, subj.viewport, *bg.mesh,
                                bg.space, sh))
                continue;
            if (sh.t >= bestT) continue;
            bestT     = sh.t;
            outHit    = sh;
            outSrcIdx = i;
            found     = true;
        }
        return found;
    }

    // Point mode — background-surface PLACEMENT. The SEED is the
    // camera-ray∩bg-surface hit (`bgSurfaceRayHit` above — the SAME BVH
    // raycast Screen mode uses), CONFIRMED by a live cross-engine
    // differential against the reference editor
    // (toolcards/topology_pen/cross_engine_differential.md: 6 live
    // placements, every one landed on the camera-ray-struck face, at
    // 3-12x the distance a work-plane-cursor nearest-foot seed would have
    // predicted) — superseding P2's doc/topopen_p2_plan.md derivation
    // (work-plane∩cursor seed), which was wrong. The reference editor's
    // background-constraint Point/nearest-foot doc-semantics still apply to an edit-time DRAG (a
    // later phase) — but for an over-surface CLICK the seed is already ON
    // the surface, so nearest-foot-of-the-seed collapses to the seed
    // itself: the `closestPointOnMeshes` call below is kept for its
    // srcIndex/face/normal out-params (so the SAME candidate-fill block
    // Screen mode already runs stays one piece of shared code, feeding
    // P1's hover/snap resolution unchanged) but is a NO-OP refinement, not
    // an independent search — a genuine no-op ONLY now that `bgFull`
    // carries each source's own ModelSpace into the refinement (task 0617
    // Stage 4 review fix): before this fix, `seedHit.point` was WORLD
    // (folded through `bg.space` inside `bgSurfaceRayHit`) while
    // `closestPointOnMeshes` searched raw LOCAL triangles, so on a
    // transformed background layer the "no-op" silently dragged the seed
    // onto the layer's IDENTITY pose and turned the reported distance into
    // the layer's translation magnitude.
    //
    // The ray missing every background surface (`bgSurfaceRayHit` returns
    // false — no background source at all, or the cursor is over empty
    // space) leaves `hit.hit == false`: an empty-area unconstrained-point
    // stays deferred to a later phase (P3), unlike P2's magnet, which
    // never missed as long as any bg source existed.
    private void pointNearestFootBackground(ref SubjectPacket subj, ref VectorStack vts) {
        import snap        : backgroundSourcesFull;
        import constraint  : closestPointOnMeshes, nearestFaceVertex, nearestFaceEdge,
                             consistentCandidateIndex, applyOffset;
        import math        : Vec3;
        import std.math     : sqrt;

        // ONE combined snapshot (task 0617 Stage 4 review fix) — mesh,
        // ModelSpace and Document-layer index together, under one lock, in
        // place of the separate backgroundSourcesSnapshot() +
        // backgroundSourceLayerIndices() calls this used to make (a second
        // lock and allocation, and the two-snapshot desync those functions'
        // own doc comments had to caveat around).
        auto bgFull = backgroundSourcesFull();

        ConstrainHitPacket hit;   // hit.hit == false by default

        SurfaceHit seedHit;
        size_t     seedSrcIdx;
        if (!bgSurfaceRayHit(subj, bgFull, seedHit, seedSrcIdx)) {
            _hitPkt = hit;   // ray missed every bg surface — no placement seed
            vts.put(&_hitPkt);
            return;
        }

        Vec3 fpt, fn;
        int  srcIdx, face;
        float d2;
        if (!closestPointOnMeshes(seedHit.point, bgFull, dblSided, fpt, fn, srcIdx, face, d2)) {
            _hitPkt = hit;   // unreachable in practice — a ray hit implies >=1 bg source
            vts.put(&_hitPkt);
            return;
        }

        hit.hit    = true;
        hit.point  = applyOffset(fpt, fn, offset);
        hit.normal = fn;
        hit.layer  = (srcIdx < cast(int)bgFull.length && bgFull[srcIdx].layerIndex >= 0)
                     ? bgFull[srcIdx].layerIndex : srcIdx;
        hit.face   = face;
        hit.t      = sqrt(d2);

        // Same candidate-fill block as Screen mode (P1, review NIT-1),
        // sourced from the WINNING bg mesh/face this branch resolved.
        // `srcIdx >= 0` is no longer checked here (review NIT, this fix):
        // `closestPointOnMeshes` only reaches this point on a `true`
        // return, which per its own doc comment guarantees srcIdx is a
        // valid (non-negative) index — the `>= 0` half of the old guard
        // was always true.
        if (srcIdx < cast(int)bgFull.length && bgFull[srcIdx].mesh !is null) {
            auto src = bgFull[srcIdx].mesh;
            auto ms  = bgFull[srcIdx].space;
            hit.nearestVert = nearestFaceVertex(*src, ms, face, fpt);
            hit.nearestEdge = nearestFaceEdge(*src, ms, face, fpt);

            hit.nearestVert = consistentCandidateIndex(
                hit.nearestVert, (*src).vertices.length);
            if (hit.nearestVert >= 0)
                hit.nearestVertPos = ms.isIdentity
                    ? (*src).vertices[hit.nearestVert]
                    : ms.toWorldPoint((*src).vertices[hit.nearestVert]);

            hit.nearestEdge = consistentCandidateIndex(
                hit.nearestEdge, (*src).edges.length);
            if (hit.nearestEdge >= 0) {
                auto e = (*src).edges[hit.nearestEdge];
                if (e[0] < (*src).vertices.length && e[1] < (*src).vertices.length) {
                    hit.nearestEdgeA = ms.isIdentity
                        ? (*src).vertices[e[0]] : ms.toWorldPoint((*src).vertices[e[0]]);
                    hit.nearestEdgeB = ms.isIdentity
                        ? (*src).vertices[e[1]] : ms.toWorldPoint((*src).vertices[e[1]]);
                } else {
                    hit.nearestEdge = -1;  // e[0]/e[1] stale relative to *src
                }
            }
        }

        _hitPkt = hit;
        vts.put(&_hitPkt);
    }

    // Screen mode — publish `bgSurfaceRayHit`'s camera-ray∩surface hit
    // directly as a ConstrainHitPacket. Reuses BvhPick/pickSurface
    // (source/bvh_pick.d) via the shared helper above — no new raycast
    // machinery, per the topology-pen P0 layering rule. Behaviorally
    // byte-identical to the original P0 `raycastBackground` body (only the
    // BVH-scan loop itself moved into `bgSurfaceRayHit`, above, so Point
    // mode can share it).
    private void screenRaycastBackground(ref SubjectPacket subj, ref VectorStack vts) {
        import snap       : backgroundSourcesFull;
        import constraint : nearestFaceVertex, nearestFaceEdge, consistentCandidateIndex;

        // ONE combined snapshot (task 0617 Stage 4 review fix) — see
        // pointNearestFootBackground's doc comment above for why.
        auto bgFull = backgroundSourcesFull();

        ConstrainHitPacket hit;
        SurfaceHit sh;
        size_t     srcI;
        if (!bgSurfaceRayHit(subj, bgFull, sh, srcI)) {
            _hitPkt = hit;
            vts.put(&_hitPkt);
            return;
        }

        auto src = bgFull[srcI].mesh;
        auto ms  = bgFull[srcI].space;
        hit.hit         = true;
        hit.point       = sh.point;
        hit.normal      = sh.normal;
        hit.layer       = (srcI < bgFull.length && bgFull[srcI].layerIndex >= 0)
                          ? bgFull[srcI].layerIndex : cast(int)srcI;
        hit.face        = sh.face;
        hit.t           = sh.t;
        hit.nearestVert = nearestFaceVertex(*src, ms, sh.face, sh.point);
        hit.nearestEdge = nearestFaceEdge(*src, ms, sh.face, sh.point);

        // topology-pen P1 (doc/topopen_p1_plan.md): candidate world
        // positions, so resolveHoverTarget (constraint.d) stays a pure
        // function of the packet alone. Index-guarded — best-effort,
        // same posture as nearestFaceVertex/nearestFaceEdge themselves
        // (the bg mesh may have mutated out from under `src` since the
        // BVH was built).
        //
        // Review NIT-1: re-derive the index through
        // consistentCandidateIndex() (constraint.d) rather than only
        // gating the position-fill on an inline bounds check — a
        // candidate whose position we cannot fill is reset to -1 here
        // too, so `hit.nearestVert`/`hit.nearestEdge` and
        // `hit.nearestVertPos`/`nearestEdgeA`/`nearestEdgeB` can never
        // go inconsistent (a `>=0` index left paired with the struct's
        // default `Vec3(0,0,0)` position — a phantom vertex/edge at the
        // world origin that resolveHoverTarget would otherwise trust).
        //
        // Task 0617 Stage 4 review fix: the fill is folded through `ms` —
        // `src.vertices[]` is LOCAL, and every position this stage
        // publishes elsewhere (`hit.point`, `sh.normal`) is WORLD, so a raw
        // local read here silently published a local position as a world
        // candidate for any transformed background layer.
        hit.nearestVert = consistentCandidateIndex(
            hit.nearestVert, (*src).vertices.length);
        if (hit.nearestVert >= 0)
            hit.nearestVertPos = ms.isIdentity
                ? (*src).vertices[hit.nearestVert]
                : ms.toWorldPoint((*src).vertices[hit.nearestVert]);

        hit.nearestEdge = consistentCandidateIndex(
            hit.nearestEdge, (*src).edges.length);
        if (hit.nearestEdge >= 0) {
            auto e = (*src).edges[hit.nearestEdge];
            if (e[0] < (*src).vertices.length && e[1] < (*src).vertices.length) {
                hit.nearestEdgeA = ms.isIdentity
                    ? (*src).vertices[e[0]] : ms.toWorldPoint((*src).vertices[e[0]]);
                hit.nearestEdgeB = ms.isIdentity
                    ? (*src).vertices[e[1]] : ms.toWorldPoint((*src).vertices[e[1]]);
            } else {
                hit.nearestEdge = -1;  // e[0]/e[1] stale relative to *src
            }
        }

        _hitPkt = hit;
        vts.put(&_hitPkt);
    }

    // --- Config fields (default values match survey §2 presets) ------------
    // `enabled` SHADOWS Stage.enabled (which defaults true for generic stages).
    // CONS defaults OFF — the user must explicitly enable it, matching SNAP.
    bool          enabled  = false;
    ConstrainGeom geom     = ConstrainGeom.Point;
    float         offset   = 0.0f;
    bool          handle   = true;
    bool          dblSided = false;

    // Set ONLY via an explicit user-facing entry point — `constrain.toggle`
    // (ConstrainToggleCommand.apply, below) and a `tool.pipe.attr constrain
    // enabled <v>` write (ToolPipeAttrCommand.apply's constrain special
    // case, commands/tool/pipe.d) — mirroring ActionCenterStage/AxisStage's
    // `setUserMode()` / FalloffStage's `tool.pipe.attr falloff type`
    // special case: the LOCK lives at the COMMAND layer, not inside
    // `onParamChanged()` (review fix SF — the prior onParamChanged-sets-
    // userLocked-on-every-write design couldn't tell an explicit user edit
    // apart from a tool's own transient composition calling `setAttr`
    // directly on the stage, e.g. TopologyPenTool.activate(), which is
    // exactly the SF-1 bug this refactor fixes). Consulted by
    // `resetTransient()` (called from app.d's `resetTransientPipeStages()`)
    // so an explicit user lock survives a tool switch while a tool's own
    // transient CONS composition cleanly reverts. Cleared by reset() and by
    // an explicit `enabled=false` write through either command-layer path.
    bool userLocked = false;

    this() { publishState(); }

    // --- Stage abstract interface ------------------------------------------
    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Cons; }
    override string   id()       const                          { return "constrain"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordCons; }

    /// Restore every field to its declaration default (auto-invoked by
    /// SceneReset via pipeline.allMut() -> s.reset()).
    override void reset() {
        enabled    = false;
        geom       = ConstrainGeom.Point;
        offset     = 0.0f;
        handle     = true;
        dblSided   = false;
        userLocked = false;
        _bgBvh.clear();
        _hitPkt = ConstrainHitPacket.init;
        publishState();
    }

    /// Same as reset() but respects userLocked — called by
    /// `resetTransientPipeStages()` (tool.set / tool switch) so an
    /// EXPLICIT user constrain setting survives switching tools, while a
    /// tool's own transient composition (e.g. TopologyPenTool enabling
    /// CONS+Point on activate() without locking it) cleanly reverts.
    /// Mirrors ActionCenterStage.resetTransient / AxisStage.resetTransient
    /// (topology-pen P0 REV-2).
    void resetTransient() {
        if (userLocked) return;
        reset();
    }

    // --- Typed params schema: fullParams() is the attr UNIVERSE, params()
    // is the panel VISIBILITY filter over it (task 0184 / audit-2 C2). When
    // disabled, params() exposes ONLY the `enabled` toggle so the panel hides
    // the four dependent rows (Mode / Offset / Handle / Dbl Sided) until the
    // user enables the stage. The full 5-param set stays reachable via the
    // HTTP surface: the base Stage's setAttr / listAttrs / knownAttrs all
    // derive from `fullParams()`, not `params()` — this MUST be a `public
    // override` (not `private`) or the base dispatches to its own default
    // `fullParams() => params()` and silently drops the 4 hidden attrs from
    // the wire surface when disabled.
    override Param[] fullParams() {
        return [
            Param.bool_("enabled", "Enabled", &enabled, false),
            Param.intEnum_("geometry", "Mode", cast(int*)&geom,
                constrainGeomEntries, cast(int)ConstrainGeom.Point),
            Param.float_("offset",   "Offset",    &offset,   0.0f),
            Param.bool_("handle",    "Handle",    &handle,    true),
            Param.bool_("dblSided",  "Dbl Sided", &dblSided, false),
        ];
    }

    override Param[] params() {
        // Disabled: expose only the enabler so the panel can re-enable CONS.
        // Enabled: expose all 5 config rows.
        return enabled ? fullParams() : fullParams()[0 .. 1];
    }

    // knownAttrs / setAttr / listAttrs are no longer overridden here — the
    // base Stage derives all three from `fullParams()` (above), which is
    // symmetric (every attr is a plain field-backed Param, no array /
    // read-only / write-only asymmetry), so the three hand-written forks
    // (and the geom->token switch each used to carry) are gone. See the
    // `knownAttrs() == fullParams() names` unittest at the bottom of this
    // file for the enforcement that replaces manual verification.

    // Deliberately does NOT touch `userLocked` (review fix SF). This fires
    // for EVERY successful setAttr — both an explicit external
    // `tool.pipe.attr constrain <name> <value>` write AND a tool's own
    // internal composition (e.g. TopologyPenTool.activate() calling
    // `cs.setAttr(...)` directly on the stage instance) — so it cannot tell
    // the two apart. Locking here unconditionally is exactly the bug the
    // prior version had: it forced every transient tool composition to
    // immediately un-lock again afterward, which in turn let a tool's own
    // un-lock clobber a genuine prior user lock. The lock now lives
    // one layer up, at the explicit-user COMMAND entry points that can
    // actually tell the two callers apart — `constrain.toggle`
    // (commands/constrain/toggle.d) and `tool.pipe.attr constrain enabled
    // <v>` (ToolPipeAttrCommand's constrain special case,
    // commands/tool/pipe.d) — mirroring ActionCenterStage/AxisStage's
    // `setUserMode()` and FalloffStage's `tool.pipe.attr falloff type`
    // special case.
    override void onParamChanged(string name) {
        publishState();
    }

private:
    void publishState() {
        setStatePath("constrain/enabled", enabled ? "true" : "false");
        setStatePath("constrain/geometry",
                     wireTagForValue(constrainGeomEntries, cast(int)geom));
    }
}

// ---------------------------------------------------------------------------
// params() snapshot — module-level so `dub test --config=tests` runs it.
// A unittest in tests/ would be silently skipped (sourcePaths is "source/").
// ---------------------------------------------------------------------------
unittest {
    auto cs = new ConstrainStage();
    // Default: disabled → only the 'enabled' toggle is exposed.
    auto ps = cs.params();
    assert(ps.length == 1, "disabled: expected 1 param");
    assert(ps[0].name == "enabled", "disabled: first param must be 'enabled'");
    // Enabled → full 5 params visible.
    cs.enabled = true;
    ps = cs.params();
    assert(ps.length == 5, "enabled: expected 5 params");
    assert(ps[0].name == "enabled");
    assert(ps[1].name == "geometry");
    assert(ps[2].name == "offset");
    assert(ps[3].name == "handle");
    assert(ps[4].name == "dblSided");
}

// ---------------------------------------------------------------------------
// OBJ-4 (MANDATORY): knownAttrs() == fullParams() names. Constrain's derived
// knownAttrs() has ZERO coverage elsewhere — no `constrain` form exercises
// the forms-engine startup validator that reads it — so a future edit that
// silently un-derives it (reintroducing a hand literal, or forgetting to
// promote `fullParams()` back to `public override` after some refactor)
// would go undetected without this. It ALSO guards OBJ-5 directly: had
// `fullParams()` been left `private` (non-virtual), the base's `knownAttrs()`
// would dispatch to the BASE `fullParams()` (== `params()`, 1 attr while
// disabled) and this assert would fail with length 1 instead of 5.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;
    auto cs = new ConstrainStage();
    // Even while disabled (params() under-reports 1), knownAttrs() must
    // report the FULL 5-attr universe.
    auto known = cs.knownAttrs();
    auto full  = cs.fullParams();
    assert(known.length == full.length,
        "knownAttrs()/fullParams() length drift — OBJ-5 non-virtual trap?");
    foreach (i, n; known)
        assert(n == full[i].name, "knownAttrs()[" ~ i.to!string ~ "] != fullParams() name");
    assert(known == ["enabled", "geometry", "offset", "handle", "dblSided"]);
}

// ---------------------------------------------------------------------------
// OBJ-3: set->read round-trip + NEGATIVE + table-completeness for the
// single-sourced `constrainGeomEntries` table (replaces the deleted
// hand-written geom<->token switches).
// ---------------------------------------------------------------------------
unittest {
    import params : tableCoversEnum;

    auto cs = new ConstrainStage();
    // Round-trip every wire tag through setAttr -> listAttrs.
    foreach (tag; ["off", "screen", "vector", "point"]) {
        assert(cs.setAttr("geometry", tag), "setAttr(geometry, " ~ tag ~ ") rejected");
        bool found = false;
        foreach (kv; cs.listAttrs())
            if (kv[0] == "geometry") { assert(kv[1] == tag); found = true; }
        assert(found, "listAttrs() missing 'geometry' after setAttr");
    }
    // NEGATIVE: a bogus token must be rejected (accept-set not widened).
    assert(!cs.setAttr("geometry", "bogus"));

    // TABLE-COMPLETENESS: every ConstrainGeom member has a table entry.
    assert(tableCoversEnum(constrainGeomEntries, [
        cast(int)ConstrainGeom.Off, cast(int)ConstrainGeom.Screen,
        cast(int)ConstrainGeom.Vector, cast(int)ConstrainGeom.Point,
    ]));
}
