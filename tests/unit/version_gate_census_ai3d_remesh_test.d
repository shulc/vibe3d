module tests.unit.version_gate_census_ai3d_remesh_test;

import tests.unit.census_symbols : isIdentChar;

import std.algorithm : sort, startsWith;
import std.file : exists, readText, remove, tempDir, write;
import std.format : format;
import std.json : parseJSON;
import std.path : buildPath, dirName;
import std.process : Config, execute, thisProcessID;
import std.string : indexOf, splitLines, strip;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private bool reaches(ref string[][string] graph, string root, string target)
{
    bool[string] seen;
    string[] queue = [root];
    size_t head;
    while (head < queue.length)
    {
        const current = queue[head++];
        if (current in seen) continue;
        seen[current] = true;
        if (current == target) return true;
        if (auto next = current in graph) queue ~= *next;
    }
    return false;
}

private struct DependencyGraph
{
    string[][string] edges;
    bool[string] ours;
    size_t edgeCount;
}

private DependencyGraph readDependencyGraph(string path)
{
    DependencyGraph result;
    foreach (line; readText(path).splitLines)
    {
        const first = line.indexOf(" : ");
        if (first < 0) continue;
        const tail = line[cast(size_t) first + 3 .. $];
        const secondRel = tail.indexOf(" : ");
        if (secondRel < 0) continue;

        const importerField = line[0 .. cast(size_t) first];
        const importerEnd = importerField.indexOf(" (");
        if (importerEnd < 0) continue;
        const targetField = tail[cast(size_t) secondRel + 3 .. $];
        size_t targetEnd;
        while (targetEnd < targetField.length
               && (isIdentChar(targetField[targetEnd])
                   || targetField[targetEnd] == '.'))
            ++targetEnd;
        if (targetEnd == 0) continue;

        const importer = importerField[0 .. cast(size_t) importerEnd];
        const target = targetField[0 .. targetEnd];
        result.edges[importer] ~= target;
        if (importerField.indexOf(" (source/") >= 0)
            result.ours[importer] = true;
        ++result.edgeCount;
    }
    return result;
}

private string declaredModule(string path)
{
    foreach (line; readText(path).splitLines)
    {
        const trimmed = line.strip;
        if (!trimmed.startsWith("module ")) continue;
        const end = trimmed.indexOf(';');
        assert(end > 7, format("module declaration has no name in %s", path));
        return trimmed[7 .. cast(size_t) end].idup;
    }
    assert(false, format("source file has no module declaration: %s", path));
    return null;
}

private bool isGatedTarget(string moduleName)
{
    return moduleName.startsWith("ai3d.")
        || moduleName.startsWith("commands.ai3d.")
        || moduleName == "ai3d_command_registration"
        || moduleName.startsWith("remesh.")
        || moduleName == "commands.mesh.remesh"
        || moduleName == "ui.remesh_modal_state";
}

unittest
{
    foreach (moduleName; [
            "ai3d.job_controller", "commands.ai3d.import_result",
            "ai3d_command_registration", "remesh.remesh_job",
            "commands.mesh.remesh", "ui.remesh_modal_state",
        ])
        assert(isGatedTarget(moduleName), moduleName);
    foreach (moduleName; ["ai.model_adapter", "commands.mesh.bevel", "ui.panels"])
        assert(!isGatedTarget(moduleName), moduleName);
}

