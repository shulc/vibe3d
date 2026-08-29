// neutrality_boundary_test — the witness for the neutrality dictionary's
// TOKEN BOUNDARY (task 3301).
//
// WHAT IS BEING PINNED. The private neutrality lint
// (`tools/local/neutrality_lint.sh`, task 0364) matches a banned token with an
// anchor on each side. The anchor's job has always been "the token is not part
// of a longer WORD" — that is what keeps the lint quiet about `modeling` and
// about `modOk` (a real identifier in source/app.d, "modifier ok"), and a lint
// that is noisy is a lint that gets switched off. Until 2026-08-29 that anchor
// was written `\b`, which does NOT say that. `\b`'s word class is
// [A-Za-z0-9_], so `\bTOKEN\b` also refuses to fire when the very next
// character is a DIGIT or an UNDERSCORE. Both refusals are holes, and the
// digit one is the worst possible hole to have: a product name written with
// its version number stuck to it is the single most likely real-world spelling
// of a leak. Measured through `neutrality_lint.sh --paths` on three files
// outside the repo (backlog 3301): free prose FAILed, a hyphen before the
// version FAILed, and the glued form reported 0 findings.
//
// The boundary is now `(^|[^A-Za-z])TOKEN($|[^A-Za-z])` in both dictionaries
// and in `gen_candidates.py`'s `ere_for`, and this module is its witness.
//
// THE SELF-REFUTING TRAP, AND HOW IT IS SOLVED HERE. A public test cannot
// prove "the lint catches the forbidden token" by containing the forbidden
// token — writing it here IS the leak the lint exists to prevent, and no
// amount of comment around it changes that. This module therefore never
// handles a real token. It builds the SAME boundary around a SYNTHETIC one
// (`kSynthetic` below — six letters that are not a product, not a reference
// symbol and not a vibe3d identifier) and asserts the full match/no-match
// table on it. The boundary is token-independent by construction: nothing in
// `(^|[^A-Za-z])X($|[^A-Za-z])` depends on what `X` spells, so a table proved
// on a synthetic X holds for every X the private dictionary lists.
//
// What that costs, stated honestly: this module proves the boundary BEHAVES
// correctly, and it proves the private dictionary is WRITTEN in that boundary
// (unittest 3, when the private tree is reachable) — but it cannot prove any
// particular product name is in the dictionary at all. That last question is
// the private dictionary's own content, it stays private, and its witness is
// `tools/local/neutrality/selftest/selftest.sh`, which may plant a real token
// because it lives in the private tree. Splitting the question this way is
// what lets the BOUNDARY half run in a routine public lane
// (`dub test --config=tests`) instead of in a private script nobody runs.
//
// THE TWO DIRECTIONS, BOTH PINNED. A boundary fix can fail in two ways and a
// witness that only covers one of them is worth nothing:
//   * TOO NARROW — `\b`, or a class that keeps `0-9`. The version-suffix and
//     snake_case spellings go unseen. Cells marked `must match` below.
//   * TOO BROAD — no trailing class at all, or a bare substring test. Then
//     `modOk`-shaped identifiers start firing and the lint gets turned off.
//     Cells marked `must NOT match` below.
// Mutate the boundary either way and a NAMED SPELLING is printed, not a count.
//
// MUTATIONS THAT REDDEN IT (all run 2026-08-29, both directions):
//   * `kBoundaryTail` -> `($|[^A-Za-z0-9])` (the old, digit-inclusive class):
//     unittest 1 names the glued-version spelling.
//   * `kBoundaryTail` -> `` (dropped): unittest 1 names the `…Ok` spelling.
//   * `kBoundaryLead`/`kBoundaryTail` -> `\b` (the pre-3301 anchor): unittest 1
//     names the glued-version spelling AND unittest 3 names the dictionary
//     lines that carry `\b`.
//   * put `\b` back in the private dictionary: unittest 3 names the file and
//     the LINE NUMBER (never the content — that is the leak).
//
// The scan is `__FILE_FULL_PATH__`-rooted, never cwd-rooted: the unit binary
// is run from several directories and a cwd-relative path would quietly find
// nothing, which for a census reads as "clean".
module tests.unit.neutrality_boundary_test;

