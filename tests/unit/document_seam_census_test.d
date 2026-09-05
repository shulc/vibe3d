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
//   * add a seventh reader to the seam ⇒ the declaration-set assertion reddens,
//     and it reddens whether the reader is spelled at indent 4 or at column 0;
//   * put that seventh reader in a SECOND `version(unittest)` block, or outside
//     every block ⇒ the header-uniqueness guard or the backstop reddens. Both
//     of those were GREEN once, measured, not imagined — see the parse below.
module tests.unit.document_seam_census_test;

import std.algorithm : canFind, sort, startsWith;
import std.array : appender, join;
import std.file : dirEntries, exists, isDir, readText, SpanMode;
import std.format : format;
import std.path : buildNormalizedPath, buildPath, dirName, relativePath;
import std.regex : ctRegex, matchAll, matchFirst, regex;
import std.string : endsWith, replace, splitLines, strip;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// The file that DECLARES the seam, and the one file allowed to call it.
private enum seamDecl = "source/document.d";
private enum seamCaller = "tests/unit/document_test.d";

/// The six accessors. Data, deliberately: spelled as string literals so that
/// this census is not itself a caller of the thing it is counting.
private immutable string[] seamReaders = [
    "testHistoryBucketHolds",
    "testEditTargetCandidate",
    "testExclusiveSelect",
    "testMeshFieldAddr",
    "testImageFieldAddr",
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

/// The accessor names declared by the `version (unittest)` seam at the tail of
/// `source/document.d`, read out of the file rather than trusted from a list.
///
/// PARSED BY NAME CONVENTION, NOT BY RETURN TYPE, and that is the whole point
/// of this function's second draft. The first matched `^    Ident\*? +name\(`,
/// so it saw only a BARE-IDENTIFIER return type: `const(Layer) testStray(` and
/// `ref Mesh testStrayRef(` parsed to nothing at all, `declared == listed`
/// still held over the six it did see, and a seventh accessor was born
/// uncensused — exactly the failure the caller below exists to prevent. Not
/// inferred: both spellings were added to the live seam and this census stayed
/// GREEN both times (task 4120 review, cells C1 and C2).
///
/// THE SECOND ROUND FOUND TWO MORE OF THE SAME KIND — a guard keyed on a
/// STRING rather than on a SHAPE — and both were measured the same way, by
/// putting the thing in the live seam and watching this census stay GREEN
/// (task 4120 re-review, cells R1 and R2):
///
///   * the header was compared as the exact string `version (unittest) {`, so
///     D's equally legal `version(unittest) {` was not a header at all. A
///     second block spelled that way could hold a seventh accessor while the
///     "exactly ONE header" guard below still counted one;
///   * the yield-a-name guard was gated on `startsWith("    ")`, so a
///     declaration at COLUMN 0 was filtered out as "not a declaration line"
///     before the guard could fire on it.
///
/// Five guards now. The last two are the ones that generalise:
///
///   * the header is matched by a whitespace-tolerant regex and ALL matches
///     are counted, so "exactly one" means one BLOCK and not one spelling of
///     one block. The predecessor took the LAST match, so a second block above
///     the seam silently moved the parse window past it;
///   * the opening brace may sit on the header line or on the next one — D
///     reads both as the same block, and so does this;
///   * the block is bounded by its own closing brace rather than running to
///     end of file, so a declaration added BELOW the seam is out of scope
///     instead of being counted into it;
///   * every block line NOT DEEPER than the declaration column must yield a
///     name. Matching a convention can only ever miss, so the miss is made
///     loud: such a line carrying a `(` and no `test<Upper>` name is a
///     failure, not a silent zero. Keyed on the indent DEPTH, because the
///     `startsWith("    ")` it replaces was a filter the guard sat behind;
///   * and OUTSIDE the block, nothing in the file may look like a seam
///     accessor at all. That is the backstop under the other four: it does not
///     care how a second block was spelled, only that a `test<Upper>(`
///     declaration ended up somewhere this parse does not read.
private string[] declaredSeamReaders(string rawText)
{
    // Comments and string literals blanked first: `source/document.d` names
    // this very header inside the prose above the seam, and a parse that read
    // raw text would locate the block in a paragraph about the block.
    const text = blankNonCode(rawText);
    auto lines = text.splitLines;

    // Whitespace-tolerant, and every match counted — see cell R2 above.
    enum headRe = ctRegex!(`^[ \t]*version[ \t]*\([ \t]*unittest[ \t]*\)[ \t]*\{?[ \t]*$`);
    size_t[] headLines;
    foreach (n, line; lines)
        if (!matchFirst(line, headRe).empty) headLines ~= n + 1;
    assert(headLines.length == 1,
        format("%s must hold exactly ONE `version (unittest)` block header for "
             ~ "this census to know which block it is reading; found %d (lines "
             ~ "%s). A second block would leave one of them unenumerated.",
               seamDecl, headLines.length, headLines));
    const headIdx = headLines[0] - 1;

    // Allman or not: the brace is on the header line, or alone on the next.
    size_t start = headIdx;
    if (!lines[headIdx].strip.endsWith("{"))
    {
        assert(headIdx + 1 < lines.length && lines[headIdx + 1].strip == "{",
            format("the `version (unittest)` header at %s:%d is not followed by "
                 ~ "an opening brace on its own or the next line; this census "
                 ~ "cannot tell where the seam begins.", seamDecl, headIdx + 1));
        start = headIdx + 1;
    }

    size_t end = lines.length;
    foreach (n; start + 1 .. lines.length)
        if (lines[n] == "}") { end = n; break; }
    assert(end < lines.length,
        format("the `version (unittest)` block in %s is not closed by a "
             ~ "column-0 `}`; this census cannot bound the seam and would read "
             ~ "the rest of the file as part of it.", seamDecl));

    auto names = appender!(string[]);
    // The seam's naming convention, and the only thing the parse keys on:
    // `test` then an upper-case letter. Every return-type spelling therefore
    // parses — `const(Layer)`, `ref Mesh`, `inout(Mesh)*`, an attribute in
    // front of any of them.
    enum nameRe = ctRegex!(`\btest[A-Z][A-Za-z0-9_]*[ \t]*\(`);
    foreach (n; start + 1 .. end)
    {
        const line = lines[n];
        const body_ = line.strip;
        if (body_.length == 0) continue;
        // Declarations sit AT MOST at indent 4; bodies are deeper. The depth
        // test is the guard, not a filter in front of it: `startsWith("    ")`
        // excused a column-0 declaration from having to yield a name at all.
        size_t indent;
        while (indent < line.length && (line[indent] == ' ' || line[indent] == '\t'))
            ++indent;
        if (indent > 4) continue;
        if (!body_.canFind('(')) continue;
        auto m = matchAll(line, nameRe);
        assert(!m.empty,
            format("%s:%d is a declaration-depth line in the seam and yields "
                 ~ "no `test<Upper>` name: `%s`. Seam accessors are recognised "
                 ~ "BY THAT CONVENTION, so an accessor named otherwise would "
                 ~ "be invisible here; rename it, or move it out of the seam.",
                   seamDecl, n + 1, body_));
        const hit = m.front[0];
        names.put(hit[0 .. $ - 1].strip.idup);
    }

    // THE BACKSTOP. Four guards above decide what the ONE block contains; this
    // one refuses a seam-shaped declaration that never entered a block this
    // parse reads — whatever the spelling that put it there.
    string[] outside;
    foreach (n, line; lines)
    {
        if (n > start && n < end) continue;
        if (matchFirst(line, nameRe).empty) continue;
        outside ~= format("%d: %s", n + 1, line.strip);
    }
    assert(outside.length == 0,
        format("%s names a `test<Upper>(` accessor outside the one parsed "
             ~ "`version (unittest)` block, so this census would never see it: "
             ~ "%s. Move it into the seam, or stop naming it like one.",
               seamDecl, outside.join("; ")));

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
