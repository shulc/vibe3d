module toolpipe.stages.constrain;

import std.format : format;

import toolpipe.stage   : Stage, TaskCode, ordCons, parseInto;
import toolpipe.packets : ConstrainPacket, ConstrainGeom;
import operator         : Operator, Task, VectorStack, PacketKind;
import popup_state      : setStatePath;
import params           : Param, IntEnumEntry;

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

    // --- Typed params schema (drives Tool Properties panel visibility) ------
    // When disabled, expose ONLY the `enabled` toggle so the panel hides the
    // four dependent rows (Mode / Offset / Handle / Dbl Sided) until the user
    // enables the stage. The full 5-param set remains reachable via the HTTP
    // surface: setAttr / listAttrs / knownAttrs all use fullParams() —
    // mirroring FalloffStage's filter + override pattern (stage.d:133-138).
    private Param[] fullParams() {
        return [
            Param.bool_("enabled", "Enabled", &enabled, false),
            Param.intEnum_("geometry", "Mode", cast(int*)&geom,
                [IntEnumEntry(cast(int)ConstrainGeom.Off,    "off",    "Off"),
                 IntEnumEntry(cast(int)ConstrainGeom.Screen, "screen", "Screen"),
                 IntEnumEntry(cast(int)ConstrainGeom.Vector, "vector", "Vector"),
                 IntEnumEntry(cast(int)ConstrainGeom.Point,  "point",  "Point")],
                cast(int)ConstrainGeom.Point),
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

    // Keep the HTTP surface FULL regardless of the params() filter.
    // stage.d default setAttr / listAttrs walk params() — after the filter they
    // would drop the 4 hidden attrs. Override all three to use fullParams().
    override string[] knownAttrs() {
        return ["enabled", "geometry", "offset", "handle", "dblSided"];
    }
    override bool setAttr(string name, string value) {
        foreach (ref p; fullParams()) {
            if (p.name != name) continue;
            bool ok = parseInto(p, value);
            if (ok) onParamChanged(name);
            return ok;
        }
        return false;
    }
    // const: must not call non-const fullParams(); stringify fields directly.
    override string[2][] listAttrs() const {
        string geomStr;
        final switch (geom) {
            case ConstrainGeom.Off:    geomStr = "off";    break;
            case ConstrainGeom.Screen: geomStr = "screen"; break;
            case ConstrainGeom.Vector: geomStr = "vector"; break;
            case ConstrainGeom.Point:  geomStr = "point";  break;
        }
        return [
            ["enabled",  enabled  ? "true" : "false"],
            ["geometry", geomStr],
            ["offset",   format("%g", offset)],
            ["handle",   handle   ? "true" : "false"],
            ["dblSided", dblSided ? "true" : "false"],
        ];
    }

    override void onParamChanged(string name) { publishState(); }

private:
    void publishState() {
        setStatePath("constrain/enabled", enabled ? "true" : "false");
        string gstr;
        final switch (geom) {
            case ConstrainGeom.Off:    gstr = "off";    break;
            case ConstrainGeom.Screen: gstr = "screen"; break;
            case ConstrainGeom.Vector: gstr = "vector"; break;
            case ConstrainGeom.Point:  gstr = "point";  break;
        }
        setStatePath("constrain/geometry", gstr);
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
