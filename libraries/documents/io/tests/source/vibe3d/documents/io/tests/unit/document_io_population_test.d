module vibe3d.documents.io.tests.unit.document_io_population_test;

// Task 20262620: frozen owner source-private and public cells are judged without
// importing them; compiler admission and execution remain separate witnesses.
unittest {
    import object : ModuleInfo;
    import std.algorithm : canFind, sort;
    import std.stdio : writeln;

    immutable string[] expected = [
        "vibe3d.documents.io.io.native",
        "vibe3d.documents.io.tests.unit.io.image_path_test",
        "vibe3d.documents.io.tests.unit.io.native_source_cells_test",
        "vibe3d.documents.io.tests.unit.io.native_test",
    ];
    assert(expected.length == 4, "document-io frozen carrier roster floor 4");
    string[] actual;
    foreach (info; ModuleInfo)
        if (info !is null && info.unitTest !is null && expected.canFind(info.name))
            actual ~= info.name;
    foreach (name; expected) {
        size_t occurrences;
        foreach (found; actual) if (found == name) ++occurrences;
        assert(occurrences == 1,
               "PKG-POP-document-io must occur exactly once: " ~ name);
    }
    actual.sort;
    assert(actual.length == 4, "document-io selected carrier population 4");
    assert(actual == expected, "document-io selected carrier sorted identity");
    writeln("PKG-POPULATION package=document-io selected=4 exactly-once=4");
}
