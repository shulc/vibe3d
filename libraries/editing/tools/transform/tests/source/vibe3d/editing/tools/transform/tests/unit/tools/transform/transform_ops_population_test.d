module vibe3d.editing.tools.transform.tests.unit.tools.transform.transform_ops_population_test;

// Independently frozen Wave6D public carriers; registry enumeration does not
// import the modules whose presence it checks (task 20262120).
unittest {
    import object : ModuleInfo;
    import std.algorithm : canFind, sort;

    immutable string[] expected = [
        "vibe3d.editing.tools.transform.tests.unit.ortho_relocate_prior_test",
        "vibe3d.editing.tools.transform.tests.unit.tools.transform.arcball_regression_test",
        "vibe3d.editing.tools.transform.tests.unit.tools.transform.arcball_test",
        "vibe3d.editing.tools.transform.tests.unit.tools.transform.item_xform_kernels_test",
        "vibe3d.editing.tools.transform.tests.unit.tools.transform.item_xform_regression_test",
        "vibe3d.editing.tools.transform.tests.unit.tools.transform.morph_route_test",
        "vibe3d.editing.tools.transform.tests.unit.tools.transform.scale_input_test",
        "vibe3d.editing.tools.transform.tests.unit.tools.transform.xform_kernels_test",
        "vibe3d.editing.tools.transform.tools.transform.relocate_plane_test",
    ];
    assert(expected.length == 9, "transform public carrier roster floor");
    string[] actual;
    foreach (m; ModuleInfo) {
        if (m.unitTest !is null && expected.canFind(m.name))
            actual ~= m.name;
    }
    actual.sort;
    assert(actual.length == 9, "transform public carrier population changed");
    assert(actual == expected, "transform public carrier identity changed");
}
