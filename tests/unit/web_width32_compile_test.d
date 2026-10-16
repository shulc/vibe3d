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
for owner in packages/forms-model packages/editor-ui  packages/document-channels  packages/document-io packages/alignment-ops packages/command-runtime packages/application-core packages/creation-ops packages/display-policy  packages/interaction-query packages/interchange    packages/selection-model packages/scene-query packages/editor-commands packages/interactive-tools packages/viewport-host    packages/pipe-evaluation packages/subpatch-preview packages/tool-state packages/transform-ops packages/viewport-gpu   ; do
    mapfile -t package_files < <(dub describe --root="$owner" --config=web \
        --data=source-files --data-list 2>>"$2" | sed '/^$/d' | grep '\.d$')
    files+=("${package_files[@]}")
done
for selected in :edit-contracts :interaction-data :json-number :log :mesh-contracts :parallel :param-schema :plane-bytes :profiling :screen-buckets :spatial :mesh-change :camera-model :image-codec :input-events :mesh-edit-log :mesh-topology :render-model :mesh :document-model :mesh-edit-replay :mesh-ops :mesh-preview :mesh-snapshot :pipe-contracts; do
    mapfile -t package_files < <(dub describe "$selected" --config=web --data=source-files --data-list 2>>"$2" | sed '/^$/d' | grep '\.d$')
    files+=("${package_files[@]}")
done
# Math is a root-registered subpackage; the child recipe is not an independent root.
mapfile -t package_files < <(dub describe :math --config=web \
    --data=source-files --data-list 2>>"$2" | sed '/^$/d' | grep '\.d$')
