// Quantize and Smooth own VertexPositionResultBuilder implementations, and
// Jitter shares collectLegacyLiveResult. This source census
// forces either roster to be reviewed before another builder or independent
// live-mesh diff loop can appear in CommandWrapperTool.
module tests.unit.command_wrapper_result_census_test;

import std.algorithm : count;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private size_t countInSource(string needle) {
    size_t hits;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const code = blankUnittestBodies(blankNonCode(readText(de.name)));
        hits += code.count(needle);
    }
    return hits;
}

unittest {
    const builderHits = countInSource("VertexPositionResultBuilder");
    assert(builderHits == 8, format(
        "VertexPositionResultBuilder census changed: expected the interface, " ~
        "its Quantize/Smooth implementations, and CommandWrapperTool's " ~
        "adapter (8 code hits); found %d", builderHits));

    const legacyHits = countInSource("collectLegacyLiveResult");
    assert(legacyHits == 3, format(
        "collectLegacyLiveResult census changed: expected one collector and its " ~
        "two shared callers; found %d", legacyHits));

    const wrapper = blankUnittestBodies(blankNonCode(readText(buildPath(repoRoot,
        "source", "tools", "common", "command_wrapper.d"))));
    const diffReads = wrapper.count(
        "auto a = baseline[i], b = meshPtr.vertices[i];");
    const indexAppends = wrapper.count("result.indices ~= cast(uint)i;");
    const beforeAppends = wrapper.count("result.before ~= a;");
    const afterAppends = wrapper.count("result.after ~= b;");
    assert(diffReads == 1 && indexAppends == 1 && beforeAppends == 1 &&
           afterAppends == 1, format(
        "independent wrapper live-mesh diff collector appeared: expected the " ~
        "single collectLegacyLiveResult loop (reads/indices/before/after " ~
        "1/1/1/1), found %d/%d/%d/%d", diffReads, indexAppends,
        beforeAppends, afterAppends));

    size_t sourceFiles;
    foreach (_; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth))
        ++sourceFiles;
    assert(sourceFiles > 400, format(
        "command-wrapper result census walked only %d source files", sourceFiles));
}
