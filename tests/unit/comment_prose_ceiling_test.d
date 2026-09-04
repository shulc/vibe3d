// Source-comment policy gate (task 4058).
//
// TWO RATCHETS OVER ONE LEDGER, and they measure different things. The policy
// (doc/source_prose_policy.md) is about PROSE: a decision-history narrative of
// 40 lines or more belongs in doc/. So the ratchet that enforces the policy is
// the per-file count of COMMENT RUNS of 40+ consecutive full-line comments.
// Beside it, and NOT a proxy for it, is the per-file count of task-citing
// comment lines: that one bounds POINTER sprawl. The 264-line journal this
// task moved cost the citation ledger a single line, which is exactly why the
// run ratchet had to exist too.
//
// Both are exact: every file with a nonzero count has a row, an unlisted file
// has a ceiling of zero, and a row may only fall. This forbids moving prose
// between files and forbids spending slack after a cleanup.
//
// The scanner reads D comments, not raw lines. Strings and code containing
// "task 0000" are invisible; line, block, nested and trailing comments count.
// One source line counts once even when it cites several tasks. A citation is
// "task NNNN", its plural, the Russian spellings, or a path to the card under
// the tasks tree (`doc/tasks/work/NNNN-…`) — the pointer form the policy asks
// people to write. A run is broken by a blank line or by any line carrying
// code, so a trailing comment beside code never extends one.
//
// Refresh mechanically, then READ THE DIFF: regeneration will faithfully
// absorb an addition nobody reviewed.
//
//     rdmd -version=CitationLedgerTool -I. \
//         tests/unit/comment_prose_ceiling_test.d > \
//         tests/unit/comment_prose_ceiling_ledger.txt
module tests.unit.comment_prose_ceiling_test;

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
private enum ledgerPath = "tests/unit/comment_prose_ceiling_ledger.txt";

/// The policy's own threshold: a comment run this long or longer is journal
/// until argued otherwise (doc/source_prose_policy.md).
private enum size_t longRunLines = 40;

/// Both citation spellings the policy accepts. The first alternative is the
/// inline id (`task 1906`, `tasks 1520`, `задача 0613`); the second is the
/// pointer form — a path to the card under the tasks tree, which carries no
/// literal "task NNNN" and was invisible to this gate's first cut.
private enum citationRe = ctRegex!(
    `(^|[^A-Za-z0-9_])(tasks?|задач[аи]) ?[0-9]{4}([^0-9]|$)` ~
    `|(^|[^A-Za-z0-9_])tasks/[A-Za-z]+/[0-9]{4}([^0-9]|$)`, "i");
private enum refreshCommand =
    "rdmd -version=CitationLedgerTool -I. " ~
    "tests/unit/comment_prose_ceiling_test.d > " ~ ledgerPath;

private struct Ledger
{
    size_t sourceFiles;
    size_t citationLines;
    size_t citingFiles;
    size_t longRuns;
    size_t filesWithLongRuns;
    size_t[string] allowance;
    size_t[string] runAllowance;
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
    bool sawLongRuns;
    bool sawFilesWithLongRuns;

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
            case "long-comment-runs":
                assert(words.length == 2 && !sawLongRuns,
                       format("%s:%d: expected one `long-comment-runs N` row",
                              origin, lineNo));
                result.longRuns = parseCount(words[1], origin, lineNo);
                sawLongRuns = true;
                break;
            case "files-with-long-runs":
                assert(words.length == 2 && !sawFilesWithLongRuns,
                       format("%s:%d: expected one `files-with-long-runs N` row",
                              origin, lineNo));
                result.filesWithLongRuns = parseCount(words[1], origin, lineNo);
                sawFilesWithLongRuns = true;
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
            case "allow-runs":
                assert(words.length == 3,
                       format("%s:%d: expected `allow-runs source/path.d N`", origin, lineNo));
                assert((words[1] in result.runAllowance) is null,
                       format("%s:%d: duplicate long-run allowance row for %s",
                              origin, lineNo, words[1]));
                result.runAllowance[words[1]] = parseCount(words[2], origin, lineNo);
                assert(result.runAllowance[words[1]] > 0,
                       format("%s:%d: zero-count allowance rows are omitted", origin, lineNo));
                break;
            default:
                assert(false, format("%s:%d: unknown ledger row `%s`", origin, lineNo, line));
        }
    }

    assert(sawSourceFiles && sawCitationLines && sawCitingFiles
           && sawLongRuns && sawFilesWithLongRuns,
           origin ~ ": source-files, task-citation-lines, citing-files, " ~
           "long-comment-runs and files-with-long-runs are all required");
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

private struct FileCensus
{
    size_t citationLines;
    size_t longRuns;
}

