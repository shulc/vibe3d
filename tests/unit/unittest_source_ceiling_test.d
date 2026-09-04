// Source-test policy gate (task 4057).
//
// `unittest` declarations in source/ may only fall from the recorded total.
// `version(unittest)` has a per-file ceiling of 10; files already above it
// carry their own numeric ceiling in unittest_source_ceiling_ledger.txt, and
// that allowance is EXACT — a file that sheds a guard must lower its row.
//
// Both counts operate on D code, not raw text. `scanD` is the census gate's D
// lexer; `blankNonCode` removes line/block/nested comments plus every D string
// and character literal before the version regex runs. The first unittest is
// a fixture proving that a comment and a string containing the word unittest
// do not move either count — and it first proves the decoys are COUNTABLE, so
// the proof cannot pass over tokens that were never visible to begin with.
//
// ADMITTING A PERMITTED BLOCK. CLAUDE.md ("Running Tests") permits an in-module
// `unittest` under source/ when it needs direct access to a `private` symbol,
// and this gate is a ratchet that reddens on ANY addition. The two are not in
// conflict: admission is deliberate. In the SAME commit as the new block, raise
// `unittest-blocks` and that file's `block` row in the ledger, and name the
// private symbol in the commit message. The per-file rows are ENFORCED (their
// sum must equal the recorded total, and no file may exceed its own row), so a
// block that MOVES between two files needs both rows edited — a move used to be
// invisible here.
//
// REFRESHING THE LEDGER. The rows are generated, not hand-counted:
//
//     rdmd -version=CeilingLedgerTool -I. \
//         tests/unit/unittest_source_ceiling_test.d > \
//         tests/unit/unittest_source_ceiling_ledger.txt
//
// Read the resulting diff before committing it: regeneration is mechanical and
// will happily absorb an addition nobody argued for.
module tests.unit.unittest_source_ceiling_test;

import std.algorithm : sort;
import std.array : appender, join, replace;
import std.conv : to;
import std.file : dirEntries, exists, isDir, readText, SpanMode;
import std.format : format;
import std.path : buildNormalizedPath, buildPath, dirName, relativePath;
import std.range : walkLength;
import std.regex : ctRegex, matchAll;
import std.string : endsWith, split, splitLines, strip;

import tests.unit.census_gate : scanD;
import tests.unit.version_poll_census_test : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum ledgerPath = "tests/unit/unittest_source_ceiling_ledger.txt";
private enum versionUnittestRe = ctRegex!(`\bversion\s*\(\s*unittest\s*\)`);
private enum unittestBlockRe = ctRegex!(`\bunittest\s*\{`);

// The one refresh command, quoted into every message that could otherwise send
// someone hunting for a generator that does not exist. The 176 rows below were
// first produced by a scratch program outside the repository; this is that
// program, committed beside the numbers it writes.
private enum refreshCommand =
    "rdmd -version=CeilingLedgerTool -I. " ~
    "tests/unit/unittest_source_ceiling_test.d > " ~ ledgerPath;

// The admission procedure, quoted into the growth message. The policy permits
// an inline unittest for a `private` symbol and the gate reddens on every
// addition, so the person who trips it has to read the way forward HERE, at the
// point of failure, not infer that there is one.
private enum admissionProcedure =
    "an in-module unittest under source/ is admissible only when it needs a " ~
    "`private` symbol (CLAUDE.md, \"Running Tests\"); everything else belongs " ~
    "in tests/unit/. To admit a permitted block, raise `unittest-blocks` AND " ~
    "that file's `block` row in " ~ ledgerPath ~ " in the SAME commit as the " ~
    "block, naming the private symbol in the commit message. Refresh the rows " ~
    "with: " ~ refreshCommand;

private struct Ledger
{
    size_t sourceFiles;
    size_t unittestBlocks;
    size_t versionCeiling;
    size_t[string] blocksByFile;
    size_t[string] versionAllow;
}

private size_t parseCount(string word, string origin, size_t lineNo)
{
    try return word.to!size_t;
    catch (Exception)
        throw new Exception(format("%s:%d: `%s` is not a non-negative integer",
                                   origin, lineNo, word));
}

