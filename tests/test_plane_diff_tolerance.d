// The injected helper cannot contain a unittest: it is linked into every test
// binary, where druntime would run it and skip that binary's main. This file is
// the helper's socket-free boundary witness instead.

import plane_diff_helpers;

import std.algorithm : sort;
import std.array     : join;
import std.file      : SpanMode, dirEntries, readText;
import std.format    : format;
import std.math      : nextUp;
import std.path      : baseName;
import std.string    : count;

void main() {}

private double asDouble(float value)
{
    return value;
}

private float ulpsAbove(float value, size_t ulps)
{
    foreach (_; 0 .. ulps) value = nextUp(value);
    return value;
}

private string numberToken(float value)
{
    return format("%.17g", asDouble(value));
}

private string planeDump(string vertexToken, string countToken = "1")
{
    return `{"provenance":{"producedBy":"synthetic"},`
         ~ `"counts":{"vertices":` ~ countToken ~ `},`
         ~ `"vertices":[[` ~ vertexToken ~ `,0,0]]}`;
}

private struct Cell
{
    string name;
    string frozenText;
    string freshText;
    string[] expected;
}

unittest
{
    immutable float three = 3.0f;
    immutable float zero = 0.0f;
    immutable float corpusMinimum = 0x1p-31f;
    immutable float absUnder = 9.0e-7f;
    immutable float absOver = 1.0e-6f;
    immutable float unit = 1.0f;
    immutable float unitShift = unit + 1.0e-3f;

    Cell[] cells = [
        Cell("P-rel", planeDump(numberToken(three)),
             planeDump(numberToken(ulpsAbove(three, 11))), []),
        Cell("P-abs", planeDump(numberToken(zero)),
             planeDump(numberToken(corpusMinimum)), []),
        Cell("P-abs-edge", planeDump(numberToken(zero)),
             planeDump(numberToken(absUnder)), []),
        Cell("R-rel-over", planeDump(numberToken(three)),
             planeDump(numberToken(ulpsAbove(three, 13))), ["vertices"]),
        Cell("R-abs-over", planeDump(numberToken(zero)),
             planeDump(numberToken(absOver)), ["vertices"]),
        Cell("R-1e-3", planeDump(numberToken(unit)),
             planeDump(numberToken(unitShift)), ["vertices"]),
        Cell("I-int", planeDump(numberToken(unit), "104857600"),
             planeDump(numberToken(unit), "104857601"), ["counts"]),
        Cell("T-type", planeDump("null"),
             planeDump(numberToken(corpusMinimum)), ["vertices"]),
    ];

    string[] failures;
    size_t evaluated;
    foreach (cell; cells) {
        ++evaluated;
        if (cell.frozenText == cell.freshText) {
            failures ~= cell.name ~ ": the two serialized inputs are identical";
            continue;
        }

        try {
            auto actual = planeDiff(cell.frozenText, cell.freshText);
            actual.sort();
            auto expected = cell.expected.dup;
            expected.sort();
            if (actual != expected)
                failures ~= format("%s: expected %s, got %s",
                                   cell.name, expected, actual);
        } catch (Throwable error) {
            failures ~= cell.name ~ ": comparator threw: " ~ error.msg;
        }
    }

    if (evaluated != 8)
        failures ~= format("population: expected 8 cells, evaluated %d", evaluated);

    // The census patterns are assembled at runtime so this witness cannot
    // match its own source text. Skip this file as a second, independent guard.
    immutable oldComparator = "pa.to" ~ "String() != pb.toString()";
    immutable definition = "string[]" ~ " planeDiff";
    size_t oldCount;
    size_t definitionCount;
    string[] definitionFiles;
    foreach (entry; dirEntries("tests", "*.d", SpanMode.shallow)) {
        if (baseName(entry.name) == baseName(__FILE__)) continue;
        immutable sourceText = readText(entry.name);
        oldCount += sourceText.count(oldComparator);
        immutable found = sourceText.count(definition);
        definitionCount += found;
        if (found > 0) definitionFiles ~= entry.name;
    }
    if (oldCount != 0)
        failures ~= format("census: found %d serialized-text comparator(s)",
                           oldCount);
    if (definitionCount != 1
        || definitionFiles != ["tests/plane_diff_helpers.d"])
        failures ~= format("census: expected one planeDiff definition in the "
                         ~ "shared helper, found %d in %s",
                           definitionCount, definitionFiles);

    assert(failures.length == 0,
           "plane-diff tolerance witness failed:\n  " ~ failures.join("\n  "));
}
