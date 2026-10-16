module vibe3d.editing.commands.editor.tests.unit.editor_commands_population_test;

// Wave14 frozen owned enabled module identities, independently of imports.
unittest {
    import object : ModuleInfo;
    import std.algorithm : canFind, sort;
    import std.stdio : writeln;
    immutable string[] expected = [
        "vibe3d.editing.commands.editor.commands.mesh.edge_crease",
        "vibe3d.editing.commands.editor.tests.unit.commands.mesh.edge_crease_source_public_test",
        "vibe3d.editing.commands.editor.tests.unit.commands.mesh.remove_source_public_test",
        "vibe3d.editing.commands.editor.tests.unit.commands.mesh.symmetrize_source_public_test",
        "vibe3d.editing.commands.editor.tests.unit.commands.mesh.vertex_set_source_public_test",
        "vibe3d.editing.commands.editor.tests.unit.commands.select.boundary_source_public_test",
        "vibe3d.editing.commands.editor.tests.unit.commands.select.by_stat_source_public_test",
        "vibe3d.editing.commands.editor.tests.unit.commands.select.by_tag_source_public_test",
        "vibe3d.editing.commands.editor.tests.unit.commands.select.type_from_source_public_test",
        "vibe3d.editing.commands.editor.tests.unit.editor_commands_population_test",
    ];
    assert(expected.length == 10, "editor-commands frozen owned roster floor 10");
    string[] actual;
    foreach (info; ModuleInfo)
        if (info !is null && info.unitTest !is null && expected.canFind(info.name))
            actual ~= info.name;
    foreach (name; expected) {
        size_t occurrences;
        foreach (found; actual) if (found == name) ++occurrences;
        assert(occurrences == 1, "PKG-POP-editor-commands must occur exactly once: " ~ name);
    }
    actual.sort;
    assert(actual.length == 10, "editor-commands selected owned population 10");
    assert(actual == expected, "editor-commands selected owned sorted identity");
    writeln("PKG-POPULATION package=editor-commands selected=10 exactly-once=10");
}
