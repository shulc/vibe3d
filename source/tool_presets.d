module tool_presets;

import std.format : format;
import std.json : JSONValue;

import registry         : Registry;
import tool             : Tool, ToolFlag;
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stage   : parseInto;
import params : Param, injectParamsInto;
import prefs  : g_prefs;

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
    foreach (Node node; root["presets"]) {
        if (!node.containsKey("id"))
            throw new Exception(format("tool_presets: entry in '%s' missing 'id'", path));
        if (!node.containsKey("base"))
            throw new Exception(format("tool_presets: preset '%s' in '%s' missing 'base'",
                                       node["id"].as!string, path));
        ToolPreset p;
        p.id   = node["id"].as!string;
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
    return presets;
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
// preset id) onto a freshly built tool, AFTER the preset's YAML attrs — so a
// sticky value overrides config/tool_presets.yaml (that is the point). Each
// stored value is a wire string re-applied through the same parseInto path the
// stage attr setter uses. Unknown attrs (a stale prefs entry naming a param the
// tool no longer exposes) are skipped silently — never throws, so a stale
// prefs file can't block tool activation. Inert when no sticky entry exists.
private void applyStickyToolDefaults(Tool t, string presetId) {
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
                // Sticky user defaults override the YAML attrs above.
                applyStickyToolDefaults(t, presetCopy.id);
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