private Ledger parseLedger(string text, string origin)
{
    Ledger result;
    bool sawSourceFiles;
    bool sawUnittestBlocks;
    bool sawVersionCeiling;

    foreach (zeroLine, raw; text.splitLines)
    {
        const lineNo = zeroLine + 1;
        const line = raw.strip;
        if (line.length == 0 || line[0] == '#') continue;

        const words = line.split;
        switch (words[0])
        {
            case "source-files":
                assert(words.length == 2 && !sawSourceFiles,
                       format("%s:%d: expected one `source-files N` row", origin, lineNo));
                result.sourceFiles = parseCount(words[1], origin, lineNo);
                sawSourceFiles = true;
                break;
            case "unittest-blocks":
                assert(words.length == 2 && !sawUnittestBlocks,
                       format("%s:%d: expected one `unittest-blocks N` row", origin, lineNo));
                result.unittestBlocks = parseCount(words[1], origin, lineNo);
                sawUnittestBlocks = true;
                break;
            case "version-ceiling":
                assert(words.length == 2 && !sawVersionCeiling,
                       format("%s:%d: expected one `version-ceiling N` row", origin, lineNo));
                result.versionCeiling = parseCount(words[1], origin, lineNo);
                sawVersionCeiling = true;
                break;
            case "block":
                assert(words.length == 3,
                       format("%s:%d: expected `block source/path.d N`", origin, lineNo));
                assert((words[1] in result.blocksByFile) is null,
                       format("%s:%d: duplicate block row for %s", origin, lineNo, words[1]));
                result.blocksByFile[words[1]] = parseCount(words[2], origin, lineNo);
                assert(result.blocksByFile[words[1]] > 0,
                       format("%s:%d: zero-count block rows are omitted", origin, lineNo));
                break;
            case "allow-version":
                assert(words.length == 3,
                       format("%s:%d: expected `allow-version source/path.d N`", origin, lineNo));
                assert((words[1] in result.versionAllow) is null,
                       format("%s:%d: duplicate version allow-list row for %s",
                              origin, lineNo, words[1]));
                result.versionAllow[words[1]] = parseCount(words[2], origin, lineNo);
                break;
            default:
                assert(false, format("%s:%d: unknown ledger row `%s`", origin, lineNo, line));
        }
    }

    assert(sawSourceFiles && sawUnittestBlocks && sawVersionCeiling,
           origin ~ ": source-files, unittest-blocks, and version-ceiling are required");
    foreach (path, limit; result.versionAllow)
        assert(limit > result.versionCeiling,
               format("%s: %s belongs on the allow-list only above the ordinary ceiling %d",
                      origin, path, result.versionCeiling));
    return result;
}

private size_t countVersionUnittest(string source)
{
    return blankNonCode(source).matchAll(versionUnittestRe).walkLength;
}

/// Ledger rows are written with `/` and no `./` prefix. `relativePath` hands
/// back `\` on Windows, where every row would miss: the block rows would all
/// read as "recorded 0" and the ten allow-list rows would report as stale
/// allowances. Latent today — the module gate does not run on Windows — and one
/// line to close. `buildNormalizedPath` drops the `./` the generator's default
/// root (".") would otherwise prepend to all 165 rows.
private string toLedgerPath(string path)
{
    return buildNormalizedPath(path).replace("\\", "/");
}

private struct FileCount
{
    string path;
    size_t unittestBlocks;
    size_t versionUnittest;
}

private FileCount[] scanSourceTree(string root)
{
    const sourceDir = buildPath(root, "source");
    if (!isDir(sourceDir)) return [];

    auto found = appender!(FileCount[]);
    foreach (entry; dirEntries(sourceDir, SpanMode.depth))
    {
        if (!entry.isFile || !entry.name.endsWith(".d")) continue;
        const text = readText(entry.name);
        found.put(FileCount(toLedgerPath(relativePath(entry.name, root)),
                            cast(size_t) scanD(text).blocks,
                            countVersionUnittest(text)));
    }
    auto files = found.data;
    files.sort!((a, b) => a.path < b.path);
    return files;
}

private size_t recordedBlocks(ref Ledger ledger, string path)
{
    if (auto count = path in ledger.blocksByFile) return *count;
    return 0;
}

