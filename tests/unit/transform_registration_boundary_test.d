module tests.unit.transform_registration_boundary_test;

import core.exception : AssertError;
import command_history : CommandHistory;
import commands.layer.xform_edit : LayerXformEdit;
import commands.mesh.morph_edit : MeshMorphEdit;
import commands.mesh.vertex_edit : MeshVertexEdit;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import mesh_gpu : GpuMesh;
import pipe_gizmo_host : PipeGizmoHost;
import registry : Registry;
import transform_tool_registration : TransformToolDeps,
    registerTransformToolCommands;
static import transform_tool_registration;

import std.array : join;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : baseName, buildPath, dirName, relativePath;
import std.exception : assertThrown;
import std.string : indexOf, replace, split, startsWith, strip;
import tests.unit.census_symbols : blankNonCode, countOccurrences,
    ImportDecl, importDeclarations, statementsContaining;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private bool identifierChar(char ch) {
    return ch == '_' || (ch >= '0' && ch <= '9')
        || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z');
}

private size_t identifierCount(string code, string identifier) {
    size_t total;
    size_t from;
    while (from < code.length) {
        const hit = code.indexOf(identifier, from);
        if (hit < 0) break;
        const pos = cast(size_t) hit;
        const left = pos == 0 || !identifierChar(code[pos - 1]);
        const end = pos + identifier.length;
        const right = end == code.length || !identifierChar(code[end]);
        if (left && right) ++total;
        from = end;
    }
    return total;
}

private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    assert(at >= 0, "6506 boundary missing source marker " ~ marker);
    size_t i = cast(size_t) at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "6506 boundary found no body after " ~ marker);
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    assert(false, "6506 boundary found unterminated body after " ~ marker);
}

private string collapseWhitespace(string text) {
    string result;
    bool spacing;
    foreach (ch; text) {
        const ws = ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t';
        if (ws) { spacing = result.length > 0; continue; }
        if (spacing) result ~= ' ';
        result ~= ch;
        spacing = false;
    }
    return result;
}

private string[] importTargets(string code, const ImportDecl[] declarations) {
    string[] result;
    foreach (decl; declarations) {
        auto list = code[decl.start + "import".length .. decl.moduleListEnd].strip;
        if (list.length && list[$ - 1] == ';') list = list[0 .. $ - 1].strip;
        foreach (binding; list.split(',')) {
            auto target = binding.strip;
            const equals = target.indexOf('=');
            if (equals >= 0) target = target[cast(size_t) equals + 1 .. $].strip;
            if (target.length) result ~= target;
        }
    }
    return result;
}

private struct ModuleImports {
    string name;
    string[] imports;
}

private ModuleImports scanModule(string source) {
    const code = blankNonCode(source);
    ModuleImports result;
    result.imports = importTargets(code, importDeclarations(code));
    foreach (statement; statementsContaining(code, "module")) {
        if (!statement.startsWith("module ") || statement.length <= 8) continue;
        result.name = statement["module ".length .. $ - 1].strip;
        break;
    }
    return result;
}

private struct Closure {
    string[] queue;
    bool[string] reached;
    string[string] parent;
}

private Closure closureFrom(string seed, ref ModuleImports[string] modules) {
    Closure result;
    result.queue = [seed];
    result.reached[seed] = true;
    for (size_t head; head < result.queue.length; ++head) {
        const current = result.queue[head];
        const node = current in modules;
        if (node is null) continue;
        foreach (next; node.imports) {
            if (!(next in modules) || next in result.reached) continue;
            result.reached[next] = true;
            result.parent[next] = current;
            result.queue ~= next;
        }
    }
    return result;
}

private string reachChain(string seed, string target, const ref Closure closure) {
    string[] chain;
    string current = target;
    while (true) {
        chain = [current] ~ chain;
        if (current == seed) break;
        const previous = current in closure.parent;
        if (previous is null) break;
        current = *previous;
    }
    return chain.join(" -> ");
}

// L1/L1b: readable smoke plus the non-synonym string-injection ratchet.
unittest {
    const raw = readText(buildPath(repoRoot, "source",
        "transform_tool_registration.d"));
    const code = blankNonCode(raw);
    assert(raw.length > 3_000,
        "6506 boundary population: transform registrar source is unexpectedly small");
    foreach (needle; ["EditorApp", "editor_app", "Ai3dModalRefs",
            "Ai3dModalState", "RemeshModalRefs", "EditorAiState",
            "AiExplorationController", "AiInteractionLogWriter",
            "with (", "with("])
        assert(countOccurrences(code, needle) == 0,
            "6506 registrar names " ~ needle);
    assert(countOccurrences(code, "mixin") == 0,
        "6506 transform registrar gained a mixin injection surface");
}

