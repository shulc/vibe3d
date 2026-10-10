module tests.unit.input_events_population_test;

// Task 20262190: frozen input carriers and private owners are judged without
// importing them; compiler admission and execution remain separate witnesses.
unittest {
    import object : ModuleInfo;
    import std.algorithm : canFind, sort;
    import std.stdio : writeln;

    immutable string[] expected = [
        "eventlog",
        "tests.unit.binding_resolve_test",
        "tests.unit.eventlog_parser_test",
        "tests.unit.eventlog_test",
        "tests.unit.tool_input_test",
        "tool_input",
    ];
    assert(expected.length == 6, "input-events frozen carrier roster floor 6");
    string[] actual;
    foreach (info; ModuleInfo)
        if (info !is null && info.unitTest !is null && expected.canFind(info.name))
            actual ~= info.name;
    foreach (name; expected) {
        size_t occurrences;
        foreach (found; actual) if (found == name) ++occurrences;
        assert(occurrences == 1,
               "PKG-POP-input-events must occur exactly once: " ~ name);
    }
    actual.sort;
    assert(actual.length == 6, "input-events selected carrier population 6");
    assert(actual == expected, "input-events selected carrier sorted identity");
    writeln("PKG-POPULATION package=input-events selected=6 exactly-once=6");
}
