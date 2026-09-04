// Source-comment policy gate (task 4058).
//
// A task citation in source/**.d is a pointer from the implementation to its
// decision record. Those pointers may only fall per file: every file with a
// citation has an exact row in comment_task_citation_ceiling_ledger.txt, while
// an unlisted file has a ceiling of zero. This forbids moving citation-heavy
// prose between files and forbids spending slack after a cleanup.
//
// The scanner reads D comments, not raw lines. Strings and code containing
// "task 0000" are invisible; line, block, nested and trailing comments count.
// One source line counts once even when it cites several tasks.
//
// Refresh mechanically, then READ THE DIFF: regeneration will faithfully
// absorb an addition nobody reviewed.
//
//     rdmd -version=CitationLedgerTool -I. \
//         tests/unit/comment_task_citation_ceiling_test.d > \
//         tests/unit/comment_task_citation_ceiling_ledger.txt
module tests.unit.comment_task_citation_ceiling_test;

import std.algorithm : sort;
import std.array : appender, join;
import std.conv : to;
import std.exception : assumeUnique;
import std.file : dirEntries, exists, isDir, readText, SpanMode;
import std.format : format;
import std.path : buildNormalizedPath, buildPath, dirName, relativePath;
import std.range : empty, walkLength;
import std.regex : ctRegex, matchAll, matchFirst;
import std.string : endsWith, split, splitLines, strip;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum ledgerPath = "tests/unit/comment_task_citation_ceiling_ledger.txt";
private enum citationRe = ctRegex!(
    `(?i)(^|[^A-Za-z0-9_])(task|задач[аи]) ?[0-9]{4}([^0-9]|$)`);
private enum refreshCommand =
    "rdmd -version=CitationLedgerTool -I. " ~
    "tests/unit/comment_task_citation_ceiling_test.d > " ~ ledgerPath;

private struct Ledger
{
    size_t sourceFiles;
    size_t citationLines;
    size_t citingFiles;
    size_t[string] allowance;
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
    bool sawCitationLines;
    bool sawCitingFiles;

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
            case "task-citation-lines":
                assert(words.length == 2 && !sawCitationLines,
                       format("%s:%d: expected one `task-citation-lines N` row",
                              origin, lineNo));
                result.citationLines = parseCount(words[1], origin, lineNo);
                sawCitationLines = true;
                break;
            case "citing-files":
                assert(words.length == 2 && !sawCitingFiles,
                       format("%s:%d: expected one `citing-files N` row", origin, lineNo));
                result.citingFiles = parseCount(words[1], origin, lineNo);
                sawCitingFiles = true;
                break;
            case "allow":
                assert(words.length == 3,
                       format("%s:%d: expected `allow source/path.d N`", origin, lineNo));
                assert((words[1] in result.allowance) is null,
                       format("%s:%d: duplicate allowance row for %s",
                              origin, lineNo, words[1]));
                result.allowance[words[1]] = parseCount(words[2], origin, lineNo);
                assert(result.allowance[words[1]] > 0,
                       format("%s:%d: zero-count allowance rows are omitted", origin, lineNo));
                break;
            default:
                assert(false, format("%s:%d: unknown ledger row `%s`", origin, lineNo, line));
        }
    }

    assert(sawSourceFiles && sawCitationLines && sawCitingFiles,
           origin ~ ": source-files, task-citation-lines, and citing-files are required");
    return result;
}

/// Keep comment bytes and line breaks in place, blanking code and literals.
/// `blankNonCode(src, true)` preserves code + comments while its ordinary form
/// preserves only code; their difference is therefore the comment projection.
private string commentText(string src)
{
    const withComments = blankNonCode(src, true);
    const codeOnly = blankNonCode(src);
    assert(withComments.length == src.length && codeOnly.length == src.length);

    auto result = new char[src.length];
    foreach (i, c; src)
    {
        if (c == '\n') result[i] = '\n';
        else result[i] = (codeOnly[i] == ' ' && withComments[i] != ' ')
            ? withComments[i] : ' ';
    }
    return result.assumeUnique;
}

private size_t countCitationLines(string source)
{
    size_t result;
    foreach (line; commentText(source).splitLines)
        if (!line.matchFirst(citationRe).empty) ++result;
    return result;
}

private string toLedgerPath(string path)
{
    import std.array : replace;
    return buildNormalizedPath(path).replace("\\", "/");
}

private struct FileCount
{
    string path;
    size_t citationLines;
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
                            countCitationLines(text)));
    }
    auto files = found.data;
    files.sort!((a, b) => a.path < b.path);
    return files;
}

private size_t recordedAllowance(ref Ledger ledger, string path)
{
    if (auto count = path in ledger.allowance) return *count;
    return 0;
}

