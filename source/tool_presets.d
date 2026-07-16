module tool_presets;

import std.format : format;
import std.json : JSONValue;

import registry         : Registry;
import tool             : Tool, ToolFlag;
import toolpipe.pipeline : g_pipeCtx;
import params : Param, ParamProvider, injectParamsInto, parseInto;
import prefs  : g_prefs, Prefs;

// ---------------------------------------------------------------------------
// Tool presets — declarative `<base tool> + <per-pipe-stage attrs>` bundles.
// A preset is a named base tool plus per-pipe-stage attribute overrides
// (e.g. `xfrm.shear` = falloff.linear + xfrm.transform with attrs). Presets
// live in `config/tool_presets.yaml`.
//
// Each loaded preset registers as a new tool factory in `Registry` that:
//   1. Calls the named base factory (Move / Rotate / Scale / ...).
//   2. For each `pipe.<stageId>` block, applies `setAttr(key, value)` to
//      the matching toolpipe stage. Values stringify the same way the
//      `tool.pipe.attr <stageId> <name> <value>` HTTP command does.
//
// New presets = YAML edits, no recompile.
// ---------------------------------------------------------------------------

struct ToolPreset {
    string                    id;            // e.g. "xfrm.softDrag"
    string                    base;          // base tool id, e.g. "move"
    string[string][string]    pipeAttrs;     // stageId → (key → value)
    string[string]            toolAttrs;     // tool-level attr → value
    uint                      flags;         // OR of ToolFlag bits
}

// Map YAML flag name → ToolFlag bit. Names match the enum members
// case-insensitively so `flags: [brushReset]` and `flags: [BrushReset]`
// both parse. See the ToolFlag enum doc in `source/tool.d`.
private uint parseToolFlag(string name) {
    import std.uni : toLower;
    import std.string : strip;
    switch (toLower(strip(name))) {
        case "immediate":  return ToolFlag.Immediate;
        case "brushreset": return ToolFlag.BrushReset;
        default: throw new Exception("tool_presets: unknown flag '" ~ name ~ "'");
    }
}

