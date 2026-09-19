module tests.unit.mesh_registration_boundary_test;

import core.exception : AssertError;
import editmode : EditMode;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import math : Viewport;
import mesh_command_registration : MeshCommandDeps, registerMeshCommands;
static import mesh_command_registration;
import registry : Registry;
import remesh.remesh_job : RemeshJob;
import std.array : join;
import std.exception : assertThrown;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName;
import std.string : indexOf, split, startsWith, strip;
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
    assert(at >= 0, "6509 boundary missing source marker " ~ marker);
    const brace = code[cast(size_t) at .. $].indexOf('{');
    assert(brace >= 0, "6509 boundary found no body after " ~ marker);
    const body = balancedSpan(
        code, cast(size_t) at + cast(size_t) brace, '{', '}');
    assert(body.length,
        "6509 boundary found unterminated body after " ~ marker);
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

// Return only expression-lambda bodies. A block-lambda has no `=>` and is
// deliberately not cut; L4's `{` term is the independent guard for it.
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

// L1/L1b: the first group records vocabulary removed by J. The second group
// is an explicit forward guard: every one was already zero before this slice.
unittest {
    const raw = readText(buildPath(repoRoot, "source",
        "mesh_command_registration.d"));
    const code = blankNonCode(raw);
    assert(raw.length > 20_000,
        "6509 boundary population: mesh registrar source is unexpectedly small");
    immutable moved = ["EditorApp", "with (", "vpm", "remeshModalState"];
    immutable before = [1, 2, 3, 1];
    foreach (i, needle; moved)
        assert(countOccurrences(code, needle) == 0,
            format("6509 extracted boundary: `%s` had %d code occurrence(s) "
                 ~ "before J and must now be zero", needle, before[i]));
    foreach (needle; ["editor_app", "Ai3dModalRefs", "Ai3dModalState",
            "RemeshModalRefs", "RemeshModalState", "ViewportManager",
            "EditorAiState", "AiExplorationController",
            "AiInteractionLogWriter", "with("])
        assert(countOccurrences(code, needle) == 0,
            "6509 forward guard: mesh registrar names " ~ needle
          ~ " (this vocabulary was already absent before J)");
    assert(countOccurrences(code, "mixin") == 0,
        "6509 mesh registrar gained a mixin injection surface");
}

// L2: conservative source-only import closure with a broad-root control.
unittest {
    ModuleImports[string] modules;
    size_t sourceFiles, meshSeen;
    foreach (entry; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++sourceFiles;
        auto scanned = scanModule(readText(entry.name));
        if (!scanned.name.length) continue;
        assert(scanned.name !in modules, "6509 duplicate source module " ~ scanned.name);
        modules[scanned.name] = scanned;
        if (scanned.name == "mesh_command_registration") ++meshSeen;
    }
    auto meshClosure = closureFrom("mesh_command_registration", modules);
    auto positive = closureFrom("registration", modules);
    assert(sourceFiles >= 500 && meshSeen == 1
            && meshClosure.queue.length == 176,
        format("6509 import scanner population: files=%d mesh=%d closure=%d/176",
            sourceFiles, meshSeen, meshClosure.queue.length));
    assert("editor_app" in positive.reached,
        "6509 positive control: registration does not reach editor_app");
    foreach (forbidden; ["editor_app", "registration", "app",
            "ai.exploration", "ai.interaction_log_writer", "ai.state",
            "ai3d.worker_manager", "http_server", "viewport",
            "ui.remesh_modal_state"])
        if (forbidden in meshClosure.reached)
            assert(false, "6509 mesh_command_registration reaches " ~ forbidden
                ~ ": " ~ reachChain("mesh_command_registration", forbidden,
                    meshClosure));
}

// L3a: compiler-owned complete member sets.
static assert([__traits(allMembers, MeshCommandDeps)] == [
    "meshRebuildDrop_", "originSnapshot_", "remeshJob_",
    "requestRemeshOpen_", "promoteGeometryType_", "__ctor",
    "meshRebuildDrop", "originSnapshot", "remeshJob",
    "requestRemeshOpen", "promoteGeometryType"],
    "6509 MeshCommandDeps member set changed");
static assert([__traits(allMembers, LiveSessionRole)] == [
    "session_", "__ctor", "activeMesh", "document", "subjectType"]);
static assert([__traits(allMembers, LiveViewModeRole)] == [
    "view_", "mode_", "__ctor", "view", "mode", "modeCell"]);
static assert([__traits(allMembers, mesh_command_registration)] == [
    "object", "commands", "MeshCommandDeps", "registerMeshCommands"],
    "6509 mesh registrar module member set changed: "
  ~ [__traits(allMembers, mesh_command_registration)].stringof);