/// One walk, two numbers. `blankNonCode` never moves a newline, so the code
/// and comment projections split into the same number of lines as the source
/// and can be read in lockstep.
private FileCensus censusOf(string source)
{
    const comments = commentText(source).splitLines;
    const code = blankNonCode(source).splitLines;
    assert(comments.length == code.length,
           "the code and comment projections must line up with the source");

    FileCensus result;
    size_t run;
    void closeRun() { if (run >= longRunLines) ++result.longRuns; run = 0; }

    foreach (i, line; comments)
    {
        const bool hasComment = line.strip.length > 0;
        if (hasComment && !line.matchFirst(citationRe).empty) ++result.citationLines;
        // A run is FULL-LINE comments only: a line carrying code (a trailing
        // comment) or a blank line ends it.
        if (hasComment && code[i].strip.length == 0) ++run;
        else closeRun();
    }
    closeRun();
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
    FileCensus census;
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
                            censusOf(text)));
    }
    auto files = found.data;
    files.sort!((a, b) => a.path < b.path);
    return files;
}

private size_t recordedAllowance(const size_t[string] table, string path)
{
    if (auto count = path in table) return *count;
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
        // the plural spelling is a citation too: tasks 0011 and 0012
        // so is the pointer form the policy asks for:
        // doc/tasks/work/0013-some-card-slug.md
        enum quoted = "task 0008";
        enum backtick = `Task 0009`;
        enum token = q{ task 0010 };
        // ordinary prose has no citation
FIXTURE";

    // A raw scan must see every decoy first; otherwise the comment projection
    // could appear correct over tokens the fixture never made countable.
    assert(fixture.matchAll(citationRe).walkLength == 12,
           "citation fixture must contain twelve raw task references");
    assert(censusOf(fixture).citationLines == 7,
           "seven comment lines in the fixture cite tasks, in four spellings");
    assert(censusOf("// no issue number here\n").citationLines == 0,
           "ordinary comment prose must not spend the citation allowance");
    assert(censusOf("// see doc/tasks/work/0013-some-card-slug.md\n").citationLines == 1,
           "a path to a card under the tasks tree is the policy's pointer form");
    assert(censusOf("// tasks 0011 and 0012\n").citationLines == 1,
           "the plural spelling is a citation");
    assert(toLedgerPath(`source\mesh.d`) == "source/mesh.d",
           "ledger paths must be normalised to `/`");
}

unittest // the run census counts 40+ line comment blocks, and only those
{
    static string commentBlock(size_t lines, string prefix = "", string suffix = "")
    {
        string text = prefix;
        foreach (i; 0 .. lines) text ~= "// narrative line\n";
        return text ~ suffix;
    }

    assert(censusOf(commentBlock(longRunLines - 1)).longRuns == 0,
           "a 39-line run is under the policy threshold");
    assert(censusOf(commentBlock(longRunLines)).longRuns == 1,
           "40 lines is the threshold itself, not one past it");
    assert(censusOf(commentBlock(longRunLines + 1)).longRuns == 1,
           "one run stays one run however far past the threshold it goes");
    assert(censusOf(commentBlock(longRunLines) ~ "\n" ~ commentBlock(longRunLines)).longRuns == 2,
           "a blank line separates two runs and each is counted");
    assert(censusOf(commentBlock(20) ~ "\n" ~ commentBlock(20)).longRuns == 0,
           "a blank line BREAKS a run: two 20-line halves are not one 40-line block");
    assert(censusOf(commentBlock(20) ~ "int x; // trailing\n" ~ commentBlock(20)).longRuns == 0,
           "a line carrying code breaks a run even when it also carries a comment");
    assert(censusOf(commentBlock(longRunLines, "int leading;\n", "int trailing;\n")).longRuns == 1,
           "code above and below a run does not hide it");
}

