module tests.unit.create_registration_boundary_test;


import tests.unit.census_symbols : exists = wave15Exists;

import core.exception : AssertError;
import vibe3d.editing.commands.runtime.command_history : CommandHistory;
import vibe3d.editing.commands.editor.commands.mesh.session_edit : MeshSessionEdit;
import vibe3d.apps.desktop.create_tool_registration : CreateToolDeps, registerCreateToolCommands;
static import create_tool_registration = vibe3d.apps.desktop.create_tool_registration;
import vibe3d.runtime.application_core.live_registration_roles : LiveSessionRole, LiveViewModeRole;
import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
import vibe3d.editing.tools.interactive.registry : Registry;
import vibe3d.viewport.gpu.shader : LitShader;
import vibe3d.editing.tools.interactive.tools.edit.topology_pen.defs : TopoPenFactories;

import std.array : join;
import std.algorithm : sort, canFind;
import std.file : SpanMode;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, readText = wave15ReadText;
import std.format : format;
import std.path : buildPath, dirName;
import std.exception : assertThrown;
import std.string : indexOf, split, startsWith, strip;
import std.traits : FieldNameTuple;
import tests.unit.census_symbols : balancedSpan, blankNonCode,
    countOccurrences, ImportDecl, importDeclarations, statementsContaining;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private bool identifierChar(char ch) {
    return ch == '_' || (ch >= '0' && ch <= '9')
        || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z');
}

private size_t identifierCount(string code, string identifier) {
    size_t total, from;
    while (from < code.length) {
        const hit = code.indexOf(identifier, from);
        if (hit < 0) break;
        const pos = cast(size_t) hit;
        const end = pos + identifier.length;
        if ((pos == 0 || !identifierChar(code[pos - 1]))
                && (end == code.length || !identifierChar(code[end])))
            ++total;
        from = end;
    }
    return total;
}

private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    assert(at >= 0, "6507 boundary missing source marker " ~ marker);
    const brace = code[cast(size_t) at .. $].indexOf('{');
    assert(brace >= 0, "6507 boundary found no body after " ~ marker);
    const body = balancedSpan(
        code, cast(size_t) at + cast(size_t) brace, '{', '}');
    assert(body.length,
        "6507 boundary found unterminated body after " ~ marker);
    return body;
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

// Extract expression-lambda bodies. This intentionally leaves the surrounding
// call text in lambdaFree: only deferred expressions are removed from its
// direct-read population.
private string lambdaScopes(string body) {
    string result;
    size_t from;
    while (from < body.length) {
        const arrow = body.indexOf("=>", from);
        if (arrow < 0) break;
        size_t i = cast(size_t) arrow + 2;
        size_t parens, brackets, braces;
        const begin = i;
        for (; i < body.length; ++i) {
            switch (body[i]) {
                case '(': ++parens; break;
                case ')': if (parens) --parens; else goto done; break;
                case '[': ++brackets; break;
                case ']': if (brackets) --brackets; break;
                case '{': ++braces; break;
                case '}': if (braces) --braces; else goto done; break;
                case ',': case ';': if (!parens && !brackets && !braces) goto done; break;
                default: break;
            }
        }
done:
        result ~= body[begin .. i];
        from = i + (i < body.length ? 1 : 0);
    }
    return result;
}