unittest
{
    auto manifest = parseJSON(readText(buildPath(repoRoot, "dub.json")));
    string[] excluded;
    size_t webConfigurations;
    foreach (configuration; manifest["configurations"].array)
    {
        if (configuration["name"].str != "web") continue;
        ++webConfigurations;
        if (auto paths = "excludedSourceFiles" in configuration.object)
            foreach (path; (*paths).array) excluded ~= path.str.idup;
    }
    excluded.sort;
    string[] expectedClassB = [
        "source/ai3d/job_controller.d",
        "source/ai3d/stage_artifact.d",
        "source/ai3d/worker_manager.d",
        "source/ai3d_command_registration.d",
        "source/commands/ai3d/generate.d",
        "source/commands/ai3d/generate_test_hooks.d",
    ];
    expectedClassB.sort;
    enum expectedWebConfigurations = 1;
    assert(webConfigurations == expectedWebConfigurations,
        format("W16-A web configuration population changed: expected %d, got %d",
               expectedWebConfigurations, webConfigurations));
    assert(excluded == expectedClassB,
        format("W16-A web excludedSourceFiles must equal class B: expected %s, got %s",
               expectedClassB, excluded));

    const webDepsPath = buildPath(tempDir(),
        format("vibe3d-w16-a-web-deps-%d.txt", thisProcessID()));
    const nativeDepsPath = buildPath(tempDir(),
        format("vibe3d-w16-a-native-deps-%d.txt", thisProcessID()));
    const describeErrorPath = buildPath(tempDir(),
        format("vibe3d-w16-a-describe-%d.txt", thisProcessID()));
    const webProbePath = buildPath(tempDir(),
        format("vibe3d-w16-a-web-inproc-probe-%d.d", thisProcessID()));
    scope (exit)
    {
        if (exists(webDepsPath)) remove(webDepsPath);
        if (exists(nativeDepsPath)) remove(nativeDepsPath);
        if (exists(describeErrorPath)) remove(describeErrorPath);
        if (exists(webProbePath)) remove(webProbePath);
    }

    // THE KEY IS DERIVED, NOT HAND-PASSED, and that distinction is the whole point of this
    // census. An earlier form took flags from `--config=tests` and then added `-version=web`
    // itself. That witnesses the FLAG and not the BUILD: measured 2026-09-21, `web` is
    // predefined by no compiler and was in no dub version list, so every `version (web)` site
    // in the wave took the NATIVE arm on a real wasm target while a census that supplied the
    // key by hand stayed green. Reading the key out of `--config=web` makes this assert fail
    // if the configuration is ever dropped from dub.json -- which is the failure that the
    // hand-passed form could not see.
enum compileDependencyGraph = q"SH
set -o pipefail
cd "$1"
config="$4"
flags=$(dub describe --config="$config" \
    --data=import-paths,string-import-paths,versions,debug-versions \
    2>"$2")
describe_status=$?
if [ "$describe_status" -ne 0 ]; then
  cat "$2"
  echo "FATAL: W16-A dub describe --config=$config failed; closure census did not run" >&2
  exit 2
fi
if [ "$config" = web ]; then
  case " $flags " in *" -version=web "*) ;; *)
    echo "FATAL: --config=web described no -version=web; the gates would be inert" >&2; exit 2 ;;
  esac
