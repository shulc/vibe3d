module toolpipe.stages.constrain;

import toolpipe.stage   : Stage, TaskCode, ordCons;
import toolpipe.packets : ConstrainPacket, ConstrainGeom, ConstrainHitPacket,
                          SubjectPacket;
import operator         : Operator, Task, VectorStack, PacketKind;
import popup_state      : setStatePath;
import params           : Param, IntEnumEntry, wireTagForValue;
import bvh_pick         : BvhPick, SurfaceHit;

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
// Functional scope (topology-pen P2, doc/topopen_p2_plan.md, supersedes the
// earlier Stage-0 "working assumption" comment below):
//   * `point` mode  — background-surface MAGNET: nearest world-space foot
//                     on the background mesh to the work-plane∩cursor SEED
//                     (NOT the camera-ray hit — see `pointNearestFootBackground`
//                     below). This is the Topology Pen's mode.
//   * `screen` mode — camera-ray∩surface (search perpendicular to the
//                     view); this is the Topology Sketch sibling's mode
//                     (see `screenRaycastBackground` below, unchanged from
//                     the original P0 raycast).
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
    // Point = nearest-foot magnet (`pointNearestFootBackground`); Screen =
    // camera-ray (`screenRaycastBackground`, byte-identical to the original
    // P0 body). Off/Vector are unreachable through the evaluate() gate
    // above — kept here only so the `final switch` stays exhaustive.
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

    // Point mode — background-surface MAGNET (topology-pen P2,
    // doc/topopen_p2_plan.md P2a-2): nearest world-space foot on any
    // background-layer mesh to the work-plane∩cursor SEED (NOT the
    // camera-ray hit — that is Screen mode, `screenRaycastBackground`
    // below). This is the mode the Topology Pen uses.
    //
    // Seed derivation:
    //   1. Work-plane basis: prefer the WorkplanePacket already published
    //      earlier in THIS SAME evaluate() pass (WORK sits at Task.Work=0,
    //      before Task.Cons=3, so it always runs first — see pipeline.d's
    //      per-Task-slot walk). Absent WorkplanePacket (WORK stage missing
    //      from the pipe) falls back to a direct `pickMostFacingPlane`
    //      read — the SAME auto-pick WorkplaneStage itself would use —
    //      with `center = Vec3(0,0,0)` deliberately mirroring
    //      WorkplaneStage's own auto-mode publish (`_publishedPacket.center
    //      = Vec3(0,0,0)`, workplane.d), NOT `pickWorkplaneFrame`'s
    //      `vp.focus` fallback (that one is for CREATE tools placing
    //      geometry AT the camera focus — a different concern from this
    //      constraint seed).
    //   2. Seed = the cursor ray (from `subj.viewport.eye` along
    //      `screenRay(subj.cursorX, subj.cursorY, subj.viewport)`)
    //      intersected with that plane. No intersection (ray parallel to
    //      the plane) leaves `hit.hit = false` — an UNDEFINED seed, not a
    //      "no bg surface" miss.
    //   3. `constraint.closestPointOnMeshes(seed, bgSrc, ...)` finds the
    //      globally nearest foot across every background source — this
    //      ALWAYS finds a point when at least one bg source has faces
    //      (nearest-foot never "misses" the way a ray can), so `hit.hit`
    //      is false here only when there is no background source at all.
    //   4. The candidate-fill block (nearestVert/nearestEdge +
    //      world-position pairs) is the SAME logic `screenRaycastBackground`
    //      already runs (P1, review NIT-1's `consistentCandidateIndex`
    //      guard) — sourced from the WINNING bg mesh/face this branch
    //      resolved, so P1 hover keeps working unchanged over the
    //      corrected point.
    private void pointNearestFootBackground(ref SubjectPacket subj, ref VectorStack vts) {
        import snap        : backgroundSourcesSnapshot, backgroundSourceLayerIndices;
        import constraint  : closestPointOnMeshes, nearestFaceVertex, nearestFaceEdge,
                             consistentCandidateIndex, applyOffset;
        import toolpipe.packets : WorkplanePacket;
        import tools.create.create_common : pickMostFacingPlane;
        import math        : Vec3, screenRay, rayPlaneIntersect;
        import std.math     : sqrt;

        auto bgSrc      = backgroundSourcesSnapshot();
        auto bgSrcLayer = backgroundSourceLayerIndices();

        ConstrainHitPacket hit;   // hit.hit == false by default

        Vec3 wpCenter, wpNormal;
        if (auto wp = vts.get!WorkplanePacket()) {
            wpCenter = wp.center;
            wpNormal = wp.normal;
        } else {
            // WORK didn't publish this pass (stage missing from the pipe) —
            // fall back to the same auto-pick WorkplaneStage itself would
            // use. `center = Vec3(0,0,0)` deliberately mirrors
            // WorkplaneStage's own auto-mode publish (see doc comment
            // above) — not a `vp.focus`-anchored fallback.
            auto bp = pickMostFacingPlane(subj.viewport);
            wpCenter = Vec3(0, 0, 0);
            wpNormal = bp.normal;
        }

        Vec3 dir = screenRay(subj.cursorX, subj.cursorY, subj.viewport);
        Vec3 seed;
        if (!rayPlaneIntersect(subj.viewport.eye, dir, wpCenter, wpNormal, seed)) {
            _hitPkt = hit;   // ray parallel to the work-plane — undefined seed
            vts.put(&_hitPkt);
            return;
        }

        Vec3 fpt, fn;
        int  srcIdx, face;
        float d2;
        if (!closestPointOnMeshes(seed, bgSrc, dblSided, fpt, fn, srcIdx, face, d2)) {
            _hitPkt = hit;   // no background source with faces — no hit
            vts.put(&_hitPkt);
            return;
        }

        hit.hit    = true;
        hit.point  = applyOffset(fpt, fn, offset);
        hit.normal = fn;
        hit.layer  = (srcIdx >= 0 && srcIdx < cast(int)bgSrcLayer.length)
                     ? bgSrcLayer[srcIdx] : srcIdx;
        hit.face   = face;
        hit.t      = sqrt(d2);

        // Same candidate-fill block as Screen mode (P1, review NIT-1),
        // sourced from the WINNING bg mesh/face this branch resolved.
        if (srcIdx >= 0 && srcIdx < cast(int)bgSrc.length && bgSrc[srcIdx] !is null) {
            auto src = bgSrc[srcIdx];
            hit.nearestVert = nearestFaceVertex(*src, face, fpt);
            hit.nearestEdge = nearestFaceEdge(*src, face, fpt);

            hit.nearestVert = consistentCandidateIndex(
                hit.nearestVert, (*src).vertices.length);
            if (hit.nearestVert >= 0)
                hit.nearestVertPos = (*src).vertices[hit.nearestVert];

            hit.nearestEdge = consistentCandidateIndex(
                hit.nearestEdge, (*src).edges.length);
            if (hit.nearestEdge >= 0) {
                auto e = (*src).edges[hit.nearestEdge];
                if (e[0] < (*src).vertices.length && e[1] < (*src).vertices.length) {
                    hit.nearestEdgeA = (*src).vertices[e[0]];
                    hit.nearestEdgeB = (*src).vertices[e[1]];
                } else {
                    hit.nearestEdge = -1;  // e[0]/e[1] stale relative to *src
                }
            }
        }

        _hitPkt = hit;
        vts.put(&_hitPkt);
    }

    // Screen mode — cast a ray from the current cursor pixel through every
    // background layer's mesh (snap.backgroundSourcesSnapshot(), world-space,
    // PINNED identity transform for P0 — R4), keep the globally nearest hit,
    // and publish it as a ConstrainHitPacket. Reuses BvhPick/pickSurface
    // (source/bvh_pick.d) — no new raycast machinery, per the topology-pen
    // P0 layering rule. Byte-identical to the original P0 `raycastBackground`
    // body (topology-pen P2 REV: only the enclosing gate/dispatch changed —
    // this branch's OWN behavior did not).
    private void screenRaycastBackground(ref SubjectPacket subj, ref VectorStack vts) {
        import snap       : backgroundSourcesSnapshot, backgroundSourceLayerIndices;
        import constraint : nearestFaceVertex, nearestFaceEdge, consistentCandidateIndex;

        auto bgSrc      = backgroundSourcesSnapshot();
        // Parallel Document-layer-index array (NIT-3) — index i is the
        // Document-layer index bgSrc[i] came from. Stays Document-free here
        // (both are plain snapshots from snap.d); a length mismatch (an
        // installer that didn't supply indices) falls back to the bgSrc
        // slot itself below, so this never indexes out of bounds.
        auto bgSrcLayer = backgroundSourceLayerIndices();

        // Prune cache entries whose mesh left the current background set.
        bool[size_t] live;
        foreach (src; bgSrc)
            if (src !is null) live[cast(size_t)src] = true;
        size_t[] stale;
        foreach (addr, bp; _bgBvh)
            if ((addr in live) is null) stale ~= addr;
        foreach (addr; stale) _bgBvh.remove(addr);

        ConstrainHitPacket hit;
        float bestT = float.infinity;
        foreach (i, src; bgSrc) {
            if (src is null) continue;
            size_t addr = cast(size_t)src;
            auto pp = addr in _bgBvh;
            BvhPick bp;
            if (pp is null) {
                bp = new BvhPick();
                _bgBvh[addr] = bp;
            } else {
                bp = *pp;
            }
            SurfaceHit sh;
            if (!bp.pickSurface(subj.cursorX, subj.cursorY, subj.viewport, *src, sh))
                continue;
            if (sh.t >= bestT) continue;
            bestT           = sh.t;
            hit.hit         = true;
            hit.point       = sh.point;
            hit.normal      = sh.normal;
            hit.layer       = (i < bgSrcLayer.length) ? bgSrcLayer[i] : cast(int)i;
            hit.face        = sh.face;
            hit.t           = sh.t;
            hit.nearestVert = nearestFaceVertex(*src, sh.face, sh.point);
            hit.nearestEdge = nearestFaceEdge(*src, sh.face, sh.point);

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
            hit.nearestVert = consistentCandidateIndex(
                hit.nearestVert, (*src).vertices.length);
            if (hit.nearestVert >= 0)
                hit.nearestVertPos = (*src).vertices[hit.nearestVert];

            hit.nearestEdge = consistentCandidateIndex(
                hit.nearestEdge, (*src).edges.length);
            if (hit.nearestEdge >= 0) {
                auto e = (*src).edges[hit.nearestEdge];
                if (e[0] < (*src).vertices.length && e[1] < (*src).vertices.length) {
                    hit.nearestEdgeA = (*src).vertices[e[0]];
                    hit.nearestEdgeB = (*src).vertices[e[1]];
                } else {
                    hit.nearestEdge = -1;  // e[0]/e[1] stale relative to *src
                }
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
// params() snapshot — module-level so `dub test --config=modeling` runs it.
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