private string lambdaFree(string body) {
    string result;
    size_t from, copyFrom;
    while (from < body.length) {
        const arrow = body.indexOf("=>", from);
        if (arrow < 0) break;
        size_t i = cast(size_t) arrow + 2;
        size_t parens, brackets, braces;
        for (; i < body.length; ++i) {
            const ch = body[i];
            if (ch == '(') ++parens;
            else if (ch == ')') { if (parens) --parens; else break; }
            else if (ch == '[') ++brackets;
            else if (ch == ']') { if (brackets) --brackets; }
            else if (ch == '{') ++braces;
            else if (ch == '}') { if (braces) --braces; else break; }
            else if ((ch == ',' || ch == ';')
                    && !parens && !brackets && !braces) break;
        }
        result ~= body[copyFrom .. cast(size_t) arrow + 2];
        copyFrom = i;
        from = i + (i < body.length ? 1 : 0);
    }
    result ~= body[copyFrom .. $];
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

private struct ModuleImports { string name; string[] imports; }

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

private struct Closure { string[] queue; bool[string] reached; string[string] parent; }

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

private void pinClosure(string seed, const ref Closure closure, size_t baselineCount) {
    const baseline = readText(buildPath(repoRoot, "tests", "unit",
        seed ~ "_baseline_closure.txt")).strip.split('\n');
    assert(baseline.length == baselineCount, "registrar baseline manifest population: " ~ seed);
    auto actual = closure.queue.dup;
    sort(actual);
    string[] added, removed;
    foreach (name; actual) if (!baseline.canFind(name)) added ~= name;
    foreach (name; baseline) if (!actual.canFind(name)) removed ~= name;
    assert(added.length == 0 && removed.length == 0,
        format("%s exact closure delta: added=%s removed=%s members=%s", seed, added, removed, actual));
}

// L1/L1b: the narrow registrar has no broad app vocabulary or mixin surface.
unittest {
    const raw = readText(buildPath(repoRoot, "source",
        "create_tool_registration.d"));
    const code = blankNonCode(raw);
    assert(raw.length > 8_000,
        "6507 boundary population: create registrar source is unexpectedly small");
    foreach (needle; ["EditorApp", "editor_app", "Ai3dModalRefs",
            "Ai3dModalState", "RemeshModalRefs", "EditorAiState",
            "AiExplorationController", "AiInteractionLogWriter",
            "with (", "with("])
        assert(countOccurrences(code, needle) == 0,
            "6507 registrar names " ~ needle);
    assert(countOccurrences(code, "mixin") == 0,
        "6507 create registrar gained a mixin injection surface");
}

// L2: conservative import closure with a broad-root positive control.
unittest {
    ModuleImports[string] modules;
    size_t sourceFiles, createSeen;
    foreach (scanSourceRoot; [buildPath(repoRoot, "source"), buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source"), buildPath(repoRoot, "packages/pipe-contracts/source"), buildPath(repoRoot, "packages/mesh-preview/source"), buildPath(repoRoot, "util/json-number/source"), buildPath(repoRoot, "packages/selection-model/source"), buildPath(repoRoot, "packages/scene-query/source"), buildPath(repoRoot, "packages/editor-commands/source")])

    foreach (entry; dirEntries(scanSourceRoot, "*.d", SpanMode.depth)) {
        ++sourceFiles;
        auto scanned = scanModule(readText(entry.name));
        if (!scanned.name.length) continue;
        assert(scanned.name !in modules, "6507 duplicate source module " ~ scanned.name);
        modules[scanned.name] = scanned;
        if (scanned.name == "create_tool_registration") ++createSeen;
    }
    const string[] sourceCarriersWave14_1 = [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
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
];

import tests.unit.census_symbols : exists = wave15Exists;
    import std.path : buildPath;
    foreach (relative; [
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
    ]) {
        size_t occurrences;
        foreach (candidate; sourceCarriersWave14_1) if (candidate == relative) ++occurrences;
        assert(occurrences == 1, "Wave14 logical source input missing/duplicate: " ~ relative);

    }
    foreach (sourceCarrier; sourceCarriersWave14_1) {
        const sourceCarrierPath = buildPath(repoRoot, sourceCarrier);

        auto scanned = scanModule(readText(sourceCarrierPath));
        if (!scanned.name.length) continue;
        assert(scanned.name !in modules, "6507 duplicate source module " ~ scanned.name);
        modules[scanned.name] = scanned;
        if (scanned.name == "create_tool_registration") ++createSeen;

    }
    auto create = closureFrom("create_tool_registration", modules);
    auto positive = closureFrom("registration", modules);
    // Exact closure sizes make every newly reachable module in the G→H→J→K
    // registrar chain an explicit boundary review instead of hidden slack.
    // Task 7144 (S3b review item 8): the Element Move pick takes its symmetry
    // packet through `symmetry_pick.captureLiveSymmetry`, like the click
    // helpers, which adds `symmetry_pick` to the transform closure (+1).
    // Task 7122: `value_drag` (the shared no-handle value drag) (+1).
    // Slice M1a review: `edit_session` refuses navigation while a button is
    // held, which reaches the leaf `held_gesture_buttons` (+1 each).
    // Slice M5: `prefs` holds the tool attribute cache, which reaches the leaf
    // `toolpipe.attr_cache` (+1 each).
    // Retopology slice S4: the lit uploads read the leaf `light_rig` (+1).
    // Viewport shading S1a (task 9070): the face-VBO writers read the leaf
    // `vertex_normals` (+1).
    // Viewport shading S4b (task 9250): the lit shader reads the Reflection
    // images, `viewport_env` and its decoder `io.image_decode` (+2).
    // Pen S1: the pen reads its one stroke builder, `tools.create.pen_geometry` (+1).
    // Wave-2 PRM1: eleven parameter-update owner modules became one (-10).
    // Wave-2 PRM2: five more folded into it (-5).
    // Task 9429: the topology tools compose `tools.topology_step` (+1).
    // Task 9492: the attribute doors read `tool_attr_bounds` (+1).
    // Task 9490: the radial ring start reads `workplane_fit`'s frame (+1).
    // Task 9525: Drag Weld became a topology-pen preset, `tools.edit.drag_weld` gone (-1).
    // Task 9449: the shared tools.edit.haul_axis_latch adds one module.
    assert(sourceFiles >= 500 && createSeen == 1 && create.queue.length >= 200,
        format("6507 import scanner population: files=%d create=%d closure=%d",
            sourceFiles, createSeen, create.queue.length));
    assert("editor_app" in positive.reached,
        "6507 positive control: registration does not reach editor_app");
    foreach (forbidden; ["editor_app", "registration", "app",
            "ai.exploration", "ai.interaction_log_writer", "ai.state",
            "ai3d.worker_manager", "http_server"])
        if (forbidden in create.reached)
            assert(false, "6507 create_tool_registration reaches " ~ forbidden
                ~ ": " ~ reachChain("create_tool_registration", forbidden, create));
    // Task 20261660: Tool reaches the detached model_preview view (+1 each).
    // Wave6A: the existing kernel reaches its extracted cluster_values leaf (+1 each).
    // Wave9 frozen closure map retains all members and adds morph_preview.
    pinClosure("create_tool_registration", create, 276);
    pinClosure("registration", positive, 547);
    assert(create.queue.length == 276 && positive.queue.length == 547,
        "6507 reviewed narrow and broad closure populations");
}

// L3a: compiler-owned complete member sets, including private declarations.
static assert([__traits(allMembers, CreateToolDeps)] == [
    "gpu_", "litShader_", "history_", "bevelEditFactory_", "penFactories_",
    "__ctor", "gpu", "litShader", "history", "bevelEditFactory", "penFactories"],
    "6507 CreateToolDeps member set changed");
static assert([__traits(allMembers, LiveSessionRole)] == [
    "session_", "__ctor", "activeMesh", "document", "subjectType"]);
static assert([__traits(allMembers, LiveViewModeRole)] == [
    "view_", "mode_", "__ctor", "view", "mode", "modeCell"]);
static assert([__traits(allMembers, create_tool_registration)] == [
    "object", "CreateToolDeps", "registerHeadlessTool",
    "registerCreateToolCommands", "registerGeneratorTools",
    "registerPrimitiveTools"],
    "6507 create registrar module member set changed");

// L3b: each body is non-empty and uses only the public dependency accessors.
unittest {
    const code = blankNonCode(readText(buildPath(repoRoot, "source",
        "create_tool_registration.d")));
    const helper = bodyAt(code, "private void registerHeadlessTool(");
    const generator = bodyAt(code, "private void registerGeneratorTools(");
    const primitive = bodyAt(code, "private void registerPrimitiveTools(");
    const entry = bodyAt(code, "void registerCreateToolCommands(");
    assert(helper.length > 150 && generator.length > 1_200
        && primitive.length > 2_500 && entry.length > 100,
        "6507 registrar body population floor changed");
    const bodies = helper ~ generator ~ primitive ~ entry;
    struct Row { string receiver, member; size_t count; }
    immutable rows = [
        Row("deps", "gpu", 16), Row("deps", "litShader", 15),
        Row("deps", "history", 16), Row("deps", "bevelEditFactory", 15),
        Row("deps", "penFactories", 1), Row("owner", "activeMesh", 18),
        Row("owner", "subjectType", 1),
        Row("live", "view", 2), Row("live", "mode", 2),
        Row("live", "modeCell", 2),
    ];
    foreach (row; rows) {
        const actual = countOccurrences(bodies,
            row.receiver ~ "." ~ row.member ~ "(");
        assert(actual == row.count, format(
            "6507 %s.%s used %d time(s), roster says %d",
            row.receiver, row.member, actual, row.count));
    }
    const depsReceivers = countOccurrences(bodies, "deps.");
    const ownerReceivers = countOccurrences(bodies, "owner.");
    const liveReceivers = countOccurrences(bodies, "live.");
    assert(depsReceivers == 63 && ownerReceivers == 19 && liveReceivers == 6,
        format("6507 registrar receiver population changed: deps=%d/63 "
             ~ "owner=%d/19 live=%d/6", depsReceivers, ownerReceivers,
            liveReceivers));
    static foreach (member; [__traits(allMembers, CreateToolDeps)]) {{
        static if (member != "__ctor" && member[$ - 1] == '_')
            assert(identifierCount(bodies, member) == 0,
                "6507 forbidden private member reached from registrar: " ~ member);
    }}
}

// L3c: signature, field identity, disabled default construction, and storage.
static assert(is(typeof(&registerCreateToolCommands) == void function(
    ref Registry, LiveSessionRole, LiveViewModeRole, CreateToolDeps)));
static assert(CreateToolDeps.tupleof.length == 5);
static assert(!__traits(compiles, CreateToolDeps()));
static assert(__traits(identifier, CreateToolDeps.tupleof[0]) == "gpu_"
    && is(typeof(CreateToolDeps.tupleof[0]) == GpuMesh*));
static assert(__traits(identifier, CreateToolDeps.tupleof[1]) == "litShader_"
    && is(typeof(CreateToolDeps.tupleof[1]) == LitShader));
static assert(__traits(identifier, CreateToolDeps.tupleof[2]) == "history_"
    && is(typeof(CreateToolDeps.tupleof[2]) == CommandHistory));
static assert(__traits(identifier, CreateToolDeps.tupleof[3]) == "bevelEditFactory_"
    && is(typeof(CreateToolDeps.tupleof[3]) == MeshSessionEdit delegate()));
static assert(__traits(identifier, CreateToolDeps.tupleof[4]) == "penFactories_"
    && is(typeof(CreateToolDeps.tupleof[4]) == TopoPenFactories));

private TopoPenFactories completePenBundle() {
    TopoPenFactories bundle;
    static foreach (field; FieldNameTuple!TopoPenFactories)
        __traits(getMember, bundle, field) = () => null;
    return bundle;
}

unittest { // L3d: positive control precedes each independently missing input.
    GpuMesh gpu;
    auto history = new CommandHistory;
    MeshSessionEdit delegate() bevel = () => null;
    auto pen = completePenBundle();
    auto lit = LitShader.init;
    auto ok = CreateToolDeps(&gpu, lit, history, bevel, pen);
    assert(ok.gpu() is &gpu && ok.litShader() is lit
        && ok.history() is history && ok.bevelEditFactory() is bevel
        && ok.penFactories().build is pen.build,
        "6507 floor: the all-valid roster must construct and hold each member");
    assertThrown!AssertError(CreateToolDeps(null, lit, history, bevel, pen));
    assertThrown!AssertError(CreateToolDeps(&gpu, lit, null, bevel, pen));
    assertThrown!AssertError(CreateToolDeps(&gpu, lit, history, null, pen));
    pen.build = null;
    assertThrown!AssertError(CreateToolDeps(&gpu, lit, history, bevel, pen));
}

unittest {
    const code = blankNonCode(readText(buildPath(repoRoot, "source",
        "create_tool_registration.d")));
    const ctorBody = bodyAt(code,
        "this(GpuMesh* gpu, LitShader litShader, CommandHistory history,");
    assert(ctorBody.length > 500,
        format("6507 ctor-body floor: constructor body read as %d bytes",
            ctorBody.length));
    size_t rosterRows;
    static foreach (member; [__traits(allMembers, CreateToolDeps)]) {{
        static if (member != "__ctor" && member[$ - 1] != '_') {
            ++rosterRows;
            assert(identifierCount(ctorBody, member ~ "_") == 1,
                "6507 storage: constructor field `" ~ member
              ~ "_` must occur exactly once");
            assert(countOccurrences(ctorBody,
                    member ~ "_ = " ~ member ~ ";") == 1,
                "6507 storage: the constructor does not assign `" ~ member
              ~ "_` from its own parameter exactly once");
            assert(countOccurrences(bodyAt(code, member ~ "()"),
                    "return " ~ member ~ "_;") == 1,
                "6507 storage: accessor `" ~ member
              ~ "()` does not return its own field");
        }
    }}
    assert(rosterRows == 5, "6507 storage population: expected five members");
}


private enum kExpectedCall = "{ registerCreateToolCommands(app.reg(), "
    ~ "LiveSessionRole(app.sessionOwner), "
    ~ "LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()), "
    ~ "CreateToolDeps(app.gpuPtr, app.litShader, app.history, "
    ~ "app.bevelEditFactory, app.topoPenFactories)); }";

unittest { // L4/L4b: direct, closure-free composition plus live app wiring.
    const code = blankNonCode(readText(buildPath(repoRoot, "source", "registration.d")));
    const body = bodyAt(code, "private void registerCreateTools(EditorApp app)");
    const direct = countOccurrences(lambdaFree(body), "app.");
    assert(direct == 9, format(
        "6507 composition root: the create root reads app dependencies %d time(s) "
      ~ "directly, expected 9 — a dependency left the direct argument list, most "
      ~ "likely into a lambda", direct));
    assert(identifierCount(lambdaScopes(body), "app") == 0
            && countOccurrences(body, "&app.") == 0,
        "6507 closure: the create composition root reaches an EditorApp member "
      ~ "inside a lambda or through a method address — the channel came back");
    assert(countOccurrences(body, "=>") == 0
            && countOccurrences(body, "{") == 1,
        "6507 composition root: a lambda or nested scope appeared in the create root");
    assert(countOccurrences(collapseWhitespace(code), kExpectedCall) == 1,
        "6507 call text: the create composition-root call text or its multiplicity changed");

    const appCode = collapseWhitespace(blankNonCode(
        readText(buildPath(repoRoot, "source", "app.d"))));
    const registerAt = appCode.indexOf("registerTools(app);");
    immutable assignments = [
        "app.gpuPtr = &gpu;", "app.litShader = litShader;",
        "app.history = history;", "app.bevelEditFactory = bevelEditFactory;",
        "app.topoPenFactories = buildTopoPenFactories();",
    ];
    foreach (assignment; assignments) {
        const wiredAt = appCode.indexOf(assignment);
        assert(countOccurrences(appCode, assignment) == 1
                && countOccurrences(appCode, "registerTools(app);") == 1
                && wiredAt >= 0 && registerAt >= 0 && wiredAt < registerAt,
            "6507 app wiring order: dependency `" ~ assignment
          ~ "` must be wired before the one registerTools(app) call");
    }
}
