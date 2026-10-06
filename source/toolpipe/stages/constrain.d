module toolpipe.stages.constrain;

import toolpipe.stage   : Stage, TaskCode, ordCons, ToolSwitchTransient;
import toolpipe.packets : ConstrainPacket, ConstrainGeom, ConstrainHitPacket,
                          SubjectPacket;
import operator         : Operator, Task, VectorStack, PacketKind;
import popup_state      : setStatePath, installPreparedStatePath;
import params           : Param, IntEnumEntry, wireTagForValue;
import bvh_pick         : BackgroundRayPicker, SurfaceHit;
import math             : Vec3, Viewport;
import constraint        : BackgroundSource;
import snap             : backgroundSourcesFull;

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
// Background surface (task 9403, M-CONS): `rayHit` is the ONE background
// query (`backgroundHit`), ungated, on a world ray; `rayHitAt` takes a window
// pixel's centre;
// `surfaceOnRay` / `surfaceAt` add the pointer gate `enabled && handle`;
// `offsetPoint` is the offset each client applies in its captured order;
// `pass` is the constraint's own pass over a point a tool already placed
// (`constrainPoint` under this stage's settings; capture K-C4).
// The stage's own hover publish (`publishSurfaceHit`) reads `rayHitAt`,
// UNGATED by `handle` (K-C4 h0 == h1): the topology pen's placement, the hit
// offset, then `pass` over it —
//   * `point`  mode — the nearest foot + offset·n (K-C4 pt_off);
//   * `screen` mode — the nearest hit on the view line, offset AGAIN (K-C4 scr, scr2:
//     the double offset);
//   * `vector` mode — accepted attrs, no publish (no drag consumer yet).
//
// HTTP setAttr keys (via tool.pipe.attr constrain <name> <value>):
//   `enabled`  : "true" / "false"
//   `geometry` : "off" / "screen" / "vector" / "point"
//   `offset`   : float, world units (default 0; a negative write stores 0)
//   `handle`   : "true" / "false" (default true)
//   `dblSided` : "true" / "false" (default false)
// ---------------------------------------------------------------------------

/// The user's remembered constraint (fixtures/constraint_boot.json):
/// `yes` = remembered, not in the pipe (boot, scene reset); `inPipe` =
/// remembered and enabled (a tool drop or the user's toggle-on put it there);
/// `no` = forgotten (toggle-off, the Escape clear) until the next toggle-on.
enum Remembered : ubyte { yes, inPipe, no }

struct PreparedConstrainCompositionProjection {
    bool enabled, userLocked;
    ConstrainGeom geom;
    float offset;
    bool handle, dblSided;
    Remembered remembered;
}

unittest {
    auto live = new ConstrainStage();
    assert(!live.enabled && live.geom == ConstrainGeom.Off &&
           live.remembered == Remembered.yes, "fresh constrain stage is not the boot state");
    live.enabled = true;
    live.geom = ConstrainGeom.Screen;
    live.offset = 4.0f;
    live.handle = false;
    live.dblSided = true;
    live.installPreparedTransientReset();
    assert(!live.enabled && live.geom == ConstrainGeom.Off &&
           live.offset == 0.0f && live.handle && !live.dblSided,
           "prepared constrain transient reset omitted live value state");
    live.userLocked = true;
    live.enabled = true;
    live.geom = ConstrainGeom.Screen;
    live.installPreparedTransientReset();
    assert(live.enabled && live.geom == ConstrainGeom.Screen && live.userLocked,
           "prepared constrain transient reset ignored the user lock");
    auto kept = new ConstrainStage();
    kept.remembered = Remembered.inPipe;
    kept.geom = ConstrainGeom.Screen;
    kept.installPreparedTransientReset();
    import popup_state : getStatePath;
    assert(getStatePath("constrain/enabled") == "true" &&
           getStatePath("constrain/geometry") == "off",
           "prepared constrain transient reset published a stale state path");
    assert(kept.enabled && kept.geom == ConstrainGeom.Off,
           "prepared constrain transient reset ignored the remembered constraint");
    const before = kept.capturePreparedCompositionProjection();
    kept.remembered = Remembered.no;
    assert(!kept.matchesPreparedCompositionProjection(before),
           "prepared constrain projection omitted the remembered state");
}

