// fixture_provenance_census_test — every golden fixture's `provenance` block
// must be STRUCTURALLY VALID, and the corpus must actually contain some
// (task 3140).
//
// THIS CLOSES THE PROVENANCE FAMILY'S THIRD DEFECT, AND IT IS THE ONE THAT
// UNBLOCKED THE OTHER TWO. Three cards, one family:
//
//   * backlog 2860 -- `tools/local/fixture_gen/provenance_check.py` (private
//     repo) was correct and meaningful and called by NOTHING: not
//     `./run_test.d`, not `dub test --config=tests`, not any CI step. Its
//     own point (2) named the fix: "a module test that reads the fixture
//     catalogue lands in the unit lane for free". This is that.
//   * backlog 2970 -- its sibling `tests/test_provenance_offline.py` was
//     ALSO uncalled, and RED on an untouched tree: it asserted
//     `provenance_manifest.json`'s keys equalled the on-disk fixture set, a
//     manifest that turned out to be task 0366 Phase 3's one-time back-fill
//     INPUT (frozen ~2026-07-13), not a live registry -- see that file's own
//     comment for the argued decision. Fixed in the private tree; this
//     module does not depend on it.
//   * backlog 3080 -- `provenance_check.py`'s own population was narrower
//     than the corpus: two FLAT globs reached 165 of 186 on-disk fixture
//     files, and every one of the 21 it missed (`tool_gesture/`,
//     `undo_parity/`, `edge_extend/`, `weightmap_display/`) was
//     non-compliant. So its exit-0 was green FOR THE WRONG REASON -- not
//     because the corpus was clean, but because the checker's window never
//     reached the part that was not. All 21 were fixed (task 3140) BEFORE
//     that glob was widened, per 3080's own explicit ordering rule: turning
//     a gate on over a corpus that violates it gets the gate switched back
//     off by the first person who meets it on someone else's change.
//
// This module's own population is RECURSIVE from day one (`dirEntries` +
// `SpanMode.depth`, exactly like `fixture_parameters_census_test.d`, task
// 3010's sibling in this same family) precisely so it cannot repeat 3080's
// mistake in a fourth form: a checker whose glob is narrower than the corpus
// it claims to cover.
//
// WHAT THIS DELIBERATELY DOES NOT CHECK. `provenance.reference` accepts
// either the three neutral literals (`vibe3d-selfgen`, `analytic`, `unknown`)
// or the SHAPE `ref-editor@<version>` -- it does NOT content-scan the version
// suffix for a smuggled product name. That denylist lives in the PRIVATE tree
// (`tools/local/neutrality/dictionary.txt`) on purpose, and embedding it into
// a PUBLIC file to check for its own absence would be self-defeating (the
// checker would then carry the very tokens it exists to forbid). The general
// neutrality gate (`tools/local/neutrality_lint.sh`) already scans this
// entire public tree, fixture JSON content included, for those tokens on
// every commit. This module owns structural shape only: is `provenance`
// present, and if present, does every field hold a value from its own
// vocabulary.
//
// CORRECTION, measured 2026-08-29 (task 3300): the delegation above USED to
// read "that is the authoritative check for THAT question", and for one shape
// it was not, for one shape, between 2026-08-29's measurement and the same
// day's fix. The private dictionary's patterns were anchored with `\b`, whose
// word class is [A-Za-z0-9_], so a banned token followed immediately by a
// DIGIT inside the version suffix -- `ref-editor@<token><digit>...` -- carried
// no boundary and was NOT matched; verified with `neutrality_lint.sh --paths`
// against three probe files, where the hyphenated and the free-prose forms
// both FAIL and that one form reported 0 findings. `provenance.
// reference_is_neutral` (private) caught it via an always-on substring test
// and was the only checker that did, in no routine lane.
//
// CLOSED by task 3301: the dictionary boundary is now
// `(^|[^A-Za-z])TOKEN($|[^A-Za-z])`, which treats a digit and an `_` as the
// delimiters they are while still keeping `modeling` / `modOk` / `lineDrawn`
// quiet, and the BOUNDARY itself now has a witness in this same lane --
// `tests/unit/neutrality_boundary_test.d`, which proves the match/no-match
// table on a SYNTHETIC token because a public test may not carry a real one.
// So the delegation is honest again: SHAPE here, CONTENT in the private
// dictionary, and the RULE that dictionary matches by is pinned publicly.
// This module still does not embed the denylist, for the reason above.
//
// THE INLINE-.d POPULATION IS A SMALL, ENUMERATED SET, DELIBERATELY, mirroring
// `provenance_check.py`'s `INLINE_D_FILES` (private repo) so the two
// checkers' populations cannot silently diverge from each other -- backlog
// 3080 §4 names exactly that divergence as the next form of this family's
// defect if nobody keeps the two lists in step by hand.
//
// MUTATIONS THAT REDDEN IT (task 3140's card records them run):
//   * strip the `provenance` key from a compliant fixture => named by file;
//   * corrupt a present block (`"source": "live-capture"` -> a bad enum
//     value) => named by file and offending value;
//   * add a fixture with NO provenance block one directory deeper than the
//     old flat globs reached (e.g. under `tool_gesture/`) => this module's
//     RECURSIVE scan catches it where a flat glob would not;
//   * narrow the SCANNER ITSELF (`SpanMode.depth` -> `SpanMode.shallow`, or
//     any walk that stops descending) => the nested floor in unittest 1.
//     Task 3140 ran its mutations against the already-built binary with
//     mutated FIXTURE DATA, which is legitimate for a census that reads the
//     corpus at run time but leaves this module's own CODE unmutated; run
//     2026-08-29 (task 3300), the shallow walk was GREEN at 381 modules
//     before that floor existed.
// Removing the LAST `provenance` block from the corpus, or the removal of
// every `live-capture`/`simulated`/`analytic` entry, would fire the
// anti-vacuity assertions below (both branches must be exercised on real
// data, not merely permitted).
//
// The scan is `__FILE_FULL_PATH__`-rooted, never cwd-rooted: a lane runs the
// unit binary from several directories and a cwd-relative glob would quietly
// match nothing.
module tests.unit.fixture_provenance_census_test;

