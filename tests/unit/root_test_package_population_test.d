module tests.unit.root_test_package_population_test;

// Task 20262150: frozen source identities judge the root binary without importing
// any judged module. Runtime cell execution remains ut_runner's separate authority.
// Wave8 D: this names the existing private snapshot fixture, not a new cell.
// getUnitTests observes emitted functions under the actual fixture version.
private template SnapshotFixturePopulation() {
    import vibe3d.mesh.core.mesh;
    enum coreCells = __traits(getUnitTests, vibe3d.mesh.core.mesh).length;
    static assert(coreCells >= 2, "ROOT-SNAPSHOT-CELL core unittest population floor");
    enum mappedCells = () {
        size_t count;
        static foreach (cell; __traits(getUnitTests, vibe3d.mesh.core.mesh)) {
            static foreach (attribute; __traits(getAttributes, cell)) {
                static if (is(typeof(attribute) == string)) {
                    static if (attribute == "mesh-snapshot-private-cells") ++count;
                }
            }
        }
        return count;
    }();
    static assert(mappedCells == 1,
        "ROOT-SNAPSHOT-CELL mapped private fixture must be compiled exactly once");
    static assert(coreCells > mappedCells,
        "ROOT-SNAPSHOT-CELL ordinary core unittest complement floor");
    enum SnapshotFixturePopulation = true;
}