// L3b: every family read goes through the pinned public accessor roster.
unittest {
    const code = blankNonCode(readText(buildPath(repoRoot, "source",
        "mesh_command_registration.d")));
    const body = bodyAt(code,
        "void registerMeshCommands(ref Registry reg, LiveSessionRole owner,");
    assert(body.length > 16_000,
        format("6509 registrar-body floor: body read as %d bytes", body.length));
    assert(identifierCount(body, "owner") == 107,
        "6509 receiver reconciliation: owner must serve exactly 107 reads");
    assert(identifierCount(body, "live") == 215,
        "6509 receiver reconciliation: live must serve exactly 215 reads");
    assert(identifierCount(body, "deps") == 15,
        "6509 receiver reconciliation: deps must serve exactly 15 reads");
    struct Row { string receiver, member; size_t count; }
    immutable rows = [
        Row("owner", "activeMesh", 107),
        Row("live", "view", 107), Row("live", "mode", 107),
        Row("live", "modeCell", 1),
        Row("deps", "meshRebuildDrop", 7),
        Row("deps", "originSnapshot", 3), Row("deps", "remeshJob", 2),
        Row("deps", "requestRemeshOpen", 1),
        Row("deps", "promoteGeometryType", 2),
    ];
    foreach (row; rows) {
        const actual = countOccurrences(body,
            row.receiver ~ "." ~ row.member ~ "(");
        assert(actual == row.count, format(
            "6509 %s.%s used %d time(s), roster says %d",
            row.receiver, row.member, actual, row.count));
    }
    assert(countOccurrences(body, "regPtr.toolFactories[") == 3,
        "6509 registry idiom: expected three late tool-factory reads");
    assert(countOccurrences(body, "reg.toolFactories[") == 0,
        "6509 registry idiom: the family reads reg.toolFactories directly "
      ~ "instead of the address local");
    static foreach (member; [__traits(allMembers, MeshCommandDeps)]) {{
        static if (member != "__ctor" && member[$ - 1] == '_')
            assert(identifierCount(body, member) == 0,
                "6509 forbidden private member reached from registrar: " ~ member);
    }}
}

// L3c: signature, field identity, disabled default construction, and storage.
static assert(is(typeof(&registerMeshCommands) == void function(
    ref Registry, LiveSessionRole, LiveViewModeRole, MeshCommandDeps)));
static assert(MeshCommandDeps.tupleof.length == 5);
static assert(!__traits(compiles, MeshCommandDeps()));
static assert(__traits(identifier, MeshCommandDeps.tupleof[0]) == "meshRebuildDrop_"
    && is(typeof(MeshCommandDeps.tupleof[0]) == void delegate()));
static assert(__traits(identifier, MeshCommandDeps.tupleof[1]) == "originSnapshot_"
    && is(typeof(MeshCommandDeps.tupleof[1]) == Viewport delegate()));
static assert(__traits(identifier, MeshCommandDeps.tupleof[2]) == "remeshJob_"
    && is(typeof(MeshCommandDeps.tupleof[2]) == RemeshJob));
static assert(__traits(identifier, MeshCommandDeps.tupleof[3]) == "requestRemeshOpen_"
    && is(typeof(MeshCommandDeps.tupleof[3]) == void delegate()));
static assert(__traits(identifier, MeshCommandDeps.tupleof[4]) == "promoteGeometryType_"
    && is(typeof(MeshCommandDeps.tupleof[4]) == void delegate(EditMode)));

unittest { // L3d: the all-valid control exercises every accessor first.
    size_t drops, opens;
    EditMode[] promotions;
    void drop() { ++drops; }
    Viewport snapshot() { Viewport result; result.width = 6509; return result; }
    void open() { ++opens; }
    void promote(EditMode mode) { promotions ~= mode; }
    auto job = new RemeshJob;
    auto ok = MeshCommandDeps(&drop, &snapshot, job, &open, &promote);
    ok.meshRebuildDrop()();
    const vp = ok.originSnapshot()();
    ok.requestRemeshOpen()();
    ok.promoteGeometryType()(EditMode.Edges);
    assert(drops == 1 && vp.width == 6509 && ok.remeshJob() is job
        && opens == 1 && promotions == [EditMode.Edges],
        "6509 floor: the all-valid roster must hold and expose every member");
    assertThrown!AssertError(MeshCommandDeps(
        cast(void delegate()) null, &snapshot, job, &open, &promote));
    assertThrown!AssertError(MeshCommandDeps(
        &drop, cast(Viewport delegate()) null, job, &open, &promote));
    assertThrown!AssertError(MeshCommandDeps(&drop, &snapshot, null, &open, &promote));
    assertThrown!AssertError(MeshCommandDeps(
        &drop, &snapshot, job, cast(void delegate()) null, &promote));
    assertThrown!AssertError(MeshCommandDeps(
        &drop, &snapshot, job, &open, cast(void delegate(EditMode)) null));
}

