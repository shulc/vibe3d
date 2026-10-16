module tests.unit.root_test_package_population_test;

// Task 20262150: frozen source identities judge the root binary without importing
// any judged module. Runtime cell execution remains ut_runner's separate authority.
// Wave8 D: this names the existing private snapshot fixture, not a new cell.
// getUnitTests observes emitted functions under the actual fixture version.
private template SnapshotFixturePopulation() {
    import mesh;
    enum coreCells = __traits(getUnitTests, mesh).length;
    static assert(coreCells >= 2, "ROOT-SNAPSHOT-CELL core unittest population floor");
    enum mappedCells = () {
        size_t count;
        static foreach (cell; __traits(getUnitTests, mesh)) {
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
    auto ordered = expected.dup;
    ordered.sort();
    assert(ordered == expected, "root package ModuleInfo manifest sorted");
    size_t[string] occurrences;
    size_t[string] transitional;
    foreach (info; ModuleInfo) {
        if (info is null || info.name is null) continue;
        if (expected.canFind(info.name)) ++occurrences[info.name];
        if (mathMoved && ["math", "math_geometry", "math_matrix", "math_quaternion", "math_vector", "vibe3d.util.math"].canFind(info.name)) {
            ++transitional[info.name];
            assert(info.unitTest is null, "root math transitional module has no unittest: " ~ info.name);
        }
    }
    if (mathMoved) {
        assert(transitional.length == 6, "root math transitional population 6");
        foreach (name; ["math", "math_geometry", "math_matrix", "math_quaternion", "math_vector", "vibe3d.util.math"])
            assert(transitional.get(name, 0) == 1, "root math transitional exactly once: " ~ name);
    }
    foreach (name; ["eventlog", "held_gesture_buttons", "tool_input", "input_zones", "input_context", "shortcuts"])
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
