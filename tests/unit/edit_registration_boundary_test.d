module tests.unit.edit_registration_boundary_test;

import core.exception : AssertError;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import commands.mesh.vertex_edit : MeshVertexEdit;
import edit_tool_registration : EditSessionFactories, EditToolDeps,
    registerEditToolCommands;
static import edit_tool_registration;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import mesh_gpu : GpuMesh;
import pipe_gizmo_host : PipeGizmoHost;
import registry : Registry;
import shader : LitShader;

import std.array : join;
import std.exception : assertThrown;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName;
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
    assert(at >= 0, "6670 boundary missing source marker " ~ marker);
    const brace = code[cast(size_t) at .. $].indexOf('{');
    assert(brace >= 0, "6670 boundary found no body after " ~ marker);
    const body = balancedSpan(
        code, cast(size_t) at + cast(size_t) brace, '{', '}');
    assert(body.length,
        "6670 boundary found unterminated body after " ~ marker);
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
                case ',': case ';':
                    if (!parens && !brackets && !braces) goto done;
                    break;
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

private string probeAppendix(string needle) {
    if (needle == "with (" || needle == "with(")
        return "\nvoid _probe6670(){ " ~ needle ~ "0) {} }\n";
    if (needle == "new ToolHeadlessCommand(")
        return "\nvoid _probe6670(){ auto _ = " ~ needle ~ "); }\n";
    return "\nvoid _probe6670(" ~ needle ~ " x) {}\n";
}

// L1/L1b/L5: every zero has a same-scanner canary that must flip to one.
unittest {
    const raw = readText(buildPath(repoRoot, "source",
        "edit_tool_registration.d"));
    const code = blankNonCode(raw);
    assert(raw.length > 12_000, format(
        "6670 boundary population: edit registrar read as %d bytes", raw.length));
    foreach (needle; ["EditorApp", "editor_app", "Ai3dModalRefs",
            "Ai3dModalState", "RemeshModalRefs", "EditorAiState",
            "AiExplorationController", "AiInteractionLogWriter",
            "with (", "with(", "mixin", "registerHeadlessTool",
            "new ToolHeadlessCommand("]) {
        assert(countOccurrences(code, needle) == 0,
            "6670 registrar names " ~ needle);
        assert(countOccurrences(
                blankNonCode(raw ~ probeAppendix(needle)), needle) == 1,
            "6670 the needle for " ~ needle
          ~ " cannot reach: it reports 0 on text that CONTAINS it");
    }
}

// L2: population, positive control and bans precede the exact closure pins.
unittest {
    ModuleImports[string] modules;
    size_t sourceFiles, editSeen;
    foreach (entry; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++sourceFiles;
        auto scanned = scanModule(readText(entry.name));
        if (!scanned.name.length) continue;
        assert(scanned.name !in modules,
            "6670 duplicate source module " ~ scanned.name);
        modules[scanned.name] = scanned;
        if (scanned.name == "edit_tool_registration") ++editSeen;
    }
    auto edit = closureFrom("edit_tool_registration", modules);
    auto positive = closureFrom("registration", modules);
    assert(sourceFiles >= 500 && editSeen == 1, format(
        "6670 import scanner population: files=%d edit=%d",
        sourceFiles, editSeen));
    assert("editor_app" in positive.reached,
        "6670 positive control: registration does not reach editor_app");
    foreach (forbidden; ["editor_app", "registration", "app",
            "ai.exploration", "ai.interaction_log_writer", "ai.state",
            "ai3d.worker_manager", "http_server", "viewport",
            "ui.remesh_modal_state"])
        if (forbidden in edit.reached)
            assert(false, "6670 edit_tool_registration reaches " ~ forbidden
                ~ ": " ~ reachChain("edit_tool_registration", forbidden, edit));
    assert(edit.queue.length == 251 && positive.queue.length == 513,
        format("6670 import closure census changed: edit=%d/251 "
            ~ "registration=%d/513", edit.queue.length,
            positive.queue.length));
}

private enum string[] kSessionFields = [
    "bevelEditFactory", "loopSliceEditFactory", "reduceEditFactory",
    "cloneEditFactory", "arrayEditFactory", "edgeExtrudeEditFactory",
    "edgeExtendEditFactory", "polyExtrudeEditFactory",
    "radialArrayEditFactory", "smoothShiftEditFactory",
    "strokeExtrudeEditFactory",
];