ToolPreset[] loadToolPresets(string path) {
    import dyaml;

    Node root;
    try {
        root = Loader.fromFile(path).load();
    } catch (Exception e) {
        throw new Exception(format("tool_presets: failed to load '%s': %s", path, e.msg));
    }
    if (!root.containsKey("presets"))
        throw new Exception(format("tool_presets: '%s' missing top-level 'presets' key", path));

    ToolPreset[] presets;
    // Alias entries (`id` + `alias:` only, no `base`) are stashed here during
    // the first pass and resolved in a SEPARATE second pass below, against the
    // full set of base presets collected in pass one. This is deliberately
    // two-pass (rather than "look up the target so far") so a future YAML
    // reorder — an alias entry placed BEFORE its canonical target — still
    // resolves; nothing here depends on file order.
    string[2][] pendingAliases; // [aliasId, targetId]

    foreach (Node node; root["presets"]) {
        if (!node.containsKey("id"))
            throw new Exception(format("tool_presets: entry in '%s' missing 'id'", path));
        string id = node["id"].as!string;

        if (node.containsKey("alias")) {
            // An alias entry is a bare pointer to a canonical preset — it may
            // carry ONLY `id` + `alias`. Mixing in `base`/`pipe`/`attrs`/`flags`
            // would leave it ambiguous which side wins, so reject it outright.
            if (node.containsKey("base") || node.containsKey("pipe")
                    || node.containsKey("attrs") || node.containsKey("flags"))
                throw new Exception(format(
                    "tool_presets: preset '%s' in '%s' has 'alias' plus "
                    ~ "'base'/'pipe'/'attrs'/'flags' — an alias entry may only "
                    ~ "have 'id' and 'alias'", id, path));
            pendingAliases ~= [id, node["alias"].as!string];
            continue;
        }

        if (!node.containsKey("base"))
            throw new Exception(format("tool_presets: preset '%s' in '%s' missing 'base'",
                                       id, path));
        ToolPreset p;
        p.id   = id;
        p.base = node["base"].as!string;

        if (node.containsKey("pipe")) {
            foreach (string stageId, Node attrsNode; node["pipe"]) {
                string[string] attrs;
                foreach (string key, Node valNode; attrsNode) {
                    attrs[key] = valNode.as!string;
                }
                p.pipeAttrs[stageId] = attrs;
            }
        }
        // Top-level `attrs:` block — tool-level params (not pipe
        // stages). Used by Transform / TransformMove / etc. presets
        // to flip T/R/S flags on xfrm.transform. Applied after the
        // base tool's factory builds it, BEFORE activate().
        if (node.containsKey("attrs")) {
            foreach (string key, Node valNode; node["attrs"])
                p.toolAttrs[key] = valNode.as!string;
        }
        if (node.containsKey("flags")) {
            // Accept either a sequence (`flags: [brushReset]`) or a
            // scalar (`flags: brushReset`). Mapping form is rejected —
            // YAML mappings don't fit a bitmask.
            Node fnode = node["flags"];
            if (fnode.nodeID == NodeID.sequence) {
                foreach (Node nm; fnode)
                    p.flags |= parseToolFlag(nm.as!string);
            } else if (fnode.nodeID == NodeID.scalar) {
                p.flags |= parseToolFlag(fnode.as!string);
            } else {
                throw new Exception(format(
                    "tool_presets: preset '%s' has non-sequence/scalar `flags`", p.id));
            }
        }
        presets ~= p;
    }

    // Second pass: resolve every stashed alias against the base presets
    // collected above. Order-independent by construction — `presets` is
    // already fully populated regardless of where in the file the alias
    // entry sat relative to its target. Only base presets are searched
    // (`presets[0 .. baseCount]`); resolved aliases are appended past that
    // bound, so an alias-to-alias target finds nothing and throws, exactly
    // as the error message below promises.
    immutable baseCount = presets.length;
    foreach (aliasPair; pendingAliases) {
        string aliasId  = aliasPair[0];
        string targetId = aliasPair[1];
        const(ToolPreset)* target = null;
        foreach (ref p; presets[0 .. baseCount])
            if (p.id == targetId) { target = &p; break; }
        if (target is null)
            throw new Exception(format(
                "tool_presets: preset '%s' in '%s' has alias target '%s' — "
                ~ "not a known base preset (unknown id, or the target is "
                ~ "itself an alias; alias-to-alias chains are not supported)",
                aliasId, path, targetId));
        presets ~= resolveAliasPreset(*target, aliasId);
    }

    return presets;
}

// Build the resolved ToolPreset for an alias entry: a full, independent copy
// of the canonical target's `base` / `pipeAttrs` / `toolAttrs` / `flags`,
// renamed to the alias's own id. Deep-copies the nested maps (rather than
// sharing the target's AA instances) so the two presets can never be made to
// alias each other's storage even if a later change starts mutating a
// resolved ToolPreset in place.
private ToolPreset resolveAliasPreset(const ref ToolPreset target, string aliasId) {
    ToolPreset r;
    r.id    = aliasId;
    r.base  = target.base;
    r.flags = target.flags;
    r.toolAttrs = target.toolAttrs.dup;
    foreach (stageId, attrs; target.pipeAttrs)
        r.pipeAttrs[stageId] = attrs.dup;
    return r;
}