files+=("${package_files[@]}")
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
    const productionPrefixes = [buildPath(repoRoot, "libraries/viewport/camera/source") ~ "/", buildPath(repoRoot, "packages/document-channels/source") ~ "/", buildPath(repoRoot, "libraries/documents/image-codec/source") ~ "/", buildPath(repoRoot, "packages/document-io/source") ~ "/", buildPath(repoRoot, "source") ~ "/", buildPath(repoRoot, "packages/alignment-ops/source") ~ "/", buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "libraries/documents/model/source"), buildPath(repoRoot, "libraries/editing/params/source"), buildPath(repoRoot, "packages/pipe-runtime/source") ~ "/", buildPath(repoRoot, "packages/creation-ops/source") ~ "/", buildPath(repoRoot, "packages/display-policy/source") ~ "/", buildPath(repoRoot, "libraries/editing/contracts/source") ~ "/", buildPath(repoRoot, "libraries/platform/input/source") ~ "/", buildPath(repoRoot, "packages/interaction-query/source") ~ "/", buildPath(repoRoot, "packages/interchange/source") ~ "/", buildPath(repoRoot, "libraries/mesh/change/source") ~ "/", buildPath(repoRoot, "libraries/mesh/contracts/source") ~ "/", buildPath(repoRoot, "libraries/mesh/edit-log/source") ~ "/", buildPath(repoRoot, "libraries/mesh/edit-replay/source") ~ "/", buildPath(repoRoot, "libraries/mesh/ops/source") ~ "/", buildPath(repoRoot, "libraries/mesh/snapshot/source") ~ "/", buildPath(repoRoot, "libraries/mesh/topology/source") ~ "/", buildPath(repoRoot, "libraries/mesh/core/source") ~ "/", buildPath(repoRoot, "packages/pipe-evaluation/source") ~ "/", buildPath(repoRoot, "libraries/util/profiling/source") ~ "/", buildPath(repoRoot, "libraries/util/spatial/source") ~ "/", buildPath(repoRoot, "packages/subpatch-preview/source") ~ "/", buildPath(repoRoot, "packages/tool-state/source") ~ "/", buildPath(repoRoot, "packages/transform-ops/source") ~ "/", buildPath(repoRoot, "packages/viewport-gpu/source") ~ "/", buildPath(repoRoot, "libraries/util/log/source") ~ "/", buildPath(repoRoot, "libraries/util/math/source/vibe3d/util/math") ~ "/", buildPath(repoRoot, "libraries/util/parallel/source") ~ "/", buildPath(repoRoot, "libraries/util/plane-bytes/source") ~ "/", buildPath(repoRoot, "libraries/util/screen-buckets/source") ~ "/", buildPath(repoRoot, "libraries/editing/pipeline/contracts/source") ~ "/", buildPath(repoRoot, "libraries/mesh/preview/source") ~ "/", buildPath(repoRoot, "libraries/util/json-number/source") ~ "/",
        buildPath(repoRoot, "packages/selection-model/source"),
        buildPath(repoRoot, "packages/scene-query/source"),
        buildPath(repoRoot, "packages/editor-commands/source"),
        buildPath(repoRoot, "packages/interactive-tools/source"),
        buildPath(repoRoot, "packages/viewport-host/source"),
        buildPath(repoRoot, "libraries/editing/interaction/data/source"),
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
    string[] expectedCurrentModules = baseline.dup;
    size_t mathTranslations;
    foreach (ref name; expectedCurrentModules)
        foreach (oldName; ["math", "math_geometry", "math_matrix", "math_quaternion", "math_vector"])
            if (name == oldName)
            {
                name = "vibe3d.util.math." ~ oldName;
                ++mathTranslations;
            }
    assert(mathTranslations == 5, "Wave19 web baseline must translate five original math identities");
    size_t d1Translations;
    foreach (ref name; expectedCurrentModules)
        foreach (pair; [
        ["editmode", "vibe3d.editing.contracts.editmode"],
        ["prepared_tool_effect", "vibe3d.editing.contracts.prepared_tool_effect"],
        ["seltype", "vibe3d.editing.contracts.seltype"],
        ["tool_policy_values", "vibe3d.editing.contracts.tool_policy_values"],
        ["ai.advisor", "vibe3d.editing.interaction.data.ai.advisor"],
        ["ai.debug_trace", "vibe3d.editing.interaction.data.ai.debug_trace"],
        ["ai.interaction", "vibe3d.editing.interaction.data.ai.interaction"],
        ["change_bus", "vibe3d.mesh.change.change_bus"],
        ["mesh_dirty", "vibe3d.mesh.change.mesh_dirty"],
        ["mesh_corner_maps", "vibe3d.mesh.contracts.mesh_corner_maps"],
        ["mesh_plane_types", "vibe3d.mesh.contracts.mesh_plane_types"],
        ["mesh_scope", "vibe3d.mesh.contracts.mesh_scope"],
        ["mesh_types", "vibe3d.mesh.contracts.mesh_types"],
        ["argstring", "vibe3d.editing.params.argstring"],
        ["params", "vibe3d.editing.params.params"],
        ["perf_probe", "vibe3d.util.profiling.perf_probe"],
        ["item_xform", "vibe3d.util.spatial.item_xform"],
        ["spatial", "vibe3d.util.spatial.spatial"],
        ["symmetry_plane", "vibe3d.util.spatial.symmetry_plane"],
        ["trackball", "vibe3d.util.spatial.trackball"],
        ["workplane_basis", "vibe3d.util.spatial.workplane_basis"],
        ["json_num", "vibe3d.util.json_number.json_num"],
        ["log", "vibe3d.util.log.log"],
        ["tsan_annotate", "vibe3d.util.parallel.tsan_annotate"],
        ["plane_bytes", "vibe3d.util.plane_bytes.plane_bytes"],
        ["screen_buckets", "vibe3d.util.screen_buckets.screen_buckets"]])
            if (name == pair[0]) { name = pair[1]; ++d1Translations; }
    assert(d1Translations == 26, "Wave19 D1 web baseline translates 26 original real definitions");
    size_t d2Translations;
    foreach (ref name; expectedCurrentModules)
        foreach (pair; [
            ["view", "vibe3d.viewport.camera.view"],
            ["document", "vibe3d.documents.model.document"],
            ["document_selection", "vibe3d.documents.model.document_selection"],
            ["edit_target_contract", "vibe3d.documents.model.edit_target_contract"],
            ["image_data", "vibe3d.documents.model.image_data"],
            ["item_kinds", "vibe3d.documents.model.item_kinds"],
            ["io.image_decode", "vibe3d.documents.image_codec.io.image_decode"],
            ["eventlog", "vibe3d.platform.input.eventlog"],
            ["held_gesture_buttons", "vibe3d.platform.input.held_gesture_buttons"],
            ["input_context", "vibe3d.platform.input.input_context"],
            ["input_zones", "vibe3d.platform.input.input_zones"],
            ["sdl_error", "vibe3d.platform.input.sdl_error"],
            ["shortcuts", "vibe3d.platform.input.shortcuts"],
            ["tool_input", "vibe3d.platform.input.tool_input"],
            ["mesh_edit_delta", "vibe3d.mesh.edit_log.mesh_edit_delta"],
            ["mesh_edit_replay", "vibe3d.mesh.edit_replay.mesh_edit_replay"],
            ["geometry_clipboard", "vibe3d.mesh.ops.geometry_clipboard"],
            ["mesh_edge_slice", "vibe3d.mesh.ops.mesh_edge_slice"],
            ["mesh_ops.bevel_curves", "vibe3d.mesh.ops.mesh_ops.bevel_curves"],
            ["mesh_ops.bevel_fin", "vibe3d.mesh.ops.mesh_ops.bevel_fin"],
            ["mesh_ops.bevel_vertex", "vibe3d.mesh.ops.mesh_ops.bevel_vertex"],
            ["mesh_ops.box_geom", "vibe3d.mesh.ops.mesh_ops.box_geom"],
            ["mesh_ops.bridge", "vibe3d.mesh.ops.mesh_ops.bridge"],
            ["mesh_ops.bridge_patch", "vibe3d.mesh.ops.mesh_ops.bridge_patch"],
            ["mesh_ops.cleanup", "vibe3d.mesh.ops.mesh_ops.cleanup"],
            ["mesh_ops.connected_mask", "vibe3d.mesh.ops.mesh_ops.connected_mask"],
            ["mesh_ops.cut", "vibe3d.mesh.ops.mesh_ops.cut"],
            ["mesh_ops.decimate", "vibe3d.mesh.ops.mesh_ops.decimate"],
            ["mesh_ops.edge_bevel", "vibe3d.mesh.ops.mesh_ops.edge_bevel"],
            ["mesh_ops.extrude", "vibe3d.mesh.ops.mesh_ops.extrude"],
            ["mesh_ops.face_alignment", "vibe3d.mesh.ops.mesh_ops.face_alignment"],
            ["mesh_ops.face_merge", "vibe3d.mesh.ops.mesh_ops.face_merge"],
            ["mesh_ops.loop_slice", "vibe3d.mesh.ops.mesh_ops.loop_slice"],
            ["mesh_ops.poly_bevel", "vibe3d.mesh.ops.mesh_ops.poly_bevel"],
            ["mesh_ops.revolve", "vibe3d.mesh.ops.mesh_ops.revolve"],
            ["mesh_ops.select_loop", "vibe3d.mesh.ops.mesh_ops.select_loop"],
            ["mesh_ops.thicken", "vibe3d.mesh.ops.mesh_ops.thicken"],
            ["mesh_ops.triangulate", "vibe3d.mesh.ops.mesh_ops.triangulate"],
            ["mesh_stats", "vibe3d.mesh.ops.mesh_stats"],
            ["uv_island", "vibe3d.mesh.ops.uv_island"],
            ["uv_project", "vibe3d.mesh.ops.uv_project"],
            ["uv_relax", "vibe3d.mesh.ops.uv_relax"],
            ["uv_transform", "vibe3d.mesh.ops.uv_transform"],
            ["uv_unwrap", "vibe3d.mesh.ops.uv_unwrap"],
            ["uv_weld", "vibe3d.mesh.ops.uv_weld"],
            ["active_mesh_resolver", "vibe3d.mesh.preview.active_mesh_resolver"],
            ["morph_preview", "vibe3d.mesh.preview.morph_preview"],
            ["snapshot", "vibe3d.mesh.snapshot.snapshot"],
            ["mesh_topo", "vibe3d.mesh.topology.mesh_topo"],
            ["mesh", "vibe3d.mesh.core.mesh"],
            ["mesh_morph", "vibe3d.mesh.core.mesh_morph"],
            ["mesh_planes", "vibe3d.mesh.core.mesh_planes"],
            ["mesh_selsets", "vibe3d.mesh.core.mesh_selsets"],
            ["operator", "vibe3d.editing.pipeline.contracts.operator"],
            ["toolpipe.packets", "vibe3d.editing.pipeline.contracts.toolpipe.packets"]])
            if (name == pair[0]) { name = pair[1]; ++d2Translations; }
    assert(d2Translations == 55, "Wave19 D2 web baseline translates55 original real definitions");
    expectedCurrentModules ~= currentOnlyModules;
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