// L3a: compiler-owned complete member sets. The shared live roles are already
// pinned by create_registration_boundary_test and
// transform_registration_boundary_test. The ordered factory expectation is
// shared with L3c so the two witnesses cannot drift independently.
static assert([__traits(allMembers, EditToolDeps)] == [
    "gpu_", "litShader_", "history_", "pipeGizmoHost_", "vxEditFactory_",
    "sessions_", "__ctor", "gpu", "litShader", "history", "pipeGizmoHost",
    "vxEditFactory", "bevelEditFactory", "loopSliceEditFactory",
    "reduceEditFactory", "cloneEditFactory", "arrayEditFactory",
    "edgeExtrudeEditFactory", "edgeExtendEditFactory",
    "polyExtrudeEditFactory", "radialArrayEditFactory",
    "smoothShiftEditFactory", "strokeExtrudeEditFactory"],
    "6670 EditToolDeps member set changed");
static assert([__traits(allMembers, EditSessionFactories)] == kSessionFields,
    "6670 ordered EditSessionFactories member set changed");
static assert([__traits(allMembers, edit_tool_registration)] == [
    "object", "EditSessionFactories", "EditToolDeps",
    "registerEditToolCommands"],
    "6670 edit registrar module member set changed");

// L3b: the registrar body is populated, every public dependency accessor has
// its measured use count, and no private storage name leaks into that body.
unittest {
    const code = blankNonCode(readText(buildPath(repoRoot, "source",
        "edit_tool_registration.d")));
    const entry = bodyAt(code, "void registerEditToolCommands(");
    const ctor = bodyAt(code, "this(GpuMesh* gpu, LitShader litShader,");
    assert(entry.length > 12_000 && ctor.length > 650,
        format("6670 registrar body population changed: entry=%d ctor=%d",
            entry.length, ctor.length));
    struct Row { string receiver, member; size_t count; }
    immutable rows = [
        Row("deps", "gpu", 20), Row("deps", "litShader", 17),
        Row("deps", "history", 20), Row("deps", "pipeGizmoHost", 1),
        Row("deps", "vxEditFactory", 1),
        Row("deps", "bevelEditFactory", 9),
        Row("deps", "loopSliceEditFactory", 1),
        Row("deps", "reduceEditFactory", 1),
        Row("deps", "cloneEditFactory", 1),
        Row("deps", "arrayEditFactory", 1),
        Row("deps", "edgeExtrudeEditFactory", 1),
        Row("deps", "edgeExtendEditFactory", 1),
        Row("deps", "polyExtrudeEditFactory", 1),
        Row("deps", "radialArrayEditFactory", 1),
        Row("deps", "smoothShiftEditFactory", 1),
        Row("deps", "strokeExtrudeEditFactory", 1),
        Row("owner", "activeMesh", 20), Row("owner", "document", 0),
        Row("owner", "subjectType", 0), Row("live", "view", 0),
        Row("live", "mode", 0), Row("live", "modeCell", 18),
    ];
    foreach (row; rows) {
        const actual = countOccurrences(entry,
            row.receiver ~ "." ~ row.member ~ "(");
        assert(actual == row.count, format(
            "6670 %s.%s used %d time(s), roster says %d",
            row.receiver, row.member, actual, row.count));
    }
    static foreach (member; [__traits(allMembers, EditToolDeps)]) {{
        static if (member.length && member[$ - 1] == '_')
            assert(identifierCount(entry, member) == 0,
                "6670 forbidden private member reached from registrar: " ~ member);
    }}
    size_t rosterRows;
    static foreach (member; [__traits(allMembers, EditToolDeps)]) {{
        static if (member != "__ctor" && member.length
                && member[$ - 1] != '_')
            ++rosterRows;
    }}
    const depsReceivers = countOccurrences(entry, "deps.");
    const ownerReceivers = countOccurrences(entry, "owner.");
    const liveReceivers = countOccurrences(entry, "live.");
    // Five direct accessors plus eleven flattened session accessors. The
    // private sessions_ bundle deliberately has no public bundle accessor.
    assert(rosterRows == 16
            && depsReceivers + ownerReceivers + liveReceivers >= 106,
        format("6670 registrar population: roster=%d/16 receivers=%d (floor 106)",
            rosterRows, depsReceivers + ownerReceivers + liveReceivers));
}

// L3c: signature, storage identity/types and disabled default construction.
static assert(is(typeof(&registerEditToolCommands) == void function(
    ref Registry, LiveSessionRole, LiveViewModeRole, EditToolDeps)));
static assert(EditToolDeps.tupleof.length == 6);
static assert(EditSessionFactories.tupleof.length == 11);
static assert(!__traits(compiles, EditToolDeps()));
static assert(__traits(identifier, EditToolDeps.tupleof[0]) == "gpu_"
    && is(typeof(EditToolDeps.tupleof[0]) == GpuMesh*));
static assert(__traits(identifier, EditToolDeps.tupleof[1]) == "litShader_"
    && is(typeof(EditToolDeps.tupleof[1]) == LitShader));
static assert(__traits(identifier, EditToolDeps.tupleof[2]) == "history_"
    && is(typeof(EditToolDeps.tupleof[2]) == CommandHistory));
