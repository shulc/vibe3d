module tests.unit.display_policy_population_test;

// Task 20262210: frozen display public carriers are judged without
// importing them; compiler admission and execution remain separate witnesses.
unittest {
    import object : ModuleInfo;
    import std.algorithm : canFind, sort;
    import std.stdio : writeln;

    immutable string[] expected = [
        "tests.unit.camera_stamp_test",
        "tests.unit.vertex_normals_test",
        "tests.unit.viewport_scheme_test",
        "tests.unit.weightmap_state_test",
    ];
    assert(expected.length == 4, "display-policy frozen carrier roster floor 4");
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
    assert(actual.length == 4, "display-policy selected carrier population 4");
    assert(actual == expected, "display-policy selected carrier sorted identity");
    writeln("PKG-POPULATION package=display-policy selected=4 exactly-once=4");
}
