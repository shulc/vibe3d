// The document test-access seam has ONE caller file, and this closes it
// (task 4120).
//
// `source/document.d` ends in a `version (unittest)` block of six readers that
// reach state which is `private` for a reason. They exist so that the document
// unit tests can be ordinary top-level `unittest` blocks in an ordinary test
// module instead of a `mixin template` the production module imports back —
// the live cyclic import this task removed. The comment at the seam carries
// the alternatives and why the compiler rejected them.
//
// THE COST THE SEAM CARRIES, AND WHAT THIS FILE DOES ABOUT IT. Those six are
// PUBLIC inside a `-unittest` build. Nothing in the language stops a second
// test module from reaching for them, and each one that does turns a narrow
// seam into a general back door — after which the fields are private only in
// the sense that nobody has typed the other spelling yet. So the caller set is
// ENUMERATED rather than merely intended: exactly one file may name them, and
// a second one reddens here.
//
// WHY IT IS NOT ENOUGH TO ASSERT THAT. Two ways the assertion could be true
// and mean nothing, both guarded above it:
//
//   * The names could match NOTHING. "No file outside the pair names a seam
//     reader" holds trivially over an empty match set — the vacuous-predicate
//     shape. So the census first requires each of the six to be USED, at least
//     once, in the one file allowed to use it. A rename on one side only, or a
//     reader whose last call site went away, dies here rather than passing.
//   * The LIST could go stale. A seventh reader added to the seam and not
//     added below would be uncensused, and this file would keep passing over
//     the six it knows. So the list is checked against the block itself: the
//     declarations parsed out of the seam must be exactly the names listed.
//
// The scan reads code, not raw text: comments and string literals are blanked
// first, which is also why the names below can be spelled here as data without
// this file counting as a caller of anything.
//
// MUTATIONS, each in isolation:
//   * add a call to any seam reader from a second test module ⇒ the caller-set
//     assertion reddens, naming that file;
//   * delete the last call to one reader from `tests/unit/document_test.d`
//     ⇒ the population floor reddens, naming that reader;
//   * add a seventh reader to the seam ⇒ the declaration-set assertion reddens.
module tests.unit.document_seam_census_test;

import std.algorithm : canFind, sort;
import std.array : appender, join;
import std.file : dirEntries, exists, isDir, readText, SpanMode;
import std.format : format;
import std.path : buildNormalizedPath, buildPath, dirName, relativePath;
import std.regex : ctRegex, matchAll, regex;
import std.string : endsWith, replace, splitLines, strip;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// The file that DECLARES the seam, and the one file allowed to call it.
private enum seamDecl = "source/document.d";
private enum seamCaller = "tests/unit/document_test.d";

/// The six readers. Data, deliberately: spelled as string literals so that
/// this census is not itself a caller of the thing it is counting.
private immutable string[] seamReaders = [
    "testHistoryBucketHolds",
    "testEditTargetCandidate",
    "testExclusiveSelect",
    "testMeshField",
    "testImageField",
    "testPreparedPendingImage",
];

private string toScanPath(string path)
{
    return buildNormalizedPath(path).replace("\\", "/");
}

/// Word-boundary occurrences of `name` in `code`, which must already have had
/// its comments and string literals blanked.
private size_t occurrences(string code, string name)
{
    return matchAll(code, regex(`(^|[^A-Za-z0-9_])` ~ name ~ `($|[^A-Za-z0-9_])`))
        .save.count;
}

private size_t count(R)(R range)
{
    size_t n;
    foreach (_; range) ++n;
    return n;
}

/// The reader names declared by the `version (unittest)` seam at the tail of
/// `source/document.d`, read out of the file rather than trusted from a list.
private string[] declaredSeamReaders(string text)
{
    enum head = "version (unittest) {";
    const at = text.canFind(head);
    assert(at, seamDecl ~ " no longer contains a `version (unittest) {` block; "
             ~ "the seam census cannot locate the seam");
    size_t i = 0;
    foreach (n, line; text.splitLines)
        if (line.strip == head) i = n;
    auto names = appender!(string[]);
    // A declaration inside the block: four spaces, a return type (possibly
    // `Mesh*`), a space, the name, an open paren.
    enum declRe = ctRegex!(`^    [A-Za-z_][A-Za-z0-9_]*\*? +([A-Za-z_][A-Za-z0-9_]*)\(`);
    foreach (line; text.splitLines[i + 1 .. $])
    {
        auto m = matchAll(line, declRe);
        if (!m.empty) names.put(m.front[1].idup);
    }
    auto result = names.data;
    result.sort();
    return result;
}

unittest
{
    const declPath = buildPath(repoRoot, seamDecl);
    const callerPath = buildPath(repoRoot, seamCaller);
    assert(exists(declPath), seamDecl ~ " is missing");
    assert(exists(callerPath), seamCaller ~ " is missing");

    // ---- (1) the LIST is the seam. A seventh reader cannot be born uncensused.
    string[] listed = seamReaders.dup;
    listed.sort();
    const declared = declaredSeamReaders(readText(declPath));
    assert(declared == listed,
        format("the `version (unittest)` seam in %s declares %s, but this "
             ~ "census knows %s. Add the new reader to `seamReaders` in this "
             ~ "file (and give it a call site), or delete it from the seam.",
               seamDecl, declared, listed));

    // ---- (2) the POPULATION FLOOR. Every reader is actually reached, so the
    //          caller-set assertion below cannot be true over an empty set.
    const callerCode = blankNonCode(readText(callerPath));
    size_t callTotal;
    string[] unused;
    foreach (name; seamReaders)
    {
        const n = occurrences(callerCode, name);
        callTotal += n;
        if (n == 0) unused ~= name;
    }
    assert(unused.length == 0,
        format("seam readers with no call site in %s: %s. A reader nothing "
             ~ "reaches is either a rename that was only half applied or dead "
             ~ "production code; either way the caller-set check below would "
             ~ "be passing over nothing.", seamCaller, unused.join(", ")));
    assert(callTotal >= seamReaders.length,
        format("expected at least one call per reader in %s, found %d in total",
               seamCaller, callTotal));

    // ---- (3) THE LAW. Nothing outside the declaring file and that one caller
    //          may name a seam reader.
    string[] strays;
    foreach (root; ["source", "tests"])
    {
        const dir = buildPath(repoRoot, root);
        if (!isDir(dir)) continue;
        foreach (entry; dirEntries(dir, SpanMode.depth))
        {
            if (!entry.isFile || !entry.name.endsWith(".d")) continue;
            const rel = toScanPath(relativePath(entry.name, repoRoot));
            if (rel == seamDecl || rel == seamCaller) continue;
            const code = blankNonCode(readText(entry.name));
            foreach (name; seamReaders)
                if (occurrences(code, name) > 0)
                    strays ~= rel ~ " names " ~ name;
        }
    }
    assert(strays.length == 0,
        format("the document test-access seam has exactly one caller file, %s, "
             ~ "and these reach it too: %s. Every extra caller widens a "
             ~ "`private` field's real audience; add the state you need to the "
             ~ "test through `%s` instead, or argue the widening on the card "
             ~ "before editing this census.",
               seamCaller, strays.join("; "), seamCaller));
}