static assert(__traits(identifier, EditToolDeps.tupleof[3]) == "pipeGizmoHost_"
    && is(typeof(EditToolDeps.tupleof[3]) == PipeGizmoHost));
static assert(__traits(identifier, EditToolDeps.tupleof[4]) == "vxEditFactory_"
    && is(typeof(EditToolDeps.tupleof[4]) == MeshVertexEdit delegate()));
static assert(__traits(identifier, EditToolDeps.tupleof[5]) == "sessions_"
    && is(typeof(EditToolDeps.tupleof[5]) == EditSessionFactories));
static foreach (i, field; kSessionFields) {
    static assert(__traits(identifier, EditSessionFactories.tupleof[i]) == field);
    static assert(is(typeof(EditSessionFactories.tupleof[i]) ==
        MeshSessionEdit delegate()));
}

private EditSessionFactories completeSessionFactories() {
    EditSessionFactories result;
    static foreach (field; FieldNameTuple!EditSessionFactories)
        __traits(getMember, result, field) = () => null;
    return result;
}

unittest { // L3d: the all-valid control precedes each missing required input.
    GpuMesh gpu;
    auto lit = LitShader.init;
    auto history = new CommandHistory;
    auto pipe = new PipeGizmoHost;
    MeshVertexEdit delegate() vx = () => null;
    auto sessions = completeSessionFactories();
    auto ok = EditToolDeps(&gpu, lit, history, pipe, vx, sessions);
    assert(ok.gpu() is &gpu && ok.litShader() is lit
            && ok.history() is history && ok.pipeGizmoHost() is pipe
            && ok.vxEditFactory() is vx,
        "6670 floor: the all-valid dependency roster must construct");
    static foreach (field; FieldNameTuple!EditSessionFactories)
        assert(__traits(getMember, ok, field)()
                is __traits(getMember, sessions, field),
            "6670 floor: accessor did not return session factory " ~ field);
    assertThrown!AssertError(EditToolDeps(
        null, lit, history, pipe, vx, sessions));
    assertThrown!AssertError(EditToolDeps(
        &gpu, lit, null, pipe, vx, sessions));
    assertThrown!AssertError(EditToolDeps(
        &gpu, lit, history, pipe, null, sessions));
    sessions.bevelEditFactory = null;
    assertThrown!AssertError(EditToolDeps(
        &gpu, lit, history, pipe, vx, sessions));
}

private enum kExpectedCall = "{ registerEditToolCommands(app.reg(), "
    ~ "LiveSessionRole(app.sessionOwner), "
    ~ "LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()), "
    ~ "EditToolDeps(app.gpuPtr, app.litShader, app.history, app.pipeGizmoHost, "
    ~ "app.vxEditFactory, EditSessionFactories( "
    ~ "bevelEditFactory: app.bevelEditFactory, "
    ~ "loopSliceEditFactory: app.loopSliceEditFactory, "
    ~ "reduceEditFactory: app.reduceEditFactory, "
    ~ "cloneEditFactory: app.cloneEditFactory, "
    ~ "arrayEditFactory: app.arrayEditFactory, "
    ~ "edgeExtrudeEditFactory: app.edgeExtrudeEditFactory, "
    ~ "edgeExtendEditFactory: app.edgeExtendEditFactory, "
    ~ "polyExtrudeEditFactory: app.polyExtrudeEditFactory, "
    ~ "radialArrayEditFactory: app.radialArrayEditFactory, "
    ~ "smoothShiftEditFactory: app.smoothShiftEditFactory, "
    ~ "strokeExtrudeEditFactory: app.strokeExtrudeEditFactory))); }";

unittest { // L4: direct, closure-free, one-statement production composition.
    const code = blankNonCode(readText(buildPath(
        repoRoot, "source", "registration.d")));
    const rootBody = bodyAt(code,
        "private void registerEditTools(EditorApp app)");
    const direct = countOccurrences(lambdaFree(rootBody), "app.");
    assert(direct >= 20, format(
        "6670 composition root reads app dependencies %d time(s) directly; "
      ~ "expected at least 20 — a dependency left the direct argument list, "
      ~ "most likely into a lambda", direct));
    assert(identifierCount(lambdaScopes(rootBody), "app") == 0
            && countOccurrences(rootBody, "&app.") == 0,
        "6670 closure: the edit composition root reaches an EditorApp member "
      ~ "inside a lambda or through a method address");
    assert(countOccurrences(rootBody, "=>") == 0
            && countOccurrences(rootBody, "{") == 1
            && countOccurrences(rootBody, "with (") == 0,
        "6670 composition root gained a lambda, nested scope, or with(app)");
    assert(countOccurrences(collapseWhitespace(code), kExpectedCall) == 1,
        "6670 call text: the complete edit composition-root call changed");
}