import std.algorithm : canFind;
import std.file      : dirEntries, exists, isFile, readText, SpanMode;
import std.format    : format;
import std.json      : JSONException, JSONType, JSONValue, parseJSON;
import std.path      : buildPath, dirName, dirSeparator, extension, relativePath;
import std.regex     : matchAll, regex;
import std.string    : indexOf;

private enum unitDir     = dirName(__FILE_FULL_PATH__);      // tests/unit
private enum testsDir    = dirName(unitDir);                 // tests
private enum fixturesDir = buildPath(testsDir, "fixtures");

/// The small, enumerated set of `.d` files (relative to `tests/`) that carry
/// inline `provenance` blocks. Kept in step BY HAND with
/// `tools/local/fixture_gen/provenance_check.py`'s `INLINE_D_FILES` (private
/// repo) -- see the module doc comment above.
private immutable string[] kInlineDFiles = [
    "test_acen_select_center.d",
    "test_fixture_acen_select_basis.d",
];

/// Regex for one inline block: `enum string json = \`{...}\`;`, DOTALL so
/// the JSON body's own newlines are matched by `.`.
private enum string kJsonBlockPattern = "enum\\s+string\\s+json\\s*=\\s*`(.*?)`\\s*;";

/// The vocabularies, kept in step with `tools/local/fixture_gen/provenance.py`
/// (private). A value added there and not here reddens this module with the
/// offending value printed, which is the intended way to find out.
private enum int kProvenanceSchema = 1;
private immutable string[] kSourceValues = [
    "live-capture", "simulated", "analytic", "unknown",
];
private immutable string[] kMethodValues = [
    "capture-drag", "command", "from-trace", "rr-memory", "self-drive",
    "closed-form", "hand", "static-read", "gui-gesture", "debug-live", "unknown",
];
private immutable string[] kNeutralReferenceLiterals = [
    "vibe3d-selfgen", "analytic", "unknown",
];

private struct Scanned
{
    string[] problems;
    size_t files;                                    /// items scanned (fixture files + inline blocks)
    size_t withBlock;                                 /// items carrying a `provenance` key
    size_t parity, smokeSimulated, smokeAnalytic, unknownSource;
    size_t nested;                                    /// fixture files found BELOW `tests/fixtures/`
    bool[string] nestedDirs;                          /// their distinct first path segments
}

/// True for `provenance.reference` iff it is one of the three neutral
/// literals, or matches the SHAPE `ref-editor@<version>` (letters, digits,
/// `.`, `_`, `+`, `-` only in the version). See the module doc comment for
/// why this does not also content-scan the version for a banned token.
private bool isNeutralReferenceShape(string r)
{
    if (kNeutralReferenceLiterals.canFind(r))
        return true;
    enum string prefix = "ref-editor@";
    if (r.length <= prefix.length || r[0 .. prefix.length] != prefix)
        return false;
    immutable ver = r[prefix.length .. $];
    foreach (c; ver)
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
              || c == '.' || c == '_' || c == '+' || c == '-'))
            return false;
    return true;
}