// L2: conservative source-only import closure, including guarded and local
// imports. Over-approximation can false-red this prohibition, never false-green it.
unittest {
    ModuleImports[string] modules;
    size_t sourceFiles, transformSeen;
    foreach (entry; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++sourceFiles;
        auto scanned = scanModule(readText(entry.name));
        if (!scanned.name.length) continue;
        assert(scanned.name !in modules, "6506 duplicate source module " ~ scanned.name);
        modules[scanned.name] = scanned;
        if (scanned.name == "transform_tool_registration") ++transformSeen;
    }
    auto transform = closureFrom("transform_tool_registration", modules);
    auto positive = closureFrom("registration", modules);
    assert(sourceFiles >= 500 && transformSeen == 1,
        format("6506 import scanner population: files=%d transform seen=%d",
            sourceFiles, transformSeen));
    assert(transform.queue.length >= 200,
        format("6506 transform import closure too small: %d modules",
            transform.queue.length));
    assert("editor_app" in positive.reached,
        "6506 positive control: registration does not reach editor_app");
    foreach (forbidden; ["editor_app", "registration", "app",
            "ai.exploration", "ai.interaction_log_writer", "ai.state",
            "ai3d.worker_manager", "http_server"])
        if (forbidden in transform.reached)
            assert(false, "6506 transform_tool_registration reaches " ~ forbidden
                ~ ": " ~ reachChain("transform_tool_registration", forbidden,
                    transform));
    // The positive number was 512 + one per registration-family module added
    // since 6506 installed this census: slice 6503 (the shared const item
    // reader) took it to 513, slice 6509 (the extracted mesh registrar) to 514,
    // and slice 6670 (the extracted edit registrar) to 515. It later shrank
    // to 511 when four route-only imports left http_server for an app adapter.
    // Later legal links brought it to 512, and the browser file-dialog backend
    // added by W15-N brings it to 513. The browser pick-resume queue (task
    // 7400, io.browser_pick_resume, reached through the browser backend)
    // brings it to 515 on a main that stood at 514; `transform` stays 252.
    // It is a POSITIVE control, so it is EXPECTED to move on a legal link —
    // what must not move without review is `transform`; W15-C adds the
    // build-selected subpatch backend to every mesh-bearing closure, taking
    // both this closure and the broad control up by one.
    // Task 7120's pure plane-fit module (workplane_fit, reached through
    // commands.workplane) takes the broad control from 515 to 516.
    //
    // Both of those slices bumped this literal from 512 to 513 in their own
    // lanes, independently. Two lanes each incrementing the same counter write
    // the SAME text, so git merges them without a conflict and the file then
    // states 513 where the truth is 514. The gate on the REBASED sha is what
    // catches that; a gate taken before the rebase cannot.
    // Browser Assimp transport adds io.assimp_wire to the broad registration
    // closure; the transform-only closure stays at its pinned boundary.
    // Task 7144 (S3b review item 8): the Element Move pick takes its symmetry
    // packet through `symmetry_pick.captureLiveSymmetry`, like the click
    // helpers, which adds `symmetry_pick` to the transform closure (+1).
    // Task 7122: `value_drag`, reached through the edit-tool registrar (+1 each).
    // Slice M1a review: `edit_session` refuses navigation while a button is
    // held, which reaches the leaf `held_gesture_buttons` (+1 each).
    assert(transform.queue.length == 255 && positive.queue.length == 519,
        format("6506 import closure census changed: transform=%d/255 "
            ~ "registration=%d/519", transform.queue.length,
            positive.queue.length));
}

// L3a: compiler-owned complete member sets, including private members.
static assert([__traits(allMembers, TransformToolDeps)] == [
    "gpu_", "history_", "vertexEditFactory_", "morphEditFactory_",
    "itemEditFactory_", "pipeGizmoHost_", "exploreSilentHover_", "__ctor",
    "gpu", "history", "vertexEditFactory", "morphEditFactory",
    "itemEditFactory", "pipeGizmoHost", "exploreSilentHover"],
    "6506 TransformToolDeps member set changed");
static assert([__traits(allMembers, LiveSessionRole)] == [
    "session_", "__ctor", "activeMesh", "document", "subjectType"],
    "6506 LiveSessionRole member set changed");
static assert([__traits(allMembers, LiveViewModeRole)] == [
    "view_", "mode_", "__ctor", "view", "mode", "modeCell"],
    "6506 LiveViewModeRole member set changed");
static assert([__traits(allMembers, transform_tool_registration)] == [
    "object", "TransformToolDeps", "TransformFactoryDefaults",
    "buildUnifiedTransform", "registerTransformToolCommands"],
    "6506 transform registrar module member set changed");

