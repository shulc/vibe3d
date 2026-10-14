module tests.unit.morph_route_census_test;

import tests.unit.census_symbols : wave15InputsIntact, wave15InputStart;


/// The files allowed to mention `MorphRoute`, repo-relative with `/`.
private static immutable string[] morphRouteHomes = [
    "packages/transform-ops/source/tools/transform/morph_route.d",
    "packages/transform-ops/source/tools/transform/xform_kernels.d",
    "source/tools/transform/xfrm_apply.d",
    "source/tools/transform/xfrm_transform.d",
];

/// The SUBSET rule as a pure function of a scan result, so it can be exercised
/// on a synthetic input as well as on the real tree. Returns the offenders.
private string[] morphRouteOutsiders(const(string)[] hits) {
    import std.algorithm : canFind;
    string[] bad;
    foreach (h; hits) if (!morphRouteHomes.canFind(h)) bad ~= h;
    return bad;
}

version (unittest) {
    import std.path : dirName;

    // .../tests/unit/morph_route_census_test.d -> repository root
    private enum morphRouteRepoRoot =
        dirName(dirName(dirName(__FILE_FULL_PATH__)));

    /// Every `.d` under `source/` whose text contains `MorphRoute`,
    /// repo-relative with `/` separators — the documented grep, in D.
    private string[] morphRouteHits(string root) {
        import std.file : SpanMode;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, exists = wave15Exists, isDir = wave15IsDir, read = wave15ReadText;
        import std.path      : buildPath, relativePath;
        import std.algorithm : canFind, sort;
        import std.array     : array, replace;
        import std.string    : endsWith;

        string[] hits;
        foreach (owner; ["source", "packages/command-runtime/source", "packages/application-core/source", "packages/camera-model/source", "packages/document-channels/source", "packages/image-codec/source", "packages/document-io/source", "packages/document-model/source", "packages/param-schema/source", "packages/pipe-runtime/source", "packages/mesh-ops/source", "packages/interchange/source", "packages/interaction-query/source", "packages/pipe-evaluation/source", "packages/tool-state/source", "packages/transform-ops/source", "packages/creation-ops/source", "packages/alignment-ops/source", "packages/input-events/source", "packages/display-policy/source", "packages/viewport-gpu/source", "packages/subpatch-preview/source", "packages/edit-contracts/source", "packages/mesh-change/source", "packages/mesh-contracts/source", "packages/mesh-edit-log/source", "packages/mesh-edit-replay/source", "packages/mesh-snapshot/source", "packages/mesh-topology/source", "packages/mesh/source", "packages/profiling/source", "packages/spatial/source", "util/log/source", "util/math/source", "util/parallel/source", "util/plane-bytes/source", "util/screen-buckets/source", "packages/pipe-contracts/source", "packages/mesh-preview/source", "util/json-number/source"]) {
        const dir = buildPath(root, owner);
        if (!exists(dir) || !isDir(dir)) continue;
        foreach (entry; dirEntries(dir, SpanMode.depth)) {
            if (!entry.isFile || !entry.name.endsWith(".d")) continue;
            auto text = cast(const(char)[]) read(entry.name);
            if (!text.canFind("MorphRoute")) continue;
            auto rel = relativePath(entry.name, root);
            version (Windows) rel = rel.replace("\\", "/");
            hits ~= rel;
        }
        }
    foreach (sourceCarrier; [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
    ]) {
        const sourceCarrierPath = buildPath(root, sourceCarrier);

            auto text = cast(const(char)[]) read(sourceCarrierPath);
            if (!text.canFind("MorphRoute")) continue;
            auto rel = relativePath(sourceCarrierPath, root);
            version (Windows) rel = rel.replace("\\", "/");
            hits ~= rel;

    }
        sort(hits);
        return hits;
    }
}

// The gate against the REAL tree.
//
// The lower-bound assertion is not decoration: a scanner that resolved the
// wrong root, or matched nothing, would return an empty list and satisfy the
// subset rule vacuously — the "inert measurement" failure this repo keeps
// finding. Requiring the four known homes back makes the scan prove it ran.
//
// Mutation: add the text `MorphRoute` to any other file under `source/`
// (e.g. a comment in `source/mesh.d`) -> this reddens naming that file
// (verified).
unittest {
    auto wave15Inputs = wave15InputStart();
    import std.algorithm : canFind;
    import std.format    : format;

    auto hits = morphRouteHits(morphRouteRepoRoot);
    assert(hits.length >= morphRouteHomes.length,
        format("the MorphRoute scan found %d file(s) under %s/source — it must "
             ~ "find at least the %d known homes, so an empty or mis-rooted "
             ~ "scan cannot pass the subset rule vacuously",
               hits.length, morphRouteRepoRoot, morphRouteHomes.length));
    foreach (home; morphRouteHomes)
        assert(hits.canFind(home),
            "the scan did not see " ~ home ~ " — it is one of the seam's own "
          ~ "files and must be in its own gate's input");

    auto bad = morphRouteOutsiders(hits);
    assert((bad.length == 0) && wave15InputsIntact(wave15Inputs),
        format("%s mention(s) MorphRoute and is not one of the seam's four "
             ~ "homes. A second routing site writes the map from somewhere "
             ~ "this file's reasoning does not cover — review it, then add it "
             ~ "to `morphRouteHomes` and to the header list.", bad));
}

// The rule itself, on a synthetic input — so the gate's PREDICATE is pinned
// independently of the tree it happens to be run against. Without this, the
// block above goes green both when the rule works and when
// `morphRouteOutsiders` always returns empty.
unittest {
    assert(morphRouteOutsiders(morphRouteHomes).length == 0,
        "the four homes are, by definition, not outsiders");
    auto bad = morphRouteOutsiders(
        ["source/tools/transform/xfrm_apply.d", "source/tools/mystery.d"]);
    assert(bad.length == 1 && bad[0] == "source/tools/mystery.d",
        "a hit outside the home set must be REPORTED, not silently accepted");
}
