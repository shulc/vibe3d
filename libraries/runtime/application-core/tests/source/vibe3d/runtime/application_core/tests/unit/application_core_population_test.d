module vibe3d.runtime.application_core.tests.unit.application_core_population_test;
import std.algorithm : canFind, sort;
import std.stdio : writeln;

// Wave13: owned enabled identities; lower-owner cells have separate rosters.
unittest {
    immutable string[] expected = ["vibe3d.runtime.application_core.tests.unit.application_core_population_test", "vibe3d.runtime.application_core.tests.unit.command_invocation_test", "vibe3d.runtime.application_core.tests.unit.standalone_application_test"];
    string[] actual;
    foreach (info; ModuleInfo)
        if (info.unitTest && expected.canFind(info.name)) actual ~= info.name;
    actual.sort;
    assert(actual == expected, "application-core owned execution population 3 changed");
    foreach (name; actual) writeln("APPLICATION_CORE-EXECUTION-MODULE ", name);
    writeln("APPLICATION_CORE-EXECUTION-ROSTER owned-modules=3");
}
