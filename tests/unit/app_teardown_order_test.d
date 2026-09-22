// Task 6770: pin the source declaration order of app.d teardown guards before
// the frame-extraction campaign starts moving main() braces. This is a source
// ratchet, not a proof that the current order is semantically correct. It also
// stops covering a guard once that guard moves out of app.d; the extracting
// slice must move or replace this witness together with the code.
module tests.unit.app_teardown_order_test;

import std.algorithm : filter;
import std.array     : array, join;
import std.file      : readText;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.regex     : ctRegex, matchFirst;
import std.string    : endsWith, indexOf, split, splitLines, startsWith, strip;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum ledgerPath = "tests/unit/app_teardown_order_ledger.txt";
private enum refreshCommand =
    "rdmd -version=TeardownOrderLedgerTool -I. " ~
    "tests/unit/app_teardown_order_test.d > " ~ ledgerPath;

private enum scopeExitRe = ctRegex!(`\bscope\s*\(\s*exit\s*\)`);
private enum teardownSymbolRe = ctRegex!(
    `\b(gl[A-Z]\w*|SDL_\w+|ImGui\w*|ig[A-Z]\w*|shutdownIPR|destroyGL|\.destroy\(\)|\.shutdown\(\))`);

private struct ScopeExit
{
    string key;
    string text;
    bool selected;
    size_t braceDepth;
}

private string normalise(string text)
{
    return text.split.join(" ");
}

private string stableKey(string text)
{
    // FNV-1a over the normalised CODE statement. The whole declaration is
    // hashed because three selected braced guards have the identical first
    // line `scope(exit) {`; hashing that line alone would alias them.
    ulong hash = 14_695_981_039_346_656_037UL;
    foreach (char c; text)
    {
        hash ^= cast(ubyte)c;
        hash *= 1_099_511_628_211UL;
    }
    return format("%016x", hash);
}

private size_t spanEnd(string[] lines, size_t start)
{
    if (lines[start].indexOf('{') < 0)
    {
        auto end = start;
        while (end < lines.length && !lines[end].strip.endsWith(";")) ++end;
        assert(end < lines.length,
            format("6770 scope(exit) statement at code line %d has no semicolon", start + 1));
        return end;
    }

    size_t depth;
    bool started;
    foreach (lineNo; start .. lines.length)
    {
        foreach (char c; lines[lineNo])
        {
            if (c == '{')
            {
                ++depth;
                started = true;
            }
            else if (c == '}' && started && --depth == 0)
                return lineNo;
        }
    }
    assert(false,
        format("6770 braced scope(exit) at code line %d is unbalanced", start + 1));
    return start;
}

private ScopeExit[] scanScopeExits(string source)
{
    const code = blankNonCode(source);
    auto lines = code.splitLines.array;
    ScopeExit[] rows;
    size_t braceDepth;
    foreach (lineNo, line; lines)
    {
        auto hit = matchFirst(line, scopeExitRe);
        if (!hit.empty)
        {
            size_t declarationDepth = braceDepth;
            foreach (char c; hit.pre)
            {
                if (c == '{') ++declarationDepth;
                else if (c == '}') --declarationDepth;
            }
            const end = spanEnd(lines, lineNo);
            auto statement = normalise(lines[lineNo .. end + 1].join("\n"));
            if (normalise(hit.pre) == "} else")
            {
                size_t previous = lineNo;
                while (previous > 0 && lines[previous - 1].strip.length == 0)
                    --previous;
                assert(previous > 0
                    && normalise(lines[previous - 1].strip) == "version (web) {",
                    format("6770 scope(exit) at code line %d has an unrecognised `} else` owner",
                        lineNo + 1));
                statement = "version (web) { } else "
                    ~ normalise(lines[lineNo][hit.pre.length .. $]
                        ~ "\n" ~ lines[lineNo + 1 .. end + 1].join("\n"));
            }
            rows ~= ScopeExit(stableKey(statement), statement,
                !matchFirst(statement, teardownSymbolRe).empty,
                declarationDepth);
        }
        foreach (char c; line)
        {
            if (c == '{') ++braceDepth;
            else if (c == '}') --braceDepth;
        }
    }
    return rows;
}

