module tests.unit.version_gate_census_ai3d_remesh_test;

import tests.unit.census_symbols : isIdentChar;

import std.algorithm : count, sort, startsWith;
import std.array : join;
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

private string[] reachabilityPath(ref string[][string] graph,
                                  string root, string target)
{
    bool[string] seen;
    string[string] parent;
    string[] queue = [root];
    size_t head;
    seen[root] = true;
    while (head < queue.length)
    {
        const current = queue[head++];
        if (current == target)
        {
            string[] path;
            for (auto node = target; ; node = parent[node])
            {
                path = [node] ~ path;
                if (node == root) return path;
            }
        }
        if (auto next = current in graph)
            foreach (candidate; *next)
            {
                if (candidate in seen) continue;
                seen[candidate] = true;
                parent[candidate] = current;
                queue ~= candidate;
            }
    }
    return null;
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
        || moduleName == "ai3d_command_registration";
}

unittest
{
    foreach (moduleName; [
            "ai3d.job_controller", "commands.ai3d.import_result",
            "ai3d_command_registration",
        ])
        assert(isGatedTarget(moduleName), moduleName);
    foreach (moduleName; ["ai.model_adapter", "commands.mesh.bevel", "ui.panels",
            "remesh.remesh_job", "commands.mesh.remesh", "ui.remesh_modal_state"])
        assert(!isGatedTarget(moduleName), moduleName);
}

// W16-OSD production-wiring census.  The web build must make the GPU
// evaluator gate immutable, while the native build retains the one smoke-test
// writer which enables it only after comparing GPU and CPU results.  The
// dependency-graph compile later in this module is the semantic witness: if
// the app.d version gate is removed, the web arm attempts to assign this enum
// and compilation fails.
unittest
{
    const osd = readText(buildPath(repoRoot, "source", "subpatch_osd.d"));
    const app = readText(buildPath(repoRoot, "source", "app.d"));

    enum webGate = "version (web) enum bool g_osdGpuEnabled = false;\n"
                 ~ "else __gshared bool g_osdGpuEnabled = false;";
    assert(osd.count(webGate) == 1,
        format("W16-OSD evaluator gate roster changed: expected one web enum/native "
             ~ "mutable declaration, got %d", osd.count(webGate)));
    assert(osd.count("g_osdGpuEnabled ? osdc_gl_create(osd) : null") == 1,
        "W16-OSD production evaluator selection must have exactly one gate reader");

    enum nativeSmoke =
        "    version (web) {\n"
      ~ "    } else {\n"
      ~ "        import subpatch_osd : runGlEvaluatorSmokeTest, g_osdGpuEnabled;";
    assert(app.count(nativeSmoke) == 1,
        "W16-OSD app wiring must compile the GL evaluator smoke writer only on native");
    assert(app.count("g_osdGpuEnabled = true;") == 1,
        "W16-OSD native smoke must remain the sole GPU evaluator gate writer");
}

