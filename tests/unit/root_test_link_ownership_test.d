module tests.unit.root_test_link_ownership_test;

// Task 20262150: the root test target owns package D sources once; production
// archives and isolated consumers retain their modeling settings.
unittest {
    import std.file : readText;
    import std.json : JSONValue, parseJSON;
    import std.path : buildPath, dirName;
    import std.algorithm : sort, canFind;

    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    enum owners = ["camera-model", "document-channels", "image-codec", "document-io", "document-model", "param-schema", "pipe-runtime", "alignment-ops", "common", "creation-ops", "display-policy", "edit-contracts", "input-events", "interaction-query", "interchange", "mesh-change", "mesh-contracts", "mesh-edit-log", "mesh-edit-replay", "mesh-ops", "mesh-snapshot", "mesh-topology", "mesh", "pipe-evaluation", "profiling", "spatial", "subpatch-preview", "tool-state", "transform-ops", "viewport-gpu", "log", "math", "parallel", "plane-bytes", "screen-buckets", "json-number", "pipe-contracts", "mesh-preview"];
    enum utilOwners = ["json-number", "log", "math", "parallel", "plane-bytes", "screen-buckets"];
    enum noCarriers = ["log", "parallel", "plane-bytes", "profiling", "screen-buckets", "mesh-change", "mesh-topology"];
    enum fixtureOnlyVersions = ["edit-contracts", "mesh", "mesh-change", "mesh-contracts", "mesh-edit-log", "mesh-edit-replay", "mesh-snapshot", "mesh-topology"];
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
    foreach (owner; owners)
        assert(selected.canFind("vibe3d-" ~ owner),
               "root test ownership named selector " ~ owner);
    assert(selected.length == 38 && selected == expected,
           "root test ownership frozen thirty-eight selectors");
    foreach (owner; owners) {
        const packageName = "vibe3d-" ~ owner;
        const packagePath = (utilOwners.canFind(owner) ? "util/" : "packages/") ~ owner;
        assert(desktop["dependencies"][packageName]["path"].str == packagePath,
               "root test ownership dependency path " ~ owner);
        assert(tests["subConfigurations"][packageName].str == "root-tests",
               "root test ownership selector " ~ owner);
        foreach (grant; ["sourcePaths", "importPaths"])
            assert(occurrences(tests[grant], packagePath ~ "/source") == 1,
                   "root test ownership explicit production grant " ~ owner ~ " " ~ grant);
        foreach (grant; ["sourcePaths", "importPaths"])
            assert(occurrences(tests[grant], packagePath ~ "/tests/source") == (noCarriers.canFind(owner) ? 0 : 1),
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
        if (fixtureOnlyVersions.canFind(owner)) {
            assert(source["versions"].array.length == 0,
                   "root test ownership lower fixture-only versions " ~ owner);
            source["versions"] = modeling["versions"];
        }
        if (owner == "mesh-ops") {
            assert(modeling["dflags-ldc"].array.length == 1 &&
                   modeling["dflags-ldc"][0].str == "--singleobj",
                   "root test ownership mesh-ops LDC archive flag");
            auto flags = "dflags-ldc" in source.object;
            assert(flags is null || flags.array.length == 0,
                   "root test ownership mesh-ops sourceLibrary has no archive flag");
            modeling.object.remove("dflags-ldc");
            source.object.remove("dflags-ldc");
        }
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
