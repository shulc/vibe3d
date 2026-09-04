// Source-test policy gate (task 4057).
//
// `unittest` declarations in source/ may only fall from the recorded total.
// `version(unittest)` has a per-file ceiling of 10; files already above it
// carry their own numeric ceiling in unittest_source_ceiling_ledger.txt.
//
// Both counts operate on D code, not raw text. `scanD` is the census gate's D
// lexer; `blankNonCode` removes line/block/nested comments plus every D string
// and character literal before the version regex runs. The first unittest is
// a fixture proving that a comment and a string containing the word unittest
// do not move either count.
module tests.unit.unittest_source_ceiling_test;

import std.algorithm : sort;
import std.array : appender, join;
import std.conv : to;
import std.file : dirEntries, isDir, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName, relativePath;
import std.range : walkLength;
import std.regex : ctRegex, matchAll;
import std.string : endsWith, split, splitLines, strip;

import tests.unit.census_gate : scanD;
import tests.unit.version_poll_census_test : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum ledgerPath = "tests/unit/unittest_source_ceiling_ledger.txt";
private enum versionUnittestRe = ctRegex!(`\bversion\s*\(\s*unittest\s*\)`);

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
        found.put(FileCount(relativePath(entry.name, root),
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
    enum fixture = q{
        unittest {}
        version(unittest) {}
        // fixture line: unittest and version(unittest) must NOT be counted
        enum quoted = "unittest version(unittest)";
    };

    assert(scanD(fixture).blocks == 1,
           "the comment/string fixture must contain exactly one real unittest block");
    assert(countVersionUnittest(fixture) == 1,
           "the comment/string fixture must contain exactly one real version(unittest)");
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
                  "refresh the task-4057 ledger deliberately",
                  ledger.sourceFiles, files.length));

    size_t blockTotal;
    foreach (ref file; files) blockTotal += file.unittestBlocks;
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
                             "per-file increases: %s",
                             ledger.unittestBlocks, blockTotal,
                             growers.length ? growers.join(", ") : "none found"));
    }

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
}