fi
dmd -deps="$3" -o- -c $flags $(find source -name '*.d' -print)
SH";
    enum graphConfigurations = ["web", "modeling"];
    const graphPaths = [webDepsPath, nativeDepsPath];
    foreach (index, config; graphConfigurations)
    {
        const depsPath = graphPaths[index];
        const run = execute(["bash", "-c", compileDependencyGraph, "w16-a-deps",
                             repoRoot, describeErrorPath, depsPath, config],
                            null, Config.none, size_t.max, repoRoot);
        assert(run.status == 0,
            format("W16-A %s dependency graph did not compile (status %d):\n%s",
                   config, run.status, run.output));
        assert(exists(depsPath),
            format("W16-A dmd -deps produced no %s dependency file", config));
    }

    auto webGraph = readDependencyGraph(webDepsPath);

    enum subjects = [
        "app", "editor_app", "http_providers", "mesh_command_registration",
        "registration", "ui.panels",
    ];
    enum fullyGatedModules = [
        "commands.mesh.remesh", "remesh.region_stitch",
        "remesh.remesh_job", "ui.remesh_modal_state",
    ];
    bool[string] subjectSet;
    foreach (subject; subjects) subjectSet[subject] = true;
    bool[string] fullyGatedSet;
    foreach (subject; fullyGatedModules) fullyGatedSet[subject] = true;

    bool[string] importersSeen;
    bool[string] leakSet;
    foreach (importer, targets; webGraph.edges)
    {
        if (importer in subjectSet)
        {
            importersSeen[importer] = true;
            foreach (target; targets)
                if (isGatedTarget(target)) leakSet[importer] = true;
        }
        if (importer in fullyGatedSet)
            foreach (target; targets)
                if (target != "object") leakSet[importer] = true;
    }

    string[] leaks;
    foreach (subject; subjects)
        if (subject in leakSet) leaks ~= subject;
    foreach (subject; fullyGatedModules)
        if (subject in leakSet) leaks ~= subject;
    leaks.sort;
    const gatedModulesSeen = importersSeen.length;

    assert(webGraph.edgeCount > 0,
        "W15-D+D2 parsed zero dmd -deps edges; an empty graph makes every closure clean");
    assert(gatedModulesSeen == 6,
        format("W15-D+D2 gated-module population changed: expected 6 composition modules, got %d",
               gatedModulesSeen));
    assert(leaks.length == 0,
        format("W15-D+D2 web graph still has direct ai3d/remesh edges: %s; "
             ~ "removing version (web) from one use in source/ui/panels.d "
             ~ "must report [\"ui.panels\"] here", leaks));

    bool[string] appClosure;
    foreach (moduleName; webGraph.ours.byKey)
        if (reaches(webGraph.edges, "app", moduleName)) appClosure[moduleName] = true;
    enum appClosurePopulationFloor = 500;
    assert(appClosure.length >= appClosurePopulationFloor,
        format("W16-A web app-closure population fell below the non-vacuity floor %d: got %d; "
             ~ "this floor is not a W16-A dependency witness",
               appClosurePopulationFloor, appClosure.length));

    foreach (path; excluded)
    {
        const moduleName = declaredModule(buildPath(repoRoot, path));
        assert(moduleName !in appClosure,
            format("W16-A excluded class-B module remains in the web app closure: %s (%s)",
                   moduleName, path));
    }

    string[] classA;
    foreach (moduleName; appClosure.byKey)
    {
        if (moduleName != "http_transport"
                && reaches(webGraph.edges, moduleName, "http_transport"))
            classA ~= moduleName;
    }
    classA.sort;
    enum expectedClassA = [
        "app", "editor_app", "frame_runner", "http_command_adapter",
        "http_providers", "http_server", "input_frame_state", "input_router",
        "registration", "ui.panels",
    ];
    assert(reaches(webGraph.edges, "app", "http_transport"),
        "W16-A web graph lost its HTTP-router carrier; the transport census is vacuous");
    assert(classA == expectedClassA,
        format("W16-A HTTP class-A graph-shape pin changed (not a W16-A facility witness): "
             ~ "expected %s, got %s",
               expectedClassA, classA));

    // This is the one expansion point for W16-P/W16-DEP as further native-only
    // facilities are removed from the browser target.
    enum forbiddenWebModules = ["std.socket"];
    string[] reachableForbidden;
    foreach (forbidden; forbiddenWebModules)
        if (reaches(webGraph.edges, "app", forbidden)) reachableForbidden ~= forbidden;
    assert(reachableForbidden.length == 0,
        format("W16-A web app closure reaches forbidden modules: %s", reachableForbidden));

    string[] webThreadEdges;
    foreach (moduleName; appClosure.byKey)
        foreach (target; webGraph.edges[moduleName])
            if (target.startsWith("core.thread"))
                webThreadEdges ~= moduleName ~ ">" ~ target;
    webThreadEdges.sort;
    assert(webThreadEdges.length == 0,
        format("W16-A web app closure has project modules with direct core.thread* edges: %s",
               webThreadEdges));

    auto nativeGraph = readDependencyGraph(nativeDepsPath);
    bool[string] nativeAppClosure;
    foreach (moduleName; nativeGraph.ours.byKey)
        if (reaches(nativeGraph.edges, "app", moduleName))
            nativeAppClosure[moduleName] = true;
    string[] nativeMissingForbidden;
    foreach (forbidden; forbiddenWebModules)
        if (!reaches(nativeGraph.edges, "app", forbidden))
            nativeMissingForbidden ~= forbidden;
    assert(nativeMissingForbidden.length == 0,
        format("W16-A native positive control lost forbidden-module reachability: %s",
               nativeMissingForbidden));

    string[] nativeThreadEdges;
    foreach (moduleName; nativeAppClosure.byKey)
        foreach (target; nativeGraph.edges[moduleName])
            if (target.startsWith("core.thread"))
                nativeThreadEdges ~= moduleName ~ ">" ~ target;
    nativeThreadEdges.sort;
    assert(nativeThreadEdges.length > 0,
        "W16-A native positive control has no project module with a direct core.thread* edge");

    enum webProbeSource = q"PROBE
module w16_a_web_inproc_probe;
import http_server : HttpServer, InProcessHttpTransport;
import std.format : format;
import std.stdio : writefln;
void main()
{
    int calls;
    auto server = new HttpServer(0);
    server.setPathQueryProvider((float t) {
        ++calls;
        return `{"surface":"inline"}`;
    });
    server.markProvidersWired();
    server.tickAll();
    auto response = (new InProcessHttpTransport(server)).request(
        "POST", "/api/path", `{"t":0.25}`);
    writefln("W16-A web in-process transport: status=%d calls=%d body=%s",
             response.statusCode, calls, response.body);
    assert(response.statusCode == 200 && calls == 1,
        format("W16-A web in-process transport expected status=200 calls=1, "
             ~ "got status=%d calls=%d body=%s",
               response.statusCode, calls, response.body));
}
PROBE";
    write(webProbePath, webProbeSource);
    enum runWebProbe = q"SH
