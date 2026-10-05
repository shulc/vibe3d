// Task 9445 (FAL1): the falloff INPUT plumbing has one home per piece —
// `falloff.d : FalloffInput / weightedLerp / magnetElementPacket` and
// `TransformTool.beginHeadlessDeform` — and the retired copies (the align
// kernels' lerp, the per-command capture, the magnet sphere literals, the
// headless preambles) occur nowhere else. Behaviour cells cannot see a
// hand-rolled copy; this reads the text.
module tests.unit.falloff_plumbing_census_test;

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
    foreach (f; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth))
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
    assert(countOccurrences(code["source/falloff.d"], "evaluateFalloffAt") == 4,
           "falloff census: source/falloff.d no longer shows `evaluateFalloffAt`'s "
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