unittest {
    static assert(SnapshotFixturePopulation!());
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.string : splitLines, strip;
    import std.algorithm : sort, canFind;
    import std.array : array;
    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    import tests.unit.census_symbols : wave19MathMoved;
    const mathMoved = wave19MathMoved(root);
    string[] expected;
    foreach (line; readText(buildPath(root, "tests/unit/root_test_package_module_roster.txt")).splitLines)
        if (line.strip.length && line.strip[0] != '#') expected ~= line.strip;
    assert(expected.length == 480, "root package ModuleInfo frozen population 480");
    foreach (moduleName; ["math", "math_geometry", "math_matrix", "math_quaternion", "math_vector"]) {
        const selected = mathMoved ? "vibe3d.util.math." ~ moduleName : moduleName;
        const rejected = mathMoved ? moduleName : "vibe3d.util.math." ~ moduleName;
        assert(expected.canFind(selected) && !expected.canFind(rejected),
            "root package ModuleInfo selected math identity: " ~ moduleName);
    }
    // 20263013: selected D1 real definitions are a bijection; runtime remains 480.
    assert(expected.canFind("vibe3d.editing.contracts.editmode") && !expected.canFind("editmode"), "root package ModuleInfo selected D1 identity: editmode");
    assert(expected.canFind("vibe3d.editing.contracts.prepared_tool_effect") && !expected.canFind("prepared_tool_effect"), "root package ModuleInfo selected D1 identity: prepared_tool_effect");
    assert(expected.canFind("vibe3d.editing.contracts.seltype") && !expected.canFind("seltype"), "root package ModuleInfo selected D1 identity: seltype");
    assert(expected.canFind("vibe3d.editing.contracts.tool_policy_values") && !expected.canFind("tool_policy_values"), "root package ModuleInfo selected D1 identity: tool_policy_values");
    assert(expected.canFind("vibe3d.editing.interaction.data.ai.advisor") && !expected.canFind("ai.advisor"), "root package ModuleInfo selected D1 identity: ai.advisor");
    assert(expected.canFind("vibe3d.editing.interaction.data.ai.debug_trace") && !expected.canFind("ai.debug_trace"), "root package ModuleInfo selected D1 identity: ai.debug_trace");
    assert(expected.canFind("vibe3d.editing.interaction.data.ai.interaction") && !expected.canFind("ai.interaction"), "root package ModuleInfo selected D1 identity: ai.interaction");
    assert(expected.canFind("vibe3d.mesh.change.change_bus") && !expected.canFind("change_bus"), "root package ModuleInfo selected D1 identity: change_bus");
    assert(expected.canFind("vibe3d.mesh.change.mesh_dirty") && !expected.canFind("mesh_dirty"), "root package ModuleInfo selected D1 identity: mesh_dirty");
    assert(expected.canFind("vibe3d.mesh.contracts.mesh_corner_maps") && !expected.canFind("mesh_corner_maps"), "root package ModuleInfo selected D1 identity: mesh_corner_maps");
    assert(expected.canFind("vibe3d.mesh.contracts.mesh_plane_types") && !expected.canFind("mesh_plane_types"), "root package ModuleInfo selected D1 identity: mesh_plane_types");
    assert(expected.canFind("vibe3d.mesh.contracts.mesh_scope") && !expected.canFind("mesh_scope"), "root package ModuleInfo selected D1 identity: mesh_scope");
    assert(expected.canFind("vibe3d.mesh.contracts.mesh_types") && !expected.canFind("mesh_types"), "root package ModuleInfo selected D1 identity: mesh_types");
    assert(expected.canFind("vibe3d.editing.params.argstring") && !expected.canFind("argstring"), "root package ModuleInfo selected D1 identity: argstring");
    assert(expected.canFind("vibe3d.editing.params.params") && !expected.canFind("params"), "root package ModuleInfo selected D1 identity: params");
    assert(expected.canFind("vibe3d.util.profiling.perf_probe") && !expected.canFind("perf_probe"), "root package ModuleInfo selected D1 identity: perf_probe");
    assert(expected.canFind("vibe3d.util.spatial.item_xform") && !expected.canFind("item_xform"), "root package ModuleInfo selected D1 identity: item_xform");
    assert(expected.canFind("vibe3d.util.spatial.spatial") && !expected.canFind("spatial"), "root package ModuleInfo selected D1 identity: spatial");
    assert(expected.canFind("vibe3d.util.spatial.symmetry_plane") && !expected.canFind("symmetry_plane"), "root package ModuleInfo selected D1 identity: symmetry_plane");
    assert(expected.canFind("vibe3d.util.spatial.trackball") && !expected.canFind("trackball"), "root package ModuleInfo selected D1 identity: trackball");
    assert(expected.canFind("vibe3d.util.spatial.workplane_basis") && !expected.canFind("workplane_basis"), "root package ModuleInfo selected D1 identity: workplane_basis");
    assert(expected.canFind("vibe3d.util.json_number.json_num") && !expected.canFind("json_num"), "root package ModuleInfo selected D1 identity: json_num");
    assert(expected.canFind("vibe3d.util.log.log") && !expected.canFind("log"), "root package ModuleInfo selected D1 identity: log");
    assert(expected.canFind("vibe3d.util.parallel.tsan_annotate") && !expected.canFind("tsan_annotate"), "root package ModuleInfo selected D1 identity: tsan_annotate");
    assert(expected.canFind("vibe3d.util.plane_bytes.plane_bytes") && !expected.canFind("plane_bytes"), "root package ModuleInfo selected D1 identity: plane_bytes");
    assert(expected.canFind("vibe3d.util.screen_buckets.screen_buckets") && !expected.canFind("screen_buckets"), "root package ModuleInfo selected D1 identity: screen_buckets");
    assert(expected.canFind("vibe3d.viewport.camera.view") && !expected.canFind("view"), "root package ModuleInfo selected D2 identity: view");
    assert(expected.canFind("vibe3d.documents.model.document") && !expected.canFind("document"), "root package ModuleInfo selected D2 identity: document");
    assert(expected.canFind("vibe3d.documents.model.document_selection") && !expected.canFind("document_selection"), "root package ModuleInfo selected D2 identity: document_selection");
    assert(expected.canFind("vibe3d.documents.model.edit_target_contract") && !expected.canFind("edit_target_contract"), "root package ModuleInfo selected D2 identity: edit_target_contract");
    assert(expected.canFind("vibe3d.documents.model.image_data") && !expected.canFind("image_data"), "root package ModuleInfo selected D2 identity: image_data");
    assert(expected.canFind("vibe3d.documents.model.item_kinds") && !expected.canFind("item_kinds"), "root package ModuleInfo selected D2 identity: item_kinds");
    assert(expected.canFind("vibe3d.documents.image_codec.io.image_decode") && !expected.canFind("io.image_decode"), "root package ModuleInfo selected D2 identity: io.image_decode");
    assert(expected.canFind("vibe3d.platform.input.eventlog") && !expected.canFind("eventlog"), "root package ModuleInfo selected D2 identity: eventlog");
    assert(expected.canFind("vibe3d.platform.input.held_gesture_buttons") && !expected.canFind("held_gesture_buttons"), "root package ModuleInfo selected D2 identity: held_gesture_buttons");
    assert(expected.canFind("vibe3d.platform.input.input_context") && !expected.canFind("input_context"), "root package ModuleInfo selected D2 identity: input_context");
    assert(expected.canFind("vibe3d.platform.input.input_zones") && !expected.canFind("input_zones"), "root package ModuleInfo selected D2 identity: input_zones");
    assert(expected.canFind("vibe3d.platform.input.shortcuts") && !expected.canFind("shortcuts"), "root package ModuleInfo selected D2 identity: shortcuts");
    assert(expected.canFind("vibe3d.platform.input.tool_input") && !expected.canFind("tool_input"), "root package ModuleInfo selected D2 identity: tool_input");
    assert(expected.canFind("vibe3d.mesh.edit_log.mesh_edit_delta") && !expected.canFind("mesh_edit_delta"), "root package ModuleInfo selected D2 identity: mesh_edit_delta");
    assert(expected.canFind("vibe3d.mesh.edit_replay.mesh_edit_replay") && !expected.canFind("mesh_edit_replay"), "root package ModuleInfo selected D2 identity: mesh_edit_replay");
    assert(expected.canFind("vibe3d.mesh.ops.geometry_clipboard") && !expected.canFind("geometry_clipboard"), "root package ModuleInfo selected D2 identity: geometry_clipboard");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_analysis") && !expected.canFind("mesh_analysis"), "root package ModuleInfo selected D2 identity: mesh_analysis");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_edge_slice") && !expected.canFind("mesh_edge_slice"), "root package ModuleInfo selected D2 identity: mesh_edge_slice");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.bevel_curves") && !expected.canFind("mesh_ops.bevel_curves"), "root package ModuleInfo selected D2 identity: mesh_ops.bevel_curves");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.bevel_fin") && !expected.canFind("mesh_ops.bevel_fin"), "root package ModuleInfo selected D2 identity: mesh_ops.bevel_fin");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.bevel_vertex") && !expected.canFind("mesh_ops.bevel_vertex"), "root package ModuleInfo selected D2 identity: mesh_ops.bevel_vertex");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.box_geom") && !expected.canFind("mesh_ops.box_geom"), "root package ModuleInfo selected D2 identity: mesh_ops.box_geom");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.bridge") && !expected.canFind("mesh_ops.bridge"), "root package ModuleInfo selected D2 identity: mesh_ops.bridge");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.bridge_patch") && !expected.canFind("mesh_ops.bridge_patch"), "root package ModuleInfo selected D2 identity: mesh_ops.bridge_patch");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.cleanup") && !expected.canFind("mesh_ops.cleanup"), "root package ModuleInfo selected D2 identity: mesh_ops.cleanup");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.connected_mask") && !expected.canFind("mesh_ops.connected_mask"), "root package ModuleInfo selected D2 identity: mesh_ops.connected_mask");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.cut") && !expected.canFind("mesh_ops.cut"), "root package ModuleInfo selected D2 identity: mesh_ops.cut");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.decimate") && !expected.canFind("mesh_ops.decimate"), "root package ModuleInfo selected D2 identity: mesh_ops.decimate");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.edge_bevel") && !expected.canFind("mesh_ops.edge_bevel"), "root package ModuleInfo selected D2 identity: mesh_ops.edge_bevel");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.extrude") && !expected.canFind("mesh_ops.extrude"), "root package ModuleInfo selected D2 identity: mesh_ops.extrude");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.face_alignment") && !expected.canFind("mesh_ops.face_alignment"), "root package ModuleInfo selected D2 identity: mesh_ops.face_alignment");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.face_merge") && !expected.canFind("mesh_ops.face_merge"), "root package ModuleInfo selected D2 identity: mesh_ops.face_merge");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.loop_slice") && !expected.canFind("mesh_ops.loop_slice"), "root package ModuleInfo selected D2 identity: mesh_ops.loop_slice");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.poly_bevel") && !expected.canFind("mesh_ops.poly_bevel"), "root package ModuleInfo selected D2 identity: mesh_ops.poly_bevel");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.revolve") && !expected.canFind("mesh_ops.revolve"), "root package ModuleInfo selected D2 identity: mesh_ops.revolve");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.select_loop") && !expected.canFind("mesh_ops.select_loop"), "root package ModuleInfo selected D2 identity: mesh_ops.select_loop");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.thicken") && !expected.canFind("mesh_ops.thicken"), "root package ModuleInfo selected D2 identity: mesh_ops.thicken");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_ops.triangulate") && !expected.canFind("mesh_ops.triangulate"), "root package ModuleInfo selected D2 identity: mesh_ops.triangulate");
    assert(expected.canFind("vibe3d.mesh.ops.mesh_stats") && !expected.canFind("mesh_stats"), "root package ModuleInfo selected D2 identity: mesh_stats");
    assert(expected.canFind("vibe3d.mesh.ops.uv_island") && !expected.canFind("uv_island"), "root package ModuleInfo selected D2 identity: uv_island");
    assert(expected.canFind("vibe3d.mesh.ops.uv_project") && !expected.canFind("uv_project"), "root package ModuleInfo selected D2 identity: uv_project");
    assert(expected.canFind("vibe3d.mesh.ops.uv_relax") && !expected.canFind("uv_relax"), "root package ModuleInfo selected D2 identity: uv_relax");
    assert(expected.canFind("vibe3d.mesh.ops.uv_transform") && !expected.canFind("uv_transform"), "root package ModuleInfo selected D2 identity: uv_transform");
    assert(expected.canFind("vibe3d.mesh.ops.uv_unwrap") && !expected.canFind("uv_unwrap"), "root package ModuleInfo selected D2 identity: uv_unwrap");
    assert(expected.canFind("vibe3d.mesh.ops.uv_weld") && !expected.canFind("uv_weld"), "root package ModuleInfo selected D2 identity: uv_weld");
    assert(expected.canFind("vibe3d.mesh.preview.active_mesh_resolver") && !expected.canFind("active_mesh_resolver"), "root package ModuleInfo selected D2 identity: active_mesh_resolver");
    assert(expected.canFind("vibe3d.mesh.preview.morph_preview") && !expected.canFind("morph_preview"), "root package ModuleInfo selected D2 identity: morph_preview");
    assert(expected.canFind("vibe3d.mesh.snapshot.snapshot") && !expected.canFind("snapshot"), "root package ModuleInfo selected D2 identity: snapshot");
    assert(expected.canFind("vibe3d.mesh.topology.mesh_topo") && !expected.canFind("mesh_topo"), "root package ModuleInfo selected D2 identity: mesh_topo");
    assert(expected.canFind("vibe3d.mesh.core.mesh") && !expected.canFind("mesh"), "root package ModuleInfo selected D2 identity: mesh");
    assert(expected.canFind("vibe3d.mesh.core.mesh_morph") && !expected.canFind("mesh_morph"), "root package ModuleInfo selected D2 identity: mesh_morph");
    assert(expected.canFind("vibe3d.mesh.core.mesh_planes") && !expected.canFind("mesh_planes"), "root package ModuleInfo selected D2 identity: mesh_planes");
    assert(expected.canFind("vibe3d.mesh.core.mesh_selsets") && !expected.canFind("mesh_selsets"), "root package ModuleInfo selected D2 identity: mesh_selsets");
    assert(expected.canFind("vibe3d.editing.pipeline.contracts.operator") && !expected.canFind("operator"), "root package ModuleInfo selected D2 identity: operator");
    assert(expected.canFind("vibe3d.editing.pipeline.contracts.toolpipe.packets") && !expected.canFind("toolpipe.packets"), "root package ModuleInfo selected D2 identity: toolpipe.packets");
    auto ordered = expected.dup;
    ordered.sort();
    assert(ordered == expected, "root package ModuleInfo manifest sorted");
    size_t[string] occurrences;
    size_t[string] transitional;
    foreach (info; ModuleInfo) {
        if (info is null || info.name is null) continue;
        if (expected.canFind(info.name)) ++occurrences[info.name];
        if (["vibe3d.mesh.core", "vibe3d.documents.model"].canFind(info.name)) {
            ++transitional[info.name];
            assert(info.unitTest is null, "root selective facade has no unittest: " ~ info.name);
        }
        if (mathMoved && ["vibe3d.util.math"].canFind(info.name)) {
            ++transitional[info.name];
            assert(info.unitTest is null, "root math transitional module has no unittest: " ~ info.name);
        }
    }
    if (mathMoved) {
        assert(transitional.length == 3, "root final selective APIs3");
        foreach (name; ["vibe3d.mesh.core", "vibe3d.documents.model"])
            assert(transitional.get(name, 0) == 1, "root selective API exactly once: " ~ name);
        foreach (name; ["vibe3d.util.math"])
            assert(transitional.get(name, 0) == 1, "root math transitional exactly once: " ~ name);
    }
    foreach (name; ["vibe3d.platform.input.eventlog", "vibe3d.platform.input.held_gesture_buttons", "vibe3d.platform.input.tool_input", "vibe3d.platform.input.input_zones", "vibe3d.platform.input.input_context", "vibe3d.platform.input.shortcuts"])
        assert(occurrences.get(name, 0) == 1,
               "ROOT-PACKAGE-MODULE-input-events must occur exactly once: " ~ name);
    foreach (name; ["camera_stamp", "display_state", "viewport_scheme", "viewport_overlay_mode", "viewport_probe_sampling", "weightmap_view", "light_rig", "vertex_normals"])
        assert(occurrences.get(name, 0) == 1,
               "ROOT-PACKAGE-MODULE-display-policy must occur exactly once: " ~ name);
    foreach (name; ["gl_thread_guard", "gpu_pass_timer", "mesh_gpu", "shader", "viewport_env", "gpu_select"])
        assert(occurrences.get(name, 0) == 1,
               "ROOT-PACKAGE-MODULE-viewport-gpu must occur exactly once: " ~ name);
    foreach (name; ["subpatch_preview", "subpatch_osd", "subpatch_worker", "subpatch_worker_web", "subpatch_factories"])
        assert(occurrences.get(name, 0) == 1,
               "ROOT-PACKAGE-MODULE-subpatch-preview must occur exactly once: " ~ name);
    assert(occurrences.length == 480, "root package ModuleInfo selected population 480");
    foreach (name; expected)
        assert(occurrences.get(name, 0) == 1,
               "root package ModuleInfo must occur exactly once: " ~ name);
}
