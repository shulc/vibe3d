// Registry construction-authority witnesses: behavior first, then the
// capability fence and its bounded bypass census (task 6510).
module tests.unit.registry_construction_authority_test;


import tests.unit.census_symbols : exists = wave15Exists;

import std.algorithm : canFind, count, sort;
import std.array : array;
import std.exception : assertThrown;
import std.file : SpanMode;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, readText = wave15ReadText;
import std.format : format;
import std.path : baseName, buildPath, buildNormalizedPath, dirName;
import std.string : indexOf, splitLines;

import vibe3d.apps.desktop.application_command_binding : CommandInvocationContext;
import vibe3d.editing.commands.runtime.command : Command, CommandOrigin;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.runtime.application_core.live_registration_roles : LiveSessionRole;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.tools.interactive.registry : CommandFactory, Registry;
import vibe3d.editing.commands.runtime.command_registry : CommandRegistry;
import vibe3d.editing.contracts.seltype : SelType;
import tests.unit.census_symbols : blankNonCode, registrationFamilyBytes,
    symbolTokenHits;
import tests.unit.live_registration_rig : LiveRegistrationRig;
import vibe3d.viewport.camera.view : View;

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
                                             "..", "..");

private SelType supportedModesObserved;

private class ProbeCommand : Command {
    private Mesh mesh_;
    private View view_;
    private string id_;

    this(string id) {
        view_ = new View(0, 0, 32, 32);
        super(&mesh_, view_, EditMode.Polygons);
        id_ = id;
    }

    override string name() const { return id_; }
    SelType observedType() { return currentType(); }

    override EditMode[] supportedModes() const {
        auto mutableThis = cast(ProbeCommand)this;
        supportedModesObserved = mutableThis.currentType();
        return super.supportedModes();
    }
}

private final class OriginalProbeCommand : ProbeCommand {
    this(string id) { super(id); }
}

private final class ReplacementProbeCommand : ProbeCommand {
    this(string id) { super(id); }
}

// A1/A5: a real application binding sees a command registered after an
// ordinary family and after authority binding; enumeration grows live too.
version (AccessCensusOnly) {} else version (AccessRuntimeOnly) {} else unittest {
    auto rig = new LiveRegistrationRig;
    rig.registerLifecycle();
    const before = rig.registry.commandIds().length;
    assert(before >= 18,
        "6510 late-registration population lost the ordinary family");
    rig.registry.bindSelTypeAuthority(rig.liveSession());
    rig.registry.registerCommand("k.late",
        () => cast(Command)new ProbeCommand("k.late"));
    assert(rig.registry.commandIds().length == before + 1
        && rig.registry.commandIds().canFind("k.late"),
        "6510 late registration is absent from live command enumeration");
    auto result = rig.binding.invokeLine("k.late", "",
        CommandInvocationContext(CommandOrigin.script, false));
    auto command = cast(ProbeCommand)result.command;
    assert(command !is null && command.observedType() == SelType.Vertex,
        "6510 late command missed the application selection authority");
}

// A2: authority stays live after binding rather than retaining a snapshot.
version (AccessCensusOnly) {} else version (AccessRuntimeOnly) {} else unittest {
    auto rig = new LiveRegistrationRig;
    rig.registry.bindSelTypeAuthority(rig.liveSession());
    rig.session.selTypeOrder.touch(SelType.Item);
    rig.registry.registerCommand("k.live",
        () => cast(Command)new ProbeCommand("k.live"));
    auto command = cast(ProbeCommand)rig.registry.makeCommand("k.live");
    assert(command.observedType() == SelType.Item,
        "6510 bound selection authority retained its pre-bind value");
    rig.session.selTypeOrder.touch(SelType.Polygon);
    assert(command.observedType() == SelType.Polygon,
        "6510 constructed command retained a selection-type snapshot");
}

