module tool_presets;

import std.format : format;

import registry         : Registry;
import tool             : Tool;
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
        presets ~= p;
    }
    return presets;
}

/// Register every preset as a factory in `reg.toolFactories`. The
/// closure each preset produces calls the named base factory then
/// applies the preset's pipe attrs via `Stage.setAttr`. Throws if a
/// preset references an unknown base tool.
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
                if (g_pipeCtx !is null) {
                    foreach (stageId, attrs; presetCopy.pipeAttrs) {
                        auto stage = g_pipeCtx.pipeline.findById(stageId);
                        if (stage is null) continue;
                        foreach (k, v; attrs)
                            stage.setAttr(k, v);
                    }
                }
                return t;
            };
        }
        reg.toolFactories[p.id] = makeFactory(p);
    }
}
