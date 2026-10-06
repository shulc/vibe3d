// Module unittests for `tool_presets`, moved verbatim out of source/tool_presets.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tool_presets_test;

import std.format : format;
import std.json : JSONValue;
import registry         : Registry;
import tool             : Tool, ToolFlag;
import toolpipe.pipeline : g_pipeCtx;
import params : Param, ParamProvider, injectParamsInto, parseInto;
import prefs  : g_prefs, Prefs;
import tool_presets;

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

// Magnet's ID must remain a radial Move composition. A plain Move
// factory loses the explicit T-only xfrm.transform profile.
unittest {
    auto presets = loadToolPresets("config/tool_presets.yaml");
    const(ToolPreset)* magnet = null;
    foreach (ref p; presets)
        if (p.id == "xfrm.magnet") magnet = &p;
    assert(magnet !is null, "xfrm.magnet preset missing");
    assert(magnet.base == "xfrm.transform");
    assert(magnet.toolAttrs["T"] == "true");
    assert(magnet.toolAttrs["R"] == "false");
    assert(magnet.toolAttrs["S"] == "false");
    assert(magnet.pipeAttrs["falloff"]["type"] == "radial");
}

// Task 9525 review: `noBackgroundConstraint` is the topology pen's flag (its
// activation alone composes a background constraint). The shipped Drag Weld
// preset carries it; on any other base the loader refuses the preset.
unittest {
    import std.conv : to;
    import std.exception : collectExceptionMsg;
    import std.file : remove, write;
    import std.process : thisProcessID;
    import std.algorithm.searching : canFind;
    const(ToolPreset)* weld = null;
    auto shipped = loadToolPresets("config/tool_presets.yaml");
    foreach (ref p; shipped) if (p.id == "mesh.dragWeld") weld = &p;
    assert(weld !is null && weld.base == "mesh.topoPen"
           && (weld.flags & ToolFlag.NoBackgroundConstraint),
           "the Drag Weld preset must carry the flag on the pen");
    const path = "/var/tmp/vibe3d-9525-flag-base-" ~ to!string(thisProcessID) ~ ".yaml";
    write(path, "presets:\n  - id: wrong\n    base: move\n    flags: [noBackgroundConstraint]\n");
    scope(exit) remove(path);
    const msg = collectExceptionMsg(loadToolPresets(path));
    assert(msg !is null && msg.canFind("noBackgroundConstraint on base 'move'"),
           "the flag on a non-pen base must be refused at load: " ~ msg);
}