unittest {
    const code = blankNonCode(readText(buildPath(repoRoot, "source",
        "mesh_command_registration.d")));
    const ctorBody = bodyAt(code,
        "this(void delegate() meshRebuildDrop, Viewport delegate() originSnapshot,");
    assert(ctorBody.length > 400,
        format("6509 ctor-body floor: constructor body read as %d bytes",
            ctorBody.length));
    size_t rosterRows;
    static foreach (member; [__traits(allMembers, MeshCommandDeps)]) {{
        static if (member != "__ctor" && member[$ - 1] != '_') {
            ++rosterRows;
            assert(identifierCount(ctorBody, member ~ "_") == 1,
                "6509 storage: constructor field `" ~ member
              ~ "_` must occur exactly once");
            assert(countOccurrences(ctorBody,
                    member ~ "_ = " ~ member ~ ";") == 1,
                "6509 storage: constructor does not assign `" ~ member
              ~ "_` from its own parameter exactly once");
            assert(countOccurrences(bodyAt(code, member ~ "()"),
                    "return " ~ member ~ "_;") == 1,
                "6509 storage: accessor `" ~ member
              ~ "()` does not return its own field");
        }
    }}
    assert(rosterRows == 5, "6509 storage population: expected five members");
}

private enum kExpectedCall = "registerMeshCommands(app.reg(), "
    ~ "LiveSessionRole(app.sessionOwner), "
    ~ "LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()), "
    ~ "MeshCommandDeps(() => dropActiveTool(ToolTransition.meshRebuildDrop), "
    ~ "&viewports.originSnapshot, app.remeshJob, "
    ~ "&remeshModalState.requestOpen, app.promoteGeometryType));";

unittest { // L4/L4b: direct composition, lambda domains, and app wiring.
    const code = blankNonCode(readText(buildPath(repoRoot, "source", "registration.d")));
    const root = bodyAt(code, "private void registerMeshFamily(EditorApp app)");
    const collapsed = collapseWhitespace(root);
    assert(countOccurrences(lambdaFree(root), "app.") == 9, format(
        "6509 composition root: the mesh root reads app dependencies %d time(s) "
      ~ "directly, expected 9 — a direct read left the argument list (most likely "
      ~ "into a lambda) or an unrecorded one was added",
        countOccurrences(lambdaFree(root), "app.")));
    assert(identifierCount(lambdaScopes(root), "app") == 0
            && countOccurrences(root, "&app.") == 0
            && countOccurrences(root, "{") == 1,
        "6509 closure: the mesh composition root reaches an EditorApp member "
      ~ "inside a lambda (expression body or block body) or through a method "
      ~ "address — the channel came back");
    assert(countOccurrences(root, "=>") == 1,
        "6509 composition root: a second expression lambda appeared in the mesh "
      ~ "root — the one permitted lambda adapts ToolTransition only");
    assert(countOccurrences(collapseWhitespace(code), kExpectedCall) == 1,
        "6509 call text: the mesh composition-root call text or its multiplicity changed");
    assert(collapsed.length > 300,
        "6509 composition-root population: root body is unexpectedly small");

    const appCode = collapseWhitespace(blankNonCode(
        readText(buildPath(repoRoot, "source", "app.d"))));
    const registerAt = appCode.indexOf("registerCommands(app);");
    immutable assignments = [
        "app.remeshModalState = remeshModalState;",
        "app.vpm = vpm;", "app.remeshJob = remeshJob;",
        "app.dropActiveTool = cast(void delegate(ToolTransition))&dropActiveTool;",
        "app.promoteGeometryType = cast(void delegate(EditMode))&promoteGeometryType;",
    ];
    foreach (assignment; assignments) {
        const wiredAt = appCode.indexOf(assignment);
        assert(countOccurrences(appCode, assignment) == 1
                && countOccurrences(appCode, "registerCommands(app);") == 1
                && wiredAt >= 0 && registerAt >= 0 && wiredAt < registerAt,
            "6509 app wiring order: dependency `" ~ assignment
          ~ "` must be wired before registerCommands(app)");
    }
}

unittest { // L5: a live production call sits above four old-path negatives.
    const code = blankNonCode(readText(buildPath(repoRoot, "source", "registration.d")));
    assert(countOccurrences(code, "registerMeshCommands(app.reg()") == 1,
        "6509 old-path floor: registration.d lost the narrow registrar call");
    foreach (needle; ["new MeshScreenSlice(", "setResolvedVpProvider",
                      "setPromoteHook", "new ToolHeadlessCommand("])
        assert(countOccurrences(code, needle) == 0,
            "6509 old path: registration.d retained " ~ needle);
}
