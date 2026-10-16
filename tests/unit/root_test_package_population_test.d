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
    auto ordered = expected.dup;
    ordered.sort();
    assert(ordered == expected, "root package ModuleInfo manifest sorted");
    size_t[string] occurrences;
    foreach (info; ModuleInfo) {
        if (info is null || info.name is null) continue;
        if (expected.canFind(info.name)) ++occurrences[info.name];
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
