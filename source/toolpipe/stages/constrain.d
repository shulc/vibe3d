module toolpipe.stages.constrain;

import toolpipe.stage   : Stage, TaskCode, ordCons;
import toolpipe.packets : ConstrainPacket, ConstrainGeom;
import operator         : Operator, Task, VectorStack, PacketKind;
import popup_state      : setStatePath;
import params           : Param, IntEnumEntry, wireTagForValue;

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
// Functional scope (Stages 1-4 of doc/cons_constraint_plan.md):
//   * `point` mode  — nearest world-space foot on the background mesh
//                     (working assumption; revisited on Stage-0 capture).
//   * `screen`/`vector` modes — accepted attrs, round-trip cleanly,
//                     but currently no-op (return movingPos unchanged)
//                     until Stage 0 resolves their projection direction.
//   * `offset`, `handle`, `dblSided` — accepted attrs, round-trip,
//                     no-op pending Stage-0 captures.
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
        return true;
    }

    // --- Config fields (default values match survey §2 presets) ------------
    // `enabled` SHADOWS Stage.enabled (which defaults true for generic stages).
    // CONS defaults OFF — the user must explicitly enable it, matching SNAP.
    bool          enabled  = false;
    ConstrainGeom geom     = ConstrainGeom.Point;
    float         offset   = 0.0f;
    bool          handle   = true;
    bool          dblSided = false;

    // Reserved for Stage 5 (capture-gated): set when the user explicitly
    // toggles/sets CONS via constrain.toggle or tool.pipe.attr; cleared by
    // reset() and geometry=off. Not yet consulted — CONS currently survives
    // tool switches via the default no-op in resetTransientPipeStages (same as
    // snap); a future resetTransient() would read this to honour an explicit lock.
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
        publishState();
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

    override void onParamChanged(string name) { publishState(); }

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
