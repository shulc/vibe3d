module tests.unit.subpatch_hash_seed_census_test;

import std.file : exists;

import std.array : appender;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName;
import std.regex : ctRegex, matchAll;
import std.range : walkLength;
import std.string : splitLines;
import tests.unit.census_symbols : blankNonCode, enclosingSymbols, symbolAt;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum seededHashRe = ctRegex!(`hashOf\(.*,\s*\w+\)`);

private struct Hit
{
    string file;
    size_t line;
    string symbol;
}

private Hit[] scanSeededHashes(string file, string source)
{
    const code = blankNonCode(source);
    const symbols = enclosingSymbols(code);
    auto hits = appender!(Hit[]);
    foreach (i, line; code.splitLines)
        if (line.matchAll(seededHashRe).walkLength != 0)
            hits.put(Hit(file, i + 1, symbolAt(symbols, i)));
    return hits.data;
}

unittest // the defect-shaped regex sees code and rejects comment/string decoys
{
    enum fixture = q{
        void compute() {
            ulong h;
            h = hashOf(values, h);
            // h = hashOf(commented, h);
            enum quoted = "h = hashOf(quoted, h);";
        }
    };
    const hits = scanSeededHashes("fixture.d", fixture);
    assert(hits.length == 1,
        format("seeded-hash positive control found %d sites, expected one", hits.length));
    assert(hits[0].symbol == "compute",
        format("seeded-hash positive control landed in `%s`", hits[0].symbol));
}

unittest // every production array-plus-seed hash stays in the reviewed stencil key
{
    auto hits = appender!(Hit[]);
    size_t sourceFiles;
    foreach (scanSourceRoot; [buildPath(repoRoot, "source"), buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source")]
        ~ (exists(buildPath(repoRoot, "packages/selection-model/source")) ? [buildPath(repoRoot, "packages/selection-model/source")] : [])
        ~ (exists(buildPath(repoRoot, "packages/scene-query/source")) ? [buildPath(repoRoot, "packages/scene-query/source")] : [])
        ~ (exists(buildPath(repoRoot, "packages/editor-commands/source")) ? [buildPath(repoRoot, "packages/editor-commands/source")] : []))

    foreach (entry; dirEntries(scanSourceRoot, "*.d", SpanMode.depth)) {
        ++sourceFiles;
        const relative = entry.name[repoRoot.length + 1 .. $];
        hits.put(scanSeededHashes(relative, readText(entry.name)));
    }
    const string[] sourceCarriersWave14_1 = [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
];
    import std.file : exists;
    import std.path : buildPath;
    foreach (relative; [
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
    ]) {
        size_t occurrences;
        foreach (candidate; sourceCarriersWave14_1) if (candidate == relative) ++occurrences;
        assert(occurrences == 1, "Wave14 logical source input missing/duplicate: " ~ relative);
        assert(exists(buildPath(repoRoot, relative)), "Wave14 logical source physical input missing: " ~ relative);
    }
    foreach (sourceCarrier; sourceCarriersWave14_1) {
        const sourceCarrierPath = buildPath(repoRoot, sourceCarrier);

        const relative = sourceCarrierPath[repoRoot.length + 1 .. $];
        hits.put(scanSeededHashes(relative, readText(sourceCarrierPath)));

    }
    const found = hits.data;
    assert(sourceFiles >= 548,
        format("seeded-hash census scanned only %d source files", sourceFiles));
    assert(found.length >= 8,
        format("seeded-hash census population collapsed to %d hits", found.length));
    assert(found.length == 8,
        format("seeded-hash census found %d sites, expected exactly 8: %s",
               found.length, found));
    foreach (hit; found)
        assert(hit.file == "packages/subpatch-preview/source/subpatch_preview.d"
            && hit.symbol == "SubpatchPreview.computeStencilKey",
            format("unreviewed seeded hash at %s:%d in `%s`",
                   hit.file, hit.line, hit.symbol));
}