// A3: the cold metadata door constructs through the same authority-aware
// path. Its fallback is deliberately different, proving the cell discriminates.
version (AccessCensusOnly) {} else version (AccessRuntimeOnly) {} else unittest {
    auto rig = new LiveRegistrationRig;
    rig.session.switchGeometryType(EditMode.Polygons);
    rig.session.selTypeOrder.touch(SelType.Item);

    Registry fallback;
    fallback.registerCommand("k.fallback",
        () => cast(Command)new ProbeCommand("k.fallback"));
    auto fallbackCommand = cast(ProbeCommand)fallback.makeCommand("k.fallback");
    assert(fallbackCommand.observedType() == SelType.Polygon,
        "6510 cold-walk floor no longer differs from the live item authority");

    supportedModesObserved = SelType.Vertex;
    rig.registry.bindSelTypeAuthority(rig.liveSession());
    rig.registry.registerCommand("k.cache",
        () => cast(Command)new ProbeCommand("k.cache"));
    rig.registry.cacheSupportedModes();
    assert(supportedModesObserved == SelType.Item,
        "6510 cacheSupportedModes bypassed authority-aware construction");
}

// A4: registration and replacement are distinct operations.
version (AccessCensusOnly) {} else version (AccessRuntimeOnly) {} else unittest {
    Registry reg;
    CommandFactory factory = () => cast(Command)new ProbeCommand("k.one");
    reg.registerCommand("k.one", factory);
    assertThrown!Exception(reg.registerCommand("k.one", factory));
    assertThrown!Exception(reg.replaceCommand("k.missing", factory));
}

// A6: an alias copies the factory value present at alias time; replacing the
// source later cannot silently retarget the alias.
version (AccessCensusOnly) {} else version (AccessRuntimeOnly) {} else unittest {
    Registry reg;
    reg.registerCommand("k.original",
        () => cast(Command)new OriginalProbeCommand("k.original"));
    reg.aliasCommand("k.original", "k.alias");
    assert(reg.hasCommand("k.original") && reg.hasCommand("k.alias"),
        "6510 alias population is incomplete");
    reg.replaceCommand("k.original",
        () => cast(Command)new ReplacementProbeCommand("k.original"));
    assert(cast(ReplacementProbeCommand)reg.makeCommand("k.original") !is null,
        "6510 alias witness replacement factory is not distinguishable");
    assert(cast(OriginalProbeCommand)reg.makeCommand("k.alias") !is null,
        "6510 alias followed a later replacement of its source");
}

// A7: the latch rejects late authority after an unbound construction, while
// the honest bind-then-build order succeeds and carries the authority.
version (AccessCensusOnly) {} else version (AccessRuntimeOnly) {} else unittest {
    auto rig = new LiveRegistrationRig;
    Registry late;
    late.registerCommand("k.early",
        () => cast(Command)new ProbeCommand("k.early"));
    assert(late.makeCommand("k.early") !is null,
        "6510 latch floor did not construct the unbound command");
    assertThrown!Exception(late.bindSelTypeAuthority(rig.liveSession()));

    Registry honest;
    honest.bindSelTypeAuthority(rig.liveSession());
    honest.registerCommand("k.honest",
        () => cast(Command)new ProbeCommand("k.honest"));
    auto command = cast(ProbeCommand)honest.makeCommand("k.honest");
    assert(command !is null && command.observedType() == SelType.Vertex,
        "6510 honest authority order did not attach the live provider");
}

// Existing unknown-id behavior remains an exception at the application
// binding and cannot create a history entry.
version (AccessCensusOnly) {} else version (AccessRuntimeOnly) {} else unittest {
    auto rig = new LiveRegistrationRig;
    const before = rig.history.undoEntries.length;
    bool threw;
    try {
        rig.binding.invokeLine("k.missing", "",
            CommandInvocationContext(CommandOrigin.script, false));
    } catch (Exception) {
        threw = true;
    }
    assert(threw && rig.history.undoEntries.length == before,
        "6510 unknown command behavior or history side effect changed");
}

// H1: the visibility checks below target an existing member.
static assert([__traits(allMembers, CommandRegistry)].canFind("commandFactories_"));
// H2: returning the same member to public is a fence failure.
static assert(__traits(getVisibility, CommandRegistry.commandFactories_) == "private");
// H3: the exact external read and write are both rejected.
static assert(!__traits(compiles, {
    CommandFactory factory;
    Registry reg;
    reg.commandFactories_["k"] = factory;
}));
static assert(!__traits(compiles, {
    Registry reg;
    auto factory = reg.commandFactories_["k"];
}));
static assert(!__traits(compiles, {
    CommandFactory factory;
    CommandRegistry reg;
    reg.commandFactories_["k"] = factory;
}));
static assert(!__traits(compiles, {
    CommandRegistry reg;
    auto factory = reg.commandFactories_["k"];
}));
static assert([__traits(allMembers, CommandRegistry)] == [
    "commandFactories_", "selTypeAuthority_", "commandsBuiltWithoutAuthority_",
    "registerCommand", "replaceCommand", "aliasCommand", "hasCommand",
    "commandIds", "makeCommand", "bindSelTypeAuthority", "commandModes",
    "commandNames", "commandParamsJson", "commandNeedsTarget",
    "commandDiscardsWork", "commandDropsToolBeforeApply",
    "commandCommitsToolEditBeforeApply", "cacheSupportedModes"
], "1C lower command registry capability surface changed");

