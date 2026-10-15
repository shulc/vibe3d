// The native `-m32` target is x86, not WebAssembly. This test is deliberately only a
// WIDTH proxy: it asks the D frontend to compile the real web configuration with 32-bit
// size_t/pointers. Target-specific browser behavior belongs to the web toolchain lanes.
module tests.unit.web_width32_compile_test;

import std.algorithm : count, endsWith, startsWith, sort, canFind;
import std.array : join;
import std.file : dirEntries, exists, mkdir, readText, remove, rmdirRecurse,
    SpanMode, tempDir, write;
import std.format : format;
import std.stdio : writefln;
import std.path : buildPath, dirName;
import std.process : Config, execute, thisProcessID;
import std.string : indexOf, lastIndexOf, splitLines, strip;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private struct DepNode
{
    string moduleName;
    string path;
}

private bool parseDepNode(string field, out DepNode node)
{
    field = field.strip;
    const open = field.indexOf(" (");
    if (open < 0) return false;
    const afterOpen = cast(size_t)open + 2;
    const closeRel = field[afterOpen .. $].indexOf(')');
    if (closeRel < 0) return false;
    node.moduleName = field[0 .. cast(size_t)open];
    node.path = field[afterOpen .. afterOpen + cast(size_t)closeRel];
    return node.moduleName.length != 0 && node.path.length != 0;
}

private string errorLines(string output)
{
    string[] errors;
    foreach (line; output.splitLines)
        if (line.indexOf("Error:") >= 0)
            errors ~= line;
    return errors.length == 0 ? "(no Error lines)" : errors.join("\n");
}

unittest
{
    const stem = format("vibe3d-w16-w-width32-%d", thisProcessID());
    const depsPath = buildPath(tempDir(), stem ~ ".deps");
    const manifestPath = buildPath(tempDir(), stem ~ ".files");
    const proxyPath = buildPath(tempDir(), stem ~ "-proxy.d");
    const objectDir = buildPath(tempDir(), stem ~ "-objects");
    const describeErrorPath = buildPath(tempDir(), stem ~ ".describe-errors");
    mkdir(objectDir);
    scope (exit)
    {
        if (exists(depsPath)) remove(depsPath);
        if (exists(manifestPath)) remove(manifestPath);
        if (exists(proxyPath)) remove(proxyPath);
        if (exists(describeErrorPath)) remove(describeErrorPath);
        rmdirRecurse(objectDir);
    }

    enum inventoryWebGraph = q"SH
set -euo pipefail
cd "$1"
flags=$(dub describe --config=web \
    --data=import-paths,string-import-paths,versions,debug-versions,dflags \
    2>"$2") || { cat "$2"; exit 1; }
case " $flags " in *" -version=web "*) ;; *)
  echo "FATAL: --config=web described no -version=web; the width proxy would compile the wrong build" >&2
  exit 2
esac
mapfile -t files < <(dub describe --config=web --data=source-files --data-list \
    2>>"$2" | sed '/^$/d' | grep '\.d$')
for owner in packages/forms-model packages/editor-ui packages/camera-model packages/document-channels packages/image-codec packages/document-io packages/alignment-ops packages/command-runtime packages/application-core packages/creation-ops packages/display-policy packages/edit-contracts packages/input-events packages/interaction-query packages/interchange packages/mesh-change packages/mesh-contracts packages/mesh-edit-log packages/mesh-edit-replay packages/mesh-ops packages/selection-model packages/scene-query packages/editor-commands packages/interactive-tools packages/viewport-host packages/interaction-data packages/mesh-snapshot packages/mesh-topology packages/mesh packages/pipe-evaluation packages/profiling packages/spatial packages/subpatch-preview packages/tool-state packages/transform-ops packages/viewport-gpu util/log util/math util/parallel util/plane-bytes util/screen-buckets packages/pipe-contracts packages/mesh-preview util/json-number; do
    mapfile -t package_files < <(dub describe --root="$owner" --config=web \
        --data=source-files --data-list 2>>"$2" | sed '/^$/d' | grep '\.d$')
    files+=("${package_files[@]}")
