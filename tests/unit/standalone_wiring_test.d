module tests.unit.standalone_wiring_test;

import tests.unit.census_symbols : readText = wave15ReadText;
import std.path : dirName, buildPath;
import std.string : count, indexOf;
import tests.unit.census_symbols : blankNonCode, balancedSpan;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private string file(string path) { return readText(buildPath(repoRoot, path)); }
private string body(string code, string declaration) {
    auto offset = code.indexOf(declaration);
    assert(offset >= 0 && code.count(declaration) == 1,
        "standalone-wiring: unique production declaration " ~ declaration);
    auto open = code[offset .. $].indexOf('{');
    assert(open >= 0, "standalone-wiring: declaration has actual body");
    return balancedSpan(code, cast(size_t)offset + cast(size_t)open, '{', '}');
}

private string rawBody(string source, string declaration) {
    const code = blankNonCode(source);
    const span = body(code, declaration);
    const offset = code.indexOf(declaration);
    const begin = cast(size_t)offset + cast(size_t)code[offset .. $].indexOf('{');
    return source[begin .. begin + span.length];
}

unittest {
    const runner = file("run_test.d");
    const digest = rawBody(runner, "string sourceDigest()");
    assert(digest.count("foreach (scanSourceRoot; [\"libraries/viewport/camera/source\", \"libraries/viewport/camera/tests/source\", \"packages/document-channels/source\", \"packages/document-channels/tests/source\", \"libraries/documents/image-codec/source\", \"libraries/documents/image-codec/tests/source\", \"packages/document-io/source\", \"packages/document-io/tests/source\", \"source\", \"packages/command-runtime/source\", \"packages/application-core/source\", \"libraries/documents/model/source\", \"libraries/editing/params/source\", \"packages/pipe-runtime/source\", \"libraries/mesh/ops/source\", \"packages/interchange/source\", \"packages/interaction-query/source\", \"packages/pipe-evaluation/source\", \"packages/tool-state/source\", \"packages/transform-ops/source\", \"packages/creation-ops/source\", \"packages/alignment-ops/source\", \"libraries/platform/input/source\", \"packages/display-policy/source\", \"packages/viewport-gpu/source\", \"packages/subpatch-preview/source\", \"libraries/editing/contracts/source\", \"libraries/mesh/change/source\", \"libraries/mesh/contracts/source\", \"libraries/mesh/edit-log/source\", \"libraries/mesh/edit-replay/source\", \"libraries/mesh/snapshot/source\", \"libraries/mesh/topology/source\", \"libraries/mesh/core/source\", \"libraries/util/profiling/source\", \"libraries/util/spatial/source\", \"libraries/util/log/source\", \"util/math/source\", \"libraries/util/parallel/source\", \"libraries/util/plane-bytes/source\", \"libraries/util/screen-buckets/source\", \"libraries/editing/pipeline/contracts/source\", \"libraries/mesh/preview/source\", \"libraries/util/json-number/source\", \"packages/selection-model/source\", \"packages/scene-query/source\", \"packages/editor-commands/source\"])") == 1
        && digest.count("dirEntries(scanSourceRoot == \"util/math/source\" ? mathRoot ~ \"/source\" : scanSourceRoot, pattern, SpanMode.depth)") == 1,
        "standalone-wiring: freshness scans all forty-three production ownership roots plus four explicit test roots");
    foreach (carrier; [
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
    ])
        assert(digest.count(carrier) == 1, "standalone-wiring: exact extracted source freshness input " ~ carrier);
    const library = rawBody(runner, "string buildProjectLib(string scratch)");
    assert(library.count("\" --root=packages/tool-state\"") == 1,
        "standalone-wiring: suite unittest source grant tool-state");
    assert(library.count("\" --root=packages/transform-ops\"") == 1,
        "standalone-wiring: suite unittest source grant transform-ops");
    assert(library.count("\" :input-events\"") == 1,
        "standalone-wiring: suite unittest source grant input-events");
    assert(library.count("\" --root=packages/display-policy\"") == 1,
        "standalone-wiring: suite unittest source grant display-policy");
    assert(library.count("\" --root=packages/viewport-gpu\"") == 1,
        "standalone-wiring: suite unittest source grant viewport-gpu");
    assert(library.count("\" --root=packages/subpatch-preview\"") == 1,
        "standalone-wiring: suite unittest source grant subpatch-preview");
    assert(library.count("foreach (root; [\"\", \" :camera-model\", \" --root=packages/document-channels\", \" :image-codec\", \" --root=packages/document-io\", \" --root=packages/command-runtime\", \" --root=packages/application-core\", \" :document-model\", \" :param-schema\", \" --root=packages/pipe-runtime\", \" :json-number\", \" :pipe-contracts\", \" :mesh-preview\", \" :mesh-ops\", \" --root=packages/tool-state\", \" --root=packages/transform-ops\", \" :input-events\", \" --root=packages/display-policy\", \" --root=packages/viewport-gpu\", \" --root=packages/subpatch-preview\", \" --root=packages/selection-model\", \" --root=packages/scene-query\", \" --root=packages/editor-commands\"])") == 1
        && library.count(" --config=modeling --data=source-files --data-list 2>/dev/null") == 1,
        "standalone-wiring: suite selects exactly twenty-three modeling source inventories");
    const harvest = rawBody(runner, "void harvestSourceFlags()");
    foreach (call; [
        "gather(\"import-paths\",        \"-I=\", true)",
        "gather(\"string-import-paths\", \"-J=\", true)",
        "gather(\"versions\",            \"-version=\", true)",
        "gather(\"dflags\",               \"\", true)",
    ])
        assert(harvest.count(call) == 1,
            "standalone-wiring: typed compiler flag harvest " ~ call);
    assert(rawBody(harvest, "string gather(").count("if (compileArgs) g_compileArgs ~= prefix ~ s;") == 1,
        "standalone-wiring: harvested compiler operands enter typed vector");
    assert(harvest.count("g_compileArgs ~= extraCompileFlags.split;") == 1,
        "standalone-wiring: explicit test compiler flags enter typed vector");
    assert(library.count("harvestSourceFlags();\n    auto args = [\"-lib\", \"-unittest\"] ~ g_compileArgs ~ srcs ~ [\"-of=\" ~ lib];") == 1,
        "standalone-wiring: suite orders library/unittest flags, typed flags, selected sources and output");
    const serialization = rawBody(library, "foreach (arg; args)");
    assert(library.count("auto response = appender!string;") == 1
        && serialization.count("auto value = arg;") == 1
        && serialization.count("response.put(c);") == 1
        && serialization.count("response.put(\"\\\"\\n\");") == 1,
        "standalone-wiring: response serializes every compiler operand");
    assert(library.count("std.file.write(rsp, response.data);") == 1,
        "standalone-wiring: suite publishes serialized compiler response");
    assert(library.count("auto r = executeShell(escapeShellCommand([\"dmd\", \"@\" ~ rsp]) ~ \" 2>&1\");") == 1
        && library.indexOf("std.file.write(rsp, response.data);") < library.indexOf("auto r = executeShell("),
        "standalone-wiring: actual compiler consumes published response");
}