import std.algorithm : canFind, count, filter, map, startsWith;
import std.array     : array, join;
import std.conv      : to;
import std.file      : exists, readText, remove, tempDir, write;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.process   : execute, thisProcessID;
import std.regex     : matchFirst, regex, Regex;
import std.stdio     : stderr;
import std.string    : splitLines, strip;
import std.uni       : toLower, toUpper;

private enum unitDir  = dirName(__FILE_FULL_PATH__);          // tests/unit
private enum testsDir = dirName(unitDir);                      // tests
private enum repoRoot = dirName(testsDir);                     // the public checkout

/// THE BOUNDARY. These two literals are the whole subject of this module.
/// They must stay byte-identical to `ERE_LEAD` / `ERE_TAIL` in the private
/// `tools/local/neutrality/gen_candidates.py`, and to the anchors every
/// pattern line of both private dictionaries is written with; unittest 3
/// checks that second half mechanically whenever the private tree is present.
enum string kBoundaryLead = "(^|[^A-Za-z])";
enum string kBoundaryTail = "($|[^A-Za-z])";

/// A token that is NOT banned and NOT ours: six letters chosen to occur
/// nowhere in either dictionary, in `ours.txt`, or in this repo. The boundary
/// does not depend on what the token spells, so the table below transfers to
/// every real entry — and this file stays publishable, which is the point.
enum string kSynthetic = "qzzref";

private struct Cell
{
    string spelling;      /// the exact text a scanner would meet
    bool   mustMatch;     /// true = the lint MUST report this line
    string why;           /// printed on failure, next to the spelling
}

/// The fixture. Every `mustMatch` cell is a spelling a leak really takes;
/// every `!mustMatch` cell is a spelling our own code really takes.
private Cell[] boundaryCells()
{
    enum T = kSynthetic;
    return [
        // ---- must match: the token stands alone -------------------------
        Cell(T,                                    true,  "the bare token, whole line"),
        Cell("the reference editor is " ~ T ~ " 11.2v3", true, "free prose (the control: if THIS misses, nothing else means anything)"),
        Cell("ref-editor@" ~ T ~ "-11.2v3",        true,  "a hyphen supplies the boundary"),
        Cell("cfg." ~ T ~ " = 1",                  true,  "a dot before"),
        Cell(T ~ ".Polygon",                       true,  "a dot after"),
        Cell("https://example.com/" ~ T ~ "/dl",   true,  "inside a URL path"),
        Cell("/opt/" ~ T ~ "/bin/run",             true,  "inside a filesystem path"),
        // ---- must match: THE DIGIT HOLE (backlog 3301) ------------------
        Cell("ref-editor@" ~ T ~ "11.2v3",         true,  "A DIGIT GLUED TO THE TOKEN — the defect this module exists for"),
        Cell(T ~ "9",                              true,  "one digit after"),
        Cell(T ~ "2v3 fixture",                    true,  "a digit then letters after"),
        Cell("ref-editor@11.2v3" ~ T,              true,  "a digit glued BEFORE the token"),
        Cell("/opt/" ~ T ~ "11.2v3/bin/run",       true,  "a versioned directory name"),
        Cell("https://example.com/" ~ T ~ "11/dl", true,  "a versioned URL segment"),
        // ---- must match: THE UNDERSCORE HOLE, the same defect ------------
        Cell(T ~ "_diff harness",                  true,  "a snake_case slug — the form found in two public commit messages"),
        Cell("undo_" ~ T ~ "_migration_plan",      true,  "an underscore on BOTH sides"),
        // ---- must match: letter case is not a boundary question ---------
        Cell(T.toUpper ~ "11.2v3",                 true,  "upper case, digit glued"),
        Cell(capitalised(T) ~ "11.2v3",            true,  "title case, digit glued"),
        // ---- must NOT match: the token is part of a longer WORD ----------
        Cell(T ~ "Ok = modifier ok",               false, "a LETTER follows — this is the `modOk` shape, the false positive the anchor was bought for"),
        Cell(T ~ "kness of the plate",             false, "a lower-case letter follows"),
        Cell("pseudo" ~ T ~ " shim",               false, "a letter precedes"),
        Cell("auto x = get" ~ capitalised(T) ~ "Version();", false, "buried inside a camelCase identifier"),
        // ---- must NOT match: the token is not there at all ---------------
        Cell("modeling and modOk and thickness",   false, "ordinary words; the token does not occur (fixture control)"),
    ];
}