done
# Every file is explicit. This is required by the nine command modules whose declared
# names end in `_` while their paths do not; import lookup alone cannot resolve them.
python3 tools/ci/dmd_with_dub_flags.py "$flags" -deps="$3" -o- -c "${files[@]}"
SH";
    const inventory = execute(["bash", "-c", inventoryWebGraph,
                               "w16-w-width32-inventory", repoRoot,
                               describeErrorPath, depsPath],
                              null, Config.none, size_t.max, repoRoot);
    assert(inventory.status == 0,
        format("W16-W native-width web dependency inventory failed (status %d):\n%s",
               inventory.status, inventory.output));
    string[][string] importsByModule;
    string[string] sourcePathByModule;
    const productionPrefixes = [buildPath(repoRoot, "packages/camera-model/source") ~ "/", buildPath(repoRoot, "packages/document-channels/source") ~ "/", buildPath(repoRoot, "packages/image-codec/source") ~ "/", buildPath(repoRoot, "packages/document-io/source") ~ "/", buildPath(repoRoot, "source") ~ "/", buildPath(repoRoot, "packages/alignment-ops/source") ~ "/", buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source") ~ "/", buildPath(repoRoot, "packages/creation-ops/source") ~ "/", buildPath(repoRoot, "packages/display-policy/source") ~ "/", buildPath(repoRoot, "packages/edit-contracts/source") ~ "/", buildPath(repoRoot, "packages/input-events/source") ~ "/", buildPath(repoRoot, "packages/interaction-query/source") ~ "/", buildPath(repoRoot, "packages/interchange/source") ~ "/", buildPath(repoRoot, "packages/mesh-change/source") ~ "/", buildPath(repoRoot, "packages/mesh-contracts/source") ~ "/", buildPath(repoRoot, "packages/mesh-edit-log/source") ~ "/", buildPath(repoRoot, "packages/mesh-edit-replay/source") ~ "/", buildPath(repoRoot, "packages/mesh-ops/source") ~ "/", buildPath(repoRoot, "packages/mesh-snapshot/source") ~ "/", buildPath(repoRoot, "packages/mesh-topology/source") ~ "/", buildPath(repoRoot, "packages/mesh/source") ~ "/", buildPath(repoRoot, "packages/pipe-evaluation/source") ~ "/", buildPath(repoRoot, "packages/profiling/source") ~ "/", buildPath(repoRoot, "packages/spatial/source") ~ "/", buildPath(repoRoot, "packages/subpatch-preview/source") ~ "/", buildPath(repoRoot, "packages/tool-state/source") ~ "/", buildPath(repoRoot, "packages/transform-ops/source") ~ "/", buildPath(repoRoot, "packages/viewport-gpu/source") ~ "/", buildPath(repoRoot, "util/log/source") ~ "/", buildPath(repoRoot, "util/math/source") ~ "/", buildPath(repoRoot, "util/parallel/source") ~ "/", buildPath(repoRoot, "util/plane-bytes/source") ~ "/", buildPath(repoRoot, "util/screen-buckets/source") ~ "/", buildPath(repoRoot, "packages/pipe-contracts/source") ~ "/", buildPath(repoRoot, "packages/mesh-preview/source") ~ "/", buildPath(repoRoot, "util/json-number/source") ~ "/",
        buildPath(repoRoot, "packages/selection-model/source"),
        buildPath(repoRoot, "packages/scene-query/source"),
        buildPath(repoRoot, "packages/editor-commands/source"),
        buildPath(repoRoot, "packages/interactive-tools/source"),
        buildPath(repoRoot, "packages/viewport-host/source"),
        buildPath(repoRoot, "packages/interaction-data/source"),
        buildPath(repoRoot, "packages/ai-advisor/source") ~ "/",
        buildPath(repoRoot, "packages/ai3d-runtime/source") ~ "/",
        buildPath(repoRoot, "packages/document-actions/source") ~ "/",
        buildPath(repoRoot, "packages/http-runtime/source") ~ "/",
        buildPath(repoRoot, "packages/platform-file/source") ~ "/",
        buildPath(repoRoot, "packages/remesh-runtime/source") ~ "/",
        buildPath(repoRoot, "packages/forms-model/source") ~ "/",
        buildPath(repoRoot, "packages/editor-ui/source") ~ "/"];

    foreach (line; readText(depsPath).splitLines)
    {
        const first = line.indexOf(" : ");
        if (first < 0) continue;
        const tail = line[cast(size_t)first + 3 .. $];
        const secondRel = tail.indexOf(" : ");
        if (secondRel < 0) continue;

        DepNode importer, imported;
        if (!parseDepNode(line[0 .. cast(size_t)first], importer)) continue;
        if (!parseDepNode(tail[cast(size_t)secondRel + 3 .. $], imported)) continue;
        importsByModule[importer.moduleName] ~= imported.moduleName;
        foreach (node; [importer, imported])
            if (productionPrefixes.canFind!(prefix => node.path.startsWith(prefix)) && node.path.endsWith(".d"))
                sourcePathByModule[node.moduleName] = node.path;
    }
    bool[string] reached;
    string[] pending = ["app"];
    reached["app"] = true;
    while (pending.length != 0)
    {
        const current = pending[$ - 1];
        pending.length--;
        auto dependencies = current in importsByModule;
        if (dependencies !is null)
            foreach (dependency; *dependencies)
                if (dependency !in reached)
                {
                    reached[dependency] = true;
                    pending ~= dependency;
                }
    }

    string[] closurePaths;
    foreach (moduleName; reached.byKey)
    {
        auto path = moduleName in sourcePathByModule;
        if (path !is null)
        {
            closurePaths ~= *path;
        }
    }
    string[] selectedModules;
    foreach (moduleName; reached.byKey)
        if ((moduleName in sourcePathByModule) !is null) selectedModules ~= moduleName;
    sort(selectedModules);
    write(buildPath(tempDir(), stem ~ ".modules"), selectedModules.join("\n") ~ "\n");
    const baseline = readText(buildPath(repoRoot, "tests", "unit",
        "web_width32_baseline_modules.txt")).strip.splitLines;
    assert(baseline.length == 568, "web compiler baseline manifest population");
    // 20262940: the historical identities stay fixed; the approved borrowed role is current-only.
    enum currentOnlyModules = ["ui.panel_host_roles"];
    const expectedCurrentModules = baseline ~ currentOnlyModules;
    string[] added, removed;
    foreach (name; selectedModules) if (!expectedCurrentModules.canFind(name)) added ~= name;
    foreach (name; expectedCurrentModules) if (!selectedModules.canFind(name)) removed ~= name;
    assert(added.length == 0 && removed.length == 0,
        format("web compiler selected-set delta: added=%s removed=%s members=%s", added, removed, selectedModules));
    // Measured on the current W16 LD+B12 stack at
    // b777bc26e50e45da10f70889fed2d1ada5891237. This is the population floor:
    // successful dmd over fewer (or zero) files must not masquerade as a clean width pass.
    // Task 20261660: the compiler-selected web closure adds model_preview (+1).
    // Task 20261720: three literal-preserving lower-owner modules join the closure.
    // Wave8: all555 prior identities retained, eleven split-owner identities added;
    // mapping and actual native inventory: doc/application_layers_wave8_d_acceptance_fix_2026-10-10.md.
    // Wave5 compiler witness adds surface_pick, toolpipe.state_paths, workplane_basis.
    // Wave6A: the existing kernel reaches its extracted cluster_values leaf (+1).
    // Wave9 fixed mapping retains all566 identities and adds morph_preview/mesh_ops.triangulate.
    enum expectedWebModules = 568 + currentOnlyModules.length; // Wave15 retains the frozen web identities; the test-only drag helper was never in this baseline. // +1 task 9504 evaluated_move_weld; +1 task 9449 tools.edit.haul_axis_latch; -1 task 9525 tools.edit.drag_weld; +1 task 9492 tool_attr_bounds; -5 wave-2 PRM2: five more param-update owner modules folded; +1 task 9429 tools.topology_step; -10 wave-2 PRM1: eleven param-update owner modules became one; +1 pen S1 tools.create.pen_geometry; +4: remesh job, stitch, command and modal state; +1 M5 toolpipe.attr_cache; +1 viewport_probe_sampling; +3 retopology S4 light_rig, retopology_line_shade, retopology_dot_cull; +1 retopology S5 retopology_order; +1 viewport shading S1a vertex_normals; +1 viewport shading SP gpu_pass_timer; +1 viewport shading S2b viewport_composite; +1 viewport shading S1e commands.mesh.surface_attr; +1 viewport shading S4b viewport_env
    assert(closurePaths.length == expectedWebModules,
        format("W16-W web closure population changed: expected %d source modules to reach "
             ~ "the 32-bit compiler, got %d", expectedWebModules, closurePaths.length));

    sort(closurePaths);
    write(manifestPath, closurePaths.join("\n") ~ "\n");
    enum compileWidthProxy = q"SH
