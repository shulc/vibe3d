module vibe3d.viewport.subpatch.tests.unit.subpatch_preview_population_test;

// Task 20262250: frozen GPU public/private carriers are judged without
// importing them; compiler admission and execution remain separate witnesses.
unittest {
    import object : ModuleInfo;
    import std.algorithm : canFind, sort;
    import std.stdio : writeln;

    immutable string[] expected = [
        "vibe3d.viewport.gpu.gl_thread_guard",
        "vibe3d.viewport.gpu.mesh_gpu",
        "vibe3d.viewport.subpatch.tests.unit.subpatch_key_fold_test",
        "vibe3d.viewport.subpatch.tests.unit.subpatch_level_policy_test",
        "vibe3d.viewport.subpatch.tests.unit.subpatch_osd_test",
    ];
    assert(expected.length == 5, "subpatch-preview frozen carrier roster floor 5");
    string[] actual;
    foreach (info; ModuleInfo)
        if (info !is null && info.unitTest !is null && expected.canFind(info.name))
            actual ~= info.name;
    foreach (name; expected) {
        size_t occurrences;
        foreach (found; actual) if (found == name) ++occurrences;
        assert(occurrences == 1,
               "PKG-POP-subpatch-preview must occur exactly once: " ~ name);
    }
    actual.sort;
    assert(actual.length == 5, "subpatch-preview selected carrier population 5");
    assert(actual == expected, "subpatch-preview selected carrier sorted identity");
    writeln("PKG-POPULATION package=subpatch-preview selected=5 exactly-once=5");
}
