module tests.unit.root_test_package_population_test;

// Task 20262150: frozen source identities judge the root binary without importing
// any judged module. Runtime cell execution remains ut_runner's separate authority.
unittest {
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.string : splitLines, strip;
    import std.algorithm : sort, canFind;
    import std.array : array;
    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    string[] expected;
    foreach (line; readText(buildPath(root, "tests/unit/root_test_package_module_roster.txt")).splitLines)
        if (line.strip.length && line.strip[0] != '#') expected ~= line.strip;
    assert(expected.length == 134, "root package ModuleInfo frozen population 134");
    auto ordered = expected.dup;
    ordered.sort();
    assert(ordered == expected, "root package ModuleInfo manifest sorted");
    size_t[string] occurrences;
    foreach (info; ModuleInfo) {
        if (info is null || info.name is null) continue;
        if (expected.canFind(info.name)) ++occurrences[info.name];
    }
    assert(occurrences.length == 134, "root package ModuleInfo selected population 134");
    foreach (name; expected)
        assert(occurrences.get(name, 0) == 1,
               "root package ModuleInfo must occur exactly once: " ~ name);
}