unittest
{
    auto manifest = parseJSON(readText(buildPath(repoRoot, "dub.json")));
    string[] excluded;
    string[] redundantAssimpVersionConfigs;
    size_t webConfigurations;
    foreach (configuration; manifest["configurations"].array)
    {
        if (auto versions = "versions" in configuration.object)
            foreach (version_; (*versions).array)
                if (version_.str == "BindAssimp_Static")
                    redundantAssimpVersionConfigs ~= configuration["name"].str.idup;
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
    assert(redundantAssimpVersionConfigs.length == 0,
        format("W16-DEP BindAssimp_Static must come from bindbc-assimp6:static, "
             ~ "not redundant root-configuration copies: %s",
               redundantAssimpVersionConfigs));

    foreach (config; ["web", "modeling"])
    {
        const described = execute(["bash", "-c",
                "exec dub describe --config=\"$1\" 2>/dev/null",
                "w16-dep-package-census", config],
                null, Config.none, size_t.max, repoRoot);
        assert(described.status == 0,
            format("W16-DEP dub describe --config=%s failed (status %d):\n%s",
                   config, described.status, described.output));
        auto description = parseJSON(described.output);
        string[] activeNativeOnly;
        foreach (package_; description["packages"].array)
        {
            const name = package_["name"].str;
            if (package_["active"].boolean
                    && (name == "nfde" || name == "bindbc-assimp6"))
                activeNativeOnly ~= name.idup;
        }
        activeNativeOnly.sort;
        if (config == "web")
            assert(activeNativeOnly.length == 0,
                format("W16-DEP web active package fence failed: %s",
                       activeNativeOnly));
        else
        {
            assert(activeNativeOnly == ["bindbc-assimp6", "nfde"],
                format("W16-DEP modeling positive control expected "
                     ~ "[\"bindbc-assimp6\", \"nfde\"], got %s",
                       activeNativeOnly));
            bool hasAssimpStaticVersion;
            foreach (version_; description["targets"].array[0]
                                              ["buildSettings"]["versions"].array)
                if (version_.str == "BindAssimp_Static")
                    hasAssimpStaticVersion = true;
            assert(hasAssimpStaticVersion,
                "W16-DEP modeling must inherit BindAssimp_Static from "
              ~ "bindbc-assimp6:static");
        }
    }

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
python3 tools/ci/dmd_with_dub_flags.py "$flags" -deps="$3" -o- -c $(find source -name '*.d' -print)
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
            format("W16-A %s dependency graph did not compile (status %d). "
                 ~ "After W16-DEP removes native-only packages from web, this "
                 ~ "usually means an unguarded bindbc.assimp or nfde import:\n%s",
                   config, run.status, run.output));
        assert(exists(depsPath),
            format("W16-A dmd -deps produced no %s dependency file", config));
    }

    auto webGraph = readDependencyGraph(webDepsPath);

    enum subjects = [
        "app", "editor_app", "http_providers", "mesh_command_registration",
        "registration", "ui.panels",
    ];
    bool[string] subjectSet;
    foreach (subject; subjects) subjectSet[subject] = true;

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
    }

    string[] leaks;
    foreach (subject; subjects)
        if (subject in leakSet) leaks ~= subject;
    leaks.sort;
    const gatedModulesSeen = importersSeen.length;

    assert(webGraph.edgeCount > 0,
        "W15-D+D2 parsed zero dmd -deps edges; an empty graph makes every closure clean");
    assert(gatedModulesSeen == 6,
        format("W15-D+D2 gated-module population changed: expected 6 composition modules, got %d",
               gatedModulesSeen));
    assert(leaks.length == 0,
        format("W15-D+D2 web graph still has direct ai3d edges: %s", leaks));

    bool[string] appClosure;
    foreach (moduleName; webGraph.ours.byKey)
        if (reaches(webGraph.edges, "app", moduleName)) appClosure[moduleName] = true;
    enum appClosurePopulationFloor = 500;
    assert(appClosure.length >= appClosurePopulationFloor,
        format("W16-A web app-closure population fell below the non-vacuity floor %d: got %d; "
             ~ "this floor is not a W16-A dependency witness",
               appClosurePopulationFloor, appClosure.length));
    foreach (moduleName; ["remesh.remesh_job", "remesh.region_stitch",
            "commands.mesh.remesh", "ui.remesh_modal_state"])
        assert(moduleName in appClosure,
            "web quad-remesh module absent from production app closure: " ~ moduleName);

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
    enum forbiddenWebModules = [
        "bindbc.assimp",
        "nfde",
        "std.parallelism",
        "std.socket",
    ];
    string[] reachableForbidden;
    string[] forbiddenPaths;
    foreach (forbidden; forbiddenWebModules)
        if (reaches(webGraph.edges, "app", forbidden))
        {
            reachableForbidden ~= forbidden;
            forbiddenPaths ~= reachabilityPath(webGraph.edges, "app", forbidden).join(" > ");
        }

    string[] webThreadEdges;
    foreach (moduleName; appClosure.byKey)
        foreach (target; webGraph.edges[moduleName])
            if (target.startsWith("core.thread"))
                webThreadEdges ~= moduleName ~ ">" ~ target;
    webThreadEdges.sort;
    assert(reachableForbidden.length == 0,
        format("W16-A web app closure reaches forbidden modules: %s; paths: %s; "
             ~ "project core.thread* edges: %s",
               reachableForbidden, forbiddenPaths, webThreadEdges));
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

    version (SanitizerSelfTest) {
        // The instrumented nightly runs this unittest in an LDC-only DUB_HOME.
        // This nested host probe links with dmd, so DUB supplies LDC-built
        // archives (dyaml among them) and the link fails before the probe can
        // exercise web transport. The regular dmd module lane and browser lane
        // run the probe; all graph and source checks above still run here.
    } else {
    enum webProbeSource = q"PROBE
module w16_a_web_inproc_probe;
import commands.file.load : FileLoad;
import commands.file.save : FileSave;
import document : Document;
import editmode : EditMode;
import http_server : HttpServer, InProcessHttpTransport;
import io.assimp_runtime : initAssimp, isAssimpAvailable, shutdownAssimp;
import io.scene_export : exportDocumentViaAssimp, exportViaAssimp;
import io.scene_import : importViaAssimp;
import io.scene_ir : ImportedScene;
import mesh : makeCube, Mesh;
import std.file : exists, remove;
import std.format : format;
import std.stdio : writefln;
import tsan_annotate : parallelForWithCompletion;
import ui.action_menu : popupActionNeedsAssimp;
import view : View;
// Host-compiled web probe: model an absent browser Assimp module at the JS
// boundary. These symbols are supplied by web/lib/assimp_bridge.js in wasm.
extern(C) int vibe3d_web_assimp_available() nothrow @nogc { return 0; }
extern(C) int vibe3d_web_assimp_import(const(char)*, void**, uint*) { return 0; }
extern(C) void vibe3d_web_assimp_free(void*) {}
extern(C) int vibe3d_web_assimp_export(const(ubyte)*, uint,
                                      const(char)*, const(char)*) { return 0; }
void main(string[] args)
{
    bool[] visited = new bool[](4097);
    void markVisited(size_t idx) { visited[idx] = true; }
    parallelForWithCompletion!markVisited(visited.length);
    size_t visitCount;
    foreach (wasVisited; visited) if (wasVisited) ++visitCount;
    assert(visited.length > 4096 && visitCount == 4097,
        format("W16-P web-config loop runner index coverage changed: expected "
             ~ "4097 visited indices above the mesh threshold, got %d", visitCount));

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

    initAssimp();
    assert(!isAssimpAvailable(),
        "W16-DEP web runtime must report assimp unavailable");
    ImportedScene scene;
    Mesh mesh;
    auto document = Document.bootstrap(makeCube());
    assert(!importViaAssimp("probe.obj", scene),
        "W16-DEP web assimp import stub must refuse");
    assert(!exportViaAssimp(mesh, "probe.obj", "obj"),
        "W16-DEP web mesh export stub must refuse");
    assert(!exportDocumentViaAssimp(document, "probe.obj", "obj"),
        "W16-DEP web document export stub must refuse");

    assert(args.length == 2, "W16-DEP web probe needs one output path");
    const path = args[1];
    if (exists(path)) remove(path);
    scope (exit) if (exists(path)) remove(path);
    auto view = new View(0, 0, 800, 600);
    auto save = new FileSave(document.activeMesh(), view, EditMode.Vertices,
                             &document);
    save.setPath(path);
    const saveApplied = save.apply();
    assert(!saveApplied && !exists(path),
        "W16-DEP web FileSave(.obj) must refuse without creating a file");

    size_t decoderBlocked;
    foreach (id; ["file.export.obj", "file.import.gltf"])
    {
        const blocked = popupActionNeedsAssimp(id) && !isAssimpAvailable();
        assert(blocked,
            format("W16-DEP web action must be disabled without assimp: %s", id));
        decoderBlocked += blocked;
    }

    auto load = new FileLoad(document.activeMesh(), view, EditMode.Vertices,
                             &document);
    load.setPath(path);
    const loadApplied = load.apply();
    assert(!loadApplied,
        "W16-DEP web FileLoad(.obj) must refuse without assimp");
    assert(load.refusalReason() ==
            path ~ " — assimp import is unavailable in this build",
        format("W16-DEP web FileLoad(.obj) refusal drifted: %s",
               load.refusalReason()));
    shutdownAssimp();
    writefln("W16-DEP web assimp surface: saveApplied=%s fileExists=%s "
             ~ "decoderBlocked=%d loadApplied=%s",
             saveApplied, exists(path), decoderBlocked, loadApplied);
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
dmd -i=-bindbc.sdl -i=-sdl -i -debug \
  @"$out/import-paths.txt" -I=. @"$out/versions.txt" \
  @"$out/dflags.txt" @"$out/string-import-paths.txt" \
  $(tr '\n' ' ' < "$out/linker-files.txt") \
  @"$out/libs.txt" @"$out/lflags.txt" \
  $(tr '\n' ' ' < "$out/objs.txt") \
  -of="$out/probe" "$2"
"$out/probe" "$out/blocked.obj"
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
    assert(webProbe.output.indexOf(
            "W16-DEP web assimp surface: saveApplied=false fileExists=false "
          ~ "decoderBlocked=2 loadApplied=false") >= 0,
        format("W16-DEP web assimp surface lost its exact success witness:\n%s",
               webProbe.output));
    }

    const editorApp = readText(buildPath(repoRoot, "source", "editor_app.d"));
    assert(editorApp.indexOf("version (web) {\n    enum bool kGenerateAiAvailable = false;\n}") >= 0,
        "W15-D web builds must keep the AI generation action unavailable");
    assert(editorApp.indexOf("version (web) {\n} else {\nstruct Ai3dModalState") >= 0,
        "W15-D web builds must compile out the native AI modal state");

    // All five dependency checks now run in both browser and native builds.
    const meshRegistration = readText(buildPath(repoRoot, "source",
        "mesh_command_registration.d"));
    enum sharedMeshDepsChecks =
        "        assert(meshRebuildDrop !is null,\n"
      ~ "            \"6509 mesh registration requires a rebuild drop door\");\n"
      ~ "        assert(originSnapshot !is null,\n"
      ~ "            \"6509 mesh registration requires a resolved viewport provider\");\n"
      ~ "        assert(promoteGeometryType !is null,\n"
      ~ "            \"6509 mesh registration requires the geometry promote door\");\n"
      ~ "        assert(remeshJob !is null,\n"
      ~ "            \"6509 mesh registration requires the remesh job\");\n"
      ~ "        assert(requestRemeshOpen !is null,\n"
      ~ "            \"6509 mesh registration requires the remesh open door\");";
    assert(meshRegistration.indexOf(sharedMeshDepsChecks) >= 0,
        "web/native remesh dependency checks left the shared constructor");
}