unittest // the scanner sees comments and rejects code/string decoys
{
    enum fixture = q"FIXTURE
        // task 0001
        int x; // Task 0002 and task 0003 count as one line
        /* задача 0004
         * TASK 0005 */
        /+ outer task 0006 /+ nested task 0007 +/ +/
        enum quoted = "task 0008";
        enum backtick = `Task 0009`;
        enum token = q{ task 0010 };
        // ordinary prose has no citation
FIXTURE";

    // A raw scan must see every decoy first; otherwise the comment projection
    // could appear correct over tokens the fixture never made countable.
    assert(fixture.matchAll(citationRe).walkLength == 10,
           "citation fixture must contain ten raw task references");
    assert(countCitationLines(fixture) == 5,
           "only five comment lines in the fixture cite tasks");
    assert(countCitationLines("// no issue number here\n") == 0,
           "ordinary comment prose must not spend the citation allowance");
    assert(toLedgerPath(`source\mesh.d`) == "source/mesh.d",
           "ledger paths must be normalised to `/`");
}

unittest // exact per-file ceilings may only shrink
{
    auto ledger = parseLedger(readText(buildPath(repoRoot, ledgerPath)), ledgerPath);
    const files = scanSourceTree(repoRoot);

    assert(files.length > 0, "source/**.d citation census found zero files");
    assert(files.length == ledger.sourceFiles,
           format("source/**.d population changed: recorded %d, found %d; " ~
                  "refresh deliberately with: %s",
                  ledger.sourceFiles, files.length, refreshCommand));

    size_t actualTotal;
    size_t actualCitingFiles;
    string[] growth;
    size_t[string] actualByPath;
    foreach (ref file; files)
    {
        actualByPath[file.path] = file.citationLines;
        actualTotal += file.citationLines;
        if (file.citationLines > 0) ++actualCitingFiles;

        const allowed = recordedAllowance(ledger, file.path);
        if (file.citationLines > allowed)
            growth ~= format("%s recorded %d, found %d",
                             file.path, allowed, file.citationLines);
    }

    // This is the primary ratchet and intentionally precedes bookkeeping
    // checks so the mutation names the file and both useful numbers.
    assert(growth.length == 0,
           format("task-citing source comment lines exceeded their per-file ceiling: %s. " ~
                  "Move decision narrative to doc/, keep only an invariant + task id + " ~
                  "pointer at the site. Regenerate only after reviewing the diff: %s",
                  growth.join("; "), refreshCommand));

    string[] stale;
    foreach (path, allowed; ledger.allowance)
    {
        auto found = path in actualByPath;
        if (found is null)
            stale ~= format("%s is allow-listed but is not a source/**.d file", path);
        else if (*found != allowed)
            stale ~= format("%s allows %d, found %d", path, allowed, *found);
    }
    stale.sort;
    assert(stale.length == 0,
           format("the task-citation allow-list may only shrink: %s. " ~
                  "Lower changed rows in the same commit, or refresh and read the diff: %s",
                  stale.join("; "), refreshCommand));

    size_t rowTotal;
    foreach (path, allowed; ledger.allowance) rowTotal += allowed;
    assert(rowTotal == ledger.citationLines,
           format("%s: allowance rows sum to %d but task-citation-lines records %d; " ~
                  "refresh with: %s", ledgerPath, rowTotal,
                  ledger.citationLines, refreshCommand));
    assert(ledger.allowance.length == ledger.citingFiles,
           format("%s: found %d allowance rows but citing-files records %d",
                  ledgerPath, ledger.allowance.length, ledger.citingFiles));

    // Positive population floors after the real predicates: a blinded scanner
    // cannot pass merely by returning an empty set.
    assert(actualTotal > 0, "source citation census found zero task-citing comment lines");
    assert(actualCitingFiles > 0, "source citation census found zero citing files");
}

version (CitationLedgerTool)
void main(string[] args)
{
    import std.stdio : writeln, writefln;

    const root = args.length > 1 ? args[1] : ".";
    const files = scanSourceTree(root);
    size_t total;
    size_t citingFiles;
    foreach (ref file; files)
    {
        total += file.citationLines;
        if (file.citationLines > 0) ++citingFiles;
    }

    writeln("# Task 4058 source-comment task-citation ceilings. GENERATED FILE.");
    writeln("#");
    writeln("# Refresh:");
    writeln("#     rdmd -version=CitationLedgerTool -I. \\");
    writeln("#         tests/unit/comment_task_citation_ceiling_test.d > \\");
    writeln("#         " ~ ledgerPath);
    writeln("#");
    writeln("# Then READ THE DIFF. Regeneration is mechanical and will absorb an");
    writeln("# addition nobody argued for. Every row is exact and may only fall.");
    writeln("# An unlisted source file has a ceiling of zero.");
    writefln("source-files %d", files.length);
    writefln("task-citation-lines %d", total);
    writefln("citing-files %d", citingFiles);
    writeln();
    writeln("# Exact per-file allowances, sorted by path.");
    foreach (ref file; files)
        if (file.citationLines > 0)
            writefln("allow %s %d", file.path, file.citationLines);
}
