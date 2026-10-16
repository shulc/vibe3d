module vibe3d.viewport.display_policy.tests.unit.display_policy_population_test;

// Task 20262210: frozen display public carriers are judged without
// importing them; compiler admission and execution remain separate witnesses.
unittest {
    import object : ModuleInfo;
    import std.algorithm : canFind, sort;
    import std.stdio : writeln;

    immutable string[] expected = [
        "vibe3d.viewport.display_policy.tests.unit.camera_stamp_test",
        "vibe3d.viewport.display_policy.tests.unit.retopology_display_model_test",
        "vibe3d.viewport.display_policy.tests.unit.retopology_dot_cull_test",
        "vibe3d.viewport.display_policy.tests.unit.retopology_line_shade_algorithm_cells_test",
        "vibe3d.viewport.display_policy.tests.unit.retopology_order_algorithm_cells_test",
        "vibe3d.viewport.display_policy.tests.unit.select_visibility_test",
        "vibe3d.viewport.display_policy.tests.unit.vertex_normals_test",
        "vibe3d.viewport.display_policy.tests.unit.viewport_scheme_test",
        "vibe3d.viewport.display_policy.tests.unit.weightmap_state_test",
    ];
    assert(expected.length == 9, "display-policy frozen carrier roster floor 9");
    string[] actual;
    foreach (info; ModuleInfo)
        if (info !is null && info.unitTest !is null && expected.canFind(info.name))
            actual ~= info.name;
    foreach (name; expected) {
        size_t occurrences;
        foreach (found; actual) if (found == name) ++occurrences;
        assert(occurrences == 1,
               "PKG-POP-display-policy must occur exactly once: " ~ name);
    }
    actual.sort;
    assert(actual.length == 9, "display-policy selected carrier population 9");
    assert(actual == expected, "display-policy selected carrier sorted identity");
    writeln("PKG-POPULATION package=display-policy selected=9 exactly-once=9");
}