// H5: failure above is meaningful only while the supported door compiles.
static assert(__traits(compiles, {
    CommandFactory factory;
    Registry reg;
    reg.registerCommand("k", factory);
}));

// The complete member pin catches a new writable capability even when it has
// an unrelated name. Keep this after the targeted existence/visibility fence.
unittest {
    enum replacesOwner = __traits(compiles, {
        Registry reg;
        reg.commandRegistry() = typeof(reg.commandRegistry()).init;
    });
    assert(!replacesOwner, "1D owner replacement capability fence");
    enum exportsPointer = __traits(compiles, { Registry reg; auto ptr = &reg.commandRegistry(); });
    assert(!exportsPointer, "1D owner pointer capability fence");
    assert([__traits(allMembers, Registry)] == [
    "toolFactories_", "commandRegistry_", "createCommandInvocationService", "registerCommand", "registerTool",
    "replaceCommand", "replaceTool", "aliasCommand", "hasCommand",
    "hasTool", "commandIds", "toolIds", "toolFactory", "makeCommand",
    "bindSelTypeAuthority", "preActivate", "preparedPipeAttrs",
    "commandModes", "toolModes", "commandNames", "commandParamsJson",
    "toolParamsJson", "commandNeedsTarget", "toolNeedsTarget",
    "commandDiscardsWork", "commandDropsToolBeforeApply",
    "commandCommitsToolEditBeforeApply", "cacheSupportedModes",
    "registryJson", "isModeBlocked", "actionRefusal"
], "6510 Registry capability surface changed; classify the new member");
}

private struct BypassCounts {
    size_t tuples;
    size_t members;
    size_t mixes;
}

private BypassCounts bypassCounts(string raw) {
    const code = blankNonCode(raw);
    return BypassCounts(code.count(".tupleof"),
        code.count("__traits(getMember"), raw.count("mixin" ~ "("));
}

private bool hasIdentifier(string code, string identifier) {
    bool ident(char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '_';
    }
    size_t at;
    while (at < code.length) {
        const rel = code[at .. $].indexOf(identifier);
        if (rel < 0) return false;
        const pos = at + cast(size_t)rel;
        const end = pos + identifier.length;
        if ((pos == 0 || !ident(code[pos - 1]))
                && (end == code.length || !ident(code[end]))) return true;
        at = end;
    }
    return false;
}

private bool sameRows(const size_t[string] actual,
                      const size_t[string] expected) {
    if (actual.length != expected.length) return false;
    foreach (path, count; expected) {
        auto found = path in actual;
        if (found is null || *found != count) return false;
    }
    return true;
}

