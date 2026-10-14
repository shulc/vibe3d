// Keep SDL's borrowed C error pointer behind the one conversion seam added by
// task 5503. A direct SDL_GetError use in any other source file can reach a D
// formatter and print the pointer value instead of the diagnostic text.
module tests.unit.sdl_error_census_test;

import std.algorithm : sort;
import std.file : SpanMode;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, exists = wave15Exists, readText = wave15ReadText;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : indexOf, splitLines;

import tests.unit.census_symbols : blankNonCode, isIdentChar, wave15InputStart, wave15InputsIntact;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum needle = "SDL_GetError";
private enum owner = "source/sdl_error.d";

private struct Hit
{
    string file;
    size_t line;
}

private Hit[] scanText(string file, string raw)
{
    Hit[] hits;
    const code = blankNonCode(raw);
    foreach (li, line; code.splitLines)
    {
        size_t from;
        while (from + needle.length <= line.length)
        {
            const offset = line[from .. $].indexOf(needle);
            if (offset < 0) break;
            const pos = from + cast(size_t) offset;
            const end = pos + needle.length;
            if ((pos == 0 || !isIdentChar(line[pos - 1]))
                && (end == line.length || !isIdentChar(line[end])))
                hits ~= Hit(file, li + 1);
            from = end;
        }
    }
    return hits;
}

private Hit[] scanSource()
{
    const sourceRoot = buildPath(repoRoot, "source");
    assert(sourceRoot.exists,
        "SDL_GetError census cannot find source/; an empty walk is not green");

    Hit[] hits;
    foreach (scanSourceRoot; [sourceRoot, buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source"), buildPath(repoRoot, "packages/selection-model/source"), buildPath(repoRoot, "packages/scene-query/source"), buildPath(repoRoot, "packages/editor-commands/source")])

    foreach (entry; dirEntries(scanSourceRoot, "*.d", SpanMode.depth))
        hits ~= scanText(entry.name[repoRoot.length + 1 .. $],
                         readText(entry.name));
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

import tests.unit.census_symbols : exists = wave15Exists;
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

    }
    foreach (sourceCarrier; sourceCarriersWave14_1) {
        const sourceCarrierPath = buildPath(repoRoot, sourceCarrier);hits ~= scanText(sourceCarrierPath[repoRoot.length + 1 .. $],
                         readText(sourceCarrierPath));
    }
    sort!((a, b) => a.file == b.file ? a.line < b.line : a.file < b.file)(hits);
    return hits;
}

unittest
{
    // The shared lexer must keep a real call while removing both comment and
    // string decoys. The line-preserving projection keeps diagnostics useful.
    const probe = scanText("probe.d",
        "void f() { SDL_GetError(); }\n"
      ~ "// SDL_GetError()\n"
      ~ "enum text = \"SDL_GetError()\";\n");
    assert(probe == [Hit("probe.d", 1)],
        "SDL_GetError census must count code and ignore comments/strings");

    const inputStart = wave15InputStart();
    const hits = scanSource();

    // POPULATION FLOOR: without this, "every hit belongs to owner" is
    // vacuously true after the helper or its SDL symbol is renamed.
    assert(hits.length > 0, format(
        "task 5503: SDL_GetError census found %d CODE occurrence(s); the "
      ~ "single-owner predicate is VACUOUSLY TRUE over an empty population",
        hits.length));

    string[] files;
    string[] locations;
    foreach (hit; hits)
    {
        if (files.length == 0 || files[$ - 1] != hit.file)
            files ~= hit.file;
        locations ~= format("%s:%d", hit.file, hit.line);
    }

    assert(files == [owner] && wave15InputsIntact(inputStart), format(
        "task 5503: SDL_GetError must occur in exactly %s; found files: "
      ~ "%-(%s, %)\nCODE occurrences:%-(\n    %s%)\n"
      ~ "Route every SDL diagnostic through sdlError().",
        owner, files, locations));
}