unittest // comments and literals do not impersonate compiler-visible guards
{
    // Every decoy carries an OPENING BRACE. Without one, `scanD` would not
    // count it even with the comment/string stripping deleted, and this whole
    // arm passes over tokens that were never countable — a fixture that cannot
    // fail, which is the defect the task itself is about. `census_gate.d`'s own
    // decoys are braced for exactly this reason.
    enum fixture = q{
        unittest {}
        version(unittest) {}
        // fixture line: unittest { } and version(unittest) { } are comment text
        enum quoted = "unittest { } version(unittest) { }";
    };

    // Population floor for the decoys themselves: a raw scanner must see three
    // of each. This is what makes the two `== 1` assertions below evidence.
    assert(fixture.matchAll(unittestBlockRe).walkLength == 3,
           "the fixture must carry two brace-followed unittest decoys plus the real block");
    assert(fixture.matchAll(versionUnittestRe).walkLength == 3,
           "the fixture must carry two version(unittest) decoys plus the real guard");

    assert(scanD(fixture).blocks == 1,
           "the comment/string fixture must contain exactly one real unittest block");
    assert(countVersionUnittest(fixture) == 1,
           "the comment/string fixture must contain exactly one real version(unittest)");

    // Ledger rows are `/`-separated on every host.
    assert(toLedgerPath(`source\tools\transform\xfrm_transform.d`) ==
           "source/tools/transform/xfrm_transform.d",
           "ledger paths must be normalised to `/` or every row misses on Windows");
    assert(toLedgerPath("source/mesh.d") == "source/mesh.d",
           "normalisation must leave a POSIX path alone");
}

unittest // source-wide block ceiling and per-file version(unittest) ceilings
{
    auto ledger = parseLedger(readText(buildPath(repoRoot, ledgerPath)), ledgerPath);
    const files = scanSourceTree(repoRoot);

    // Anti-vacuity is explicit and pinned. At task 4057's measurement this is
    // 510 files; an empty/misdirected walk cannot satisfy either assertion.
    assert(files.length > 0, "source/**.d census found zero files");
    assert(files.length == ledger.sourceFiles,
           format("source/**.d population changed: recorded %d, found %d; " ~
                  "refresh the task-4057 ledger deliberately with: %s",
                  ledger.sourceFiles, files.length, refreshCommand));

    size_t blockTotal;
    size_t rowTotal;
    foreach (ref file; files) blockTotal += file.unittestBlocks;
    foreach (path, count; ledger.blocksByFile) rowTotal += count;

    if (blockTotal > ledger.unittestBlocks)
    {
        string[] growers;
        foreach (ref file; files)
        {
            const before = recordedBlocks(ledger, file.path);
            if (file.unittestBlocks > before)
                growers ~= format("%s %d -> %d", file.path, before,
                                  file.unittestBlocks);
        }
        assert(false, format("source unittest blocks grew: recorded total %d, found %d; " ~
                             "per-file increases: %s. %s",
                             ledger.unittestBlocks, blockTotal,
                             growers.length ? growers.join(", ") : "none found",
                             admissionProcedure));
    }

    // The per-file rows are ENFORCED, not diagnostic. Without this the only
    // live predicate was the global sum, so a block MOVED from one file to
    // another — and any row deleted or falsified — was invisible.
    string[] rowViolations;
    foreach (ref file; files)
    {
        const recorded = recordedBlocks(ledger, file.path);
        if (file.unittestBlocks > recorded)
            rowViolations ~= format("%s recorded %d, found %d",
                                    file.path, recorded, file.unittestBlocks);
    }
    assert(rowViolations.length == 0,
           format("per-file unittest rows exceeded: %s. %s",
                  rowViolations.join("; "), admissionProcedure));

    // …and the rows have to add up to the headline number, so the total cannot
    // be raised without saying which file spent it.
    assert(rowTotal == ledger.unittestBlocks,
           format("%s: `block` rows sum to %d but `unittest-blocks` records %d; " ~
                  "every admitted block needs BOTH numbers moved. Refresh with: %s",
                  ledgerPath, rowTotal, ledger.unittestBlocks, refreshCommand));

    string[] versionViolations;
    foreach (ref file; files)
    {
        size_t allowed = ledger.versionCeiling;
        if (auto exception = file.path in ledger.versionAllow) allowed = *exception;
        if (file.versionUnittest > allowed)
            versionViolations ~= format("%s recorded %d, found %d",
                                        file.path, allowed, file.versionUnittest);
    }
    assert(versionViolations.length == 0,
           "version(unittest) per-file ceiling exceeded: " ~ versionViolations.join("; "));

    // The allow-list may only SHRINK (the card's own criterion), so each
    // allowance is exact: a file that sheds a guard lowers its row in the same
    // commit, and a row naming a file that no longer exists is a dead licence.
    size_t[string] versionByPath;
    foreach (ref file; files) versionByPath[file.path] = file.versionUnittest;

    string[] staleAllowances;
    foreach (path, allowed; ledger.versionAllow)
    {
        auto found = path in versionByPath;
        if (found is null)
            staleAllowances ~= format("%s is allow-listed but is not a source/**.d file", path);
        else if (*found != allowed)
            staleAllowances ~= format("%s allows %d, found %d", path, allowed, *found);
    }
    staleAllowances.sort;  // AA order is unspecified; keep the message stable
    assert(staleAllowances.length == 0,
           format("the version(unittest) allow-list may only shrink: %s. " ~
                  "Lower the row to the found count in the same commit, or refresh with: %s",
                  staleAllowances.join("; "), refreshCommand));
}