// G1-G5: exact per-file ratchets in the bounded Registry-aware file set.
unittest {
    size_t[string] expectedTuple = [
        "tests/unit/create_registration_boundary_test.d": 11,
        "tests/unit/edit_registration_boundary_test.d": 16,
        "tests/unit/topology_pen_factory_bundle_test.d": 2,
        "tests/unit/ui/image_list_panel_roles_test.d": 4,
        "tests/unit/ui/layer_list_panel_roles_test.d": 7,
        "tests/unit/ui/tool_properties_panel_roles_test.d": 1,
        "tests/unit/ui/channels_panel_roles_test.d": 8,
        "tests/unit/unified_transform_recipe_test.d": 2,
        "tests/unit/headless_tool_pairing_test.d": 2,
        "tests/unit/mesh_registration_boundary_test.d": 11,
        "tests/unit/transform_registration_boundary_test.d": 15,
    ];
    size_t[string] expectedMember = [
        "source/create_tool_registration.d": 1,
        "source/edit_tool_registration.d": 1,
        "tests/unit/create_registration_boundary_test.d": 1,
        "tests/unit/edit_registration_boundary_test.d": 3,
        "tests/unit/topology_pen_factory_bundle_test.d": 2,
        "tests/unit/ui/image_list_panel_roles_test.d": 3,
        "tests/unit/ui/layer_list_panel_roles_test.d": 5,
        "tests/unit/ui/tool_properties_panel_roles_test.d": 11,
        "tests/unit/ui/channels_panel_roles_test.d": 2,
        "tests/unit/headless_tool_pairing_test.d": 1,
        "tests/unit/live_registration_rig.d": 1,
        "tests/unit/production_tool_policies.d": 1,
    ];
    size_t[string] foundTuple;
    size_t[string] foundMember;
    size_t scopeFiles;
    size_t codeBytes;
    size_t registryTuple;
    size_t mixes;
    size_t privateNames;
    const string[] censusRoots = ["source", "packages/command-runtime/source", "packages/application-core/source", "packages/document-model/source", "packages/param-schema/source", "packages/pipe-runtime/source", "packages/mesh-ops/source", "packages/interchange/source", "packages/interaction-query/source", "packages/pipe-evaluation/source", "packages/tool-state/source", "packages/transform-ops/source", "packages/creation-ops/source", "packages/alignment-ops/source", "packages/input-events/source", "packages/display-policy/source", "packages/viewport-gpu/source", "packages/subpatch-preview/source", "packages/edit-contracts/source", "packages/mesh-change/source", "packages/mesh-contracts/source", "packages/mesh-edit-log/source", "packages/mesh-edit-replay/source", "packages/mesh-snapshot/source", "packages/mesh-topology/source", "packages/mesh/source", "packages/profiling/source", "packages/spatial/source", "util/log/source", "util/math/source", "util/parallel/source", "util/plane-bytes/source", "util/screen-buckets/source", "packages/pipe-contracts/source", "packages/mesh-preview/source", "util/json-number/source", "tests", "packages/mesh-ops/tests/source", "packages/interchange/tests/source", "packages/interaction-query/tests/source", "packages/pipe-evaluation/tests/source", "packages/document-model/tests/source", "packages/param-schema/tests/source", "packages/pipe-runtime/tests/source", "packages/tool-state/tests/source", "packages/transform-ops/tests/source", "packages/creation-ops/tests/source", "packages/alignment-ops/tests/source", "packages/input-events/tests/source", "packages/display-policy/tests/source", "packages/viewport-gpu/tests/source", "packages/subpatch-preview/tests/source", "packages/camera-model/source", "packages/document-channels/source", "packages/image-codec/source", "packages/document-io/source", "packages/selection-model/source", "packages/scene-query/source", "packages/editor-commands/source"];
    const string[] historicalCarriers = [
        "packages/camera-model/tests/source/tests/unit/view_test.d",
        "packages/document-channels/tests/source/tests/unit/layer_params_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_test.d",
        "packages/document-io/tests/source/tests/unit/io/image_path_test.d",
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/base_revert_flag_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_apply_anchor_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_bindargs_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_registry_test.d",
        "packages/command-runtime/tests/source/tests/unit/session_edit_payload_test.d",
        "packages/application-core/tests/source/tests/unit/command_invocation_test.d",
        "packages/application-core/tests/source/tests/unit/standalone_application_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
        "packages/scene-query/tests/source/tests/unit/bvh_pick_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_projection_algorithm_cells_test.d",
];
    string[] inputPaths;
    foreach (root; censusRoots) {
        foreach (de; dirEntries(buildPath(repoRoot, root), "*.d", SpanMode.depth)) {
            inputPaths ~= de.name;
        }
    }
    foreach (relative; historicalCarriers) {
        inputPaths ~= buildPath(repoRoot, relative);
    }
    foreach (relative; [
        "packages/camera-model/source",
        "packages/document-channels/source",
        "packages/image-codec/source",
        "packages/document-io/source",
        "packages/command-runtime/source",
        "packages/application-core/source",
    ]) {
        size_t occurrences;
        foreach (candidate; censusRoots) if (candidate == relative) ++occurrences;
        assert(occurrences == 1, "registry census production root membership: " ~ relative);
    }
    foreach (relative; [
        "packages/camera-model/source/view.d",
        "packages/document-channels/source/layer_params.d",
        "packages/image-codec/source/io/image_decode.d",
        "packages/document-io/source/io/native.d",
        "packages/document-io/source/io/image_path.d",
        "packages/document-io/source/io/file_model.d",
        "packages/camera-model/tests/source/tests/unit/view_test.d",
        "packages/document-channels/tests/source/tests/unit/layer_params_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_test.d",
        "packages/document-io/tests/source/tests/unit/io/image_path_test.d",
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/application-core/source/app_version.d",
        "packages/command-runtime/source/command.d",
        "packages/command-runtime/source/command_args.d",
        "packages/command-runtime/source/command_executor.d",
        "packages/command-runtime/source/command_history.d",
        "packages/command-runtime/source/command_invocation.d",
        "packages/command-runtime/source/command_registry.d",
        "packages/command-runtime/source/command_tool_policy.d",
        "packages/command-runtime/source/commands/history/redo.d",
        "packages/command-runtime/source/commands/history/undo.d",
        "packages/command-runtime/source/commands/mesh/gesture_payload.d",
        "packages/command-runtime/source/commands/mesh/mesh_edit_payload.d",
        "packages/command-runtime/source/commands/mesh/select.d",
        "packages/command-runtime/source/commands/mesh/selection_undo.d",
        "packages/command-runtime/source/commands/mesh/session_edit.d",
        "packages/command-runtime/source/commands/mesh/triple.d",
        "packages/command-runtime/source/commands/mesh/vertex_edit.d",
        "packages/command-runtime/source/commands/select/drop.d",
        "packages/command-runtime/source/commands/select/element.d",
        "packages/command-runtime/source/commands/select/invert.d",
        "packages/command-runtime/source/history_lifecycle_contract.d",
        "packages/application-core/source/http_json.d",
        "packages/application-core/source/morph_target.d",
        "packages/application-core/source/pilot_command_registration.d",
        "packages/command-runtime/source/record_observer_hub.d",
        "packages/application-core/source/session_owner.d",
        "packages/application-core/source/standalone_application.d",
        "packages/command-runtime/source/tool_activation_ownership.d",
        "packages/application-core/source/live_registration_roles.d",
        "packages/command-runtime/tests/source/tests/unit/base_revert_flag_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_apply_anchor_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_bindargs_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_registry_test.d",
        "packages/command-runtime/tests/source/tests/unit/session_edit_payload_test.d",
        "packages/application-core/tests/source/tests/unit/command_invocation_test.d",
        "packages/application-core/tests/source/tests/unit/standalone_application_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
        "packages/scene-query/tests/source/tests/unit/bvh_pick_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_projection_algorithm_cells_test.d",
]) {
        size_t occurrences;
        foreach (candidate; inputPaths)
            if (candidate == buildPath(repoRoot, relative)) ++occurrences;
        assert(occurrences == 1, "registry census historical input membership: " ~ relative);
    }
    foreach (inputPath; inputPaths) {
            const relative = buildNormalizedPath(inputPath[repoRoot.length + 1 .. $]);
            const raw = readText(inputPath);
            const code = blankNonCode(raw);
            codeBytes += code.length;
            registryTuple += code.count("Registry.tupleof");
            if (relative != "source/registry.d"
                    && relative != "packages/command-runtime/source/command_registry.d"
                    && relative != "tests/unit/registry_construction_authority_test.d")
                if (hasIdentifier(code, "commandFactories_")
                        || hasIdentifier(code, "toolFactories_")) ++privateNames;
            if (!hasIdentifier(raw, "Registry")
                    && !hasIdentifier(raw, "CommandRegistry")) continue;
            ++scopeFiles;
            const counts = bypassCounts(raw);
            if (counts.tuples) foundTuple[relative] = counts.tuples;
            if (counts.members) foundMember[relative] = counts.members;
            mixes += counts.mixes;

    }
    assert(scopeFiles >= 50 && codeBytes > 1_000_000,
        "6510 bypass-census scope collapsed");
    assert(sameRows(foundTuple, expectedTuple),
        format("6510 Registry-value tupleof per-file ratchet changed: %s",
               foundTuple));
    assert(sameRows(foundMember, expectedMember),
        format("6510 Registry-value getMember per-file ratchet changed: %s",
               foundMember));
    assert(registryTuple == 0,
        "6510 Registry type exposes tupleof access in production or tests");
    assert(mixes == 0,
        "6510 Registry-aware file gained a string mixin bypass");
    assert(privateNames == 0,
        "6510 private factory-map name escaped its owner and fence module");

    assert(bypassCounts("Registry r; auto x = r.tupleof[0];").tuples == 1
        && bypassCounts("Registry r; auto x = r.tupleof[0]; r.tupleof[1] = x;").tuples == 2,
        "6510 tupleof ratchet positive controls do not discriminate existing/new rows");
    assert(bypassCounts("Registry r; auto x = __traits(getMember, r, `x`);").members == 1
        && bypassCounts("Registry r; auto x = __traits(getMember, r, `x`); auto y = __traits(getMember, r, `y`);").members == 2,
        "6510 getMember ratchet positive controls do not discriminate existing/new rows");
    assert(bypassCounts("Registry r; " ~ "mixin" ~ "(`r.tupleof[0];`);").mixes == 1,
        "6510 string-mixin bypass control is blind");
    assert("Registry.tupleof".count("Registry.tupleof") == 1,
        "6510 Registry.tupleof control is blind");
    assert(hasIdentifier("commandFactories_", "commandFactories_")
        && hasIdentifier("toolFactories_", "toolFactories_"),
        "6510 private-name controls are blind");
}