/// Structural lint of one block. Mirrors `provenance.lint_provenance`;
/// returns every problem rather than the first, so one run names every
/// offender.
private string[] lintProvenance(const JSONValue block)
{
    if (block.type != JSONType.object)
        return ["provenance block is not an object"];
    string[] errs;
    auto obj = block.object;

    if ("schema" !in obj || obj["schema"].type != JSONType.integer
        || obj["schema"].integer != kProvenanceSchema)
        errs ~= format("provenance.schema != %d", kProvenanceSchema);

    if ("source" !in obj || obj["source"].type != JSONType.string
        || !kSourceValues.canFind(obj["source"].str))
        errs ~= format("provenance.source %s not in %s",
                       "source" in obj ? obj["source"].toString() : "<missing>",
                       kSourceValues);

    if ("reference" !in obj || obj["reference"].type != JSONType.string
        || !isNeutralReferenceShape(obj["reference"].str))
        errs ~= format("provenance.reference %s is not a valid/neutral shape "
                       ~ "(want one of %s or 'ref-editor@<version>')",
                       "reference" in obj ? obj["reference"].toString() : "<missing>",
                       kNeutralReferenceLiterals);

    if ("method" !in obj || obj["method"].type != JSONType.string
        || !kMethodValues.canFind(obj["method"].str))
        errs ~= format("provenance.method %s not in %s",
                       "method" in obj ? obj["method"].toString() : "<missing>",
                       kMethodValues);

    if ("captured_utc" !in obj || obj["captured_utc"].type != JSONType.string
        || obj["captured_utc"].str.length == 0)
        errs ~= "provenance.captured_utc missing/empty";

    return errs;
}

/// "parity" | "smoke-simulated" | "smoke-analytic" | "unknown". Only
/// `source == "live-capture"` is parity, matching `provenance.classify`.
private string classify(const JSONValue block)
{
    if (block.type != JSONType.object || "source" !in block.object
        || block.object["source"].type != JSONType.string)
        return "unknown";
    switch (block.object["source"].str)
    {
        case "live-capture": return "parity";
        case "simulated":    return "smoke-simulated";
        case "analytic":     return "smoke-analytic";
        default:             return "unknown";
    }
}

/// Check one already-parsed fixture body. Caller has already counted it into
/// `s.files`; this only handles presence/validity/classification.
private void checkBlock(string rel, const JSONValue fx, ref Scanned s)
{
    if (fx.type != JSONType.object || "provenance" !in fx.object)
    {
        s.problems ~= format("%s: MISSING provenance block", rel);
        return;
    }
    s.withBlock++;
    auto block = fx.object["provenance"];
    auto errs = lintProvenance(block);
    foreach (e; errs)
        s.problems ~= format("%s: %s", rel, e);
    if (errs.length)
        return;
    switch (classify(block))
    {
        case "parity":          s.parity++;         break;
        case "smoke-simulated": s.smokeSimulated++;  break;
        case "smoke-analytic":  s.smokeAnalytic++;   break;
        default:                s.unknownSource++;   break;
    }
}

private Scanned scanCorpus()
{
    Scanned s;

    if (exists(fixturesDir))
    {
        foreach (entry; dirEntries(fixturesDir, SpanMode.depth))
        {
            if (!entry.isFile || entry.name.extension != ".json")
                continue;
            const rel = relativePath(entry.name, fixturesDir);
            s.files++;
            // Record the DESCENT, not merely the count -- see the nested floor
            // in unittest 1 for why a total alone cannot see a walk that
            // stopped recursing.
            if (rel.canFind(dirSeparator))
            {
                s.nested++;
                s.nestedDirs[rel[0 .. rel.indexOf(dirSeparator)]] = true;
            }
            JSONValue fx;
            try
                fx = parseJSON(readText(entry.name));
            catch (JSONException e)
            {
                s.problems ~= format("%s: fixture JSON does not parse: %s", rel, e.msg);
                continue;
            }
            checkBlock(rel, fx, s);
        }
    }

    auto blockRe = regex(kJsonBlockPattern, "s");
    foreach (leaf; kInlineDFiles)
    {
        const p = buildPath(testsDir, leaf);
        if (!exists(p))
            continue;
        const text = readText(p);
        size_t idx = 0;
        foreach (m; matchAll(text, blockRe))
        {
            idx++;
            const rel = format("%s#%d", leaf, idx);
            s.files++;
            JSONValue fx;
            try
                fx = parseJSON(m[1]);
            catch (JSONException e)
            {
                s.problems ~= format("%s: inline JSON does not parse: %s", rel, e.msg);
                continue;
            }
            checkBlock(rel, fx, s);
        }
    }

    return s;
}

