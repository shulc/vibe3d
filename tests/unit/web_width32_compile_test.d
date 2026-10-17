// The native `-m32` target is x86, not WebAssembly. This test is deliberately only a
// WIDTH proxy: it asks the D frontend to compile the real web configuration with 32-bit
// size_t/pointers. Target-specific browser behavior belongs to the web toolchain lanes.
module tests.unit.web_width32_compile_test;

import tests.unit.census_symbols : wave19MathPhysicalPath;

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
for owner in                                 ; do
    mapfile -t package_files < <(dub describe --root="$owner" --config=web \
        --data=source-files --data-list 2>>"$2" | sed '/^$/d' | grep '\.d$')
    files+=("${package_files[@]}")
done
for selected in :edit-contracts :interaction-data :json-number :log :mesh-contracts :parallel :param-schema :plane-bytes :profiling :screen-buckets :spatial :mesh-change :camera-model :image-codec :input-events :mesh-edit-log :mesh-topology :render-model :mesh :document-model :mesh-edit-replay :mesh-ops :mesh-preview :mesh-snapshot :pipe-contracts :display-policy :document-channels :interaction-query :interchange :selection-model :tool-state :document-io :pipe-evaluation :viewport-gpu :alignment-ops :creation-ops :scene-query :subpatch-preview :transform-ops :command-runtime :application-core :editor-commands :interactive-tools :forms-model :viewport-host :editor-ui; do
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
    const productionPrefixes = [buildPath(repoRoot, "libraries/viewport/camera/source") ~ "/", buildPath(repoRoot, "libraries/documents/channels/source") ~ "/", buildPath(repoRoot, "libraries/documents/image-codec/source") ~ "/", buildPath(repoRoot, "libraries/documents/io/source") ~ "/", buildPath(repoRoot, "apps/desktop/source") ~ "/", buildPath(repoRoot, "libraries/editing/tools/alignment/source") ~ "/", buildPath(repoRoot, "libraries/editing/commands/runtime/source"), buildPath(repoRoot, "libraries/runtime/application-core/source"), buildPath(repoRoot, "libraries/documents/model/source"), buildPath(repoRoot, "libraries/editing/params/source"), buildPath(repoRoot, "libraries/editing/pipeline/runtime/source") ~ "/", buildPath(repoRoot, "libraries/editing/tools/creation/source") ~ "/", buildPath(repoRoot, "libraries/viewport/display-policy/source") ~ "/", buildPath(repoRoot, "libraries/editing/contracts/source") ~ "/", buildPath(repoRoot, "libraries/platform/input/source") ~ "/", buildPath(repoRoot, "libraries/editing/selection/query/source") ~ "/", buildPath(repoRoot, "libraries/documents/interchange/source") ~ "/", buildPath(repoRoot, "libraries/mesh/change/source") ~ "/", buildPath(repoRoot, "libraries/mesh/contracts/source") ~ "/", buildPath(repoRoot, "libraries/mesh/edit-log/source") ~ "/", buildPath(repoRoot, "libraries/mesh/edit-replay/source") ~ "/", buildPath(repoRoot, "libraries/mesh/ops/source") ~ "/", buildPath(repoRoot, "libraries/mesh/snapshot/source") ~ "/", buildPath(repoRoot, "libraries/mesh/topology/source") ~ "/", buildPath(repoRoot, "libraries/mesh/core/source") ~ "/", buildPath(repoRoot, "libraries/editing/pipeline/evaluation/source") ~ "/", buildPath(repoRoot, "libraries/util/profiling/source") ~ "/", buildPath(repoRoot, "libraries/util/spatial/source") ~ "/", buildPath(repoRoot, "libraries/viewport/subpatch/source") ~ "/", buildPath(repoRoot, "libraries/editing/tools/state/source") ~ "/", buildPath(repoRoot, "libraries/editing/tools/transform/source") ~ "/", buildPath(repoRoot, "libraries/viewport/gpu/source") ~ "/", buildPath(repoRoot, "libraries/util/log/source") ~ "/", buildPath(repoRoot, "libraries/util/math/source/vibe3d/util/math") ~ "/", buildPath(repoRoot, "libraries/util/parallel/source") ~ "/", buildPath(repoRoot, "libraries/util/plane-bytes/source") ~ "/", buildPath(repoRoot, "libraries/util/screen-buckets/source") ~ "/", buildPath(repoRoot, "libraries/editing/pipeline/contracts/source") ~ "/", buildPath(repoRoot, "libraries/mesh/preview/source") ~ "/", buildPath(repoRoot, "libraries/util/json-number/source") ~ "/",
        buildPath(repoRoot, "libraries/editing/selection/model/source"),
        buildPath(repoRoot, "libraries/editing/selection/scene-query/source"),
        buildPath(repoRoot, "libraries/editing/commands/editor/source"),
        buildPath(repoRoot, "libraries/editing/tools/interactive/source"),
        buildPath(repoRoot, "libraries/viewport/host/source"),
        buildPath(repoRoot, "libraries/editing/interaction/data/source"),
        buildPath(repoRoot, "libraries/runtime/ai-advisor/source") ~ "/",
        buildPath(repoRoot, "libraries/runtime/ai3d/source") ~ "/",
        buildPath(repoRoot, "libraries/runtime/document-actions/source") ~ "/",
        buildPath(repoRoot, "libraries/runtime/http/source") ~ "/",
        buildPath(repoRoot, "libraries/platform/file/source") ~ "/",
        buildPath(repoRoot, "libraries/runtime/remesh/source") ~ "/",
        buildPath(repoRoot, "libraries/ui/forms/source") ~ "/",
        buildPath(repoRoot, "libraries/ui/editor/source") ~ "/"];

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
    string[] pending = ["vibe3d.apps.desktop.app"];
    reached["vibe3d.apps.desktop.app"] = true;
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
    enum currentOnlyModules = ["vibe3d.ui.editor.ui.panel_host_roles"];
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
    size_t finalTranslations;
    foreach (ref name; expectedCurrentModules)
        foreach (pair; [
            ["ai.copilot_gate", "vibe3d.runtime.ai_advisor.ai.copilot_gate"],
            ["ai.element_candidates", "vibe3d.runtime.ai_advisor.ai.element_candidates"],
            ["ai.exploration", "vibe3d.runtime.ai_advisor.ai.exploration"],
            ["ai.interaction_log", "vibe3d.runtime.ai_advisor.ai.interaction_log"],
            ["ai.interaction_log_writer", "vibe3d.runtime.ai_advisor.ai.interaction_log_writer"],
            ["ai.model_adapter", "vibe3d.runtime.ai_advisor.ai.model_adapter"],
            ["ai.state", "vibe3d.runtime.ai_advisor.ai.state"],
            ["tools.alignment.align_kernels", "vibe3d.editing.tools.alignment.tools.alignment.align_kernels"],
            ["app_version", "vibe3d.runtime.application_core.app_version"],
            ["http_json", "vibe3d.runtime.application_core.http_json"],
            ["io.doc_state", "vibe3d.runtime.application_core.io.doc_state"],
            ["live_registration_roles", "vibe3d.runtime.application_core.live_registration_roles"],
            ["morph_target", "vibe3d.runtime.application_core.morph_target"],
            ["pilot_command_registration", "vibe3d.runtime.application_core.pilot_command_registration"],
            ["session_owner", "vibe3d.runtime.application_core.session_owner"],
            ["command", "vibe3d.editing.commands.runtime.command"],
            ["command_args", "vibe3d.editing.commands.runtime.command_args"],
            ["command_executor", "vibe3d.editing.commands.runtime.command_executor"],
            ["command_history", "vibe3d.editing.commands.runtime.command_history"],
            ["command_invocation", "vibe3d.editing.commands.runtime.command_invocation"],
            ["command_registry", "vibe3d.editing.commands.runtime.command_registry"],
            ["command_tool_policy", "vibe3d.editing.commands.runtime.command_tool_policy"],
            ["commands.history.redo", "vibe3d.editing.commands.runtime.commands.history.redo"],
            ["commands.history.undo", "vibe3d.editing.commands.runtime.commands.history.undo"],
            ["commands.mesh.gesture_payload", "vibe3d.editing.commands.editor.commands.mesh.gesture_payload"],
            ["commands.mesh.mesh_edit_payload", "vibe3d.editing.commands.editor.commands.mesh.mesh_edit_payload"],
            ["commands.mesh.select", "vibe3d.editing.commands.editor.commands.mesh.select"],
            ["commands.mesh.selection_undo", "vibe3d.editing.commands.editor.commands.mesh.selection_undo"],
            ["commands.mesh.session_edit", "vibe3d.editing.commands.editor.commands.mesh.session_edit"],
            ["commands.mesh.triple", "vibe3d.editing.commands.editor.commands.mesh.triple"],
            ["commands.mesh.vertex_edit", "vibe3d.editing.commands.editor.commands.mesh.vertex_edit"],
            ["commands.select.drop", "vibe3d.editing.commands.runtime.commands.select.drop"],
            ["commands.select.element", "vibe3d.editing.commands.runtime.commands.select.element"],
            ["commands.select.invert", "vibe3d.editing.commands.runtime.commands.select.invert"],
            ["history_lifecycle_contract", "vibe3d.editing.commands.runtime.history_lifecycle_contract"],
            ["record_observer_hub", "vibe3d.editing.commands.runtime.record_observer_hub"],
            ["tool_activation_ownership", "vibe3d.editing.commands.runtime.tool_activation_ownership"],
            ["tools.create.pen_geometry", "vibe3d.editing.tools.creation.tools.create.pen_geometry"],
            ["camera_stamp", "vibe3d.viewport.display_policy.camera_stamp"],
            ["display_state", "vibe3d.viewport.display_policy.display_state"],
            ["light_rig", "vibe3d.viewport.display_policy.light_rig"],
            ["retopology_dot_cull", "vibe3d.viewport.display_policy.retopology_dot_cull"],
            ["retopology_line_shade", "vibe3d.viewport.display_policy.retopology_line_shade"],
            ["retopology_order", "vibe3d.viewport.display_policy.retopology_order"],
            ["select_visibility", "vibe3d.viewport.display_policy.select_visibility"],
            ["vertex_normals", "vibe3d.viewport.display_policy.vertex_normals"],
            ["viewport_overlay_mode", "vibe3d.viewport.display_policy.viewport_overlay_mode"],
            ["viewport_probe_sampling", "vibe3d.viewport.display_policy.viewport_probe_sampling"],
            ["viewport_scheme", "vibe3d.viewport.display_policy.viewport_scheme"],
            ["weightmap_view", "vibe3d.viewport.display_policy.weightmap_view"],
            ["commands.file.quit", "vibe3d.apps.desktop.commands.file.quit"],
            ["commands.image.commands", "vibe3d.runtime.document_actions.commands.image.commands"],
            ["commands.image_plane.commands", "vibe3d.runtime.document_actions.commands.image_plane.commands"],
            ["commands.layer.commands", "vibe3d.runtime.document_actions.commands.layer.commands"],
            ["commands.scene.load_mesh", "vibe3d.runtime.document_actions.commands.scene.load_mesh"],
            ["commands.scene.reset", "vibe3d.runtime.document_actions.commands.scene.reset"],
            ["layer_params", "vibe3d.documents.channels.layer_params"],
            ["io.file_model", "vibe3d.documents.io.io.file_model"],
            ["io.image_path", "vibe3d.documents.io.io.image_path"],
            ["io.native", "vibe3d.documents.io.io.native"],
            ["commands.history.clear", "vibe3d.editing.commands.editor.commands.history.clear"],
            ["commands.history.save_as_script", "vibe3d.editing.commands.editor.commands.history.save_as_script"],
            ["commands.history.show", "vibe3d.editing.commands.editor.commands.history.show"],
            ["commands.layer.xform_edit", "vibe3d.editing.commands.editor.commands.layer.xform_edit"],
            ["commands.macros.record", "vibe3d.editing.commands.editor.commands.macros.record"],
            ["commands.macros.save_recorded", "vibe3d.editing.commands.editor.commands.macros.save_recorded"],
            ["commands.mesh.add_point", "vibe3d.editing.commands.editor.commands.mesh.add_point"],
            ["commands.mesh.array_", "vibe3d.editing.commands.editor.commands.mesh.array_"],
            ["commands.mesh.axis_slice", "vibe3d.editing.commands.editor.commands.mesh.axis_slice"],
            ["commands.mesh.bevel", "vibe3d.editing.commands.editor.commands.mesh.bevel"],
            ["commands.mesh.bridge", "vibe3d.editing.commands.editor.commands.mesh.bridge"],
            ["commands.mesh.cleanup", "vibe3d.editing.commands.editor.commands.mesh.cleanup"],
            ["commands.mesh.clone_", "vibe3d.editing.commands.editor.commands.mesh.clone_"],
            ["commands.mesh.collapse", "vibe3d.editing.commands.editor.commands.mesh.collapse"],
            ["commands.mesh.copy_", "vibe3d.editing.commands.editor.commands.mesh.copy_"],
            ["commands.mesh.cut_", "vibe3d.editing.commands.editor.commands.mesh.cut_"],
            ["commands.mesh.delete_", "vibe3d.editing.commands.editor.commands.mesh.delete_"],
            ["commands.mesh.detriangulate", "vibe3d.editing.commands.editor.commands.mesh.detriangulate"],
            ["commands.mesh.duplicate_", "vibe3d.editing.commands.editor.commands.mesh.duplicate_"],
            ["commands.mesh.edge_crease", "vibe3d.editing.commands.editor.commands.mesh.edge_crease"],
            ["commands.mesh.edge_extend", "vibe3d.editing.commands.editor.commands.mesh.edge_extend"],
            ["commands.mesh.edge_extrude", "vibe3d.editing.commands.editor.commands.mesh.edge_extrude"],
            ["commands.mesh.edge_join", "vibe3d.editing.commands.editor.commands.mesh.edge_join"],
            ["commands.mesh.edge_slice", "vibe3d.editing.commands.editor.commands.mesh.edge_slice"],
            ["commands.mesh.edge_slide", "vibe3d.editing.commands.editor.commands.mesh.edge_slide"],
            ["commands.mesh.face_extrude", "vibe3d.editing.commands.editor.commands.mesh.face_extrude"],
            ["commands.mesh.fix_orientation", "vibe3d.editing.commands.editor.commands.mesh.fix_orientation"],
            ["commands.mesh.flip", "vibe3d.editing.commands.editor.commands.mesh.flip"],
            ["commands.mesh.hide", "vibe3d.editing.commands.editor.commands.mesh.hide"],
            ["commands.mesh.jitter", "vibe3d.editing.commands.editor.commands.mesh.jitter"],
            ["commands.mesh.linear_align", "vibe3d.editing.commands.editor.commands.mesh.linear_align"],
            ["commands.mesh.loop_slice", "vibe3d.editing.commands.editor.commands.mesh.loop_slice"],
            ["commands.mesh.make_polygon", "vibe3d.editing.commands.editor.commands.mesh.make_polygon"],
            ["commands.mesh.map_edit_undo", "vibe3d.editing.commands.editor.commands.mesh.map_edit_undo"],
            ["commands.mesh.merge", "vibe3d.editing.commands.editor.commands.mesh.merge"],
            ["commands.mesh.mirror_", "vibe3d.editing.commands.editor.commands.mesh.mirror_"],
            ["commands.mesh.morph_edit", "vibe3d.editing.commands.editor.commands.mesh.morph_edit"],
            ["commands.mesh.move_vertex", "vibe3d.editing.commands.editor.commands.mesh.move_vertex"],
            ["commands.mesh.paste_", "vibe3d.editing.commands.editor.commands.mesh.paste_"],
            ["commands.mesh.poly_inset", "vibe3d.editing.commands.editor.commands.mesh.poly_inset"],
            ["commands.mesh.polygon_align", "vibe3d.editing.commands.editor.commands.mesh.polygon_align"],
            ["commands.mesh.position_undo", "vibe3d.editing.commands.editor.commands.mesh.position_undo"],
            ["commands.mesh.quadruple", "vibe3d.editing.commands.editor.commands.mesh.quadruple"],
            ["commands.mesh.quantize", "vibe3d.editing.commands.editor.commands.mesh.quantize"],
            ["commands.mesh.radial_align", "vibe3d.editing.commands.editor.commands.mesh.radial_align"],
            ["commands.mesh.radial_array_", "vibe3d.editing.commands.editor.commands.mesh.radial_array_"],
            ["commands.mesh.reduce", "vibe3d.editing.commands.editor.commands.mesh.reduce"],
            ["commands.mesh.remove_", "vibe3d.editing.commands.editor.commands.mesh.remove_"],
            ["commands.mesh.screen_slice", "vibe3d.editing.commands.editor.commands.mesh.screen_slice"],
            ["commands.mesh.selection_edit", "vibe3d.editing.commands.editor.commands.mesh.selection_edit"],
            ["commands.mesh.set_material", "vibe3d.editing.commands.editor.commands.mesh.set_material"],
            ["commands.mesh.set_part", "vibe3d.editing.commands.editor.commands.mesh.set_part"],
            ["commands.mesh.smooth_shift", "vibe3d.editing.commands.editor.commands.mesh.smooth_shift"],
            ["commands.mesh.spikey", "vibe3d.editing.commands.editor.commands.mesh.spikey"],
            ["commands.mesh.spin_edge", "vibe3d.editing.commands.editor.commands.mesh.spin_edge"],
            ["commands.mesh.split_edge", "vibe3d.editing.commands.editor.commands.mesh.split_edge"],
            ["commands.mesh.split_face", "vibe3d.editing.commands.editor.commands.mesh.split_face"],
            ["commands.mesh.stroke_extrude", "vibe3d.editing.commands.editor.commands.mesh.stroke_extrude"],
            ["commands.mesh.subdivide", "vibe3d.editing.commands.editor.commands.mesh.subdivide"],
            ["commands.mesh.subdivide_faceted", "vibe3d.editing.commands.editor.commands.mesh.subdivide_faceted"],
            ["commands.mesh.subpatch_toggle", "vibe3d.editing.commands.editor.commands.mesh.subpatch_toggle"],
            ["commands.mesh.surface_attr", "vibe3d.editing.commands.editor.commands.mesh.surface_attr"],
            ["commands.mesh.sweep", "vibe3d.editing.commands.editor.commands.mesh.sweep"],
            ["commands.mesh.symmetrize", "vibe3d.editing.commands.editor.commands.mesh.symmetrize"],
            ["commands.mesh.thicken", "vibe3d.editing.commands.editor.commands.mesh.thicken"],
            ["commands.mesh.transform", "vibe3d.editing.commands.editor.commands.mesh.transform"],
            ["commands.mesh.unify", "vibe3d.editing.commands.editor.commands.mesh.unify"],
            ["commands.mesh.uv_map_util", "vibe3d.editing.commands.editor.commands.mesh.uv_map_util"],
            ["commands.mesh.uv_pack", "vibe3d.editing.commands.editor.commands.mesh.uv_pack"],
            ["commands.mesh.uv_project", "vibe3d.editing.commands.editor.commands.mesh.uv_project"],
            ["commands.mesh.uv_relax", "vibe3d.editing.commands.editor.commands.mesh.uv_relax"],
            ["commands.mesh.uv_transform", "vibe3d.editing.commands.editor.commands.mesh.uv_transform"],
            ["commands.mesh.uv_unwrap", "vibe3d.editing.commands.editor.commands.mesh.uv_unwrap"],
            ["commands.mesh.vert_join", "vibe3d.editing.commands.editor.commands.mesh.vert_join"],
            ["commands.mesh.vert_merge", "vibe3d.editing.commands.editor.commands.mesh.vert_merge"],
            ["commands.mesh.vertex_bevel", "vibe3d.editing.commands.editor.commands.mesh.vertex_bevel"],
            ["commands.mesh.vertex_center", "vibe3d.editing.commands.editor.commands.mesh.vertex_center"],
            ["commands.mesh.vertex_extrude", "vibe3d.editing.commands.editor.commands.mesh.vertex_extrude"],
            ["commands.mesh.vertex_new", "vibe3d.editing.commands.editor.commands.mesh.vertex_new"],
            ["commands.mesh.vertex_position_result", "vibe3d.editing.commands.editor.commands.mesh.vertex_position_result"],
            ["commands.mesh.vertex_set", "vibe3d.editing.commands.editor.commands.mesh.vertex_set"],
            ["commands.mesh.vertex_split", "vibe3d.editing.commands.editor.commands.mesh.vertex_split"],
            ["commands.mesh.weightmap", "vibe3d.editing.commands.editor.commands.mesh.weightmap"],
            ["commands.mesh.weld_vertex_pair", "vibe3d.editing.commands.editor.commands.mesh.weld_vertex_pair"],
            ["commands.select.between", "vibe3d.editing.commands.editor.commands.select.between"],
            ["commands.select.boundary", "vibe3d.editing.commands.editor.commands.select.boundary"],
            ["commands.select.by_stat", "vibe3d.editing.commands.editor.commands.select.by_stat"],
            ["commands.select.by_tag", "vibe3d.editing.commands.editor.commands.select.by_tag"],
            ["commands.select.connect", "vibe3d.editing.commands.editor.commands.select.connect"],
            ["commands.select.contract", "vibe3d.editing.commands.editor.commands.select.contract"],
            ["commands.select.convert", "vibe3d.editing.commands.editor.commands.select.convert"],
            ["commands.select.expand", "vibe3d.editing.commands.editor.commands.select.expand"],
            ["commands.select.fill", "vibe3d.editing.commands.editor.commands.select.fill"],
            ["commands.select.less", "vibe3d.editing.commands.editor.commands.select.less"],
            ["commands.select.loop", "vibe3d.editing.commands.editor.commands.select.loop"],
            ["commands.select.more", "vibe3d.editing.commands.editor.commands.select.more"],
            ["commands.select.ring", "vibe3d.editing.commands.editor.commands.select.ring"],
            ["commands.select.sets", "vibe3d.editing.commands.editor.commands.select.sets"],
            ["commands.select.type_from", "vibe3d.editing.commands.editor.commands.select.type_from"],
            ["macro_recorder", "vibe3d.editing.commands.editor.macro_recorder"],
            ["step_trace", "vibe3d.editing.commands.editor.step_trace"],
            ["args_dialog", "vibe3d.ui.editor.args_dialog"],
            ["buttonset", "vibe3d.ui.editor.buttonset"],
            ["forms_render", "vibe3d.ui.editor.forms_render"],
            ["imgui_event_gate", "vibe3d.ui.editor.imgui_event_gate"],
            ["imgui_flag_boundary", "vibe3d.ui.editor.imgui_flag_boundary"],
            ["imgui_style", "vibe3d.ui.editor.imgui_style"],
            ["pie_geometry", "vibe3d.ui.editor.pie_geometry"],
            ["pie_menus", "vibe3d.ui.editor.pie_menus"],
            ["pie_state", "vibe3d.ui.editor.pie_state"],
            ["popup_state", "vibe3d.ui.editor.popup_state"],
            ["ui.action_menu", "vibe3d.ui.editor.ui.action_menu"],
            ["ui.availability", "vibe3d.ui.editor.ui.availability"],
            ["ui.button_face", "vibe3d.ui.editor.ui.button_face"],
            ["ui.channel_rows", "vibe3d.ui.editor.ui.channel_rows"],
            ["ui.channels_panel", "vibe3d.ui.editor.ui.channels_panel"],
            ["ui.command_notice", "vibe3d.ui.editor.ui.command_notice"],
            ["ui.dock_drag", "vibe3d.ui.editor.ui.dock_drag"],
            ["ui.guard_modal_state", "vibe3d.ui.editor.ui.guard_modal_state"],
            ["ui.history_panel", "vibe3d.ui.editor.ui.history_panel"],
            ["ui.image_list_panel", "vibe3d.ui.editor.ui.image_list_panel"],
            ["ui.image_rows", "vibe3d.ui.editor.ui.image_rows"],
            ["ui.imgui_window_class", "vibe3d.ui.editor.ui.imgui_window_class"],
            ["ui.item_glyphs", "vibe3d.ui.editor.ui.item_glyphs"],
            ["ui.item_rename", "vibe3d.ui.editor.ui.item_rename"],
            ["ui.item_rows", "vibe3d.ui.editor.ui.item_rows"],
            ["ui.layer_list_panel", "vibe3d.ui.editor.ui.layer_list_panel"],
            ["ui.mode_popup", "vibe3d.ui.editor.ui.mode_popup"],
            ["ui.panel_chrome", "vibe3d.ui.editor.ui.panel_chrome"],
            ["ui.panels", "vibe3d.ui.editor.ui.panels"],
            ["ui.pie_record", "vibe3d.ui.editor.ui.pie_record"],
            ["ui.pie_render", "vibe3d.ui.editor.ui.pie_render"],
            ["ui.remesh_modal_state", "vibe3d.ui.editor.ui.remesh_modal_state"],
            ["ui.retained_item", "vibe3d.ui.editor.ui.retained_item"],
            ["ui.stat_record", "vibe3d.ui.editor.ui.stat_record"],
            ["ui.stat_rows", "vibe3d.ui.editor.ui.stat_rows"],
            ["ui.tool_properties_panel", "vibe3d.ui.editor.ui.tool_properties_panel"],
            ["ui.viewport_props_role", "vibe3d.ui.editor.ui.viewport_props_role"],
            ["forms", "vibe3d.ui.forms.forms"],
            ["http_server", "vibe3d.runtime.http.http_server"],
            ["http_transport", "vibe3d.runtime.http.http_transport"],
            ["playback_controller", "vibe3d.runtime.http.playback_controller"],
            ["constraint", "vibe3d.editing.selection.query.constraint"],
            ["hover_state", "vibe3d.editing.selection.query.hover_state"],
            ["mesh_bbox", "vibe3d.editing.selection.query.mesh_bbox"],
            ["mesh_visibility", "vibe3d.editing.selection.query.mesh_visibility"],
            ["path", "vibe3d.editing.selection.query.path"],
            ["snap", "vibe3d.editing.selection.query.snap"],
            ["snap_election", "vibe3d.editing.selection.query.snap_election"],
            ["surface_pick", "vibe3d.editing.selection.query.surface_pick"],
            ["symmetry", "vibe3d.editing.selection.query.symmetry"],
            ["toolpipe.guide", "vibe3d.editing.selection.query.toolpipe.guide"],
            ["viewgrid", "vibe3d.editing.selection.query.viewgrid"],
            ["workplane_fit", "vibe3d.editing.selection.query.workplane_fit"],
            ["commands.falloff", "vibe3d.editing.tools.interactive.commands.falloff"],
            ["commands.mesh.smooth", "vibe3d.editing.commands.editor.commands.mesh.smooth"],
            ["commands.tool.attr", "vibe3d.editing.tools.interactive.commands.tool.attr"],
            ["commands.tool.begin_session", "vibe3d.editing.tools.interactive.commands.tool.begin_session"],
            ["commands.tool.bridge_headless", "vibe3d.editing.tools.interactive.commands.tool.bridge_headless"],
            ["commands.tool.do_apply", "vibe3d.editing.tools.interactive.commands.tool.do_apply"],
            ["commands.tool.headless", "vibe3d.editing.tools.interactive.commands.tool.headless"],
            ["commands.tool.host", "vibe3d.editing.tools.interactive.commands.tool.host"],
            ["commands.tool.lifecycle", "vibe3d.editing.tools.interactive.commands.tool.lifecycle"],
            ["commands.tool.panel_edit", "vibe3d.editing.tools.interactive.commands.tool.panel_edit"],
            ["commands.tool.pipe", "vibe3d.editing.tools.interactive.commands.tool.pipe"],
            ["commands.tool.reset", "vibe3d.editing.tools.interactive.commands.tool.reset"],
            ["commands.tool.set", "vibe3d.editing.tools.interactive.commands.tool.set"],
            ["coord_rounding", "vibe3d.editing.tools.interactive.coord_rounding"],
            ["deform_magnet", "vibe3d.editing.tools.interactive.deform_magnet"],
            ["drag", "vibe3d.editing.tools.interactive.drag"],
            ["edit_session", "vibe3d.editing.tools.interactive.edit_session"],
            ["evaluated_move_weld", "vibe3d.editing.tools.interactive.evaluated_move_weld"],
            ["falloff_handles", "vibe3d.editing.tools.interactive.falloff_handles"],
            ["falloff_render", "vibe3d.editing.tools.interactive.falloff_render"],
            ["gizmo", "vibe3d.editing.tools.interactive.gizmo"],
            ["handler", "vibe3d.editing.tools.interactive.handler"],
            ["handles.arbiter", "vibe3d.editing.tools.interactive.handles.arbiter"],
            ["handles.gizmo_metrics", "vibe3d.editing.tools.interactive.handles.gizmo_metrics"],
            ["handles.gl_util", "vibe3d.editing.tools.interactive.handles.gl_util"],
            ["handles.shapes", "vibe3d.editing.tools.interactive.handles.shapes"],
            ["model_preview", "vibe3d.editing.tools.interactive.model_preview"],
            ["overlay_space", "vibe3d.editing.tools.interactive.overlay_space"],
            ["params_widgets", "vibe3d.editing.tools.interactive.params_widgets"],
            ["pipe_gizmo_host", "vibe3d.editing.tools.interactive.pipe_gizmo_host"],
            ["prepared_box_param", "vibe3d.editing.tools.interactive.prepared_box_param"],
            ["prepared_bridge_activation", "vibe3d.editing.tools.interactive.prepared_bridge_activation"],
            ["prepared_command_wrapper_activation", "vibe3d.editing.tools.interactive.prepared_command_wrapper_activation"],
            ["prepared_edge_bevel_activation", "vibe3d.editing.tools.interactive.prepared_edge_bevel_activation"],
            ["prepared_edge_extend_deactivate", "vibe3d.editing.tools.interactive.prepared_edge_extend_deactivate"],
            ["prepared_edge_extend_tool_activation", "vibe3d.editing.tools.interactive.prepared_edge_extend_tool_activation"],
            ["prepared_edge_extrude_activation", "vibe3d.editing.tools.interactive.prepared_edge_extrude_activation"],
            ["prepared_edge_slice_activation", "vibe3d.editing.tools.interactive.prepared_edge_slice_activation"],
            ["prepared_edge_slice_deactivate", "vibe3d.editing.tools.interactive.prepared_edge_slice_deactivate"],
            ["prepared_inherited_noop", "vibe3d.editing.tools.interactive.prepared_inherited_noop"],
            ["prepared_loop_slice_activation", "vibe3d.editing.tools.interactive.prepared_loop_slice_activation"],
            ["prepared_loop_slice_deactivate", "vibe3d.editing.tools.interactive.prepared_loop_slice_deactivate"],
            ["prepared_mirror_activation", "vibe3d.editing.tools.interactive.prepared_mirror_activation"],
            ["prepared_move_update", "vibe3d.editing.tools.interactive.prepared_move_update"],
            ["prepared_param_update", "vibe3d.editing.tools.interactive.prepared_param_update"],
            ["prepared_pipe_activation", "vibe3d.editing.tools.interactive.prepared_pipe_activation"],
            ["prepared_poly_bevel_activation", "vibe3d.editing.tools.interactive.prepared_poly_bevel_activation"],
            ["prepared_poly_extrude_activation", "vibe3d.editing.tools.interactive.prepared_poly_extrude_activation"],
            ["prepared_poly_inset_activation", "vibe3d.editing.tools.interactive.prepared_poly_inset_activation"],
            ["prepared_private_state", "vibe3d.editing.tools.interactive.prepared_private_state"],
            ["prepared_radial_array_transition", "vibe3d.editing.tools.interactive.prepared_radial_array_transition"],
            ["prepared_radial_sweep_transition", "vibe3d.editing.tools.interactive.prepared_radial_sweep_transition"],
            ["prepared_record_context", "vibe3d.editing.tools.interactive.prepared_record_context"],
            ["prepared_rotate_update", "vibe3d.editing.tools.interactive.prepared_rotate_update"],
            ["prepared_scale_update", "vibe3d.editing.tools.interactive.prepared_scale_update"],
            ["prepared_selection_profile", "vibe3d.editing.tools.interactive.prepared_selection_profile"],
            ["prepared_selection_profile_image", "vibe3d.editing.tools.interactive.prepared_selection_profile_image"],
            ["prepared_slice_activation", "vibe3d.editing.tools.interactive.prepared_slice_activation"],
            ["prepared_slice_deactivate", "vibe3d.editing.tools.interactive.prepared_slice_deactivate"],
            ["prepared_smooth_shift_activation", "vibe3d.editing.tools.interactive.prepared_smooth_shift_activation"],
            ["prepared_stroke_extrude_activation", "vibe3d.editing.tools.interactive.prepared_stroke_extrude_activation"],
            ["prepared_tack_activation", "vibe3d.editing.tools.interactive.prepared_tack_activation"],
            ["prepared_tool_transition", "vibe3d.editing.tools.interactive.prepared_tool_transition"],
            ["prepared_topology_pen_activation", "vibe3d.editing.tools.interactive.prepared_topology_pen_activation"],
            ["prepared_topology_pen_deactivate", "vibe3d.editing.tools.interactive.prepared_topology_pen_deactivate"],
            ["prepared_topology_pen_update", "vibe3d.editing.tools.interactive.prepared_topology_pen_update"],
            ["prepared_transform_activation", "vibe3d.editing.tools.interactive.prepared_transform_activation"],
            ["prepared_transform_product_activation", "vibe3d.editing.tools.interactive.prepared_transform_product_activation"],
            ["prepared_vertex_bevel_activation", "vibe3d.editing.tools.interactive.prepared_vertex_bevel_activation"],
            ["prepared_vertex_extrude_activation", "vibe3d.editing.tools.interactive.prepared_vertex_extrude_activation"],
            ["prepared_vertex_merge_activation", "vibe3d.editing.tools.interactive.prepared_vertex_merge_activation"],
            ["prepared_xfrm_activation_session", "vibe3d.editing.tools.interactive.prepared_xfrm_activation_session"],
            ["prepared_xfrm_refire_state", "vibe3d.editing.tools.interactive.prepared_xfrm_refire_state"],
            ["prepared_xfrm_replay", "vibe3d.editing.tools.interactive.prepared_xfrm_replay"],
            ["prepared_xfrm_slot_poll", "vibe3d.editing.tools.interactive.prepared_xfrm_slot_poll"],
            ["prepared_xfrm_update_boundary", "vibe3d.editing.tools.interactive.prepared_xfrm_update_boundary"],
            ["prepared_xfrm_update_edit_close", "vibe3d.editing.tools.interactive.prepared_xfrm_update_edit_close"],
            ["prepared_xfrm_update_tail", "vibe3d.editing.tools.interactive.prepared_xfrm_update_tail"],
            ["property_panel", "vibe3d.editing.tools.interactive.property_panel"],
            ["registry", "vibe3d.editing.tools.interactive.registry"],
            ["snap_render", "vibe3d.editing.tools.interactive.snap_render"],
            ["tool", "vibe3d.editing.tools.interactive.tool"],
            ["tool_attr_bounds", "vibe3d.editing.tools.interactive.tool_attr_bounds"],
            ["tool_disarm", "vibe3d.editing.tools.interactive.tool_disarm"],
            ["tool_presets", "vibe3d.editing.tools.interactive.tool_presets"],
            ["tools.alignment.array_tool", "vibe3d.editing.tools.interactive.tools.alignment.array_tool"],
            ["tools.alignment.clone_tool", "vibe3d.editing.tools.interactive.tools.alignment.clone_tool"],
            ["tools.alignment.linear_align_tool", "vibe3d.editing.tools.interactive.tools.alignment.linear_align_tool"],
            ["tools.alignment.mirror", "vibe3d.editing.tools.interactive.tools.alignment.mirror"],
            ["tools.alignment.radial_align_tool", "vibe3d.editing.tools.interactive.tools.alignment.radial_align_tool"],
            ["tools.alignment.radial_array_tool", "vibe3d.editing.tools.interactive.tools.alignment.radial_array_tool"],
            ["tools.alignment.radial_sweep_tool", "vibe3d.editing.tools.interactive.tools.alignment.radial_sweep_tool"],
            ["tools.common.command_wrapper", "vibe3d.editing.tools.interactive.tools.common.command_wrapper"],
            ["tools.create.arc", "vibe3d.editing.tools.interactive.tools.create.arc"],
            ["tools.create.box", "vibe3d.editing.tools.interactive.tools.create.box"],
            ["tools.create.capsule", "vibe3d.editing.tools.interactive.tools.create.capsule"],
            ["tools.create.cone", "vibe3d.editing.tools.interactive.tools.create.cone"],
            ["tools.create.create_common", "vibe3d.editing.tools.interactive.tools.create.create_common"],
            ["tools.create.cylinder", "vibe3d.editing.tools.interactive.tools.create.cylinder"],
            ["tools.create.pen", "vibe3d.editing.tools.interactive.tools.create.pen"],
            ["tools.create.primitive_create_tool", "vibe3d.editing.tools.interactive.tools.create.primitive_create_tool"],
            ["tools.create.sphere", "vibe3d.editing.tools.interactive.tools.create.sphere"],
            ["tools.create.torus", "vibe3d.editing.tools.interactive.tools.create.torus"],
            ["tools.create.tube", "vibe3d.editing.tools.interactive.tools.create.tube"],
            ["tools.create.vertex_place", "vibe3d.editing.tools.interactive.tools.create.vertex_place"],
            ["tools.deform.bend", "vibe3d.editing.tools.interactive.tools.deform.bend"],
            ["tools.deform.magnet", "vibe3d.editing.tools.interactive.tools.deform.magnet"],
            ["tools.deform.push", "vibe3d.editing.tools.interactive.tools.deform.push"],
            ["tools.deform.smooth_shift_tool", "vibe3d.editing.tools.interactive.tools.deform.smooth_shift_tool"],
            ["tools.deform.stroke_extrude_tool", "vibe3d.editing.tools.interactive.tools.deform.stroke_extrude_tool"],
            ["tools.edit.bridge_tool", "vibe3d.editing.tools.interactive.tools.edit.bridge_tool"],
            ["tools.edit.edge_bevel", "vibe3d.editing.tools.interactive.tools.edit.edge_bevel"],
            ["tools.edit.edge_extend", "vibe3d.editing.tools.interactive.tools.edit.edge_extend"],
            ["tools.edit.edge_extrude", "vibe3d.editing.tools.interactive.tools.edit.edge_extrude"],
            ["tools.edit.haul_axis_latch", "vibe3d.editing.tools.interactive.tools.edit.haul_axis_latch"],
            ["tools.edit.poly_bevel", "vibe3d.editing.tools.interactive.tools.edit.poly_bevel"],
            ["tools.edit.poly_extrude", "vibe3d.editing.tools.interactive.tools.edit.poly_extrude"],
            ["tools.edit.poly_inset_tool", "vibe3d.editing.tools.interactive.tools.edit.poly_inset_tool"],
            ["tools.edit.reduce", "vibe3d.editing.tools.interactive.tools.edit.reduce"],
            ["tools.edit.smooth_relax", "vibe3d.editing.tools.interactive.tools.edit.smooth_relax"],
            ["tools.edit.tack", "vibe3d.editing.tools.interactive.tools.edit.tack"],
            ["tools.edit.topology_pen.defs", "vibe3d.editing.tools.interactive.tools.edit.topology_pen.defs"],
            ["tools.edit.topology_pen.json", "vibe3d.editing.tools.interactive.tools.edit.topology_pen.json"],
            ["tools.edit.topology_pen", "vibe3d.editing.tools.interactive.tools.edit.topology_pen"],
            ["tools.edit.topology_pen.render", "vibe3d.editing.tools.interactive.tools.edit.topology_pen.render"],
            ["tools.edit.topology_pen.snap_guide", "vibe3d.editing.tools.interactive.tools.edit.topology_pen.snap_guide"],
            ["tools.edit.topology_pen.tool", "vibe3d.editing.tools.interactive.tools.edit.topology_pen.tool"],
            ["tools.edit.vert_merge_tool", "vibe3d.editing.tools.interactive.tools.edit.vert_merge_tool"],
            ["tools.edit.vertex_bevel_tool", "vibe3d.editing.tools.interactive.tools.edit.vertex_bevel_tool"],
            ["tools.edit.vertex_extrude_tool", "vibe3d.editing.tools.interactive.tools.edit.vertex_extrude_tool"],
            ["tools.slice.edge_slice_tool", "vibe3d.editing.tools.interactive.tools.slice.edge_slice_tool"],
            ["tools.slice.edge_slide", "vibe3d.editing.tools.interactive.tools.slice.edge_slide"],
            ["tools.slice.loop_slice_tool", "vibe3d.editing.tools.interactive.tools.slice.loop_slice_tool"],
            ["tools.slice.slice_tool", "vibe3d.editing.tools.interactive.tools.slice.slice_tool"],
            ["tools.topology_step", "vibe3d.editing.tools.interactive.tools.topology_step"],
            ["tools.transform.move", "vibe3d.editing.tools.interactive.tools.transform.move"],
            ["tools.transform.rotate", "vibe3d.editing.tools.interactive.tools.transform.rotate"],
            ["tools.transform.scale", "vibe3d.editing.tools.interactive.tools.transform.scale"],
            ["tools.transform.transform", "vibe3d.editing.tools.interactive.tools.transform.transform"],
            ["tools.transform.xfrm_apply", "vibe3d.editing.tools.interactive.tools.transform.xfrm_apply"],
            ["tools.transform.xfrm_handles", "vibe3d.editing.tools.interactive.tools.transform.xfrm_handles"],
            ["tools.transform.xfrm_item", "vibe3d.editing.tools.interactive.tools.transform.xfrm_item"],
            ["tools.transform.xfrm_transform", "vibe3d.editing.tools.interactive.tools.transform.xfrm_transform"],
            ["value_drag", "vibe3d.editing.tools.interactive.value_drag"],
            ["io.assimp_runtime", "vibe3d.documents.interchange.io.assimp_runtime"],
            ["io.assimp_wire", "vibe3d.documents.interchange.io.assimp_wire"],
            ["io.formats", "vibe3d.documents.interchange.io.formats"],
            ["io.lwo_export", "vibe3d.documents.interchange.io.lwo_export"],
            ["io.lwo_import", "vibe3d.documents.interchange.io.lwo_import"],
            ["io.scene_export", "vibe3d.documents.interchange.io.scene_export"],
            ["io.scene_import", "vibe3d.documents.interchange.io.scene_import"],
            ["io.scene_ir", "vibe3d.documents.interchange.io.scene_ir"],
            ["toolpipe.attr_cache", "vibe3d.editing.pipeline.evaluation.toolpipe.attr_cache"],
            ["toolpipe.obbox", "vibe3d.editing.pipeline.evaluation.toolpipe.obbox"],
            ["toolpipe", "vibe3d.editing.pipeline.evaluation.toolpipe"],
            ["toolpipe.stages.actcenter", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.actcenter"],
            ["toolpipe.stages.axis", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.axis"],
            ["toolpipe.stages.constrain", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.constrain"],
            ["toolpipe.stages.falloff", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.falloff"],
            ["toolpipe.stages.path", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.path"],
            ["toolpipe.stages.snap", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.snap"],
            ["toolpipe.stages.symmetry", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.symmetry"],
            ["toolpipe.stages.workplane", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.workplane"],
            ["toolpipe.state_paths", "vibe3d.editing.pipeline.evaluation.toolpipe.state_paths"],
            ["falloff", "vibe3d.editing.pipeline.runtime.falloff"],
            ["toolpipe.pipeline", "vibe3d.editing.pipeline.runtime.toolpipe.pipeline"],
            ["toolpipe.stage", "vibe3d.editing.pipeline.runtime.toolpipe.stage"],
            ["toolpipe.subject", "vibe3d.editing.pipeline.runtime.toolpipe.subject"],
            ["io.browser_pick_resume", "vibe3d.platform.file.io.browser_pick_resume"],
            ["io.file_dialog", "vibe3d.platform.file.io.file_dialog"],
            ["io.file_dialog_browser", "vibe3d.platform.file.io.file_dialog_browser"],
            ["ui.discard_guard", "vibe3d.ui.editor.ui.discard_guard"],
            ["remesh.region_stitch", "vibe3d.runtime.remesh.remesh.region_stitch"],
            ["remesh.remesh_job", "vibe3d.runtime.remesh.remesh.remesh_job"],
            ["bvh_pick", "vibe3d.editing.selection.scene_query.bvh_pick"],
            ["symmetry_pick", "vibe3d.editing.selection.scene_query.symmetry_pick"],
            ["selection_product", "vibe3d.editing.selection.model.selection_product"],
            ["selection_projection", "vibe3d.editing.selection.model.selection_projection"],
            ["subpatch_factories", "vibe3d.viewport.subpatch.subpatch_factories"],
            ["subpatch_osd", "vibe3d.viewport.subpatch.subpatch_osd"],
            ["subpatch_preview", "vibe3d.viewport.subpatch.subpatch_preview"],
            ["subpatch_worker_web", "vibe3d.viewport.subpatch.subpatch_worker_web"],
            ["tools.common.session_mesh_key", "vibe3d.editing.tools.state.tools.common.session_mesh_key"],
            ["tools.edit.preview_rebuild", "vibe3d.editing.tools.state.tools.edit.preview_rebuild"],
            ["tools.transform.arcball", "vibe3d.editing.tools.transform.tools.transform.arcball"],
            ["tools.transform.cluster_values", "vibe3d.editing.tools.transform.tools.transform.cluster_values"],
            ["tools.transform.item_xform_kernels", "vibe3d.editing.tools.transform.tools.transform.item_xform_kernels"],
            ["tools.transform.morph_route", "vibe3d.editing.tools.transform.tools.transform.morph_route"],
            ["tools.transform.relocate_plane", "vibe3d.editing.tools.transform.tools.transform.relocate_plane"],
            ["tools.transform.scale_input", "vibe3d.editing.tools.transform.tools.transform.scale_input"],
            ["tools.transform.xform_kernels", "vibe3d.editing.tools.transform.tools.transform.xform_kernels"],
            ["display_sync", "vibe3d.viewport.gpu.display_sync"],
            ["gpu_pass_timer", "vibe3d.viewport.gpu.gpu_pass_timer"],
            ["gpu_select", "vibe3d.viewport.gpu.gpu_select"],
            ["mesh_gpu", "vibe3d.viewport.gpu.mesh_gpu"],
            ["shader", "vibe3d.viewport.gpu.shader"],
            ["viewport_env", "vibe3d.viewport.gpu.viewport_env"],
            ["bg_gpu_cache", "vibe3d.viewport.host.bg_gpu_cache"],
            ["image_cache", "vibe3d.viewport.host.image_cache"],
            ["image_plane", "vibe3d.viewport.host.image_plane"],
            ["viewport", "vibe3d.viewport.host.viewport"],
            ["viewport_composite", "vibe3d.viewport.host.viewport_composite"],
            ["ai_command_registration", "vibe3d.apps.desktop.ai_command_registration"],
            ["app", "vibe3d.apps.desktop.app"],
            ["application_command_binding", "vibe3d.apps.desktop.application_command_binding"],
            ["commands.actr", "vibe3d.apps.desktop.commands.actr"],
            ["commands.ai.toggle", "vibe3d.apps.desktop.commands.ai.toggle"],
            ["commands.constrain.toggle", "vibe3d.apps.desktop.commands.constrain.toggle"],
            ["commands.file.load", "vibe3d.apps.desktop.commands.file.load"],
            ["commands.file.save", "vibe3d.apps.desktop.commands.file.save"],
            ["commands.mesh.magnet", "vibe3d.editing.commands.editor.commands.mesh.magnet"],
            ["commands.mesh.morph", "vibe3d.editing.commands.editor.commands.mesh.morph"],
            ["commands.mesh.remesh", "vibe3d.editing.commands.editor.commands.mesh.remesh"],
            ["commands.path.define", "vibe3d.apps.desktop.commands.path.define"],
            ["commands.prefs.coord_rounding", "vibe3d.apps.desktop.commands.prefs.coord_rounding"],
            ["commands.prefs.trackball", "vibe3d.apps.desktop.commands.prefs.trackball"],
            ["commands.snap.mode", "vibe3d.apps.desktop.commands.snap.mode"],
            ["commands.snap.toggle", "vibe3d.apps.desktop.commands.snap.toggle"],
            ["commands.snap.toggle_type", "vibe3d.apps.desktop.commands.snap.toggle_type"],
            ["commands.symmetry.toggle", "vibe3d.apps.desktop.commands.symmetry.toggle"],
            ["commands.test_undo_flags", "vibe3d.apps.desktop.commands.test_undo_flags"],
            ["commands.ui.about", "vibe3d.apps.desktop.commands.ui.about"],
            ["commands.ui.channels", "vibe3d.apps.desktop.commands.ui.channels"],
            ["commands.ui.image_list", "vibe3d.apps.desktop.commands.ui.image_list"],
            ["commands.ui.layer_list", "vibe3d.apps.desktop.commands.ui.layer_list"],
            ["commands.ui.layout_reset", "vibe3d.apps.desktop.commands.ui.layout_reset"],
            ["commands.ui.pie", "vibe3d.apps.desktop.commands.ui.pie"],
            ["commands.ui.statistics", "vibe3d.apps.desktop.commands.ui.statistics"],
            ["commands.ui.tool_properties", "vibe3d.apps.desktop.commands.ui.tool_properties"],
            ["commands.ui.viewport_props", "vibe3d.apps.desktop.commands.ui.viewport_props"],
            ["commands.viewport.command_base", "vibe3d.apps.desktop.commands.viewport.command_base"],
            ["commands.viewport.display", "vibe3d.apps.desktop.commands.viewport.display"],
            ["commands.viewport.fit", "vibe3d.apps.desktop.commands.viewport.fit"],
            ["commands.viewport.fit_selected", "vibe3d.apps.desktop.commands.viewport.fit_selected"],
            ["commands.viewport.grid_steps", "vibe3d.apps.desktop.commands.viewport.grid_steps"],
            ["commands.viewport.independence", "vibe3d.apps.desktop.commands.viewport.independence"],
            ["commands.viewport.layout_preset", "vibe3d.apps.desktop.commands.viewport.layout_preset"],
            ["commands.viewport.master", "vibe3d.apps.desktop.commands.viewport.master"],
            ["commands.viewport.view_preset", "vibe3d.apps.desktop.commands.viewport.view_preset"],
            ["commands.workplane", "vibe3d.apps.desktop.commands.workplane"],
            ["create_tool_registration", "vibe3d.apps.desktop.create_tool_registration"],
            ["edit_tool_registration", "vibe3d.apps.desktop.edit_tool_registration"],
            ["editor_app", "vibe3d.apps.desktop.editor_app"],
            ["file_io_registration", "vibe3d.apps.desktop.file_io_registration"],
            ["frame_runner", "vibe3d.apps.desktop.frame_runner"],
            ["frame_stall", "vibe3d.apps.desktop.frame_stall"],
            ["guarded_action_controller", "vibe3d.apps.desktop.guarded_action_controller"],
            ["history_macro_registration", "vibe3d.apps.desktop.history_macro_registration"],
            ["http_command_adapter", "vibe3d.apps.desktop.http_command_adapter"],
            ["http_providers", "vibe3d.apps.desktop.http_providers"],
            ["input_frame_state", "vibe3d.apps.desktop.input_frame_state"],
            ["input_router", "vibe3d.apps.desktop.input_router"],
            ["item_command_registration", "vibe3d.apps.desktop.item_command_registration"],
            ["item_pick", "vibe3d.apps.desktop.item_pick"],
            ["layout_reset_action", "vibe3d.apps.desktop.layout_reset_action"],
            ["mesh_command_registration", "vibe3d.apps.desktop.mesh_command_registration"],
            ["pipe_command_registration", "vibe3d.apps.desktop.pipe_command_registration"],
            ["prefs", "vibe3d.apps.desktop.prefs"],
            ["registration", "vibe3d.apps.desktop.registration"],
            ["scene_file_lifecycle_registration", "vibe3d.apps.desktop.scene_file_lifecycle_registration"],
            ["scene_reset_effects", "vibe3d.apps.desktop.scene_reset_effects"],
            ["selection_command_registration", "vibe3d.apps.desktop.selection_command_registration"],
            ["tool_lifecycle_registration", "vibe3d.apps.desktop.tool_lifecycle_registration"],
            ["transform_tool_registration", "vibe3d.apps.desktop.transform_tool_registration"],
            ["ui.viewport_render", "vibe3d.ui.editor.ui.viewport_render"],
            ["view_settings_registration", "vibe3d.apps.desktop.view_settings_registration"],
            ["viewport_command_registration", "vibe3d.apps.desktop.viewport_command_registration"],
            ["web_gl_loader", "vibe3d.apps.desktop.web_gl_loader"]])
            if (name == pair[0]) { name = pair[1]; ++finalTranslations; }
    assert(finalTranslations == 482, "Wave19 final web original identity bijection");
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
    const nativeSource = readText(wave19MathPhysicalPath(buildPath(repoRoot, "packages", "document-io", "source", "io", "native.d")));
    assert(nativeSource.count(
            "if (!morphVertexIndexInBounds(vidx, mesh.vertices.length))") == 1,
        "W16-W morph indices must be range-checked as long before size_t narrowing");
}