// Inject preset-level tool attrs (top-level `attrs:` block in YAML)
// onto a freshly built tool. Each value comes in as a YAML string;
// we parse it into JSON typed against the matching Param.Kind so
// injectParamsInto writes through the correct typed pointer. Throws
// when a preset names a param the tool doesn't expose — surfaces
// stale presets at startup instead of silently activating with the
// wrong defaults.
private void applyToolAttrs(Tool t, string[string] attrs, string presetId) {
    import std.conv : to;
    auto schema = t.params();
    foreach (name, valueStr; attrs) {
        const(Param)* found = null;
        foreach (ref p; schema)
            if (p.name == name) { found = &p; break; }
        if (found is null)
            throw new Exception(format(
                "tool_presets: preset '%s' sets unknown attr '%s' on '%s'",
                presetId, name, t.name));
        JSONValue jv;
        final switch (found.kind) {
            case Param.Kind.Bool:
                jv = JSONValue(valueStr == "true" || valueStr == "1");
                break;
            case Param.Kind.Int:
                jv = JSONValue(valueStr.to!long);
                break;
            case Param.Kind.Float:
                jv = JSONValue(valueStr.to!double);
                break;
            case Param.Kind.String:
            case Param.Kind.Enum:
                jv = JSONValue(valueStr);
                break;
            case Param.Kind.Vec3_:
                // "x,y,z"
                import std.string : split;
                auto p = valueStr.split(",");
                if (p.length != 3)
                    throw new Exception(format(
                        "tool_presets: preset '%s' Vec3 attr '%s' needs "
                        ~ "'x,y,z'; got '%s'", presetId, name, valueStr));
                jv = JSONValue([p[0].to!double, p[1].to!double, p[2].to!double]);
                break;
            case Param.Kind.IntEnum:
                jv = JSONValue(valueStr.to!long);
                break;
            case Param.Kind.IntArray:
            case Param.Kind.Vec3Array:
                throw new Exception(format(
                    "tool_presets: preset '%s' attr '%s' kind not "
                    ~ "supported for YAML injection", presetId, name));
        }
        JSONValue pj = JSONValue(cast(JSONValue[string]) null);
        pj[name] = jv;
        injectParamsInto(schema, pj);
        t.onParamChanged(name);
    }
}

// Apply the user's sticky tool-option defaults (persisted in prefs under this
// tool/preset id) onto a freshly built tool, AFTER the constructor defaults
// and any preset YAML attrs — so a sticky value overrides
// config/tool_presets.yaml (that is the point). Each stored value is a wire
// string re-applied through the same parseInto path the stage attr setter
// uses. Unknown attrs (a stale prefs entry naming a param the tool no longer
// exposes) are skipped silently — never throws, so a stale prefs file can't
// block tool activation. Inert when no sticky entry exists.
//
// Public + typed on `ParamProvider` (not `Tool`) so it is unit-testable
// against a tiny fake without a GL-heavy real Tool, and so it can be called
// from the universal activation chokepoints (app.d `activateToolById` /
// `toolHost.activate`) rather than only from the preset factory — this is
// what makes last-used settings restore for EVERY tool (base/direct tools
// included), not just preset-derived ones.
void applyStickyToolDefaults(ParamProvider t, string presetId) {
    auto sticky = presetId in g_prefs.toolDefaults;
    if (sticky is null) return;
    auto schema = t.params();
    foreach (name, valueStr; *sticky) {
        foreach (ref p; schema)
            if (p.name == name) {
                if (parseInto(p, valueStr)) t.onParamChanged(name);
                break;
            }
    }
}

version (unittest) {
    // Tiny ParamProvider fake — one float param — so the restore mechanism
    // is testable without a GL-heavy real Tool. Records the names
    // `onParamChanged` fired for, so the test can prove the restore path
    // (not just the pointer write) actually ran.
    private final class FakeStickyProvider : ParamProvider {
        float width = 1.0f;
        string[] changedNames;
        Param[] params() { return [Param.float_("width", "Width", &width, 1.0f)]; }
        bool paramEnabled(string name) const { return true; }
        void onParamChanged(string name) { changedNames ~= name; }
    }
}

unittest {
    // applyStickyToolDefaults — restores a persisted sticky value onto a
    // freshly built ParamProvider and fires onParamChanged for it. This is
    // the mechanism base/direct tools now use (Stage A), not just preset-
    // derived ones.
    auto saved = g_prefs;
    scope(exit) g_prefs = saved;
    g_prefs = Prefs.init;

    g_prefs.toolDefaults["fake"] = ["width": "0.25"];
    auto fake = new FakeStickyProvider();
    applyStickyToolDefaults(fake, "fake");
    assert(fake.width == 0.25f);
    assert(fake.changedNames == ["width"]);
}

unittest {
    // No sticky entry for this id -> inert (no crash, no onParamChanged).
    auto saved = g_prefs;
    scope(exit) g_prefs = saved;
    g_prefs = Prefs.init;

    auto fake = new FakeStickyProvider();
    applyStickyToolDefaults(fake, "fake");
    assert(fake.width == 1.0f);
    assert(fake.changedNames.length == 0);
}

