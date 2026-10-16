module vibe3d.viewport.gpu.tests.unit.viewport_gpu_population_test;

// Task 20262220: frozen GPU public/private carriers are judged without
// importing them; compiler admission and execution remain separate witnesses.
unittest {
    import object : ModuleInfo;
    import std.algorithm : canFind, sort;
    import std.stdio : writeln;

    immutable string[] expected = [
        "vibe3d.viewport.gpu.gl_thread_guard",
        "vibe3d.viewport.gpu.mesh_gpu",
        "vibe3d.viewport.gpu.tests.unit.viewport_env_test",
    ];
    assert(expected.length == 3, "viewport-gpu frozen carrier roster floor 3");
    string[] actual;
    foreach (info; ModuleInfo)
        if (info !is null && info.unitTest !is null && expected.canFind(info.name))
            actual ~= info.name;
    foreach (name; expected) {
        size_t occurrences;
        foreach (found; actual) if (found == name) ++occurrences;
        assert(occurrences == 1,
               "PKG-POP-viewport-gpu must occur exactly once: " ~ name);
    }
    actual.sort;
    assert(actual.length == 3, "viewport-gpu selected carrier population 3");
    assert(actual == expected, "viewport-gpu selected carrier sorted identity");
    writeln("PKG-POPULATION package=viewport-gpu selected=3 exactly-once=3");
}
