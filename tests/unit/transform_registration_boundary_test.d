module tests.unit.transform_registration_boundary_test;

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
    assert(transform.queue.length == 251 && positive.queue.length == 511,
        format("6506 import closure census changed: transform=%d/251 "
            ~ "registration=%d/511", transform.queue.length,
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
    assert(countOccurrences(collapseWhitespace(code), expected) == 1,
        "6506 composition root call text or multiplicity changed");
    assert(countOccurrences(collapsed, "=> app.") == 0,
        "6506 composition root body contains a lambda over `app.`");
}
