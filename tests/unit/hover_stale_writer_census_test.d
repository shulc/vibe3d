// Tasks 7114, 9439 (HOV1): the hover ids and `g_hoverIndexSpaceStale` are
// written by ONE publisher (`hover_state.publishHover`), and every PRESS-time
// reader reads through `hoverAtPress` (none while the ids are held stale). The
// reader cells (tests/unit/hover_at_press_test.d) set the globals themselves,
// so they cannot see the production writers or a raw read; this census can.
// Sites are keyed by their enclosing declaration (census_symbols).
module tests.unit.hover_stale_writer_census_test;

import std.algorithm : canFind, endsWith, sort, startsWith;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.regex     : regex, replaceAll;
import std.string    : indexOf, stripLeft, stripRight;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, enclosingSymbols,
    isIdentChar, lineOf, symbolAt;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private immutable kIds = ["g_hoveredVertex", "g_hoveredEdge", "g_hoveredFace"];
private enum kFlag = "g_hoverIndexSpaceStale";

/// Whole-identifier hits of `name`; `write` is set for `=` (not `==`), an
/// op-assign, `++`/`--` on either side, or an address taken (`&name`). The
/// declarations (`int g_hovered… =`, `bool g_hover… =`) are skipped.
private void hits(string code, string name, void delegate(size_t at, bool write) sink) {
    for (ptrdiff_t at = code.indexOf(name); at >= 0; at = code.indexOf(name, at + name.length)) {
        const b = cast(size_t)at, e = b + name.length;
        if ((b > 0 && isIdentChar(code[b - 1])) || (e < code.length && isIdentChar(code[e]))) continue;
        const pre = code[b >= 8 ? b - 8 : 0 .. b].stripRight;
        if (pre.endsWith(" int") || pre.endsWith(" bool")) continue;
        const rest = code[e .. $].stripLeft;
        const r2 = rest.length > 1 ? rest[0 .. 2] : rest;
        const write = (pre.endsWith("&") && !pre.endsWith("&&")) || pre.endsWith("++") || pre.endsWith("--")
            || r2 == "++" || r2 == "--" || (r2.length == 2 && r2[1] == '=' && "+-*/%|&^~".canFind(r2[0]))
            || (r2.length > 0 && r2[0] == '=' && r2 != "==");
        sink(b, write);
    }
}

unittest {
    size_t files, writes, pressCalls;
    string[] writers, pressSites, rawPressReads, frameReaders;
    immutable press = ["TackTool.onMouseButtonDown", "MagnetTool.onMouseButtonDown",
        "LoopSliceTool.onMouseButtonDown", "EdgeSliceTool.onMouseButtonDown",
        "XfrmTransformTool.tryPickElement"];
    foreach (f; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++files;
        const rel = f.name[repoRoot.length + 1 .. $];
        const code = blankUnittestBodies(blankNonCode(readText(f.name)));
        const syms = enclosingSymbols(code);
        string symOf(size_t at) { return symbolAt(syms, lineOf(code, at) - 1); }
        foreach (name; kIds ~ kFlag)
            hits(code, name, (at, write) {
                const s = symOf(at);
                if (write) { ++writes; if (!writers.canFind(s)) writers ~= s; return; }
                if (name == kFlag) return;
                if (press.canFind!(p => s.length >= p.length && s[$ - p.length .. $] == p))
                    rawPressReads ~= rel ~ ":" ~ s;
                else if (rel != "source/hover_state.d" && !frameReaders.canFind(rel))
                    frameReaders ~= rel;
            });
        hits(code, "hoverAtPress", (at, write) {
            if (!code[at + "hoverAtPress".length .. $].stripLeft.startsWith("(")) return;
            if (code[0 .. at].stripRight.endsWith("HoverIds")) return;   // its declaration
            const s = symOf(at);
            ++pressCalls;
            foreach (p; press) if (s.length >= p.length && s[$ - p.length .. $] == p
                                   && !pressSites.canFind(p)) pressSites ~= p;
        });
    }
    assert(files > 100, format("hover census: only %d source files scanned", files));

    // ONE writer: the three ids and the flag, once each, inside publishHover.
    assert(writes == 4, format("hover census: expected 4 writes (3 ids + flag), got %d in %s", writes, writers));
    assert(writers == ["publishHover"] && writers.length == 1,
           format("hover census: hover globals written outside publishHover: %s", writers));

    // Press-time readers: each named press function reads through hoverAtPress, none raw.
    assert(rawPressReads.length == 0, format("hover census: raw hover id read in a press: %s", rawPressReads));
    assert(pressSites.length == 5 && pressCalls == 5,
           format("hover census: expected 5 press sites / 5 calls, got %s / %d", pressSites, pressCalls));

    // Per-frame / report readers keep the HELD ids (task 1730): a pinned roster.
    frameReaders.sort();
    assert(frameReaders == ["source/http_providers.d", "source/tools/edit/tack.d",
                            "source/tools/slice/edge_slice_tool.d",
                            "source/tools/slice/loop_slice_tool.d"],
           format("hover census: per-frame reader roster changed: %s", frameReaders));

    // Edge slice keeps its own absorb line ABOVE its press read (task 7114).
    const es = readText(buildPath(repoRoot, "source/tools/slice/edge_slice_tool.d"))
        .replaceAll(regex(`\s+`), " ");
    const absorb = es.indexOf("if (" ~ kFlag ~ ") return true; int h = hoverAtPress().edge;");
    assert(absorb >= 0, "hover census: edge slice lost its stale absorb line above its press read");
}
