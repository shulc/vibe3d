module tests.unit.root_test_link_ownership_test;

// Task 20262150: the root test target owns package D sources once; production
// archives and isolated consumers retain their modeling settings.
unittest {

import tests.unit.census_symbols : readText = wave15ReadText;
    import std.json : JSONValue, parseJSON;
    import std.path : buildPath, dirName;
    import std.algorithm : sort, canFind;

    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    enum owners = ["camera-model", "document-channels", "image-codec", "document-io", "document-model", "param-schema", "pipe-runtime", "alignment-ops", "command-runtime", "application-core", "creation-ops", "display-policy", "edit-contracts", "input-events", "interaction-query", "interchange", "mesh-change", "mesh-contracts", "mesh-edit-log", "mesh-edit-replay", "mesh-ops", "mesh-snapshot", "mesh-topology", "mesh", "pipe-evaluation", "profiling", "spatial", "subpatch-preview", "tool-state", "transform-ops", "viewport-gpu", "log", "math", "parallel", "plane-bytes", "screen-buckets", "json-number", "pipe-contracts", "mesh-preview", "selection-model", "scene-query", "editor-commands", "interactive-tools", "viewport-host", "interaction-data", "http-runtime", "ai-advisor", "ai3d-runtime", "remesh-runtime", "platform-file", "document-actions", "render-model", "render-backends", "forms-model", "editor-ui"];
    enum wave15Owners = ["interactive-tools", "viewport-host", "interaction-data"];
    enum utilOwners = ["json-number", "log", "math", "parallel", "plane-bytes", "screen-buckets"];
    enum noCarriers = ["log", "parallel", "plane-bytes", "profiling", "screen-buckets", "mesh-change", "mesh-topology", "http-runtime", "platform-file"];
    enum fixtureOnlyVersions = ["edit-contracts", "mesh", "mesh-change", "mesh-contracts", "mesh-edit-log", "mesh-edit-replay", "mesh-snapshot", "mesh-topology"];
    string[] testHelpers(string owner) {
        if (owner == "interactive-tools")
            return ["tests/source/drag_source_helpers.d", "tests/source/snap_render_source_helpers.d"];
        if (owner == "viewport-host") return ["tests/source/image_plane_source_cells.d"];
        return [];
    }
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
    assert(selected.length == 55 && selected == expected,
           "root test ownership frozen fifty-five selectors");
    foreach (owner; owners) {
        const packageName = "vibe3d-" ~ owner;
        const packagePath = (utilOwners.canFind(owner) ? "util/" : "packages/") ~ owner;
        assert(desktop["dependencies"][packageName]["path"].str == packagePath,
               "root test ownership dependency path " ~ owner);
        assert(tests["subConfigurations"][packageName].str == "root-tests",
               "root test ownership selector " ~ owner);
        foreach (grant; ["sourcePaths", "importPaths"])
            assert(occurrences(tests[grant], packagePath ~ "/source") ==
                       (grant == "importPaths" && wave15Owners.canFind(owner) ? 0 : 1),
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
        if (["selection-model", "scene-query", "editor-commands", "http-runtime", "ai-advisor", "ai3d-runtime", "remesh-runtime", "platform-file", "document-actions"].canFind(owner)
                || wave15Owners.canFind(owner)) {
            assert(source["versions"].array.length == 2 &&
                   source["versions"][0].str == "WithAI" &&
                   source["versions"][1].str == "MeshSnapshotFixtures",
                   "root test ownership Wave14 fixture versions " ~ owner);
            source["versions"] = modeling["versions"];
        }
        const helpers = testHelpers(owner);
        if (helpers.length) {
            foreach (name; ["root-tests", "isolated-tests"]) {
                const profile = config(raw, name);
                assert(profile["targetType"].str == "sourceLibrary",
                       "root test ownership helper profile sourceLibrary " ~ owner ~ " " ~ name);
                assert(profile["importPaths"].array.length == 1 &&
                       profile["importPaths"][0].str == "tests/source",
                       "root test ownership exact helper import " ~ owner ~ " " ~ name);
                assert(profile["sourceFiles"].array.length == helpers.length,
                       "root test ownership helper source population " ~ owner ~ " " ~ name);
                foreach (helper; helpers)
                    assert(occurrences(profile["sourceFiles"], helper) == 1,
                           "root test ownership exact helper source " ~ owner ~ " " ~ name ~ " " ~ helper);
            }
            source.object.remove("importPaths");
            source.object.remove("sourceFiles");
        }
        if (wave15Owners.canFind(owner)) {
            const isolated = config(raw, "isolated-tests");
            assert(isolated["targetType"].str == "sourceLibrary" &&
                   isolated["versions"].array.length == 0,
                   "root test ownership Wave15 isolated fixture mode " ~ owner);
            foreach (name, value; isolated["subConfigurations"].object)
                if (name.length >= 7 && name[0 .. 7] == "vibe3d-")
                    assert(value.str == "isolated-tests",
                           "root test ownership Wave15 isolated lower selector " ~ owner);
        }
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
                    assert(path.str != "tests/source" && path.str != "../tests/source" &&
                           !helpers.canFind(path.str),
                           "root test ownership public carriers stay test-only " ~ owner);
        foreach (candidate; raw["configurations"].array)
            foreach (key; ["sourcePaths", "importPaths", "sourceFiles"])
                if (auto paths = key in candidate.object)
                    foreach (path; paths.array)
                        assert(((path.str != "tests/source" && path.str != "../tests/source") ||
                                (helpers.length &&
                                 ["root-tests", "isolated-tests"].canFind(candidate["name"].str) &&
                                 key == "importPaths" && path.str == "tests/source")) &&
                               (!helpers.canFind(path.str) ||
                                (["root-tests", "isolated-tests"].canFind(candidate["name"].str) &&
                                 key == "sourceFiles")),
                               "root test ownership configuration carriers stay test-only " ~ owner);
    }
}
