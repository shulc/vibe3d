module render_backends_population_test;

// Task 20262930: fixed whole-owner module identities; runtime proof is separate.
version (WithRender) unittest {
    import object : ModuleInfo;
    immutable string[] expected = ["render.backend_bridge", "render.cycles_backend", "render.render_diff", "render.rpr_backend"];
    assert(expected.length == 4, "PKG-POP-render-backends whole owner roster floor 4");
    foreach (name; expected) {
        size_t occurrences;
        foreach (info; ModuleInfo)
            if (info !is null && info.name == name) ++occurrences;
        assert(occurrences == 1, "PKG-POP-render-backends whole owner exactly once: " ~ name);
    }
}
