module tests.common_execution_roster_test;

import std.algorithm : canFind, sort;
import std.stdio : writeln;

// Task 20262100: these identities come from the approved eleven-carrier
// manifest and twelve lower-module receipt, independently of runtime discovery.
unittest
{
    immutable string[] expected = [
        "io.image_decode", "io.native", "log", "math", "mesh",
        "mesh_corner_maps", "mesh_dirty", "mesh_edit_delta", "mesh_planes",
        "mesh_topo", "plane_bytes", "screen_buckets",
        "tests.unit.document_test", "tests.unit.io.native_test",
        "tests.unit.math_test", "tests.unit.mesh_edit_delta_test",
        "tests.unit.mesh_key_test", "tests.unit.mesh_map_kind_test",
        "tests.unit.mesh_selsets_test", "tests.unit.mesh_wire_snapshot_test",
        "tests.unit.params_test", "tests.unit.seltype_test",
        "tests.unit.snapshot_test",
    ];
    string[] actual;
    foreach (info; ModuleInfo)
        if (info.unitTest && expected.canFind(info.name))
            actual ~= info.name;
    actual.sort;
    assert(actual == expected, "common frozen execution population changed");
    foreach (name; actual)
        writeln("COMMON-EXECUTION-MODULE ", name);
    writeln("COMMON-EXECUTION-ROSTER carriers=11 lower=12 population=23");
}