set -euo pipefail
cd "$1"
flags=$(dub describe --config=web \
    --data=import-paths,string-import-paths,versions,debug-versions,dflags \
    2>"$2") || { cat "$2"; exit 1; }
mapfile -t files < "$3"
unittestImports=()
if [[ ${6:-} == "-unittest" ]]; then
    unittestImports=(-Ipackages/interactive-tools/tests/source -Ipackages/viewport-host/tests/source)
fi
python3 tools/ci/dmd_with_dub_flags.py "$flags" -v -m32 ${6:+"$6"} "${unittestImports[@]}" -o- -c -od="$5" "${files[@]}" "$4"
SH";

    size_t[string] rootsExpected;
    foreach (moduleName; reached.byKey)
        if ((moduleName in sourcePathByModule) !is null)
        {
            const dot = moduleName.lastIndexOf('.');
            const shortName = dot < 0
                ? moduleName : moduleName[cast(size_t) dot + 1 .. $];
            ++rootsExpected.require(shortName, 0);
        }
    ++rootsExpected.require("w16_w_width_proxy", 0);

    size_t modesRun;
    foreach (mode; ["production", "unittest"])
    {
        ++modesRun;
        const unittestFlag = mode == "unittest" ? "-unittest" : "";
        write(proxyPath,
            "module w16_w_width_proxy;\n"
          ~ "static assert(size_t.sizeof == 4, \"-m32 width proxy is missing\");\n"
          ~ "version (web) {} else static assert(false, \"-version=web is missing\");\n"
          ~ (mode == "production" ? "" :
             "version (unittest) {} else static assert(false, \"-unittest is missing\");\n"));
        const compiled = execute(["bash", "-c", compileWidthProxy,
                                  "w16-w-width32-compile", repoRoot,
                                  describeErrorPath, manifestPath, proxyPath, objectDir,
                                  unittestFlag],
                                 null, Config.none, size_t.max, repoRoot);
        assert(compiled.status == 0,
            format("W16-W dmd -m32 x86 WIDTH proxy rejected the %d-module web closure "
                 ~ "in %s mode (status %d):\n%s", expectedWebModules, mode,
                   compiled.status, errorLines(compiled.output)));

        // `semantic3 <identifier>` is emitted once for every root source named on
        // dmd's command line. Compare its short-name multiset with the closure so a
        // truncated command cannot satisfy the independently measured graph floor.
        size_t[string] rootsSeen;
        size_t rootLines;
        foreach (line; compiled.output.splitLines)
            if (line.startsWith("semantic3 "))
            {
                ++rootLines;
                ++rootsSeen.require(line["semantic3 ".length .. $].strip, 0);
            }
        assert(rootLines == expectedWebModules + 1 && rootsSeen == rootsExpected,
            format("W16-W %s dmd analysed %d root modules; the %d-module closure "
                 ~ "plus the probe must each reach semantic3",
                   mode, rootLines, expectedWebModules));

        size_t objectFiles;
        foreach (_; dirEntries(objectDir, SpanMode.shallow)) ++objectFiles;
        assert(objectFiles == 0,
            format("W16-W %s width proxy must keep dmd -o- (no codegen), but it "
                 ~ "wrote %d object files", mode, objectFiles));
        writefln("WIDTH mode=%s modules=%d semantic3=%d objects=%d",
            mode, expectedWebModules, rootLines, objectFiles);
    }
    assert(modesRun == 2, "both production and unittest width probes must run");

    // The native runtime cell documents the long-domain contract, while this
    // wiring pin makes an inline cast-before-check regression visible on x86_64.
    const nativeSource = readText(buildPath(repoRoot, "packages", "document-io", "source", "io", "native.d"));
    assert(nativeSource.count(
            "if (!morphVertexIndexInBounds(vidx, mesh.vertices.length))") == 1,
        "W16-W morph indices must be range-checked as long before size_t narrowing");
}