// L3b: every registrar-body role read goes through the pinned accessor set.
unittest {
    const code = blankNonCode(readText(buildPath(repoRoot, "source",
        "transform_tool_registration.d")));
    const bodies = bodyAt(code, "private XfrmTransformTool buildUnifiedTransform(")
        ~ bodyAt(code, "void registerTransformToolCommands(ref Registry reg,");
    enum accessors = ["gpu", "history", "vertexEditFactory",
        "morphEditFactory", "itemEditFactory", "pipeGizmoHost",
        "exploreSilentHover"];
    static foreach (member; [__traits(allMembers, TransformToolDeps)]) {{
        static if (member != "__ctor") {
            bool allowed;
            foreach (accessor; accessors) if (member == accessor) allowed = true;
            if (!allowed)
                assert(identifierCount(bodies, member) == 0,
                    "6506 forbidden private member `" ~ member
                    ~ "` reached from the registrar body");
        }
    }}
    struct Row { string receiver, member; size_t count; }
    immutable rows = [
        Row("deps", "gpu", 9), Row("deps", "history", 9),
        Row("deps", "vertexEditFactory", 9),
        Row("deps", "morphEditFactory", 1),
        Row("deps", "itemEditFactory", 1),
        Row("deps", "pipeGizmoHost", 5),
        Row("deps", "exploreSilentHover", 1),
        Row("owner", "activeMesh", 9), Row("owner", "document", 1),
        Row("owner", "subjectType", 1), Row("live", "view", 4),
        Row("live", "mode", 4), Row("live", "modeCell", 5),
    ];
    size_t population;
    foreach (row; rows) {
        const actual = countOccurrences(bodies,
            row.receiver ~ "." ~ row.member ~ "(");
        population += actual;
        assert(actual == row.count, format(
            "6506 %s.%s used %d time(s), roster says %d",
            row.receiver, row.member, actual, row.count));
    }
    assert(population == 59 && population >= 50,
        format("6506 registrar accessor population changed: %d/59 "
            ~ "(receiver tokens deps=%d owner=%d live=%d)", population,
            identifierCount(bodies, "deps"), identifierCount(bodies, "owner"),
            identifierCount(bodies, "live")));
}

// L3c: signature and tuple identity prevent a broad context from replacing
// the seven narrow collaborators.
static assert(is(typeof(&registerTransformToolCommands) == void function(
    ref Registry, LiveSessionRole, LiveViewModeRole, TransformToolDeps)),
    "6506 transform registrar signature changed");
static assert(TransformToolDeps.tupleof.length == 7,
    "6506 TransformToolDeps field count changed");
static assert(!__traits(compiles, TransformToolDeps()),
    "6506 TransformToolDeps regained default construction");
static assert(__traits(identifier, TransformToolDeps.tupleof[0]) == "gpu_"
    && is(typeof(TransformToolDeps.tupleof[0]) == GpuMesh*));
static assert(__traits(identifier, TransformToolDeps.tupleof[1]) == "history_"
    && is(typeof(TransformToolDeps.tupleof[1]) == CommandHistory));
static assert(__traits(identifier, TransformToolDeps.tupleof[2])
        == "vertexEditFactory_"
    && is(typeof(TransformToolDeps.tupleof[2]) == MeshVertexEdit delegate()));
static assert(__traits(identifier, TransformToolDeps.tupleof[3])
        == "morphEditFactory_"
    && is(typeof(TransformToolDeps.tupleof[3]) == MeshMorphEdit delegate()));
static assert(__traits(identifier, TransformToolDeps.tupleof[4])
        == "itemEditFactory_"
    && is(typeof(TransformToolDeps.tupleof[4]) == LayerXformEdit delegate()));
static assert(__traits(identifier, TransformToolDeps.tupleof[5])
        == "pipeGizmoHost_"
    && is(typeof(TransformToolDeps.tupleof[5]) == PipeGizmoHost));
static assert(__traits(identifier, TransformToolDeps.tupleof[6])
        == "exploreSilentHover_"
    && is(typeof(TransformToolDeps.tupleof[6]) == bool delegate()));

