// Registry construction-authority witnesses: behavior first, then the
// capability fence and its bounded bypass census (task 6510).
module tests.unit.registry_construction_authority_test;

import std.algorithm : canFind, count, sort;
import std.array : array;
import std.exception : assertThrown;
import std.file : SpanMode, dirEntries, readText;
import std.format : format;
import std.path : baseName, buildPath, buildNormalizedPath, dirName;
import std.string : indexOf, splitLines;

import application_command_binding : CommandInvocationContext;
import command : Command, CommandOrigin;
import editmode : EditMode;
import live_registration_roles : LiveSessionRole;
import mesh : Mesh;
import registry : CommandFactory, Registry;
import seltype : SelType;
import tests.unit.census_symbols : blankNonCode, registrationFamilyBytes,
    symbolTokenHits;
import tests.unit.live_registration_rig : LiveRegistrationRig;
import view : View;

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
unittest {
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
unittest {
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
unittest {
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
unittest {
    Registry reg;
    CommandFactory factory = () => cast(Command)new ProbeCommand("k.one");
    reg.registerCommand("k.one", factory);
    assertThrown!Exception(reg.registerCommand("k.one", factory));
    assertThrown!Exception(reg.replaceCommand("k.missing", factory));
}

// A6: an alias copies the factory value present at alias time; replacing the
// source later cannot silently retarget the alias.
unittest {
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
unittest {
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
unittest {
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
static assert([__traits(allMembers, Registry)].canFind("commandFactories_"));
// H2: returning the same member to public is a fence failure.
static assert(__traits(getVisibility, Registry.commandFactories_) == "private");
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
// H5: failure above is meaningful only while the supported door compiles.
static assert(__traits(compiles, {
    CommandFactory factory;
    Registry reg;
    reg.registerCommand("k", factory);
}));

// The complete member pin catches a new writable capability even when it has
// an unrelated name. Keep this after the targeted existence/visibility fence.
static assert([__traits(allMembers, Registry)] == [
    "toolFactories_", "commandFactories_", "selTypeAuthority_",
    "commandsBuiltWithoutAuthority_", "registerCommand", "registerTool",
    "replaceCommand", "replaceTool", "aliasCommand", "hasCommand",
    "hasTool", "commandIds", "toolIds", "toolFactory", "makeCommand",
    "bindSelTypeAuthority", "preActivate", "preparedPipeAttrs",
    "commandModes", "toolModes", "commandNames", "commandParamsJson",
    "toolParamsJson", "commandNeedsTarget", "toolNeedsTarget",
    "commandDiscardsWork", "commandDropsToolBeforeApply",
    "commandCommitsToolEditBeforeApply", "cacheSupportedModes",
    "registryJson", "isModeBlocked", "actionRefusal"
], "6510 Registry capability surface changed; classify the new member");

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
        "tests/unit/create_registration_boundary_test.d": 1,
        "tests/unit/topology_pen_factory_bundle_test.d": 2,
        "tests/unit/ui/image_list_panel_roles_test.d": 3,
        "tests/unit/ui/layer_list_panel_roles_test.d": 5,
        "tests/unit/ui/tool_properties_panel_roles_test.d": 11,
        "tests/unit/ui/channels_panel_roles_test.d": 2,
        "tests/unit/headless_tool_pairing_test.d": 1,
        "tests/unit/live_registration_rig.d": 1,
    ];
    size_t[string] foundTuple;
    size_t[string] foundMember;
    size_t scopeFiles;
    size_t codeBytes;
    size_t registryTuple;
    size_t mixes;
    size_t privateNames;
    foreach (root; ["source", "tests"]) {
        foreach (de; dirEntries(buildPath(repoRoot, root), "*.d", SpanMode.depth)) {
            const relative = buildNormalizedPath(de.name[repoRoot.length + 1 .. $]);
            const raw = readText(de.name);
            const code = blankNonCode(raw);
            codeBytes += code.length;
            registryTuple += code.count("Registry.tupleof");
            if (relative != "source/registry.d"
                    && relative != "tests/unit/registry_construction_authority_test.d")
                if (hasIdentifier(code, "commandFactories_")
                        || hasIdentifier(code, "toolFactories_")) ++privateNames;
            if (!hasIdentifier(raw, "Registry")) continue;
            ++scopeFiles;
            const counts = bypassCounts(raw);
            if (counts.tuples) foundTuple[relative] = counts.tuples;
            if (counts.members) foundMember[relative] = counts.members;
            mixes += counts.mixes;
        }
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
    foreach (de; dirEntries(buildPath(repoRoot, "source"),
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