private ScopeExit[] readLedger(string text)
{
    ScopeExit[] rows;
    foreach (zeroLine, raw; text.splitLines)
    {
        const line = raw.strip;
        if (line.length == 0 || line.startsWith("#")) continue;
        assert(line.startsWith("scope "),
            format("%s:%d: expected `scope HASH NORMALISED-CODE`, got `%s`",
                ledgerPath, zeroLine + 1, line));
        const rest = line["scope ".length .. $];
        const words = rest.split;
        assert(words.length >= 2,
            format("%s:%d: missing hash or normalised declaration", ledgerPath,
                zeroLine + 1));
        const key = words[0];
        const declaration = rest[key.length .. $].strip;
        rows ~= ScopeExit(key, declaration, true, size_t.max);
    }
    return rows;
}

unittest
{
    const source = readText(buildPath(repoRoot, "source", "app.d"));
    const rows = scanScopeExits(source);

    // The broad and narrowed population floors precede the order pin. A
    // broken form scan or classifier must fail here, not pass an empty order.
    assert(rows.length == 26,
        format("6770 app.d scope(exit) population changed: expected 26, found %d",
            rows.length));
    const selected = rows.filter!(row => row.selected).array;
    assert(selected.length == 16,
        format("6770 teardown-rule population changed: expected 16, found %d; " ~
               "the rule is GL/SDL/ImGui/shutdownIPR/destroyGL/.destroy()/.shutdown()",
            selected.length));
    const webGuarded = selected.filter!(row =>
        row.text.startsWith("version (web) { } else ")).array;
    assert(webGuarded.length == 14,
        format("6770 web-gated teardown population changed: expected 14, found %d; " ~
               "desktop LIFO order and web omission are both part of this ledger",
            webGuarded.length));
    foreach (row; selected)
        assert(row.braceDepth == 1,
            format("6770 teardown declaration left main()'s shared top-level scope: " ~
                   "expected brace depth 1, found %d for [%s] %s; " ~
                   "the order pin below did not run",
                row.braceDepth, row.key, row.text));

    const expected = readLedger(readText(buildPath(repoRoot, ledgerPath)));
    assert(expected.length == 16,
        format("6770 generated teardown ledger must contain 16 rows, found %d; refresh with: %s",
            expected.length, refreshCommand));

    foreach (i; 0 .. expected.length)
    {
        assert(expected[i].key == selected[i].key
            && expected[i].text == selected[i].text,
            format("6770 app.d teardown declaration order changed at slot %d: " ~
                   "expected [%s] %s, found [%s] %s; refresh only after reviewing " ~
                   "the LIFO teardown consequence",
                i + 1, expected[i].key, expected[i].text,
                selected[i].key, selected[i].text));
    }
}

unittest // syntax capability: spaced/multiline forms, braces, and non-code decoys
{
    enum fixture = q{
        // scope(exit) SDL_Quit();
        enum decoy = "scope(exit) SDL_Quit();";
        scope ( exit ) glDeleteProgram(program);
        scope(exit)
            SDL_Quit();
        scope(exit) { owner.destroy(); }
        scope(exit) igSetNextWindowClass(null);
    };
    const rows = scanScopeExits(fixture);
    assert(rows.length == 4,
        format("6770 scope(exit) syntax fixture expected 4 CODE declarations, found %d",
            rows.length));
    assert(rows.filter!(row => row.selected).array.length == 4,
        "6770 teardown classifier must select every syntax-fixture declaration");
}

version (TeardownOrderLedgerTool)
void main()
{
    import std.stdio : writeln;

    const source = readText(buildPath(repoRoot, "source", "app.d"));
    const rows = scanScopeExits(source).filter!(row => row.selected).array;
    assert(rows.length == 16,
        format("refusing to generate a teardown ledger with %d rows; expected 16",
            rows.length));

    writeln("# Task 6770 app.d teardown declaration order. GENERATED FILE.");
    writeln("# Keys hash normalised CODE declarations, never source line numbers.");
    writeln("# Refresh (the generator reads source/app.d, so this output path is safe):");
    writeln("#     " ~ refreshCommand);
    writeln("# Then read the diff and review the reverse-execution consequence.");
    foreach (row; rows)
        writeln("scope " ~ row.key ~ " " ~ row.text);
}
