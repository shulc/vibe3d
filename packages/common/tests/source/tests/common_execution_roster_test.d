module tests.common_execution_roster_test;
import std.algorithm : canFind, sort;
import std.stdio : writeln;
// Wave12: retained private production cells; lower owners have their own rosters.
unittest {
    immutable string[] expected = ["command", "command_history", "command_registry", "record_observer_hub"];
    string[] actual;
    foreach (info; ModuleInfo)
        if (info.unitTest && expected.canFind(info.name)) actual ~= info.name;
    actual.sort;
    assert(actual == expected, "common frozen private production-module execution population 4 changed");
    foreach (name; actual) writeln("COMMON-EXECUTION-MODULE ", name);
    writeln("COMMON-EXECUTION-ROSTER production-modules=4");
}
