module vibe3d.viewport.camera.tests.unit.camera_model_population_test;

// Task 20262620: frozen owner source-private and public cells are judged without
// importing them; compiler admission and execution remain separate witnesses.
unittest {
    import object : ModuleInfo;
    import std.algorithm : canFind, sort;
    import std.stdio : writeln;

    immutable string[] expected = [
        "vibe3d.viewport.camera.tests.unit.view_source_cells_test",
        "vibe3d.viewport.camera.tests.unit.view_test",
    ];
    assert(expected.length == 2, "camera-model frozen carrier roster floor 2");
    string[] actual;
    foreach (info; ModuleInfo)
        if (info !is null && info.unitTest !is null && expected.canFind(info.name))
            actual ~= info.name;
    foreach (name; expected) {
        size_t occurrences;
        foreach (found; actual) if (found == name) ++occurrences;
        assert(occurrences == 1,
               "PKG-POP-camera-model must occur exactly once: " ~ name);
    }
    actual.sort;
    assert(actual.length == 2, "camera-model selected carrier population 2");
    assert(actual == expected, "camera-model selected carrier sorted identity");
    writeln("PKG-POPULATION package=camera-model selected=2 exactly-once=2");
}
