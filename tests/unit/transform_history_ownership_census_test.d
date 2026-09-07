// Transform history ownership witness (task 4610).
//
// The embedded bank population is DERIVED from XfrmTransformTool's constructor:
// every `field = new *Tool(...)` assignment is a bank proposal.  This avoids a
// hand-maintained Move/Rotate/Scale roster that could silently omit a fourth
// bank.  The population floor executes before the ownership assertion, so an
// empty/desynchronised scan cannot "prove" that no bank receives history.
module tests.unit.transform_history_ownership_census_test;

import std.algorithm : sort;
import std.array : join;
import std.conv : to;
import std.file : exists, readText;
import std.path : buildPath, dirName;
import std.regex : matchAll, regex;
import std.string : indexOf;

import tests.unit.census_symbols : blankNonCode, historySurface;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private string[] embeddedBanks(string code)
{
    string[] names;
    auto ctor = regex(`\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*new\s+`
                    ~ `[A-Za-z_][A-Za-z0-9_]*Tool\s*\(`);
    foreach (m; matchAll(code, ctor)) names ~= m.captures[1];
    names.sort();
    return names;
}

private string xfrmConstructor(string code)
{
    auto classAt = code.indexOf("class XfrmTransformTool");
    if (classAt < 0) return null;
    auto ctorRel = code[cast(size_t) classAt .. $].indexOf("this(");
    if (ctorRel < 0) return null;
    const ctorAt = cast(size_t) classAt + cast(size_t) ctorRel;
    auto openRel = code[ctorAt .. $].indexOf("{");
    if (openRel < 0) return null;
    const open = ctorAt + cast(size_t) openRel;
    int depth;
    foreach (i; open .. code.length) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) return code[open .. i + 1];
    }
    return null;
}

private string[] historyBoundBanks(string code, const string[] banks)
{
    string[] bound;
    foreach (bank; banks) {
        auto call = regex(`\b` ~ bank ~ `\s*\.\s*setUndoBindings\s*\(`);
        if (!matchAll(code, call).empty) bound ~= bank;
    }
    bound.sort();
    return bound;
}

unittest // executes in the module-unittest gate, before any HTTP driver starts
{
    immutable path = buildPath(repoRoot, "source", "tools", "transform",
                               "xfrm_transform.d");
    assert(exists(path),
        "transform history ownership census: xfrm_transform.d is missing");
    const code = blankNonCode(readText(path));

    // NON-DEGENERACY FIRST: this is what makes the absence assertion below
    // evidence rather than a vacuous truth.
    const ctor = xfrmConstructor(code);
    assert(ctor.length > 0,
        "transform history ownership census: XfrmTransformTool constructor was not found");
    const banks = embeddedBanks(ctor);
    assert(banks.length == 3,
        "transform history ownership census: expected three constructor-derived "
        ~ "embedded banks, found " ~ banks.length.to!string);

    // Runs after the population floor.  Embedded banks may hit-test and turn
    // gestures into values, but only the wrapper/run owner may receive history
    // and command factories; without those capabilities a bank cannot record.
    const bound = historyBoundBanks(code, banks);
    assert(bound.length == 0,
        "transform history ownership census: embedded banks still receive "
        ~ "history/undo factories: " ~ bound.join(", "));

    // Executes after capability removal. Every direct history write in the
    // wrapper module must now sit in the one typed decision method; the count
    // pins its three real intents without enumerating bank names.
    auto writes = historySurface(code);
    size_t ownedWrites;
    foreach (w; writes)
        if (w.symbol == "XfrmTransformTool.recordTransformCommand")
            ++ownedWrites;
    assert(ownedWrites == 3,
        "transform history ownership census: expected three typed wrapper "
        ~ "history arms, found " ~ ownedWrites.to!string);
}
