module tests.unit.tool_state_population_test;

// The Wave6C owned modules must remain live in the isolated consumer, including
// the source-private counts cell (task 20262110; application_layers_wave6_plan).
// These names are frozen from source ownership, without importing judged roots.
unittest {
    immutable string[] carriers = [
        "tests.unit.session_mesh_key_stamp_as_test",
        "tests.unit.tool_state_population_test",
        "tests.unit.tools.common.session_mesh_key_test",
        "tests.unit.tools.edit.preview_rebuild_test",
    ];
    immutable string[] production = [
        "tools.common.session_mesh_key",
        "tools.edit.preview_rebuild",
    ];

    size_t publicModules;
    foreach (name; carriers) {
        size_t matches;
        foreach (info; ModuleInfo) {
            if (info is null || info.name != name) continue;
            assert(info.unitTest !is null,
                "tool-state carrier has no unittest: " ~ name);
            ++matches;
        }
        assert(matches == 1, "tool-state owned carrier population: " ~ name);
        publicModules += matches;
    }
    assert(publicModules == 4, "tool-state frozen public module population");

    size_t productionModules;
    foreach (name; production) {
        size_t matches;
        foreach (info; ModuleInfo) {
            if (info is null || info.name != name) continue;
            if (name == "tools.common.session_mesh_key")
                assert(info.unitTest !is null,
                    "tool-state private counts cell must remain compiled");
            ++matches;
        }
        assert(matches == 1, "tool-state owned production population: " ~ name);
        productionModules += matches;
    }
    assert(productionModules == 2, "tool-state frozen production module population");
}