unittest {
    // A stale prefs entry naming a param the provider no longer exposes is
    // skipped silently, never throws.
    auto saved = g_prefs;
    scope(exit) g_prefs = saved;
    g_prefs = Prefs.init;

    g_prefs.toolDefaults["fake"] = ["noSuchParam": "9"];
    auto fake = new FakeStickyProvider();
    applyStickyToolDefaults(fake, "fake");
    assert(fake.width == 1.0f);
    assert(fake.changedNames.length == 0);
}

/// Register every preset as a factory + preActivate hook in `reg`.
/// The factory just constructs the base tool (pure — no toolpipe
/// mutation); the preActivate hook applies the preset's pipe attrs
/// via `Stage.setAttr` and runs only when the preset is actually
/// selected by the user. Splitting the two means `cacheSupportedModes`
/// can enumerate every factory at startup without leaving the global
/// toolpipe configured by whichever preset's setAttr ran last.
/// Throws if a preset references an unknown base tool.
void registerToolPresets(ref Registry reg, ToolPreset[] presets) {
    foreach (ref p; presets) {
        if ((p.base in reg.toolFactories) is null)
            throw new Exception(format(
                "tool_presets: preset '%s' references unknown base '%s'",
                p.id, p.base));

        // Capture by VALUE so each closure sees its own preset (D's
        // `foreach (ref)` over array elements closes by reference,
        // every closure would otherwise share the last iteration's
        // preset). The `presetCopy` parameter trick forces a copy.
        Tool delegate() makeFactory(ToolPreset presetCopy) {
            return () {
                auto baseFactory = presetCopy.base in reg.toolFactories;
                if (baseFactory is null)
                    throw new Exception(format(
                        "tool_presets: base '%s' for preset '%s' vanished",
                        presetCopy.base, presetCopy.id));
                auto t = (*baseFactory)();
                t.presetFlags = presetCopy.flags;
                if (presetCopy.toolAttrs.length > 0)
                    applyToolAttrs(t, presetCopy.toolAttrs, presetCopy.id);
                // Sticky user defaults are applied at the activation
                // chokepoints (app.d `activateToolById` / `toolHost.activate`),
                // not here — centralizing avoids a double-apply/double-
                // onParamChanged for the two callers that DO activate
                // (cacheSupportedModes / fv.toolAttrs build-and-discard a
                // factory purely to enumerate params(), never activating).
                return t;
            };
        }
        void delegate() makePreActivate(ToolPreset presetCopy) {
            return () {
                if (g_pipeCtx is null) return;
                foreach (stageId, attrs; presetCopy.pipeAttrs) {
                    auto stage = g_pipeCtx.pipeline.findById(stageId);
                    if (stage is null) continue;
                    foreach (k, v; attrs)
                        stage.setAttr(k, v);
                }
            };
        }
        reg.toolFactories[p.id] = makeFactory(p);
        reg.preActivate[p.id]   = makePreActivate(p);
    }
}

// Guards the alias mechanism's byte-stability claim: `ElementMove` is an
// `alias:` entry pointing at `xfrm.elementMove`; the two must resolve to
// field-identical presets (same base / pipeAttrs / toolAttrs / flags) so both
// factory ids keep behaving exactly as if each still had its own hand-written
// YAML block.
unittest {
    auto presets = loadToolPresets("config/tool_presets.yaml");
    const(ToolPreset)* canonical = null;
    const(ToolPreset)* aliased   = null;
    foreach (ref p; presets) {
        if (p.id == "xfrm.elementMove") canonical = &p;
        if (p.id == "ElementMove")      aliased   = &p;
    }
    assert(canonical !is null, "xfrm.elementMove preset missing");
    assert(aliased   !is null, "ElementMove alias preset missing");
    assert(aliased.base == canonical.base);
    assert(aliased.flags == canonical.flags);
    assert(aliased.toolAttrs == canonical.toolAttrs);
    assert(aliased.pipeAttrs == canonical.pipeAttrs);
}