class ConstrainStage : Stage, Operator, ToolSwitchTransient {
private:
    ConstrainPacket _publishedPacket;

    // --- Background-surface raycast (topology-pen P0) -----------------------
    // One BvhPick per background-layer mesh, keyed by mesh ADDRESS (the
    // stage stays Document-free — it only needs
    // `snap.backgroundSourcesSnapshot()`, mirroring how the CONS post-pass
    // projection in xfrm_transform.d already consumes that same snapshot).
    // Pruned each evaluate() so a removed/hidden background layer's BVH is
    // freed (mirrors `BgGpuCache.reconcile`'s prune pattern).
    BackgroundRayPicker _bgBvh;
    ConstrainHitPacket _hitPkt;

public:
    /// `backgroundHit` through the stage's BVHs (the ones the hover built):
    /// the background surface on a WORLD ray, UNGATED.
    /// `hit.source` indexes `sources`.
    bool rayHit(Vec3 org, Vec3 dir, out SurfaceHit hit,
                const(BackgroundSource)[] sources = backgroundSourcesFull()) {
        return backgroundHit(_bgBvh, org, dir, sources, hit);
    }

    /// `rayHit` through window pixel (x, y)'s CENTRE, the one pixel convention.
    bool rayHitAt(int x, int y, const ref Viewport vp, out SurfaceHit hit,
                  const(BackgroundSource)[] sources = backgroundSourcesFull()) {
        Vec3 org, dir;
        pixelRay(x, y, vp, org, dir);
        return rayHit(org, dir, hit, sources);
    }

    /// The background surface on the ray when the constraint takes the
    /// pointer (`enabled && handle`): the RAW hit and facet normal. Each client
    /// offsets it (`offsetPoint`) where its captured order puts the offset.
    bool surfaceOnRay(Vec3 org, Vec3 dir, out SurfaceHit hit) {
        return enabled && handle && rayHit(org, dir, hit);
    }

    /// `surfaceOnRay` through window pixel (x, y)'s centre.
    bool surfaceAt(int x, int y, const ref Viewport vp, out SurfaceHit hit) {
        Vec3 org, dir;
        pixelRay(x, y, vp, org, dir);
        return surfaceOnRay(org, dir, hit);
    }

    /// `p` moved `offset` along the surface normal `n`.
    Vec3 offsetPoint(Vec3 p, Vec3 n) const {
        import constraint : applyOffset;
        return applyOffset(p, n, offset);
    }

    /// The constraint's pass over `placed`, a WORLD point a tool already
    /// placed (`motion` its edit delta, for `vector`): Point the nearest
    /// surface foot + offset·n, Screen the view re-cast + offset·n, `placed`
    /// itself when off or disabled (K-C4 h0d / h0d_g0, scr).
    Vec3 pass(Vec3 placed, const ref Viewport vp, Vec3 motion = Vec3(0, 0, 0),
              const(BackgroundSource)[] sources = backgroundSourcesFull()) const {
        import constraint : constrainPoint;
        const cfg = packet();
        return constrainPoint(placed, motion, vp, sources, cfg);
    }

    private ConstrainPacket packet() const {
        ConstrainPacket pkt;
        pkt.enabled  = enabled;
        pkt.geom     = geom;
        pkt.offset   = offset;
        pkt.dblSided = dblSided;
        return pkt;
    }

    private static void pixelRay(int x, int y, const ref Viewport vp, out Vec3 org, out Vec3 dir) {
        import math : screenPointToRay;
        screenPointToRay(x + 0.5f, y + 0.5f, vp, org, dir);
    }

    // --- Operator interface -------------------------------------------------
    Task task() const { return Task.Cons; }
    PacketKind[] requiredPackets() const { return [PacketKind.Subject]; }