// ---------------------------------------------------------------------------
// Ledger generator
// ---------------------------------------------------------------------------
//
// (This banner sits BELOW every assertion on purpose: the mutation reds quoted
// in the task file carry line numbers, so prose added here shifts nothing.)
//
// WHAT REMAINS UNCOVERED ABOVE, stated plainly. A `block` row is a CEILING, not
// an equality: deleting a block leaves its file with slack, and a later block
// moved INTO that file spends the slack silently. Closing it would mean
// forbidding a deletion until someone edits the ledger, which is the wrong
// direction for a gate whose whole purpose is to make the count fall.
// Regenerating after a deletion is what keeps the slack at zero.
//
// The counts above are read from a file; this is the program that writes it, so
// that refreshing the ledger is a committed, repeatable act rather than a
// scratch program someone has to rebuild from the assertions. Same scanners as
// the gate, by construction — it is the same module.
//
//     rdmd -version=CeilingLedgerTool -I. \
//         tests/unit/unittest_source_ceiling_test.d > \
//         tests/unit/unittest_source_ceiling_ledger.txt
//
// `version-ceiling` is a POLICY number, not a measurement: it is carried over
// from the existing ledger rather than re-derived, so a regeneration can never
// quietly raise the per-file ceiling to whatever the tree happens to hold.
version (CeilingLedgerTool)
void main(string[] args)
{
    import std.stdio : writeln, writefln;

    const root = args.length > 1 ? args[1] : ".";

    size_t ceiling = 10;
    const existing = buildPath(root, ledgerPath);
    if (exists(existing))
        ceiling = parseLedger(readText(existing), ledgerPath).versionCeiling;

    const files = scanSourceTree(root);
    size_t blocks;
    foreach (ref file; files) blocks += file.unittestBlocks;

    writeln("# Task 4057 source-test ceilings. GENERATED FILE — do not hand-count rows.");
    writeln("#");
    writeln("# Refresh:");
    writeln("#     rdmd -version=CeilingLedgerTool -I. \\");
    writeln("#         tests/unit/unittest_source_ceiling_test.d > \\");
    writeln("#         " ~ ledgerPath);
    writeln("#");
    writeln("# Then READ THE DIFF. Regeneration is mechanical and will absorb an");
    writeln("# addition nobody argued for; an in-module unittest under source/ is");
    writeln("# admissible only for a `private` symbol, and the commit that raises");
    writeln("# `unittest-blocks` has to name that symbol.");
    writeln("#");
    writeln("# Counts are compiler-aware: comments and string/character literals are");
    writeln("# removed before either scanner runs. `version-ceiling` is policy and is");
    writeln("# carried over from the previous ledger, never re-measured.");
    writefln("source-files %d", files.length);
    writefln("unittest-blocks %d", blocks);
    writefln("version-ceiling %d", ceiling);
    writeln();
    writeln("# Per-file unittest counts. Enforced: they sum to `unittest-blocks`, and");
    writeln("# no file may hold more than its own row.");
    foreach (ref file; files)
        if (file.unittestBlocks > 0)
            writefln("block %s %d", file.path, file.unittestBlocks);
    writeln();
    writefln("# Files above the per-file version(unittest) ceiling of %d. This list may", ceiling);
    writeln("# only shrink, and each number is EXACT: shed a guard and lower the row.");
    foreach (ref file; files)
        if (file.versionUnittest > ceiling)
            writefln("allow-version %s %d", file.path, file.versionUnittest);
}