unittest { // L3d: every constructor collaborator is required independently
    GpuMesh gpu;
    auto history = new CommandHistory;
    MeshVertexEdit delegate() vertex = () => null;
    MeshMorphEdit delegate() morph = () => null;
    LayerXformEdit delegate() item = () => null;
    auto pipe = new PipeGizmoHost;
    bool delegate() silent = () => false;
    // POSITIVE CONTROL for the negatives below: without it, seven assertThrown
    // read as "each collaborator is independently required" while a constructor
    // that refuses EVERYTHING — the all-valid roster included — satisfies all
    // seven. Measured: an unconditional refusal left this whole module green
    // before this line existed, and reddens it now (5/603 failing modules
    // became 6/603, the added one being this file).
    //
    // WHICH of its two halves reports, because H/J/K copy this: for a ctor that
    // refuses everything the CONSTRUCTION throws, so the throw's own line is the
    // red and the message below never prints. The message prints for the other
    // half — a ctor that ACCEPTS a valid roster and then stores the wrong thing,
    // e.g. an accessor handing back null. Both are the control's job; only the
    // second speaks in its own words.
    auto ok = TransformToolDeps(&gpu, history, vertex, morph, item, pipe, silent);
    assert(ok.gpu() is &gpu && ok.history() is history,
        "6506 L3d floor: the all-valid roster must construct");
    assertThrown!AssertError(TransformToolDeps(
        null, history, vertex, morph, item, pipe, silent));
    assertThrown!AssertError(TransformToolDeps(
        &gpu, null, vertex, morph, item, pipe, silent));
    assertThrown!AssertError(TransformToolDeps(
        &gpu, history, null, morph, item, pipe, silent));
    assertThrown!AssertError(TransformToolDeps(
        &gpu, history, vertex, null, item, pipe, silent));
    assertThrown!AssertError(TransformToolDeps(
        &gpu, history, vertex, morph, null, pipe, silent));
    assertThrown!AssertError(TransformToolDeps(
        &gpu, history, vertex, morph, item, null, silent));
    assertThrown!AssertError(TransformToolDeps(
        &gpu, history, vertex, morph, item, pipe, null));
}

// L4: production alone assembles the registrar, and no deferred policy closes
// over the by-value EditorApp parameter.
unittest {
    const code = blankNonCode(readText(buildPath(repoRoot, "source", "registration.d")));
    const root = bodyAt(code, "private void registerTransformTools(EditorApp app)");
    const collapsed = collapseWhitespace(root);
    enum expected = "{ auto explore = app.aiExplore; auto logw = app.aiLogWriter; "
        ~ "registerTransformToolCommands(app.reg(), LiveSessionRole(app.sessionOwner), "
        ~ "LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()), "
        ~ "TransformToolDeps(app.gpuPtr, app.history, app.vxEditFactory, "
        ~ "app.morphEditFactory, app.layerXformEditFactory, app.pipeGizmoHost, "
        ~ "() => explore.enabled && logw.enabled)); }";
    enum policyMarker = "app.pipeGizmoHost, ";
    const policyAt = collapsed.indexOf(policyMarker);
    const deferredPolicy = policyAt >= 0
        ? collapsed[cast(size_t) policyAt + policyMarker.length .. $] : "";
    // POPULATION FLOOR for the needle below, and it must stay ABOVE it.
    //
    // The needle is scoped by a marker, so with the marker gone the slice is the
    // empty string and `countOccurrences("", "app.ai") == 0` passes over nothing.
    // Renaming or reordering `app.pipeGizmoHost` in that argument list would then
    // disarm the named witness silently and leave only the text pin — the state
    // this ordering exists to prevent, one level up. H/J/K each scope their own
    // needle by their own marker, so each needs its own copy of this floor.
    assert(policyAt >= 0 && deferredPolicy.length > 0,
        "6506 policy-slice floor: the `app.pipeGizmoHost, ` marker vanished, so "
        ~ "the `app.ai` needle below is measuring an empty string");
    assert(countOccurrences(deferredPolicy, "app.ai") == 0,
        "6506 composition root deferred policy closes over `app.ai`");
    assert(countOccurrences(collapseWhitespace(code), expected) == 1,
        "6506 composition root call text or multiplicity changed");

    const appCode = collapseWhitespace(blankNonCode(
        readText(buildPath(repoRoot, "source", "app.d"))));
    const registerAt = appCode.indexOf("registerTools(app);");
    struct WiringRow { string label; string[] assignments; }
    immutable rows = [
        WiringRow("GPU", ["app.gpuPtr = &gpu;"]),
        WiringRow("history", ["app.history = history;"]),
        WiringRow("vertex factory", ["app.vxEditFactory = vxEditFactory;"]),
        WiringRow("morph factory", ["app.morphEditFactory = morphEditFactory;"]),
        WiringRow("item factory",
            ["app.layerXformEditFactory = layerXformEditFactory;"]),
        WiringRow("pipe host", ["app.pipeGizmoHost = pipeGizmoHost;"]),
        WiringRow("silent-hover policy",
            ["app.aiExplore = aiExplore;", "app.aiLogWriter = aiLogWriter;"]),
    ];
    foreach (row; rows) foreach (assignment; row.assignments) {
        const wiredAt = appCode.indexOf(assignment);
        assert(countOccurrences(appCode, assignment) == 1
                && countOccurrences(appCode, "registerTools(app);") == 1
                && wiredAt >= 0 && registerAt >= 0 && wiredAt < registerAt,
            format("6506 app wiring order: %s dependency `%s` must be wired "
                ~ "before the one registerTools(app) call", row.label,
                assignment));
    }
}