// G2: nothing in the executed composition-root prefix constructs or enumerates
// commands, and the sole bind remains inside registerCommands.
unittest {
    const app = blankNonCode(readText(buildPath(repoRoot, "source", "app.d")));
    const registration = blankNonCode(readText(
        buildPath(repoRoot, "source", "registration.d")));
    const marker = "registerCommands(app);";
    assert(app.count(marker) == 1 && app.indexOf(marker) > 10_000,
        "6510 composition-root marker floor changed");
    const prefix = app[0 .. cast(size_t)app.indexOf(marker)];
    assert(prefix.count("makeCommand(") == 0
        && prefix.count("commandIds(") == 0,
        "6510 command construction or enumeration moved before authority binding");
    assert((prefix ~ "reg.makeCommand(\"x\");").count("makeCommand(") == 1,
        "6510 composition-window positive control is blind");
    auto bindHits = symbolTokenHits(registration, "source/registration.d",
                                    "bindSelTypeAuthority(");
    size_t registrarFiles;
    const familyBytes = registrationFamilyBytes(repoRoot, registrarFiles);
    assert(registrarFiles >= 15 && familyBytes > 110_000 && bindHits.length == 1
        && bindHits[0].key == "registerCommands",
        "6510 selection authority bind left registerCommands");
}