private string capitalised(string s)
{
    return s.length == 0 ? s : to!string(s[0].toUpper) ~ s[1 .. $];
}

/// The pattern the private dictionary would carry for `token`, built from the
/// two boundary literals above and nothing else. This is `ere_for`.
private string ereFor(string token)
{
    return kBoundaryLead ~ token ~ kBoundaryTail;
}

// ---------------------------------------------------------------------------
// unittest 1 — the behaviour table, on the synthetic token.
//
// This is the assertion that goes red in BOTH mutation directions, and it
// names the SPELLING, never a count.
// ---------------------------------------------------------------------------
unittest
{
    auto cells = boundaryCells();

    // Anti-vacuity floors on the FIXTURE, not on the code under test. Without
    // these, a table that lost its digit cells, or whose suppression cells
    // stopped containing the token at all, would still pass: a suppression
    // cell that does not contain the token cannot exhibit over-matching, which
    // is the "fixture cannot exhibit the phenomenon" defect this repo pays for
    // most.
    auto positives = cells.filter!(c =>  c.mustMatch).array;
    auto negatives = cells.filter!(c => !c.mustMatch).array;
    assert(positives.length >= 15,
        format("neutrality_boundary: the fixture has only %d must-match cells; " ~
               "the digit and underscore spellings are the point of this module",
               positives.length));
    auto digitGlued = positives.filter!(c => c.spelling.canFind(kSynthetic ~ "1")
                                          || c.spelling.canFind(kSynthetic ~ "9")
                                          || c.spelling.canFind(kSynthetic ~ "2")
                                          || c.spelling.canFind("3" ~ kSynthetic)).count;
    assert(digitGlued >= 4,
        format("neutrality_boundary: only %d fixture cell(s) glue a DIGIT to the token; " ~
               "that spelling IS the defect (backlog 3301) and a table without it " ~
               "goes green over the broken boundary", digitGlued));
    auto suppressionCarryingToken =
        negatives.filter!(c => c.spelling.toLower.canFind(kSynthetic)).count;
    assert(suppressionCarryingToken >= 3,
        format("neutrality_boundary: only %d suppression cell(s) actually CONTAIN the " ~
               "token; a cell that does not contain it cannot detect an over-broad " ~
               "boundary, so the anti-vacuity half would be theatre",
               suppressionCarryingToken));

    auto rx = regex(ereFor(kSynthetic), "i");
    foreach (c; cells)
    {
        immutable hit = !matchFirst(c.spelling, rx).empty;
        assert(hit == c.mustMatch,
            format("neutrality_boundary: the spelling \"%s\" %s, but it must %s.\n" ~
                   "  reason for this cell: %s\n" ~
                   "  boundary under test : %s<TOKEN>%s\n" ~
                   "  A must-match failure means a leak spelled this way is INVISIBLE to " ~
                   "tools/local/neutrality_lint.sh. A must-not-match failure means the " ~
                   "lint has started firing on ordinary words, which is how a lint gets " ~
                   "switched off. Both are regressions of task 3301.",
                   c.spelling,
                   hit ? "MATCHED" : "did not match",
                   c.mustMatch ? "match" : "NOT match",
                   c.why, kBoundaryLead, kBoundaryTail));
    }
}