unittest // exact per-file ceilings may only shrink
{
    auto ledger = parseLedger(readText(buildPath(repoRoot, ledgerPath)), ledgerPath);
    const files = scanSourceTree(repoRoot);

    assert(files.length > 0, "source/**.d prose census found zero files");
    assert(files.length == ledger.sourceFiles,
           format("source/**.d population changed: recorded %d, found %d; " ~
                  "refresh deliberately with: %s",
                  ledger.sourceFiles, files.length, refreshCommand));

    size_t actualTotal;
    size_t actualCitingFiles;
    size_t actualRunTotal;
    size_t actualRunFiles;
    string[] growth;
    string[] runGrowth;
    size_t[string] actualByPath;
    size_t[string] actualRunsByPath;
    foreach (ref file; files)
    {
        actualByPath[file.path] = file.census.citationLines;
        actualRunsByPath[file.path] = file.census.longRuns;
        actualTotal += file.census.citationLines;
        actualRunTotal += file.census.longRuns;
        if (file.census.citationLines > 0) ++actualCitingFiles;
        if (file.census.longRuns > 0) ++actualRunFiles;

        const allowed = recordedAllowance(ledger.allowance, file.path);
        if (file.census.citationLines > allowed)
            growth ~= format("%s recorded %d, found %d",
                             file.path, allowed, file.census.citationLines);

        const runsAllowed = recordedAllowance(ledger.runAllowance, file.path);
        if (file.census.longRuns > runsAllowed)
            runGrowth ~= format("%s recorded %d, found %d",
                                file.path, runsAllowed, file.census.longRuns);
    }

    // The two primary ratchets, both before any bookkeeping check, so a
    // mutation names the file and both useful numbers. The CITATION one is
    // first and the RUN one second on purpose: adding prose that cites no task
    // leaves the citation assert green above the run assert it reddens, which
    // buys both halves of that mutation from a single run.
    assert(growth.length == 0,
           format("task-citing source comment lines exceeded their per-file ceiling: %s. " ~
                  "Keep only an invariant + task id + pointer at the site. " ~
                  "Regenerate only after reviewing the diff: %s",
                  growth.join("; "), refreshCommand));

    assert(runGrowth.length == 0,
           format("comment runs of %d+ lines exceeded their per-file ceiling: %s. " ~
                  "A decision narrative that long belongs in doc/ with a pointer left " ~
                  "at the site; a CONTRACT that long is argued at its declaration and " ~
                  "the row is raised deliberately. Regenerate only after reviewing " ~
                  "the diff: %s", longRunLines, runGrowth.join("; "), refreshCommand));

    string[] stale;
    foreach (path, allowed; ledger.allowance)
    {
        auto found = path in actualByPath;
        if (found is null)
            stale ~= format("%s is allow-listed but is not a source/**.d file", path);
        else if (*found != allowed)
            stale ~= format("%s allows %d citation lines, found %d", path, allowed, *found);
    }
    foreach (path, allowed; ledger.runAllowance)
    {
        auto found = path in actualRunsByPath;
        if (found is null)
            stale ~= format("%s is run-allow-listed but is not a source/**.d file", path);
        else if (*found != allowed)
            stale ~= format("%s allows %d long comment runs, found %d", path, allowed, *found);
    }
    stale.sort;
    assert(stale.length == 0,
           format("the prose allow-lists may only shrink: %s. " ~
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

    size_t runRowTotal;
    foreach (path, allowed; ledger.runAllowance) runRowTotal += allowed;
    assert(runRowTotal == ledger.longRuns,
           format("%s: allow-runs rows sum to %d but long-comment-runs records %d; " ~
                  "refresh with: %s", ledgerPath, runRowTotal,
                  ledger.longRuns, refreshCommand));
    assert(ledger.runAllowance.length == ledger.filesWithLongRuns,
           format("%s: found %d allow-runs rows but files-with-long-runs records %d",
                  ledgerPath, ledger.runAllowance.length, ledger.filesWithLongRuns));

    // Positive population floors after the real predicates: a blinded scanner
    // cannot pass merely by returning an empty set.
    assert(actualTotal > 0, "source prose census found zero task-citing comment lines");
    assert(actualCitingFiles > 0, "source prose census found zero citing files");
    assert(actualRunTotal > 0,
           format("source prose census found zero comment runs of %d+ lines; " ~
                  "the run scanner is blind, not the tree clean", longRunLines));
    assert(actualRunFiles > 0, "source prose census found zero files with long comment runs");
}

version (CitationLedgerTool)
void main(string[] args)
{
    import std.stdio : writeln, writefln;

    const root = args.length > 1 ? args[1] : ".";
    const files = scanSourceTree(root);
    size_t total;
    size_t citingFiles;
    size_t runTotal;
    size_t runFiles;
    foreach (ref file; files)
    {
        total += file.census.citationLines;
        runTotal += file.census.longRuns;
        if (file.census.citationLines > 0) ++citingFiles;
        if (file.census.longRuns > 0) ++runFiles;
    }

    writeln("# Task 4058 source-comment prose ceilings. GENERATED FILE.");
    writeln("#");
    writeln("# Refresh:");
    writeln("#     rdmd -version=CitationLedgerTool -I. \\");
    writeln("#         tests/unit/comment_prose_ceiling_test.d > \\");
    writeln("#         " ~ ledgerPath);
    writeln("#");
    writeln("# Then READ THE DIFF. Regeneration is mechanical and will absorb an");
    writeln("# addition nobody argued for. Every row is exact and may only fall.");
    writeln("# An unlisted source file has a ceiling of zero.");
    writefln("source-files %d", files.length);
    writefln("task-citation-lines %d", total);
    writefln("citing-files %d", citingFiles);
    writefln("long-comment-runs %d", runTotal);
    writefln("files-with-long-runs %d", runFiles);
    writeln();
    writeln("# Exact per-file task-citation allowances, sorted by path.");
    foreach (ref file; files)
        if (file.census.citationLines > 0)
            writefln("allow %s %d", file.path, file.census.citationLines);
    writeln();
    writefln("# Exact per-file counts of comment runs >= %d lines, sorted by path.",
             longRunLines);
    foreach (ref file; files)
        if (file.census.longRuns > 0)
            writefln("allow-runs %s %d", file.path, file.census.longRuns);
}