// 1 — the scan reached the corpus at all, RECURSIVELY. A floor, not an exact
//     count: several lanes add fixtures concurrently (see
//     `fixture_parameters_census_test.d`'s header for the same reasoning),
//     and an exact count would be a rebase conflict per lane for no gain.
//     186 fixture JSON files + 5 inline blocks were on disk when this module
//     was written (task 3140); 150 is a floor with slack, not that number.
unittest
{
    auto s = scanCorpus();
    assert(s.files >= 150,
           format("fixture_provenance_census: the scan found only %d item(s) "
                  ~ "under %s (+ %d inline .d file(s)) -- a census that passes "
                  ~ "because it looked at nothing is this repository's "
                  ~ "most-paid-for defect", s.files, fixturesDir,
                  kInlineDFiles.length));

    // ...AND IT RECURSED. The total above cannot see this, which was measured,
    // not reasoned: swapping `SpanMode.depth` for `SpanMode.shallow` in
    // `scanCorpus` drops all 24 fixtures living below `tests/fixtures/` out of
    // the population -- every file under `edge_extend/`, `stages/`,
    // `tool_gesture/`, `undo_parity/`, `weightmap_display/`, which is EXACTLY
    // the set backlog 3080 was filed about -- and `dub test --config=tests`
    // still reports "381 modules passed unittests", exit 0 (measured
    // 2026-08-29, task 3300). 166 top-level files + 5 inline blocks = 171,
    // comfortably over the 150 floor, so the floor is satisfied by the blind
    // scanner too: a check that cannot come out differently.
    //
    // This module's header claims its recursive population is what keeps it
    // from repeating 3080's defect in a fourth form. That claim was an
    // untested comment until this assertion; the walk is now held to the
    // DESCENT, not just to a total. Floors carry slack (24 nested files in 5
    // directories on disk today) for the same reason the 150 does: several
    // lanes add fixtures concurrently and an exact count is a rebase conflict
    // per lane for no gain.
    assert(s.nested >= 10 && s.nestedDirs.length >= 3,
           format("fixture_provenance_census: the scan reached %d item(s) but "
                  ~ "only %d of them below %s, in %d subdirector(y/ies) -- the "
                  ~ "file walk is not recursing. Every fixture in a "
                  ~ "subdirectory is then outside the population and this "
                  ~ "module goes green over a corpus it never opened, which is "
                  ~ "the defect (backlog 3080) it exists to prevent",
                  s.files, s.nested, fixturesDir, s.nestedDirs.length));
}

// 2 — the validator has been exercised on real data, in more than one
//     direction: at least one PARITY (live-capture) entry and at least one
//     SMOKE (simulated/analytic) entry, so neither branch of `classify` is
//     green over the empty set.
unittest
{
    auto s = scanCorpus();
    assert(s.parity >= 1,
           format("fixture_provenance_census: not one fixture carries a valid "
                  ~ "'live-capture' provenance block (%d file(s) scanned, %d "
                  ~ "with a block) -- the parity branch of the classifier "
                  ~ "would be green over the empty set", s.files, s.withBlock));
    assert(s.smokeSimulated + s.smokeAnalytic >= 1,
           format("fixture_provenance_census: not one fixture carries a valid "
                  ~ "'simulated'/'analytic' provenance block (%d file(s) "
                  ~ "scanned, %d with a block) -- the smoke branch of the "
                  ~ "classifier would be green over the empty set",
                  s.files, s.withBlock));
}

// 3 — the rule itself: every fixture carries a `provenance` block, and every
//     PRESENT block is structurally valid. Exact term, zero exceptions.
//     Accumulated and asserted once, so one run names every offender instead
//     of only the first (druntime stops a module at its first failed assert).
//
//     This is the PRESENCE rule, unlike its sibling in
//     `fixture_parameters_census_test.d` (task 3010), which deliberately
//     keeps presence OFF because 73 fixtures were still `absent` when it
//     shipped. `provenance` has no such backlog: task 3140 closed the last 21
//     non-compliant fixtures (backlog 3080) before this module was written,
//     so every fixture in the corpus already carries a valid block, and
//     presence can be the live rule from day one instead of a second
//     deferred flag nobody flips later.
unittest
{
    auto s = scanCorpus();
    string joined;
    foreach (p; s.problems)
        joined ~= "\n  - " ~ p;
    assert(s.problems.length == 0,
           format("fixture_provenance_census: %d problem(s) in the fixture "
                  ~ "corpus's `provenance` blocks (%d item(s) scanned, %d with "
                  ~ "a block: %d parity / %d smoke-simulated / %d "
                  ~ "smoke-analytic / %d unknown-source):%s",
                  s.problems.length, s.files, s.withBlock, s.parity,
                  s.smokeSimulated, s.smokeAnalytic, s.unknownSource, joined));
}