// G3: registrar discovery is glob-owned, and every discovered production
// family has one composition-root call. A1 supplies the behavioral late-door
// half using a real family and binding.
unittest {
    string[] registrarNames;
    foreach (scanSourceRoot; [buildPath(repoRoot, "source"), buildPath(repoRoot, "packages/application-core/source")])
    foreach (de; dirEntries(scanSourceRoot,
                            "*_registration.d", SpanMode.shallow))
        registrarNames ~= baseName(de.name);
    registrarNames.sort;
    assert(registrarNames.length >= 15,
        "6510 production registrar glob population collapsed");
    const registration = blankNonCode(readText(
        buildPath(repoRoot, "source", "registration.d")));
    size_t calls;
    foreach (line; registration.splitLines())
        if (line.indexOf("register") >= 0
                && line.indexOf("Commands(app.reg()") >= 0) ++calls;
    assert(calls >= 15,
        "6510 production registrar call population collapsed");
}

// The lower behavior probe is complemented by actual desktop attachment wiring.
version (AccessRuntimeOnly) {} else unittest {
    const lower = blankNonCode(readText(buildPath(repoRoot, "packages", "command-runtime", "source", "command_registry.d")));
    const desktop = blankNonCode(readText(buildPath(repoRoot, "source", "registry.d")));
    const factory = symbolTokenHits(desktop, "source/registry.d",
        "new CommandInvocationService(commandRegistry_, executor, history,");
    assert(factory.length == 1 && factory[0].key == "Registry.createCommandInvocationService",
        "1D owner factory must borrow the embedded lower owner");
    assert(desktop.count("ref CommandRegistry") == 0 && desktop.count("CommandRegistry*") == 0,
        "1D owner must not export a named ref or pointer");
    const attached = symbolTokenHits(lower, "packages/command-runtime/source/command_registry.d",
        "command.setSelTypeProvider(selTypeAuthority_)");
    assert(attached.length == 1 && attached[0].key == "CommandRegistry.makeCommand",
        "1C lower makeCommand must attach the live selection provider");
    const forwarded = symbolTokenHits(desktop, "source/registry.d",
        "return commandRegistry_.makeCommand(id)");
    assert(forwarded.length == 1 && forwarded[0].key == "Registry.makeCommand",
        "1C desktop makeCommand must forward to the embedded lower owner");
    const bound = symbolTokenHits(desktop, "source/registry.d",
        "commandRegistry_.bindSelTypeAuthority(() => owner.subjectType())");
    assert(bound.length == 1 && bound[0].key == "Registry.bindSelTypeAuthority",
        "1C desktop authority must bind a live owner delegate into lower storage");
    const cached = symbolTokenHits(desktop, "source/registry.d",
        "commandRegistry_.cacheSupportedModes()");
    assert(cached.length == 1 && cached[0].key == "Registry.cacheSupportedModes",
        "1C desktop metadata must walk its embedded command owner once");

}


