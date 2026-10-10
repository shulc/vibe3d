module tests.unit.root_test_package_population_test;

// Task 20262150: frozen source identities judge the root binary without importing
// any judged module. Runtime cell execution remains ut_runner's separate authority.
unittest {
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.string : splitLines, strip;
    import std.algorithm : sort, canFind;
    import std.array : array;
    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    string[] expected;
    foreach (line; readText(buildPath(root, "tests/unit/root_test_package_module_roster.txt")).splitLines)
        if (line.strip.length && line.strip[0] != '#') expected ~= line.strip;
    assert(expected.length == 148, "root package ModuleInfo frozen population 148");
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
    assert(occurrences.length == 148, "root package ModuleInfo selected population 148");
    foreach (name; expected)
        assert(occurrences.get(name, 0) == 1,
               "root package ModuleInfo must occur exactly once: " ~ name);
}
