/// The per-preset tool attribute cache (tool session model, slice M5; gap rows
/// 284 and 307; evidence toolcards/tool_session_model/ M0b, cells C-H6-*,
/// C-M5-save, S-cache).
///
/// CONTRACT. One store, keyed preset -> node -> attribute -> wire value. A
/// NODE is anything that carries Params in a preset's pipe: the tool itself
/// (`kToolNode`) and every pipe stage the preset CLAIMED at its arm. At the
/// tool's drop every node's capturable Params are written here (one capture,
/// `captureDroppedNodes`, reached by both drop doors); at the next arm of the
/// same preset they are read back after the preset's own attributes and
/// before any activation auto-fit (`recallNodeAttrs`). No attribute is
/// special: there is no "the user typed it" bit and no per-attribute keep at a
/// reset site — the refuted rival R6a.
///
/// Lifetime: editor session state. A user-visible scene reset keeps it; only
/// the test-automation tail of a script `scene.reset` clears it
/// (`CommandHttpAdapter.resetAutomationAfter`). Persistence is a section of the
/// prefs document (`prefs.d`), so it reaches disk only where prefs do.
module toolpipe.attr_cache;

import params : Param, ParamProvider, isStickyCapturable, parseInto,
    stringifyParam;
import toolpipe.stage : PresetClaimable, Stage;

/// One node's attributes: attribute name -> wire value.
alias NodeAttrs = string[string];

/// The node name of the tool itself inside a preset's entry. Stage nodes are
/// keyed by their `Stage.id()`.
enum string kToolNode = "tool";

struct PipelineAttrCache {
private:
    NodeAttrs[string][string] entries_;

public:
    /// Replace one node's attributes for `preset`. An empty attribute set
    /// stores nothing (a node without capturable Params has no entry).
    void store(string preset, string node, NodeAttrs attrs) nothrow {
        if (preset.length == 0 || node.length == 0 || attrs.length == 0) return;
        entries_[preset][node] = attrs;
    }

    /// The stored attributes of one node, or null.
    const(NodeAttrs)* lookup(string preset, string node) const nothrow {
        if (auto nodes = preset in entries_)
            return node in *nodes;
        return null;
    }

    /// Every node stored for `preset` (owned copy; empty when none).
    NodeAttrs[string] presetNodes(string preset) const {
        NodeAttrs[string] result;
        if (auto nodes = preset in entries_)
            foreach (node, attrs; *nodes) result[node] = attrs.dup;
        return result;
    }

    void removePreset(string preset) nothrow { entries_.remove(preset); }
    void clear() nothrow { entries_ = null; }
    bool empty() const nothrow @nogc { return entries_.length == 0; }
    size_t presetCount() const nothrow @nogc { return entries_.length; }

    /// Read-only walk for serialisation: preset -> node -> attrs.
    int opApply(scope int delegate(string, string, const NodeAttrs) dg) const {
        foreach (preset, nodes; entries_)
            foreach (node, attrs; nodes)
                if (auto r = dg(preset, node, attrs)) return r;
        return 0;
    }
}

/// Every capturable Param of one node, as wire values. The capture rule is the
/// ONE `isStickyCapturable` for every node kind: array kinds do not round-trip
/// through a wire string, read-only Params are derived display, transient ones
/// are gesture geometry or momentary triggers.
NodeAttrs captureNodeAttrs(ParamProvider node) {
    NodeAttrs attrs;
    if (node is null) return attrs;
    foreach (ref p; node.params()) {
        if (!isStickyCapturable(p)) continue;
        attrs[p.name.idup] = stringifyParam(p).idup;
    }
    return attrs;
}

/// Write `attrs` back into `node` through its Params. A value equal to the one
/// already there is skipped, and a name the node no longer exposes, or a value
/// that does not parse, is ignored — a stale entry never blocks an arm. With
/// `notify` the node's `onParamChanged` runs for every changed name; without
/// it the caller owns that (the prepared tool arm routes it through a door).
/// Returns the changed names, owned.
string[] recallNodeAttrs(ParamProvider node, in NodeAttrs attrs, bool notify) {
    string[] changed;
    if (node is null || attrs.length == 0) return changed;
    auto schema = node.params();
    foreach (name, value; attrs) {
        foreach (ref p; schema) {
            if (p.name != name) continue;
            if (!isStickyCapturable(p)) break;
            if (stringifyParam(p) == value) break;
            // A String/Enum Param stores the supplied slice: own it first.
            if (parseInto(p, value.idup)) changed ~= name.idup;
            break;
        }
    }
    if (notify)
        foreach (name; changed) node.onParamChanged(name);
    return changed;
}

/// The nodes one drop leaves behind, captured while the tool and the stages
/// still hold their values and committed to the cache by a separate nothrow
/// step, so the prepared tool arm can capture during its fallible half and
/// commit during its publication. Both drop doors — `dropActiveTool` and the
/// prepared switch — build this with the ONE `captureDroppedNodes`.
struct DroppedNodes {
    string preset;
    NodeAttrs[string] nodes;

    void commitTo(ref PipelineAttrCache cache) nothrow {
        foreach (node, attrs; nodes) cache.store(preset, node, attrs);
    }
}

/// Capture the dropped preset's nodes: the tool, and every stage the preset
/// still CLAIMS (`PresetClaimable.presetClaimed` — a stage the user took over
/// is theirs, not the preset's, and is not written under the preset). A drop
/// with no preset id captures nothing.
DroppedNodes captureDroppedNodes(string preset, ParamProvider tool,
                                 Stage[] stages) {
    DroppedNodes dropped;
    if (preset.length == 0) return dropped;
    dropped.preset = preset.idup;
    auto toolAttrs = captureNodeAttrs(tool);
    if (toolAttrs.length) dropped.nodes[kToolNode] = toolAttrs;
    foreach (stage; stages) {
        auto claimable = cast(PresetClaimable) stage;
        if (claimable is null || !claimable.presetClaimed()) continue;
        auto attrs = captureNodeAttrs(stage);
        if (attrs.length) dropped.nodes[stage.id().idup] = attrs;
    }
    return dropped;
}