set -euo pipefail
cd "$1"
out=$(mktemp -d "/var/tmp/w16-a-web-probe.XXXXXX")
trap 'rm -rf "$out"' EXIT
for data in import-paths versions linker-files libs lflags source-files dflags \
            string-import-paths; do
  dub describe --config=web --data="$data" --data-list > "$out/$data.txt"
done
: > "$out/objs.txt"
while IFS= read -r source_file; do
  case "$source_file" in *.d|'') continue ;; esac
  object_file="$out/$(basename "$source_file").o"
  dmd -c @"$out/dflags.txt" -of="$object_file" "$source_file"
  printf '%s\n' "$object_file" >> "$out/objs.txt"
done < "$out/source-files.txt"
sed -i 's|^|-I=|' "$out/import-paths.txt"
sed -i 's|^|-version=|' "$out/versions.txt"
sed -i 's|^|-L-l|' "$out/libs.txt"
sed -i 's|^|-L|' "$out/lflags.txt"
sed -i 's|^|-J=|' "$out/string-import-paths.txt"
dmd -i -debug \
  @"$out/import-paths.txt" -I=. @"$out/versions.txt" \
  @"$out/dflags.txt" @"$out/string-import-paths.txt" \
  $(tr '\n' ' ' < "$out/linker-files.txt") \
  @"$out/libs.txt" @"$out/lflags.txt" \
  $(tr '\n' ' ' < "$out/objs.txt") \
  -of="$out/probe" "$2"
"$out/probe"
SH";
    const webProbe = execute(["bash", "-c", runWebProbe, "w16-a-web-probe",
                              repoRoot, webProbePath],
                             null, Config.none, size_t.max, repoRoot);
    assert(webProbe.status == 0,
        format("W16-A web in-process transport probe failed (status %d):\n%s",
               webProbe.status, webProbe.output));
    assert(webProbe.output.indexOf(
            `W16-A web in-process transport: status=200 calls=1 body={"surface":"inline"}`)
            >= 0,
        format("W16-A web in-process transport probe lost its exact success witness:\n%s",
               webProbe.output));

    const editorApp = readText(buildPath(repoRoot, "source", "editor_app.d"));
    assert(editorApp.indexOf("version (web) {\n    enum bool kGenerateAiAvailable = false;\n}") >= 0,
        "W15-D web builds must keep the AI generation action unavailable");
    assert(editorApp.indexOf("version (web) {\n} else {\nstruct Ai3dModalState") >= 0,
        "W15-D web builds must compile out the native AI modal state");

    // The three ARM-INDEPENDENT checks, and they are pinned OUTSIDE any version block on
    // purpose. The earlier form of this assert matched the same three asserts at the web
    // constructor's own indentation, which pinned them for ONE arm only; when the two
    // constructors collapsed into one behind a build-keyed alias, that exact text stopped
    // existing and the assert went red for a reason that was not a defect. Deleting it was
    // the wrong repair -- a removed check leaves no trace in a green gate -- so it is
    // re-pinned at the stronger property: these three run on EVERY arm, and only the two
    // remesh checks are gated.
    const meshRegistration = readText(buildPath(repoRoot, "source",
        "mesh_command_registration.d"));
    enum sharedMeshDepsChecks =
        "        assert(meshRebuildDrop !is null,\n"
      ~ "            \"6509 mesh registration requires a rebuild drop door\");\n"
      ~ "        assert(originSnapshot !is null,\n"
      ~ "            \"6509 mesh registration requires a resolved viewport provider\");\n"
      ~ "        assert(promoteGeometryType !is null,\n"
      ~ "            \"6509 mesh registration requires the geometry promote door\");\n"
      ~ "        version (web) {";
    assert(meshRegistration.indexOf(sharedMeshDepsChecks) >= 0,
        "W15-D2 the three arm-independent mesh dependency checks must stay OUTSIDE the "
      ~ "version block: they run on web and native alike, and the gate begins after them");
    enum gatedRemeshChecks =
        "            assert(remeshJob !is null,\n"
      ~ "                \"6509 mesh registration requires the remesh job\");\n"
      ~ "            assert(requestRemeshOpen !is null,\n"
      ~ "                \"6509 mesh registration requires the remesh open door\");";
    assert(meshRegistration.indexOf(gatedRemeshChecks) >= 0,
        "W15-D2 the two remesh dependency checks must stay INSIDE the native arm");
}
