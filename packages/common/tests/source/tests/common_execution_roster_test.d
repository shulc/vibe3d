module tests.common_execution_roster_test;
import std.algorithm : canFind, sort;
import std.stdio : writeln;
// Wave8: fixed remaining common carrier identities; lower owners have their own rosters.
unittest {
    immutable string[] expected = ["tests.unit.io.native_test"];
    string[] actual;
    foreach (info; ModuleInfo)
        if (info.unitTest && expected.canFind(info.name)) actual ~= info.name;
    actual.sort;
    assert(actual == expected, "common frozen public carrier execution population changed");
    foreach (name; actual) writeln("COMMON-EXECUTION-MODULE ", name);
    writeln("COMMON-EXECUTION-ROSTER carriers=1");
}