// ---------------------------------------------------------------------------
// unittest 2 — the same table through the ENGINE THE LINT ACTUALLY USES.
//
// `neutrality_lint.sh` does not run std.regex; it runs `grep -nIEi -f dict`.
// A boundary that behaves in D and not in POSIX ERE would leave the gate
// broken while this module stayed green, so the two engines are compared on
// every cell. Skipped, loudly, where `grep` is absent (the Windows runner).
// ---------------------------------------------------------------------------
unittest
{
    // Per-process names: several task worktrees run `dub test` on this host at
    // once, and a fixed /tmp name would let two of them truncate each other's
    // file mid-read — a flake that would look like a boundary regression.
    immutable tag = to!string(thisProcessID);
    immutable fixturePath = buildPath(tempDir(), "vibe3d_neutrality_cells_" ~ tag ~ ".txt");
    immutable patternPath = buildPath(tempDir(), "vibe3d_neutrality_pat_" ~ tag ~ ".txt");
    auto cells = boundaryCells();

    write(fixturePath, cells.map!(c => c.spelling).join("\n") ~ "\n");
    write(patternPath, ereFor(kSynthetic) ~ "\n");
    scope (exit)
    {
        if (exists(fixturePath)) remove(fixturePath);
        if (exists(patternPath)) remove(patternPath);
    }

    int rc;
    string output;
    try
    {
        auto r = execute(["grep", "-nIEi", "-f", patternPath, "--", fixturePath]);
        rc = r.status;
        output = r.output;
    }
    catch (Exception e)
    {
        stderr.writeln("neutrality_boundary: SKIPPED the grep cross-check — no `grep` on " ~
                       "this host (" ~ e.msg ~ "). The std.regex table in unittest 1 still ran; " ~
                       "the POSIX-ERE half of the boundary is UNWITNESSED on this platform.");
        return;
    }
    assert(rc == 0 || rc == 1,
        format("neutrality_boundary: grep exited %d over the boundary fixture — the " ~
               "pattern is not a valid POSIX ERE, so tools/local/neutrality_lint.sh " ~
               "would load it and match NOTHING.\n  pattern: %s<TOKEN>%s\n  grep said: %s",
               rc, kBoundaryLead, kBoundaryTail, output));

    bool[size_t] grepHit;
    foreach (line; output.splitLines)
    {
        auto colon = line.length;
        foreach (i, ch; line) if (ch == ':') { colon = i; break; }
        if (colon == line.length) continue;
        grepHit[to!size_t(line[0 .. colon])] = true;
    }
    foreach (i, c; cells)
    {
        immutable hit = ((i + 1) in grepHit) !is null;
        assert(hit == c.mustMatch,
            format("neutrality_boundary (grep -E): the spelling \"%s\" %s, but it must %s.\n" ~
                   "  reason for this cell: %s\n" ~
                   "  This is the engine tools/local/neutrality_lint.sh really runs, so a " ~
                   "disagreement here is the gate itself being wrong, not a D detail.",
                   c.spelling, hit ? "MATCHED" : "did not match",
                   c.mustMatch ? "match" : "NOT match", c.why));
    }
}