unittest {
    auto owner = blankNonCode(file("packages/application-core/source/standalone_application.d"));
    auto ctor = body(owner, "this(Document loadedDocument)");
    assert(ctor.count("session_ = Session.create(loadedDocument);") == 1
        && ctor.count("registry_.bindSelTypeAuthority(() => session_.selTypeOrder.current());") == 1
        && ctor.indexOf("registry_.bindSelTypeAuthority(") < ctor.indexOf("registerMeshSelectionCommand("),
        "standalone-wiring: authority bound before shared pilot registration");
    assert(ctor.count("registerMeshSelectionCommand(registry_, deps);") == 1
        && ctor.count("registerTripleCommand(registry_, deps);") == 1
        && ctor.count("registerHistoryNavigationCommands(registry_, deps, history_);") == 1
        && ctor.count("service_ = new CommandInvocationService(registry_, executor_, history_);") == 1
        && owner.count("CommandRegistry registry_;") == 1,
        "standalone-wiring: one owned registry and common factories/service");
    foreach (type; ["MeshTriple", "MeshSelect", "HistoryUndo", "HistoryRedo"])
        assert(owner.count("new " ~ type ~ "(") == 0,
            "standalone-wiring: second pilot constructor " ~ type);
    assert(body(owner, "ref Mesh liveMesh()").count("return session_.editMesh();") == 1
        && body(owner, "ref View liveView()").count("return view_;") == 1
        && ctor.count("deps.activeMesh = &liveMesh;") == 1
        && ctor.count("deps.view = &liveView;") == 1
        && ctor.count("noteMeshChange(address, flags);") == 1
        && ctor.count("session_.editMesh().syncSelection();") == 1
        && ctor.count("session_.editMesh().publishChange(MeshChangeAll);") == 1,
        "standalone-wiring: live factories and actual model subscriber");
    auto targetPublication = body(ctor, "if (session_.document.hasEditTarget())");
    assert(ctor.count("changeBus = ChangeBus.init;") == 1
        && owner.count("changeBus = ChangeBus.init;") == 1
        && ctor.indexOf("changeBus = ChangeBus.init;") < ctor.indexOf("registerMeshSelectionCommand(")
        && targetPublication.count("session_.editMesh().syncSelection();") == 1
        && targetPublication.count("session_.editMesh().publishChange(MeshChangeAll);") == 1,
        "standalone-wiring: single incoming bus init and target-guarded publication");
    auto invoke = body(owner, "CommandInvocationResult invoke(");
    assert(invoke.count("return service_.invokeLine(id, paramsJson,") == 1
        && invoke.count("CommandInvocationContext(CommandOrigin.script, false)") == 1,
        "standalone-wiring: production wrapper dispatches script through service");
    auto cli = blankNonCode(file("tools/cli/source/main.d"));
    auto main = body(cli, "int main(string[] args)");
    auto observer = body(cli, "private void snapshot(");
    auto save = body(cli, "private void save(");
    assert(main.count("readV3d(flags.input, loaded)") == 1
        && main.indexOf("readV3d(flags.input, loaded)") < main.indexOf("host = new StandaloneApplication(loaded);")
        && main.count("host = new StandaloneApplication(loaded);") == 1
        && main.count("host.invoke(id.str,") == 1
        && observer.count("host.state()") == 1
        && observer.count("diagnostic.flush();") == 1
        && main[main.indexOf("auto result = host.invoke(") .. $].count("snapshot(diagnostic, host,") == 3,
        "standalone-wiring: real CLI owner supplies post-invocation state file");
    assert(save.count("writeV3d(host.document, temporary)") == 1
        && save.count("readV3d(temporary, reopened)") == 1
        && save.count("rename(temporary, output);") == 1
        && save.count("buildPath(dirName(output),") == 1
        && save.indexOf("writeV3d(") < save.indexOf("readV3d(")
        && save.indexOf("readV3d(") < save.indexOf("rename("),
        "standalone-wiring: same-directory production write/reopen/atomic rename");
}
