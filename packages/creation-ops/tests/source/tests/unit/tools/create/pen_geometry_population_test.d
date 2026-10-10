// Frozen creation-owner carrier membership (task 20262130); no imports of the
// modules judged here. Evidence: application_layers_wave6_plan_2026-10-09.md.
module tests.unit.tools.create.pen_geometry_population_test;

unittest
{
    import std.algorithm : sort, startsWith;

    immutable string[] expected = [
        "tests.unit.tools.create.pen_geometry_population_test",
        "tests.unit.tools.create.pen_geometry_test",
    ];
    string[] actual;
    foreach (m; ModuleInfo)
        if (m && m.unitTest &&
            m.name.startsWith("tests.unit.tools.create.pen_geometry_"))
            actual ~= m.name;
    actual.sort;
    assert(actual == expected, "creation-ops frozen runtime population");
}