// ---------------------------------------------------------------------------
// unittest 3 — the bridge: the PRIVATE dictionaries must be written in the
// boundary this module declares.
//
// unittest 1 proves the boundary is right. It cannot prove the dictionary uses
// it — that is a property of a file this repo does not carry. When the private
// tree is reachable through the `tools/local` symlink (which is the normal
// developer checkout, and the private CI job), this census reads both
// dictionaries and refuses `\b` and the old digit-inclusive class. It reports
// FILE and LINE NUMBER only: printing a dictionary line here would put a
// banned token into a public test, which is the trap this module is built to
// avoid.
// ---------------------------------------------------------------------------
unittest
{
    static struct DictCheck { string rel; size_t minPatterns; size_t minAnchored; }
    immutable DictCheck[] dicts = [
        DictCheck("dictionary.txt",         20,  15),
        DictCheck("dictionary_symbols.txt", 500, 400),
    ];

    immutable neutDir = buildPath(repoRoot, "tools", "local", "neutrality");
    if (!exists(buildPath(neutDir, dicts[0].rel)))
    {
        stderr.writeln("neutrality_boundary: SKIPPED the dictionary census — the private " ~
                       "tree is not present at " ~ neutDir ~ ". This mirrors " ~
                       "neutrality_lint.sh's own \"unavailable => never block\" policy; a " ~
                       "public-only clone has nothing to check. unittest 1 and 2 still ran.");
        return;
    }

    string[] problems;
    foreach (d; dicts)
    {
        immutable path = buildPath(neutDir, d.rel);
        assert(exists(path),
            format("neutrality_boundary: %s is present but %s is not — the dictionary pair " ~
                   "has come apart and half the gate is silently gone", dicts[0].rel, d.rel));

        size_t patterns, anchoredLead;
        foreach (i, raw; readText(path).splitLines)
        {
            immutable line = raw.strip;
            if (line.length == 0 || line.startsWith("#")) continue;
            ++patterns;
            if (line.canFind(kBoundaryLead)) ++anchoredLead;
            if (line.canFind("\\b"))
                problems ~= format("%s:%d carries the `\\b` anchor, which cannot see a " ~
                                   "token followed by a digit or an underscore", d.rel, i + 1);
            if (line.canFind("[^A-Za-z0-9])"))
                problems ~= format("%s:%d anchors on the digit-inclusive class " ~
                                   "`[^A-Za-z0-9]`, which cannot see a glued version suffix",
                                   d.rel, i + 1);
        }
        // Anti-vacuity, and it must be reported through the SAME channel as the
        // findings above: an assert here would fire FIRST on a wholesale revert
        // and hide the `\b` lines that are the actual diagnosis.
        if (patterns < d.minPatterns)
            problems ~= format("%s yielded only %d pattern line(s) (floor %d) — the census " ~
                               "is reading nothing and its silence means nothing",
                               d.rel, patterns, d.minPatterns);
        else if (anchoredLead < d.minAnchored)
            problems ~= format("%s: only %d of %d pattern line(s) carry the declared " ~
                               "leading boundary `%s` (floor %d) — the dictionary and this " ~
                               "module have drifted apart",
                               d.rel, anchoredLead, patterns, kBoundaryLead, d.minAnchored);
    }

    enum size_t kMaxListed = 12;
    auto listed = problems.length > kMaxListed ? problems[0 .. kMaxListed] : problems;
    immutable tail = problems.length > kMaxListed
        ? format("\n  ... and %d more", problems.length - kMaxListed) : "";
    assert(problems.length == 0,
        format("neutrality_boundary: %d neutrality-dictionary line(s) use the PRE-3301 " ~
               "anchor. That anchor is `\\b`, whose word class is [A-Za-z0-9_], so it does " ~
               "NOT fire when the token is followed by a DIGIT (a glued version suffix — " ~
               "the single most likely real spelling of a leak) or by an UNDERSCORE (a " ~
               "snake_case slug; that form was found in two public commit messages). " ~
               "Listed by file and LINE NUMBER only: the content is private and printing " ~
               "it into a public test log would be the leak.\n  - %s%s\n" ~
               "  The boundary every pattern must use is `%s<TOKEN>%s`.",
               problems.length, listed.join("\n  - "), tail,
               kBoundaryLead, kBoundaryTail));
}

// ---------------------------------------------------------------------------
// unittest 4 — this module must not become the leak it is testing for.
//
// The obvious "improvement" to this file is to swap the synthetic token for a
// real one so the test "actually proves something". That edit IS the leak.
// When the private product dictionary is reachable, run it over this module's
// own source and refuse a hit — so the edit is caught by this module itself
// rather than by a private hook the editor may not have installed.
// ---------------------------------------------------------------------------
unittest
{
    immutable dictPath = buildPath(repoRoot, "tools", "local", "neutrality", "dictionary.txt");
    if (!exists(dictPath))
    {
        stderr.writeln("neutrality_boundary: SKIPPED the self-scan — no private dictionary " ~
                       "at " ~ dictPath ~ ".");
        return;
    }

    if (!exists(__FILE_FULL_PATH__))
    {
        stderr.writeln("neutrality_boundary: SKIPPED the self-scan — this module's own " ~
                       "source is not at " ~ __FILE_FULL_PATH__ ~ " (the binary was moved " ~
                       "away from the tree it was built in).");
        return;
    }

    size_t compiled;
    auto self = readText(__FILE_FULL_PATH__).splitLines;
    foreach (raw; readText(dictPath).splitLines)
    {
        immutable pat = raw.strip;
        if (pat.length == 0 || pat.startsWith("#")) continue;
        Regex!char rx;
        try
            rx = regex(pat, "i");
        catch (Exception)
            continue;                       // an ERE std.regex cannot read; counted out
        ++compiled;
        foreach (i, line; self)
            assert(matchFirst(line, rx).empty,
                format("neutrality_boundary: THIS FILE (%s) matches a private dictionary " ~
                       "pattern at line %d. A public test may never carry a banned token — " ~
                       "that is the self-refuting trap this module documents. Use " ~
                       "`kSynthetic`; the boundary does not depend on what the token spells.",
                       __FILE__, i + 1));
    }
    assert(compiled >= 15,
        format("neutrality_boundary: only %d dictionary pattern(s) compiled for the " ~
               "self-scan — it swept this file against almost nothing and its silence " ~
               "means nothing", compiled));
}
