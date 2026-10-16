module vibe3d.documents.channels.tests.unit.document_channels_population_test;

// Task 20262620: frozen owner source-private and public cells are judged without
// importing them; compiler admission and execution remain separate witnesses.
unittest {
    import object : ModuleInfo;
    import std.algorithm : canFind, sort;
    import std.stdio : writeln;

    immutable string[] expected = [
        "vibe3d.documents.channels.tests.unit.layer_params_test",
    ];
    assert(expected.length == 1, "document-channels frozen carrier roster floor 1");
    string[] actual;
    foreach (info; ModuleInfo)
        if (info !is null && info.unitTest !is null && expected.canFind(info.name))
            actual ~= info.name;
    foreach (name; expected) {
        size_t occurrences;
        foreach (found; actual) if (found == name) ++occurrences;
        assert(occurrences == 1,
               "PKG-POP-document-channels must occur exactly once: " ~ name);
    }
    actual.sort;
    assert(actual.length == 1, "document-channels selected carrier population 1");
    assert(actual == expected, "document-channels selected carrier sorted identity");
    writeln("PKG-POPULATION package=document-channels selected=1 exactly-once=1");
}