    bool evaluate(ref VectorStack vts) {
        if (!enabled) return false;
        _publishedPacket = packet();
        vts.put(&_publishedPacket);

        // Point and Screen publish the surface under the cursor (Vector / Off
        // none), and only for a THREAD-SAFE cursor: `subj.cursorValid` is
        // stamped true ONLY on the main-thread mouse-event path (app.d's
        // buildToolVts) and the main-thread-bridged /api/surface-raycast, so
        // an HTTP-thread evaluate() never mutates `_bgBvh` (R1 of
        // doc/topopen_p0_plan.md).
        if (geom == ConstrainGeom.Point || geom == ConstrainGeom.Screen) {
            auto subj = vts.get!SubjectPacket();
            if (subj !is null && subj.cursorValid && subj.viewport.width > 0)
                publishSurfaceHit(*subj, vts);
        }
        return true;
    }

    // The hover publish: `rayHitAt` the cursor pixel over ONE sources
    // snapshot (`sh.source` indexes it, task 0617); the hit offset, `pass`
    // after it at every offset (K-SC scr0: Screen at offset 0 is the surface
    // under the point). The hit face's nearest vertex / edge ride along as WORLD
    // candidates, so `resolveHoverTarget` stays a function of the packet.
    private void publishSurfaceHit(ref SubjectPacket subj, ref VectorStack vts) {
        import constraint : nearestFaceVertex, nearestFaceEdge, consistentCandidateIndex;

        _hitPkt = ConstrainHitPacket.init;
        scope(exit) vts.put(&_hitPkt);
        auto bgFull = backgroundSourcesFull();
        SurfaceHit sh;
        if (!rayHitAt(subj.cursorX, subj.cursorY, subj.viewport, sh, bgFull)) return;
        immutable src = sh.source, face = sh.face;
        immutable p = sh.point, n = sh.normal;
        if (src < 0 || src >= cast(int)bgFull.length || bgFull[src].mesh is null) return;

        const bg = bgFull[src];
        const m  = bg.mesh;
        Vec3 world(uint v) { return bg.space.isIdentity ? m.vertices[v] : bg.space.toWorldPoint(m.vertices[v]); }
        _hitPkt.hit    = true;
        _hitPkt.point  = pass(offsetPoint(p, n), subj.viewport, Vec3(0, 0, 0), bgFull);
        _hitPkt.normal = n;
        _hitPkt.layer  = bg.layerIndex >= 0 ? bg.layerIndex : src;
        _hitPkt.face   = face;
        _hitPkt.t      = sh.t;
        // A candidate whose position cannot be filled is -1 too, so an index
        // never pairs with a default (origin) position (review NIT-1).
        _hitPkt.nearestVert = consistentCandidateIndex(
            nearestFaceVertex(*m, bg.space, face, p), m.vertices.length);
        if (_hitPkt.nearestVert >= 0) _hitPkt.nearestVertPos = world(_hitPkt.nearestVert);
        _hitPkt.nearestEdge = consistentCandidateIndex(
            nearestFaceEdge(*m, bg.space, face, p), m.edges.length);
        if (_hitPkt.nearestEdge >= 0) {
            const e = m.edges[_hitPkt.nearestEdge];
            if (e[0] < m.vertices.length && e[1] < m.vertices.length) {
                _hitPkt.nearestEdgeA = world(e[0]);
                _hitPkt.nearestEdgeB = world(e[1]);
            } else {
                _hitPkt.nearestEdge = -1;  // e[0]/e[1] stale relative to the mesh
            }
        }
    }

    // --- Config fields (default values match survey §2 presets) ------------
    // `enabled` SHADOWS Stage.enabled (which defaults true for generic stages).
    // CONS defaults OFF — the user must explicitly enable it, matching SNAP.
    bool          enabled  = false;
    ConstrainGeom geom     = ConstrainGeom.Off;
    float         offset   = 0.0f;
    bool          handle   = true;
    bool          dblSided = false;

    // Set ONLY at the user's command doors (`constrain.toggle`, any
    // `tool.pipe.attr constrain <attr>` write, commands/tool/pipe.d), never in
    // `onParamChanged()`: a tool's own composition (TopologyPenTool.activate)
    // calls `setAttr` directly and must revert at the next tool switch, while
    // the user's settings survive it (review fix SF; cell TS-keep).
    // `remembered` is the separate fact the transient reset returns to.
    bool userLocked = false;
    Remembered remembered = Remembered.yes;

