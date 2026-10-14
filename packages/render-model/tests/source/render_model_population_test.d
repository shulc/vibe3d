module render_model_population_test;

// Task 20262930: fixed whole-owner module identities; runtime proof is separate.
version (WithRender) unittest {
    import object : ModuleInfo;
    immutable string[] expected = ["render.backend", "render.scene"];
    foreach (name; expected) {
        size_t occurrences;
        foreach (info; ModuleInfo)
            if (info !is null && info.name == name) ++occurrences;
        assert(occurrences == 1, "PKG-POP-render-model whole owner exactly once: " ~ name);
    }
}
