module vibe3d.editing.selection.scene_query.tests.unit.scene_query_population_test;

// Wave14 frozen owned enabled module identities, independently of imports.
unittest {
    import object : ModuleInfo;
    import std.algorithm : canFind, sort;
    import std.stdio : writeln;
    immutable string[] expected = [
        "vibe3d.editing.selection.scene_query.bvh_pick",
        "vibe3d.editing.selection.scene_query.tests.unit.bvh_pick_test",
        "vibe3d.editing.selection.scene_query.tests.unit.scene_query_population_test",
    ];
    assert(expected.length == 3, "scene-query frozen owned roster floor 3");
    string[] actual;
    foreach (info; ModuleInfo)
        if (info !is null && info.unitTest !is null && expected.canFind(info.name))
            actual ~= info.name;
    foreach (name; expected) {
        size_t occurrences;
        foreach (found; actual) if (found == name) ++occurrences;
        assert(occurrences == 1, "PKG-POP-scene-query must occur exactly once: " ~ name);
    }
    actual.sort;
    assert(actual.length == 3, "scene-query selected owned population 3");
    assert(actual == expected, "scene-query selected owned sorted identity");
    writeln("PKG-POPULATION package=scene-query selected=3 exactly-once=3");
}
