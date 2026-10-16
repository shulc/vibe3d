module vibe3d.editing.tools.alignment.tests.unit.alignment_ops_population_test;

// Task 20262140: freeze package carrier and private-cell ownership independently
// of their imports; doc/application_layers_wave6_plan_2026-10-09.md.
unittest {
    import object : ModuleInfo;
    import std.format : format;

    immutable string[2] expected = [
        "vibe3d.editing.tools.alignment.tests.unit.tools.alignment.align_kernels_test",
        "vibe3d.editing.tools.alignment.tools.alignment.align_kernels",
    ];
    foreach (name; expected) {
        size_t found;
        foreach (m; ModuleInfo)
            if (m !is null && m.unitTest !is null && m.name == name)
                ++found;
        assert(found == 1, format("alignment-ops population: expected one unittest module %s, got %s",
            name, found));
    }
}
