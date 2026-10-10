module tests.unit.root_test_link_ownership_test;

// Task 20262150: the root test target owns package D sources once; production
// archives and isolated consumers retain their modeling settings.
unittest {
    import std.file : readText;
    import std.json : JSONValue, parseJSON;
    import std.path : buildPath, dirName;
    import std.algorithm : sort;

    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    enum owners = ["common", "mesh-ops", "interchange", "interaction-query",
                   "pipe-evaluation", "tool-state", "transform-ops",
                   "creation-ops", "alignment-ops", "input-events", "display-policy"];
    JSONValue config(JSONValue raw, string name) {
        foreach (candidate; raw["configurations"].array)
            if (candidate["name"].str == name) return candidate;
        assert(false, "root test ownership missing configuration " ~ name);
    }
    size_t occurrences(JSONValue paths, string wanted) {
        size_t n;
        foreach (path; paths.array) if (path.str == wanted) ++n;
        return n;
    }
    auto desktop = parseJSON(readText(buildPath(root, "dub.json")));
    auto tests = config(desktop, "tests");
    string[] selected, expected;
    foreach (name, value; tests["subConfigurations"].object)
        if (name.length >= 7 && name[0 .. 7] == "vibe3d-") selected ~= name;
    foreach (owner; owners) expected ~= "vibe3d-" ~ owner;
    selected.sort(); expected.sort();
    assert(selected.length == 11 && selected == expected,
           "root test ownership frozen eleven selectors");
    foreach (owner; owners) {
        const packageName = "vibe3d-" ~ owner;
        const packagePath = "packages/" ~ owner;
        assert(desktop["dependencies"][packageName]["path"].str == packagePath,
               "root test ownership dependency path " ~ owner);
        assert(tests["subConfigurations"][packageName].str == "root-tests",
               "root test ownership selector " ~ owner);
        foreach (grant; ["sourcePaths", "importPaths"])
            assert(occurrences(tests[grant], packagePath ~ "/source") == 1,
                   "root test ownership explicit production grant " ~ owner ~ " " ~ grant);
        foreach (grant; ["sourcePaths", "importPaths"])
            assert(occurrences(tests[grant], packagePath ~ "/tests/source") == 1,
                   "root test ownership explicit carrier grant " ~ owner ~ " " ~ grant);
        auto raw = parseJSON(readText(buildPath(root, packagePath, "dub.json")));
        assert(raw["name"].str == packageName && raw["targetType"].str == "staticLibrary",
               "root test ownership preserves production archive " ~ owner);
        assert(raw["sourcePaths"].array.length == 1 && raw["sourcePaths"][0].str == "source",
               "root test ownership production source root " ~ owner);
        auto modeling = config(raw, "modeling");
        auto source = config(raw, "root-tests");
        assert(source["targetType"].str == "sourceLibrary",
               "root test ownership sourceLibrary " ~ owner);
        source.object.remove("targetType");
        source["name"] = JSONValue("modeling");
        if (auto subs = "subConfigurations" in source.object) {
            foreach (name, ref value; subs.object) {
                if (name.length >= 7 && name[0 .. 7] == "vibe3d-") {
                    assert(value.str == "root-tests", "root test ownership lower selector " ~ owner);
                    value = modeling["subConfigurations"][name];
                }
            }
        }
        assert(source == modeling, "root test ownership modeling settings preserved " ~ owner);
        foreach (key; ["sourcePaths", "importPaths", "sourceFiles"])
            if (auto paths = key in raw.object)
                foreach (path; paths.array)
                    assert(path.str != "tests/source" && path.str != "../tests/source",
                           "root test ownership public carriers stay test-only " ~ owner);
        foreach (candidate; raw["configurations"].array)
            foreach (key; ["sourcePaths", "importPaths", "sourceFiles"])
                if (auto paths = key in candidate.object)
                    foreach (path; paths.array)
                        assert(path.str != "tests/source" && path.str != "../tests/source",
                               "root test ownership configuration carriers stay test-only " ~ owner);
    }
}
