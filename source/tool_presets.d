module tool_presets;

import std.format : format;

import registry         : Registry;
import tool             : Tool, ToolFlag;
import toolpipe.pipeline : g_pipeCtx;

// ---------------------------------------------------------------------------
// Tool presets — declarative `<base tool> + <per-pipe-stage attrs>` bundles.
// MODO's `<hash type="ToolPreset" key="...">` blocks in `resrc/presets.cfg`
// (e.g. `xfrm.shear` = falloff.linear + xfrm.transform with attrs); vibe3d's
// equivalent lives in `config/tool_presets.yaml`.
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
    uint                      flags;         // OR of ToolFlag bits
}

// Map YAML flag name → ToolFlag bit. Names match the enum members
// case-insensitively so `flags: [brushReset]` and `flags: [BrushReset]`
// both parse. Mirrors MODO's `LXf_TOOL_*` / `LXfTMOD_*` semantics; see
// the ToolFlag enum doc in `source/tool.d`.
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