unittest {
    import tool : DropUndoPolicy, DropUndoExtent, DropRedoPopulation, DropUndoResidualPopulation;
    import tools.edit.topology_pen : TopologyPenTool;
    import registry : typedToolFactory;
    import mesh_gpu : GpuMesh;
    import mesh : Mesh;
    import std.file : write, remove;
    import std.conv : to;
    import std.process : thisProcessID;
    import std.exception : collectExceptionMsg;
    auto presets = loadToolPresets("config/tool_presets.yaml");
    Registry reg;
    Mesh m;
    GpuMesh gpu;
    reg.registerTool("mesh.topoPen", typedToolFactory!TopologyPenTool(() =>
        new TopologyPenTool(() => &m, &gpu)));
    ToolPreset[] selected;
    foreach (p; presets) if (p.id == "mesh.dragWeld") selected ~= p;
    assert(selected.length == 1, "one shipped weld preset");
    registerToolPresets(reg, selected); // The real loader and factory, including its override.
    const policy = DropUndoPolicy(DropUndoExtent.newestPressBlock, DropRedoPopulation.selectedSuffix);
    foreach (_; 0 .. 3) {
        auto candidate = reg.toolFactory("mesh.dragWeld")();
        assert(candidate.resolvedDropUndoPolicy() == policy, "preset factory must publish its resolved policy");
        assert(reg.toolFactory("mesh.topoPen")().resolvedDropUndoPolicy() ==
            DropUndoPolicy(DropUndoExtent.newestPressBlock, DropRedoPopulation.discard, DropUndoResidualPopulation.pressMarker),
            "preset retention must not change the base factory");
    }
    const path = "/var/tmp/vibe3d-drop-policy-" ~ to!string(thisProcessID) ~ ".yaml";
    scope(exit) remove(path);
    write(path, "presets:\n  - id: alias\n    alias: canonical\n  - id: canonical\n    base: mesh.topoPen\n    dropUndo: {extent: newestPressBlock, redo: selectedSuffix}\n");
    auto aliases = loadToolPresets(path);
    assert(aliases.length == 2 && aliases[0].hasDropUndo && aliases[1].hasDropUndo &&
        aliases[0].dropUndo == policy && aliases[1].dropUndo == policy, "alias inherits policy and presence");
    registerToolPresets(reg, aliases);
    assert(reg.toolFactory("alias")().resolvedDropUndoPolicy() == policy,
        "actual alias factory transports immutable residual policy");
    size_t configurations, accepted, rejected;
    foreach (extent; [DropUndoExtent.none, DropUndoExtent.newestPressBlock, DropUndoExtent.wholeSession])
    foreach (redo; [DropRedoPopulation.editRows, DropRedoPopulation.discard, DropRedoPopulation.selectedSuffix])
    foreach (residual; [DropUndoResidualPopulation.removeSuffix, DropUndoResidualPopulation.pressMarker]) {
        write(path, "presets:\n  - id: valid\n    base: mesh.topoPen\n    dropUndo: {extent: " ~ extent.to!string ~ ", redo: " ~ redo.to!string ~ ", residual: " ~ residual.to!string ~ "}\n");
        ++configurations;
        const valid = residual == DropUndoResidualPopulation.removeSuffix ||
            (extent == DropUndoExtent.newestPressBlock && redo == DropRedoPopulation.discard);
        if (valid) {
            auto loaded = loadToolPresets(path); ++accepted;
            assert(loaded.length == 1 && loaded[0].hasDropUndo && loaded[0].dropUndo == DropUndoPolicy(extent, redo, residual),
                "valid residual policy must round-trip");
        } else {
            ++rejected;
            assert(collectExceptionMsg(loadToolPresets(path)) !is null, "incompatible residual policy must refuse");
        }
    }
    assert(configurations == 18 && accepted == 10 && rejected == 8, "full residual policy matrix population");
    foreach (config; ["{extent: wrong}", "{redo: wrong}", "{unexpected: discard}", "{residual: wrong}"]) {
        write(path, "presets:\n  - id: bad\n    base: mesh.topoPen\n    dropUndo: " ~ config ~ "\n");
        assert(collectExceptionMsg(loadToolPresets(path)) !is null, "invalid drop policy must refuse");
    }
    write(path, "presets:\n  - id: bad\n    alias: canonical\n    dropUndo: {extent: none}\n  - id: canonical\n    base: mesh.topoPen\n");
    const aliasError = collectExceptionMsg(loadToolPresets(path));
    import std.algorithm.searching : canFind;
    assert(aliasError !is null && aliasError.canFind("has 'alias' plus"), "alias may not override policy");
}

static assert(!__traits(isVirtualMethod, Tool.setDropUndoOverride));
static assert(!__traits(isVirtualMethod, Tool.resolvedDropUndoPolicy));

unittest {
    import tool : DropUndoPolicy, DropUndoExtent, DropRedoPopulation, DropUndoResidualPopulation;
    import edit_session : EditSession;
    import command_history : CommandHistory;
    auto t = new Tool();
    const policy = DropUndoPolicy(DropUndoExtent.newestPressBlock, DropRedoPopulation.discard, DropUndoResidualPopulation.pressMarker);
    t.setDropUndoOverride(policy);
    auto session = new EditSession(() => t, new CommandHistory(), () {});
    session.noteArm("probe", 77);
    t.setDropUndoOverride(DropUndoPolicy.init);
    assert(t.resolvedDropUndoPolicy() == policy, "arming seals the copied drop policy against later replacement");
}

unittest { // Pin the real generic factory writer and the arm-time seal.
    import std.file : readText;
    import std.algorithm : count, canFind;
    import std.string : indexOf;
    const factory = readText("source/tool_presets.d");
    const session = readText("source/edit_session.d");
    enum writer = "if (presetCopy.hasDropUndo) t.setDropUndoOverride(presetCopy.dropUndo);";
    assert(factory.count(writer) == 1 && factory.indexOf(writer) < factory.indexOf("applyToolAttrs(t, presetCopy.toolAttrs"),
        "generic preset factory must configure drop policy before publishing/attribute defaults");
    assert(session.count("t.sealDropUndoPolicy();") == 1,
        "session arm must seal immutable preset data at the production reader");
}
