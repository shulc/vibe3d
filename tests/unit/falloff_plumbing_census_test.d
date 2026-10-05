// Task 9445 (FAL1): the falloff INPUT plumbing has one home per piece —
// `falloff.d : FalloffInput / weightedLerp / magnetElementPacket` and
// `TransformTool.beginHeadlessDeform` — and the retired copies (the scale
// exponent field, the align kernels' lerp, the per-command capture, the
// magnet sphere literals, the four headless preambles) occur nowhere else.
// The behaviour cells (test_xfrm_bend falloff cell, test_mesh_*, test_magnet*,
// the align fixtures) cannot see a fifth hand-rolled copy; this reads it.
module tests.unit.falloff_plumbing_census_test;

import std.algorithm : sort;
import std.array     : array;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.regex     : regex, replaceAll;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
    countOccurrences, isIdentChar;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// Whole-word occurrences of `id` (so `&weightedLerp` and an import both count;
/// `weightedLerpX` does not).
private size_t wordCount(string code, string id) {
    size_t n;
    for (size_t i = 0; i + id.length <= code.length; ++i) {
        if (code[i .. i + id.length] != id) continue;
        if (i > 0 && isIdentChar(code[i - 1])) continue;
        if (i + id.length < code.length && isIdentChar(code[i + id.length])) continue;
        ++n;
    }
    return n;
}

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

private string[] rosterOf(string[string] code, string id, out size_t total) {
    string[] rows;
    foreach (path, text; code) {
        const n = wordCount(text, id);
        total += n;
        if (n) rows ~= format("%s %d", path, n);
    }
    sort(rows);
    return rows;
}

unittest {
    auto code = sourceCode();

    // Floor: the scan read the tree, not an empty glob.
    assert(code.length > 400, format("falloff census: only %d source files", code.length));

    // Positive control for the blanking: the evaluator itself is code.
    assert(wordCount(code["source/falloff.d"], "evaluateFalloffAt") == 4,
           "falloff census: source/falloff.d no longer shows `evaluateFalloffAt`'s "
           ~ "definition + three calls (measured 4) — the scan is blind");

    // Needles: each home and its exact call-site roster (import + use per file).
    static struct Row { string id; size_t total; string[] files; }
    static immutable Row[] kRoster = [
        Row("weightedLerp", 13, [
            "source/commands/mesh/linear_align.d 2",
            "source/commands/mesh/quantize.d 2",
            "source/commands/mesh/radial_align.d 2",
            "source/commands/mesh/smooth.d 2",
            "source/falloff.d 1",
            "source/tools/alignment/linear_align_tool.d 2",
            "source/tools/alignment/radial_align_tool.d 2"]),
        Row("magnetElementPacket", 6, [
            "source/commands/mesh/magnet.d 2",
            "source/falloff.d 1",
            "source/tools/deform/magnet.d 3"]),
        Row("FalloffInput", 9, [
            "source/commands/mesh/jitter.d 2",
            "source/commands/mesh/magnet.d 2",
            "source/commands/mesh/quantize.d 2",
            "source/commands/mesh/smooth.d 2",
            "source/falloff.d 1"]),
        Row("beginHeadlessDeform", 5, [
            "source/tools/alignment/linear_align_tool.d 1",
            "source/tools/alignment/radial_align_tool.d 1",
            "source/tools/deform/bend.d 1",
            "source/tools/deform/push.d 1",
            "source/tools/transform/transform.d 1"]),
        // Retired: the dead scale exponent and the align kernels' lerp copy.
        Row("compoundPasses", 0, []),
        Row("lerp3", 0, []),
    ];
    foreach (r; kRoster) {
        size_t total;
        const rows = rosterOf(code, r.id, total);
        assert(rows == r.files && total == r.total, format(
            "falloff census: `%s` sites changed —\n  recorded %d %s\n  found    %d %s",
            r.id, r.total, r.files, total, rows));
    }

    // Structural: no retired copy beside a home's client.
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
        assert(wordCount(code[path], "captureFalloffForDrag") == 0,
               path ~ ": the headless preamble is open-coded again; use beginHeadlessDeform");
}

// Pin: the mixin's composition, by the compiler.
unittest {
    import falloff : FalloffInput;
    import operator : VectorStack;
    import toolpipe.packets : FalloffPacket;
    static struct Probe { mixin FalloffInput; }
    static assert([__traits(allMembers, Probe)] ==
        ["falloff_", "hasFalloff_", "setFalloff", "captureFalloff", "inputFalloff"]);
}
