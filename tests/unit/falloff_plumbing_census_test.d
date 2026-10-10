// Task 9445 (FAL1): the falloff INPUT plumbing has one home per piece —
// `falloff.d : FalloffInput / weightedLerp / magnetElementPacket` and
// `TransformTool.beginHeadlessDeform` — and the retired copies (the align
// kernels' lerp, the per-command capture, the magnet sphere literals, the
// headless preambles) occur nowhere else. Behaviour cells cannot see a
// hand-rolled copy; this reads the text.
module tests.unit.falloff_plumbing_census_test;

import std.file : exists;

import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.regex     : regex, replaceAll;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
    containsWord, countOccurrences;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// Code of every `source/**.d` (comments, strings and in-module unittest
/// bodies blanked; whitespace runs collapsed), keyed by repo-relative path.
private string[string] sourceCode() {
    string[string] code;
    foreach (scanSourceRoot; [buildPath(repoRoot, "source"), buildPath(repoRoot, "packages/common/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source")])

    foreach (f; dirEntries(scanSourceRoot, "*.d", SpanMode.depth))
        code[f.name[repoRoot.length + 1 .. $]] =
            blankUnittestBodies(blankNonCode(readText(f.name)))
                .replaceAll(regex(`\s+`), " ");
    return code;
}

unittest {
    auto code = sourceCode();

    // Floor: the scan read the tree, not an empty glob.
    assert(code.length > 400, format("falloff census: only %d source files", code.length));

    // Positive control for the blanking: the evaluator itself is code.
    assert(countOccurrences(code["packages/common/source/falloff.d"], "evaluateFalloffAt") == 4,
           "falloff census: packages/common/source/falloff.d no longer shows `evaluateFalloffAt`'s "
           ~ "definition + three calls (measured 4) — the scan is blind");

    // Negative needles: no retired copy beside a home's client.
    foreach (path; ["source/commands/mesh/magnet.d", "source/tools/deform/magnet.d"])
        assert(countOccurrences(code[path], "FalloffType.Element") == 0
               && countOccurrences(code[path], "ElementConnect.Ignore") == 0,
               path ~ ": a hand-built magnet sphere is back; use magnetElementPacket");
    size_t puts;
    foreach (path, text; code) puts += countOccurrences(text, "vts.put(&falloff_)");
    assert(puts == 1, format(
        "falloff census: `vts.put(&falloff_)` %d times; FalloffInput holds the one", puts));
    foreach (path; ["source/tools/alignment/linear_align_tool.d",
                    "source/tools/alignment/radial_align_tool.d",
                    "source/tools/deform/bend.d", "source/tools/deform/push.d"])
        assert(!containsWord(code[path], "captureFalloffForDrag"),
               path ~ ": the headless preamble is open-coded again; use beginHeadlessDeform");
    foreach (path, text; code)
        assert(!containsWord(text, "lerp3"), path ~ ": a `lerp3` copy is back; use weightedLerp");
}
