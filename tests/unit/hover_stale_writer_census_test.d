// Task 7114 (item 22, hypothesis (e)): `g_hoverIndexSpaceStale` is published
// beside `g_hoveredEdge` by exactly its two publishers. The consumer's unit
// cell (tests/unit/tools/slice/edge_slice_tool_test.d) sets the flag itself,
// so it cannot see the production writers; this census reads them.
module tests.unit.hover_stale_writer_census_test;

import std.algorithm : count, endsWith;
import std.array     : array, replace;
import std.exception : enforce;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.regex     : regex, replaceAll;
import std.string    : indexOf;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, isIdentChar;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum kFlag = "g_hoverIndexSpaceStale";

/// Code only (comments, strings and in-module unittest bodies blanked), with
/// every whitespace run collapsed to one space so spacing cannot hide a site.
private string codeOf(string rel) {
    return blankUnittestBodies(blankNonCode(readText(buildPath(repoRoot, rel))))
        .replaceAll(regex(`\s+`), " ");
}

private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    enforce(at >= 0, "hover stale census: missing source marker `" ~ marker ~ "`");
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    enforce(i < code.length, "hover stale census: no body after `" ~ marker ~ "`");
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) return code[begin .. i + 1];
    }
    enforce(false, "hover stale census: unterminated body after `" ~ marker ~ "`");
    return null;
}

/// Every WRITE of the flag: the whole identifier followed by `=` that is not
/// `==`, excluding its declaration (`bool g_hoverIndexSpaceStale = ...`).
/// Also counts `&g_hoverIndexSpaceStale`, an address a write could go through.
private size_t writesIn(string code) {
    size_t n;
    for (ptrdiff_t at = code.indexOf(kFlag); at >= 0;
         at = code.indexOf(kFlag, at + kFlag.length)) {
        const b = cast(size_t)at, e = b + kFlag.length;
        if (b > 0 && isIdentChar(code[b - 1])) continue;
        if (e < code.length && isIdentChar(code[e])) continue;
        if (b > 0 && code[b - 1] == '&') { ++n; continue; }
        if (code[0 .. b].endsWith("bool ")) continue;   // the declaration
        size_t j = e;
        while (j < code.length && code[j] == ' ') ++j;
        if (j < code.length && code[j] == '=' && !(j + 1 < code.length && code[j + 1] == '='))
            ++n;
    }
    return n;
}

unittest {
    const fr = bodyAt(bodyAt(codeOf("source/frame_runner.d"), "final class FrameRunner"),
                      "HoverDrawState resolveHover(");
    const ir = bodyAt(bodyAt(codeOf("source/input_router.d"), "struct InputRouter"),
                      "void refreshHoverPickAt(");

    // Positive control: the bodies found are the two publishers of the hover.
    assert(fr.count("g_hoveredEdge = ifs_.hoveredEdge;") == 1
           && ir.count("g_hoveredEdge = ifs.hoveredEdge;") == 1,
           "hover stale census: the bodies found do not publish g_hoveredEdge "
           ~ "(the marker or the body scan is wrong, not the flag)");

    assert(fr.count(kFlag ~ " = ifs_.previewIndexSpaceStale();") == 1,
           "hover stale census: FrameRunner.resolveHover does not publish previewIndexSpaceStale");
    assert(ir.count(kFlag ~ " = ifs.previewIndexSpaceStale();") == 1,
           "hover stale census: InputRouter.refreshHoverPickAt does not publish previewIndexSpaceStale");

    // Population: exactly two writers in the whole source tree, so a third
    // writer (or a constant written past the two) reddens.
    size_t files, writers;
    foreach (f; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++files;
        writers += writesIn(codeOf(f.name[repoRoot.length + 1 .. $]));
    }
    assert(files > 100, format("hover stale census: only %d source files scanned", files));
    assert(writers == 2, format("hover stale census: expected 2 writers, got %d", writers));
}
