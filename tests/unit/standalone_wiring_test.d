module tests.unit.standalone_wiring_test;
import std.file : readText;
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
    assert(digest.count("foreach (scanSourceRoot; [\"source\", \"packages/common/source\", \"packages/mesh-ops/source\", \"packages/interchange/source\", \"packages/interaction-query/source\", \"packages/pipe-evaluation/source\", \"packages/tool-state/source\", \"packages/transform-ops/source\", \"packages/creation-ops/source\", \"packages/alignment-ops/source\", \"packages/input-events/source\", \"packages/display-policy/source\", \"packages/viewport-gpu/source\", \"packages/subpatch-preview/source\"])") == 1
        && digest.count("dirEntries(scanSourceRoot, pattern, SpanMode.depth)") == 1,
        "standalone-wiring: freshness scans all fourteen production ownership roots");
    const library = rawBody(runner, "string buildProjectLib(string scratch)");
    assert(library.count("\" --root=packages/tool-state\"") == 1,
        "standalone-wiring: suite unittest source grant tool-state");
    assert(library.count("\" --root=packages/transform-ops\"") == 1,
        "standalone-wiring: suite unittest source grant transform-ops");
    assert(library.count("\" --root=packages/input-events\"") == 1,
        "standalone-wiring: suite unittest source grant input-events");
    assert(library.count("\" --root=packages/display-policy\"") == 1,
        "standalone-wiring: suite unittest source grant display-policy");
    assert(library.count("foreach (root; [\"\", \" --root=packages/common\", \" --root=packages/tool-state\", \" --root=packages/transform-ops\", \" --root=packages/input-events\", \" --root=packages/display-policy\"])") == 1
        && library.count(" --config=modeling --data=source-files --data-list 2>/dev/null") == 1
        && library.count("dmd -lib -unittest%s %s -of=%s 2>&1") == 1
        && library.count("sourceCompileFlags(), srcs.join(\" \"), lib") == 1,
        "standalone-wiring: suite compiles exactly six source inventories under unittest flags");
}

unittest {
    auto owner = blankNonCode(file("packages/common/source/standalone_application.d"));
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