    PreparedConstrainCompositionProjection capturePreparedCompositionProjection()
            const nothrow @nogc {
        return PreparedConstrainCompositionProjection(enabled, userLocked, geom,
                                                       offset, handle, dblSided, remembered);
    }
    bool matchesPreparedCompositionProjection(
            in PreparedConstrainCompositionProjection expected) const nothrow @nogc {
        return enabled == expected.enabled && userLocked == expected.userLocked &&
            geom == expected.geom && offset == expected.offset &&
            handle == expected.handle && dblSided == expected.dblSided &&
            remembered == expected.remembered;
    }
    void installPreparedPointComposition() nothrow {
        enabled = true; geom = ConstrainGeom.Point;
        installPreparedStatePath("constrain/enabled", "true");
        installPreparedStatePath("constrain/geometry", "point");
    }

    this() { publishState(); }

    // --- Stage abstract interface ------------------------------------------
    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Cons; }
    override string   id()       const                          { return "constrain"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordCons; }

    /// Every field to its declaration default (SceneReset's stage loop): the
    /// constraint is remembered but not in the pipe until a tool drop.
    /// The constraint in the pipe is a guide for any drag (findings_K-G3 PIPE-ONLY).
    override int snapGuideSources() const { return remembered == Remembered.inPipe; }

    override void reset() {
        remembered = Remembered.yes;
        userLocked = false;
        resetTransient();
    }

    /// A tool switch / drop: unless the user locked the settings, back to the
    /// defaults, in the pipe exactly when the user's constraint is.
    override void resetTransient() {
        if (userLocked) return;
        enabled    = remembered == Remembered.inPipe;
        geom       = ConstrainGeom.Off;
        offset     = 0.0f;
        handle     = true;
        dblSided   = false;
        _bgBvh.clear();
        _hitPkt = ConstrainHitPacket.init;
        publishState();
    }

    /// A tool drop puts the remembered constraint into the pipe; a forgotten
    /// one stays out (cells first-drop-*, cleared-not-readded). A user-locked
    /// stage is the user's own setting and keeps its enable, as in
    /// `resetTransient` (cell forgotten-pen-attr-drop).
    void noteToolDropped() {
        if (remembered == Remembered.yes) remembered = Remembered.inPipe;
        if (userLocked) return;
        enabled = remembered == Remembered.inPipe;
        publishState();
    }

    /// The Escape clear forgets the constraint and keeps its settings.
    override void clearTask() {
        enabled    = false;
        remembered = Remembered.no;
        userLocked = false;
        publishState();
    }

    void installPreparedTransientReset() nothrow {
        if (userLocked) return;
        enabled    = remembered == Remembered.inPipe;
        geom       = ConstrainGeom.Off;
        offset     = 0.0f;
        handle     = true;
        dblSided   = false;
        _bgBvh.clear();
        _hitPkt = ConstrainHitPacket.init;
        installPreparedStatePath("constrain/enabled", enabled ? "true" : "false");
        installPreparedStatePath("constrain/geometry", "off");
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
                constrainGeomEntries, cast(int)ConstrainGeom.Off),
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

    // Deliberately does NOT touch `userLocked` (review fix SF): it fires for a
    // tool's own composition too; the lock lives at the command doors above.
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

/// The ONE background query (task 9403, M-CONS): the nearest hit of the WORLD
/// ray over every background source, each through its own space, cached in
/// `bvh`; `hit.source` indexes `sources`. Pointer clients
/// call the stage's forms; only a pipeline-less one passes its own `bvh`.
bool backgroundHit(ref BackgroundRayPicker bvh, Vec3 org, Vec3 dir,
                   const(BackgroundSource)[] sources, out SurfaceHit hit) {
    return bvh.nearest(org, dir, sources, hit);
}

/// The live pipeline's constraint stage, or null. The ONE finder
/// over `g_pipeCtx` (`constrain.toggle`, the topology pen's activation and its
/// background ray query); a prepared image reading its OWN pipeline keeps its own.
ConstrainStage liveConstrainStage() {
    import toolpipe.pipeline : g_pipeCtx;
    if (g_pipeCtx is null) return null;
    return cast(ConstrainStage) g_pipeCtx.pipeline.findByTask(TaskCode.Cons);
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