unittest { // Construct before first registration: empty AA storage cannot mask a copy.
    import vibe3d.editing.commands.runtime.command_executor : CommandExecutor;
    import vibe3d.editing.commands.runtime.command_history : CommandHistory;
    import vibe3d.editing.commands.runtime.command_invocation : CommandInvocationOutcome, CommandInvocationResult;
    auto rig = new LiveRegistrationRig;
    Registry owner;
    assert(owner.commandIds().length == 0, "1D factory requires fresh empty owner");
    owner.bindSelTypeAuthority(rig.liveSession());
    auto history = new CommandHistory;
    auto executor = new CommandExecutor(history, () => false, (transition) {});
    auto service = owner.createCommandInvocationService(executor, history,
        (Command command, string id) => true);
    owner.registerCommand("k.factory", () => cast(Command)new OriginalProbeCommand("k.factory"));
    CommandInvocationResult first;
    bool registered;
    try {
        first = service.invokeLine("k.factory", "",
            CommandInvocationContext(CommandOrigin.script, false));
        registered = true;
    } catch (Exception) {}
    assert(registered, "1D owner factory must see registration after construction");
    auto original = cast(OriginalProbeCommand)first.command;
    assert(first.outcome == CommandInvocationOutcome.applied && original !is null,
        "1D owner factory must see registration after construction");
    Registry fallback;
    fallback.registerCommand("k.fallback", () => cast(Command)new ProbeCommand("k.fallback"));
    auto cold = cast(ProbeCommand)fallback.makeCommand("k.fallback");
    assert(cold.observedType() == SelType.Polygon && original.observedType() == SelType.Vertex,
        "1D factory live authority must differ from mode fallback");
    rig.session.selTypeOrder.touch(SelType.Item);
    assert(original.observedType() == SelType.Item && cold.observedType() == SelType.Polygon,
        "1D factory constructed command must read changed live authority");
    owner.replaceCommand("k.factory", () => cast(Command)new ReplacementProbeCommand("k.factory"));
    auto replaced = service.invokeLine("k.factory", "",
        CommandInvocationContext(CommandOrigin.script, false));
    auto replacement = cast(ReplacementProbeCommand)replaced.command;
    assert(replacement !is null && replacement.observedType() == SelType.Item,
        "1D owner factory must see replacement and live authority");
    rig.session.selTypeOrder.touch(SelType.Polygon);
    assert(original.observedType() == SelType.Polygon && replacement.observedType() == SelType.Polygon,
        "1D factory both existing commands must retain live authority");
}


