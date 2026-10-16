module vibe3d.editing.selection.model.tests.unit.selection_model_population_test;

// Wave14 frozen owned enabled module identities, independently of imports.
unittest {
    import object : ModuleInfo;
    import std.algorithm : canFind, sort;
    import std.stdio : writeln;
    immutable string[] expected = [
        "vibe3d.editing.selection.model.tests.unit.selection_model_population_test",
        "vibe3d.editing.selection.model.tests.unit.selection_product_source_public_test",
        "vibe3d.editing.selection.model.tests.unit.selection_projection_algorithm_cells_test",
    ];
    assert(expected.length == 3, "selection-model frozen owned roster floor 3");
    string[] actual;
    foreach (info; ModuleInfo)
        if (info !is null && info.unitTest !is null && expected.canFind(info.name))
            actual ~= info.name;
    foreach (name; expected) {
        size_t occurrences;
        foreach (found; actual) if (found == name) ++occurrences;
        assert(occurrences == 1, "PKG-POP-selection-model must occur exactly once: " ~ name);
    }
    actual.sort;
    assert(actual.length == 3, "selection-model selected owned population 3");
    assert(actual == expected, "selection-model selected owned sorted identity");
    writeln("PKG-POPULATION package=selection-model selected=3 exactly-once=3");
}