unittest { // The desktop receiver instantiates the same operation-only helpers.
    import vibe3d.editing.commands.runtime.command : g_editTargetResolver;
    import vibe3d.editing.commands.runtime.command_executor : CommandExecutor;
    import vibe3d.editing.commands.runtime.command_history : CommandHistory;
    import vibe3d.editing.commands.runtime.command_invocation;
    import vibe3d.mesh.change.change_bus : changeBus, ChangeBus;
    import vibe3d.mesh.core.mesh : makeCube, g_isDocumentMesh;
    import vibe3d.runtime.application_core.pilot_command_registration;
    import vibe3d.util.math.math : Vec3;
import vibe3d.util.spatial.spatial : Viewport;

    const savedResolver = g_editTargetResolver; auto savedBus = changeBus;
    const savedFilter = g_isDocumentMesh;
    scope(exit) { g_editTargetResolver = savedResolver; changeBus = savedBus; g_isDocumentMesh = savedFilter; }
    g_editTargetResolver = null; changeBus = ChangeBus.init; g_isDocumentMesh = null;
    auto a = makeCube(), b = makeCube(); Mesh* active = &a;
    auto firstView = new View(0,0,1,1), secondView = new View(0,0,2,2);
    View currentView = firstView;
    EditMode mode = EditMode.Vertices;
    auto live = new LiveRegistrationRig;
    size_t promotions, topologyCalls;
    Viewport viewport; viewport.focus = Vec3(31,0,0);
    ref Mesh liveMesh() { return *active; }
    ref View liveView() { return currentView; }
    auto deps = PilotCommandDeps(cast(PilotMesh)&liveMesh, cast(PilotView)&liveView, &mode, () => viewport,
        (EditMode next) { ++promotions; mode = next; live.session.selTypeOrder.touch(SelType.Polygon); },
        () { ++topologyCalls; });
    auto h = new CommandHistory; h.clear(); Registry registry;
    registry.bindSelTypeAuthority(live.liveSession());
    registerTripleCommand(registry, deps);
    registerMeshSelectionCommand(registry, deps);
    registerHistoryNavigationCommands(registry, deps, h);
    assert(registry.commandIds().length == 4, "pilot registrar exact four-ID population");
    foreach (id; registry.commandIds()) {
        auto c = registry.makeCommand(id);
        assert(c.meshPtr() is &a && c.viewRef is firstView && c.editModeVal == EditMode.Vertices,
            "pilot registrar must resolve initial live data");
    }
    active = &b; currentView = secondView; mode = EditMode.Edges;
    foreach (id; registry.commandIds()) {
        auto c = registry.makeCommand(id);
        assert(c.meshPtr() is &b && c.viewRef is secondView && c.editModeVal == EditMode.Edges,
            "pilot registrar must resolve changed live data");
    }
    auto service = registry.createCommandInvocationService(new CommandExecutor(h, () => false, (transition) {}), h);
    auto context = CommandInvocationContext(CommandOrigin.script, false);
    assert(service.invokeLine("mesh.select", `{"mode":"polygons","indices":[0]}`, context).applied,
        "pilot selection must apply");
    assert(promotions == 1 && mode == EditMode.Polygons && live.liveSession().subjectType() == SelType.Polygon
        && b.selectedFaces[0], "pilot selection must promote geometry type and select");
    assert(service.invokeLine("mesh.triple", "", context).applied
        && b.faces.length == 7 && a.faces.length == 6 && topologyCalls == 1,
        "pilot triple must use live target and topology capability");
    assert(service.invokeLine("history.undo", "", context).applied && b.faces.length == 6,
        "pilot undo must navigate same history");
    assert(service.invokeLine("history.redo", "", context).applied && b.faces.length == 7,
        "pilot redo must navigate same history");

}

private final class FactoryHookProbe : ProbeCommand {
    this(bool query) { super("k.hooks"); if (query) markQuery(); }
    override bool acceptsQuery() const { return true; }
    protected override bool applyImpl() { return false; }
}

unittest {
    import vibe3d.editing.commands.runtime.command_executor : CommandExecutor;
    import vibe3d.editing.commands.runtime.command_history : CommandHistory, RecordMode;
    import vibe3d.editing.commands.runtime.command_invocation : CommandInvocationOutcome;
    Registry owner;
    auto history = new CommandHistory;
    auto executor = new CommandExecutor(history, () => false, (transition) {});
    size_t refires, uiCalls, configurations, notices;
    bool query;
    owner.registerCommand("k.hooks", () => cast(Command)new FactoryHookProbe(query));
    auto service = owner.createCommandInvocationService(executor, history,
        (Command c, string id) { ++refires; return false; },
        (Command c, RecordMode mode, string id) { ++uiCalls; return CommandInvocationOutcome.deferred; },
        (Command c, bool interactive) { ++configurations; },
        (Command c) { ++notices; });
    auto deferred = service.invokeLine("k.hooks", "", CommandInvocationContext(CommandOrigin.ui, true));
    assert(deferred.outcome == CommandInvocationOutcome.deferred && refires == 1
        && uiCalls == 1 && configurations == 1 && notices == 0,
        "1D owner factory must forward refire UI and interactive hooks");
    query = true;
    auto refused = service.invokeLine("k.hooks", "", CommandInvocationContext(CommandOrigin.ui, false));
    assert(refused.outcome == CommandInvocationOutcome.refused && notices == 1,
        "1D owner factory must forward query refusal notice");
}
