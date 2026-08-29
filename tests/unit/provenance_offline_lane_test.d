// provenance_offline_lane_test — THE LANE for the private offline provenance
// test (backlog 2970, the last card of the provenance family; task 3390).
//
// WHAT THIS IS FOR. `tools/local/fixture_gen/tests/test_provenance_offline.py`
// is a real, meaningful, currently-green check over the private fixture
// tooling: it drives `provenance.py`'s schema round-trip, its lint's accept
// and reject arms (including the two neutrality rejects), its classifier,
// `provenance_manifest.json`'s own structural integrity, `gen.py`'s
// write-time `emit()`/`emit_stage()` provenance guard, and
// `provenance_check.py`'s exit code on a bare fixture. Backlog 2970 was filed
// because that file was RED on an untouched tree; task 3140 fixed the red.
// The half 2970 kept open is the other one in its title: **it was called by
// nothing**. Verified again on this branch before writing this module —
// `grep -rn` over both trees' `.github/workflows/`, `run_test.d`,
// `run_all.d`, `dub.json` and every `.sh` finds exactly one caller of
// anything in that directory, `run_all.d`'s optional `provenance_check.py`
// step, and none at all for this file.
//
// A gate nobody calls is the defect this family exists to close, and it has
// now recurred four times in it (2860, 2970, 3080, 3302). Closing 2970 by
// re-running the file by hand and writing "green" in the card would be the
// fifth.
//
// ---------------------------------------------------------------------------
// WHY THIS IS A D MODULE THAT SHELLS OUT, AND NOT A D REWRITE
// ---------------------------------------------------------------------------
// The card's preference order is (1) a module test in the routine lane, (2) a
// CI step. Option (1)'s usual shape in this family — `fixture_provenance_
// census_test.d`, `fixture_parameters_census_test.d` — is a D REIMPLEMENTATION
// that reads the fixture catalogue, and for those two it works because the
// question ("does every fixture carry a valid block?") is about the PUBLIC
// corpus, which D can read.
//
// That shape is unavailable here and 2970's own log says why: this file tests
// the PRIVATE PYTHON TOOL, not the corpus. Its subjects are
// `provenance.py`'s lint behaviour, `gen.py`'s SystemExit guard and
// `provenance_check.py`'s exit code — three private modules with no D
// counterpart and no reason to grow one. A D reimplementation would not be a
// second opinion on those functions, it would be a second, unexecuted COPY of
// them: the thing the vocabulary drift of backlog 3302 already cost eleven
// days.
//
// So the module test runs the tool instead of restating it. What is written in
// D is the part that can be WRONG in D: the judgement of what a run of it
// means. That judgement is `judgeOfflineRun` below, it is pure, and it has its
// own table-driven witness (unittest 2) which needs neither Python nor the
// private tree.
//
// ---------------------------------------------------------------------------
// WHY THIS ALONE IS NOT ENOUGH, AND WHAT SITS BESIDE IT
// ---------------------------------------------------------------------------
// Measured, not assumed:
//   * `dub test --config=tests` is triggered by a push to the PUBLIC repo
//     (`.github/workflows/ci.yaml`, `on: push: branches: [main]`).
//   * Every file this check exercises lives in the PRIVATE repo. A change to
//     `provenance.py` therefore moves no public commit and fires no public
//     lane. This module would never see it.
//   * The only private workflow triggered by a push to the private master is
//     `.github/workflows/neutrality.yml` (the other three are
//     schedule/dispatch only).
// Hence the second half of this task: a step in that private workflow, beside
// the `selftest.sh` step task 3320 added there for the same structural reason.
// The two are complementary and neither is redundant — this module catches a
// break during the developer's routine gate, the workflow step catches the
// push that actually carries the break.
//
// ---------------------------------------------------------------------------
// THE SKIP, SAID OUT LOUD
// ---------------------------------------------------------------------------
// A skip is normally the shape this project distrusts most (`## A check that
// cannot come out differently`: "the run never happened"). It is defensible
// here on exactly the grounds `fixture_provenance_census_test.d`'s
// cross-language pin already argued: the subject cannot be EDITED without the
// private tree, so in every environment where the drift can be authored, the
// symlink resolves and this runs. The skip is not silent — it prints the path
// it looked for — and it is not the whole module: unittest 2 runs everywhere
// and unittest 3 needs only a `python3`.
//
// ---------------------------------------------------------------------------
// WHAT MAKES IT NON-VACUOUS (an exit code is not a verdict)
// ---------------------------------------------------------------------------
// `status == 0` is the weakest possible reading of that run, and on its own it
// is satisfied by a Python file that was emptied, short-circuited by an early
// `sys.exit(0)`, or whose checks silently stopped being reached. So the judge
// also requires, from the run's OWN OUTPUT:
//   * the terminal line the file prints only after its `_fails` list is empty;
//   * every one of `kPhaseMarkers` — one check message per PHASE of the file,
//     so deleting a whole block names the block instead of shrinking a count;
//   * at least `kMinOkRows` `ok  :` rows overall — a floor set well under
//     today's 116 and well over the 37 that survive deleting the manifest
//     block entirely, so it separates "gutted" from "drifted" rather than
//     restating the current number;
//   * EXACTLY `kFrozenManifestRows` manifest rows. An equality rather than a
//     floor, and that is not fussiness: with a floor, DELETING a manifest row
//     reddened nothing anywhere, measured. The manifest is frozen, so its size
//     is a constant of the evidence trail — see the constant's own comment.
//   * no `FAIL:` row, even under `status == 0`.
//
// ---------------------------------------------------------------------------
// MUTATIONS THAT REDDEN IT (all run 2026-08-29 on this branch, in isolation)
// ---------------------------------------------------------------------------
//   * corrupt one `provenance_manifest.json` entry (`"source"` -> a value
//     outside its vocabulary) => unittest 1 fails and REPRINTS the Python's own
//     row, naming the manifest STEM. This is 2970's mutation clause in the only
//     shape this file still has after task 3140 — see the note below;
//   * make the Python exit 0 having checked nothing (`sys.exit(0)` after the
//     imports) => the `kMinOkRows` floor reddens, not the status;
//   * delete one phase (comment out the Phase-2 `emit()` block) => the missing
//     marker is named, and the ok-row count alone would not have moved enough
//     to notice;
//   * break the plumbing so the subprocess output is dropped => the terminal
//     line and every marker are reported missing at once (unittest 3).
// The other direction is pinned too: unittest 2's first case is a
// well-formed run, and the judge must return NOTHING for it — a judge that
// reddens on everything is worth as little as one that reddens on nothing.
//
// WHAT THIS LANE DOES **NOT** SEE, said here rather than discovered later.
// Deleting the `provenance` block from a real fixture in `tests/fixtures/` is
// the mutation backlog 2970's card names verbatim, and it does not move THIS
// file by one line: the Python's Phase-4 block builds its own two-fixture
// corpus in a `TemporaryDirectory` and never reads the repository's. Measured,
// not reasoned: with `tests/fixtures/softrotate.json`'s block deleted the
// Python still printed `all offline checks passed`, exit 0. That mutation is
// owned — and was already witnessed by task 3140 — by the two checkers that
// DO read the corpus: `fixture_provenance_census_test.d` in this same lane,
// and `provenance_check.py`. Both name the file. Deleting a manifest ROW moves
// nothing anywhere, and that is task 3140's argued decision rather than a hole:
// the manifest is a frozen Phase-3 record, so a row's absence is not a defect,
// while a row's CORRUPTION is — which is the mutation run above.
//
// Paths are `__FILE_FULL_PATH__`-rooted, never cwd-rooted: the unit binary is
// run from several directories and a cwd-relative path would quietly find
// nothing, which for a gate reads as "clean".
module tests.unit.provenance_offline_lane_test;

import std.algorithm : canFind, startsWith;
import std.array     : join;
import std.conv      : to;
import std.file      : exists, isFile, remove, tempDir, write;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.process   : Config, execute, thisProcessID;
import std.stdio     : stderr;
import std.string    : splitLines, strip;

private enum unitDir  = dirName(__FILE_FULL_PATH__);      // tests/unit
private enum testsDir = dirName(unitDir);                 // tests
private enum repoRoot = dirName(testsDir);                // the public checkout

/// The private offline test, reached through the gitignored `tools/local`
/// symlink. Absent in a bare public clone — see "THE SKIP" above.
private enum string kOfflineTest =
    buildPath(repoRoot, "tools", "local", "fixture_gen", "tests",
              "test_provenance_offline.py");

/// The line the Python file prints ONLY on the path where its failure list is
/// empty. Its absence means the run died, was truncated, or never reached the
/// end — none of which an exit code distinguishes on its own.
private enum string kTerminalLine = "all offline checks passed";

/// ONE check message per PHASE of the Python file. Chosen so that deleting or
/// short-circuiting any block names that block rather than moving a count.
/// Every one of these is verified to be a real substring of a real run by
/// unittest 1; unittest 2 verifies the judge reacts to each one's absence.
///
/// If a check here is deliberately RENAMED in the Python file, update the
/// string below. If it is DELETED, that is precisely what this list is for.
private immutable string[] kPhaseMarkers = [
    "make_provenance stamps schema",
    "lint rejects a bad source enum value",
    "lint rejects a bare product-name reference",
    "lint rejects a product name smuggled into",
    "classify: live-capture -> parity",
    "provenance_manifest.json is non-empty",
    "emit() raises SystemExit when 'provenance' is absent",
    "emit_stage() raises SystemExit when 'provenance' is absent",
    "provenance_check exits 0 when every fixture has valid provenance",
    "provenance_check exits non-zero once a bare (no-provenance) fixture",
];

/// The total-row floor — see "WHAT MAKES IT NON-VACUOUS". Measured on this
/// branch for orientation only: 116 `ok  :` rows, of which 79 are manifest
/// rows. Deleting the whole manifest block leaves 37; deleting any single
/// phase leaves 115. The floor sits between those two worlds on purpose — it
/// separates "gutted" from "drifted", and it is deliberately NOT the current
/// number, which would redden on every ordinary edit and get switched off.
private enum size_t kMinOkRows = 100;

/// The manifest's row count is pinned EXACTLY, and that is a consequence of
/// task 3140's decision rather than a second maintenance obligation: the
/// manifest is a FROZEN Phase-3 back-fill record, so its size is a constant of
/// the evidence trail, not a number that tracks the corpus. (The corpus is at
/// 196 fixtures and climbing; the manifest has been at 79 since ~2026-07-13.)
///
/// A floor instead of an equality was tried first and REJECTED by its own
/// mutation: with a floor of 60, DELETING a row -- which is backlog 2970's
/// mutation clause read literally -- reddened nothing at all, in any lane. An
/// exact pin is what makes "somebody edited the historical record" visible,
/// and it costs nothing, because a frozen artefact's size does not drift.
/// Correcting a STALE KEY in place (task 3140 did exactly that, twice) does
/// not move it.
///
/// If this number is ever changed deliberately, the reason belongs in the task
/// card AND in the argued block inside the Python file: a frozen record that
/// quietly grows is the "live registry" reading 3140 rejected, arriving by the
/// back door.
private enum size_t kFrozenManifestRows = 79;

/// At most this many `FAIL:` rows are reprinted into an assert message; the
/// rest are counted. A gutted manifest would otherwise produce a 79-line
/// assertion.
private enum size_t kMaxReprintedFails = 40;

/// When the run died instead of failing a check there is no `FAIL:` row to
/// quote, so this many trailing output lines are reprinted instead — enough
/// for a Python traceback's exception line and its message.
private enum size_t kRawTailLines = 12;

/// One run of the offline test: everything the judge is allowed to look at.
private struct OfflineRun
{
    int    status;
    string output;
}

/// THE JUDGEMENT, and the only part of this module that is written in D
/// rather than delegated. Pure: same inputs, same problems, no filesystem, no
/// process. Returns an empty array for a run that genuinely happened and
/// genuinely passed.
private struct RunStats
{
    size_t   okRows;
    size_t   manifestRows;
    string[] fails;
}

/// Count what a run reported. Shared by the judge and by the witness line
/// unittest 1 prints, so the numbers a lane's log shows are the numbers the
/// judge acted on and not a second count that could disagree.
private RunStats statsOf(string output)
{
    RunStats st;
    foreach (raw; output.splitLines)
    {
        immutable line = raw.strip;
        if (line.startsWith("FAIL:"))
            st.fails ~= line;
        else if (line.startsWith("ok  :"))
        {
            ++st.okRows;
            if (line.canFind("manifest entry") &&
                line.canFind("lints clean via make_provenance"))
                ++st.manifestRows;
        }
    }
    return st;
}

private string[] judgeOfflineRun(const OfflineRun r)
{
    string[] problems;
    auto st = statsOf(r.output);
    auto fails = st.fails;
    immutable okRows       = st.okRows;
    immutable manifestRows = st.manifestRows;

    string failDigest()
    {
        if (fails.length == 0)
        {
            // No FAIL: row means the run DIED rather than failing a check —
            // an uncaught exception, a missing import, an interpreter that is
            // not there. The reader needs the actual text, and pointing at
            // "the raw output" without printing it is how a gate becomes
            // something people disable. Print the tail: a traceback's last
            // lines carry the exception and its message.
            auto all = r.output.splitLines;
            immutable size_t keep = kRawTailLines < all.length
                                  ? kRawTailLines : all.length;
            if (keep == 0)
                return "(the run produced NO OUTPUT AT ALL — it did not even "
                     ~ "start; check the interpreter and the path)";
            string[] tail;
            foreach (line; all[$ - keep .. $])
                tail ~= line;
            return format("(no FAIL: row — the run DIED rather than failing a "
                        ~ "check. Last %d line(s) of its output:)\n    %s",
                          keep, tail.join("\n    "));
        }
        string[] shown = fails.length <= kMaxReprintedFails
                       ? fails.dup
                       : fails[0 .. kMaxReprintedFails].dup
                         ~ ("... and " ~ to!string(fails.length - kMaxReprintedFails)
                            ~ " more FAIL: row(s)");
        return "\n    " ~ shown.join("\n    ");
    }

    if (r.status != 0)
        problems ~= format("the offline provenance test exited %d. Its own "
                         ~ "failure rows name what broke: %s",
                           r.status, failDigest());

    if (fails.length != 0 && r.status == 0)
        problems ~= format("the run exited 0 but printed %d FAIL: row(s) — the "
                         ~ "file's exit path and its check list disagree, which "
                         ~ "is worse than either failing alone: %s",
                           fails.length, failDigest());

    if (!r.output.canFind(kTerminalLine))
        problems ~= format("the run never printed its terminal line %(%s%). It "
                         ~ "did not reach the end — an exit code alone cannot "
                         ~ "tell that apart from a pass.", [kTerminalLine]);

    foreach (m; kPhaseMarkers)
        if (!r.output.canFind(m))
            problems ~= format("a whole PHASE of the offline test is missing "
                             ~ "from the run: no row matched %(%s%). Either that "
                             ~ "block was deleted / short-circuited, or the "
                             ~ "check was renamed and `kPhaseMarkers` in %s "
                             ~ "needs the new spelling.",
                               [m], "tests/unit/provenance_offline_lane_test.d");

    if (okRows < kMinOkRows)
        problems ~= format("the run reported only %d passing check(s); the "
                         ~ "structural floor is %d. A run this small has been "
                         ~ "gutted or short-circuited — it is not a smaller "
                         ~ "version of the same gate.", okRows, kMinOkRows);

    if (manifestRows != kFrozenManifestRows)
        problems ~= format("%d provenance_manifest.json entry(ies) were "
                         ~ "checked; the frozen record has %d. %s The manifest "
                         ~ "is task 0366 Phase-3's one-time back-fill INPUT, "
                         ~ "not a live registry (argued in the Python file "
                         ~ "itself) — its row count is a constant of the "
                         ~ "evidence trail. If it moved on purpose, say so in "
                         ~ "the card and change `kFrozenManifestRows` here; if "
                         ~ "it moved by accident, the historical record was "
                         ~ "edited.",
                           manifestRows, kFrozenManifestRows,
                           manifestRows < kFrozenManifestRows
                             ? "Rows have been DELETED (or the check that reads "
                             ~ "them has been gutted)."
                             : "Rows have been ADDED — which is the 'the "
                             ~ "manifest must list every fixture' reading that "
                             ~ "task 3140 rejected, arriving by the back door.");

    return problems;
}

/// Run a Python file through the interpreter, capturing status and output
/// together. Shared by unittest 1 (the real file) and unittest 3 (synthetic
/// files that prove this path really transports a failure).
private OfflineRun runPython(string interpreter, string script)
{
    auto r = execute([interpreter, script], null, Config.none,
                     size_t.max, repoRoot);
    return OfflineRun(r.status, r.output);
}

/// True when a usable `python3` is on PATH.
private bool haveReachablePython(string interpreter)
{
    try
    {
        auto probe = execute([interpreter, "--version"]);
        return probe.status == 0;
    }
    catch (Exception)
        return false;
}

private enum string kPython = "python3";

// ---------------------------------------------------------------------------
// 1 — THE WIRING. Run the private offline test for real and judge it.
//
// This is the unittest backlog 2970 asks for: after it, the file executes on
// every `dub test --config=tests` in any environment where its subject can be
// edited, with no separate discipline and nobody having to remember.
// ---------------------------------------------------------------------------
unittest
{
    if (!exists(kOfflineTest) || !isFile(kOfflineTest))
    {
        stderr.writeln("[provenance_offline_lane] SKIPPED: the private offline "
                     ~ "test is not reachable at " ~ kOfflineTest ~ " (bare "
                     ~ "public checkout). Everything it exercises lives in the "
                     ~ "private tree and cannot be edited from here, so nothing "
                     ~ "this block guards can drift in this environment. "
                     ~ "unittest 2 still ran.");
        return;
    }

    assert(haveReachablePython(kPython),
        format("the private tree IS present (%s resolves) but `%s` does not "
             ~ "run. That is not a reason to skip: every private fixture tool "
             ~ "in tools/local/fixture_gen is Python, so this environment "
             ~ "cannot check ANY of them, and reporting a pass would say the "
             ~ "opposite.", kOfflineTest, kPython));

    immutable run = runPython(kPython, kOfflineTest);
    auto problems = judgeOfflineRun(run);

    // THE WITNESS LINE, and it is not decoration. This block SKIPS in a bare
    // public clone, and a skipped block and a passing one are indistinguishable
    // in a lane's log — which is the exact failure mode backlog 2970 is about,
    // one level up. So the success path says, in the lane's own output, that
    // the run happened and how big it was. `dub test --config=tests`'s log,
    // and the private workflow's step log, then carry the proof rather than an
    // exit code. Grep it: `provenance_offline_lane] RAN`.
    {
        auto st = statsOf(run.output);
        stderr.writeln(format("[provenance_offline_lane] RAN %s: exit %d, "
                            ~ "%d check row(s), %d manifest row(s), %d failure(s)",
                              kOfflineTest, run.status, st.okRows,
                              st.manifestRows, st.fails.length));
    }

    assert(problems.length == 0,
        format("the private offline provenance test (%s) did not pass this "
             ~ "lane. %d problem(s):\n  - %s\n\nThis gate exists because that "
             ~ "file spent an unknown number of weeks RED with no caller "
             ~ "(backlog 2970). Fix the named row; do not disconnect the lane.",
               kOfflineTest, problems.length, problems.join("\n  - ")));
}

// ---------------------------------------------------------------------------
// 2 — THE JUDGE'S OWN TABLE. No Python, no private tree, runs everywhere.
//
// Unittest 1 proves the markers describe a REAL run. This proves the judge
// reacts to each way that run can go wrong — and, in the first case, that it
// does NOT react to a run that is fine. Without this pair the wiring above
// would be a check satisfied by the broken code too: an `assert(status == 0)`
// is green for a file that was emptied.
// ---------------------------------------------------------------------------
unittest
{
    // A synthetic well-formed run: every phase marker, enough ok rows, enough
    // manifest rows, the terminal line, no failures.
    static string wellFormed()
    {
        string s;
        foreach (m; kPhaseMarkers)
            s ~= "ok  : " ~ m ~ "\n";
        foreach (i; 0 .. 79)
            s ~= format("ok  : manifest entry 'stem_%d' lints clean via "
                      ~ "make_provenance ()\n", i);
        foreach (i; 0 .. 27)                       // padding to the real shape
            s ~= format("ok  : filler check %d\n", i);
        s ~= "\n" ~ kTerminalLine ~ "\n";
        return s;
    }

    immutable good = wellFormed();

    // (a) the negative control for the whole module: a good run must be
    //     judged clean. A judge that reddens on everything is as useless as
    //     one that never does.
    {
        auto p = judgeOfflineRun(OfflineRun(0, good));
        assert(p.length == 0,
            format("the judge reddened on a WELL-FORMED run — it cannot "
                 ~ "discriminate, so unittest 1's green means nothing. %d "
                 ~ "problem(s):\n  - %s", p.length, p.join("\n  - ")));
    }

    // (b) a failing run in the shape the real mutation produces: one
    //     manifest entry stops linting, the Python prints a FAIL row that
    //     NAMES THE STEM, and the process exits 1. The judge must carry that
    //     name through to the assert message rather than swallow it into a
    //     count — a gate that reddens without saying WHICH row is a gate the
    //     next reader disables.
    {
        immutable named = "FAIL: manifest entry 'tests/fixtures/some_fixture' "
                        ~ "lints clean via make_provenance (source: not a valid "
                        ~ "value)";
        immutable body_ = good ~ named ~ "\n";
        auto p = judgeOfflineRun(OfflineRun(1, body_));
        assert(p.length >= 1, "a non-zero exit must be a problem");
        immutable joined = p.join("\n");
        assert(joined.canFind("exited 1"),
            "the judge must report the exit status it saw: " ~ joined);
        assert(joined.canFind(named),
            format("the judge must REPRINT the failing row so the reader is "
                 ~ "told WHICH check broke; it printed:\n%s", joined));
        assert(joined.canFind("some_fixture"),
            format("the NAME inside the failing row did not survive into the "
                 ~ "message. Backlog 2970's mutation clause is specifically "
                 ~ "\"reddens NAMING the file\"; a bare count fails it:\n%s",
                   joined));
    }

    // (c) exit 0 with a FAIL row — the two halves of the Python file
    //     disagreeing. Silent under a bare status check.
    {
        auto p = judgeOfflineRun(OfflineRun(0, good ~ "FAIL: something\n"));
        assert(p.length >= 1 && p.join("\n").canFind("exited 0 but printed"),
            "a FAIL row under status 0 must be caught: " ~ p.join("\n"));
    }

    // (d) the run never reached its end.
    {
        immutable truncated = good[0 .. good.length - (kTerminalLine.length + 2)];
        auto p = judgeOfflineRun(OfflineRun(0, truncated));
        assert(p.length >= 1 && p.join("\n").canFind("terminal line"),
            "a truncated run must be caught: " ~ p.join("\n"));
    }

    // (e) each phase marker, one at a time: the judge must name the ONE that
    //     went missing, not report a shortfall.
    foreach (m; kPhaseMarkers)
    {
        string reduced;
        foreach (line; good.splitLines)
            if (!line.canFind(m))
                reduced ~= line ~ "\n";
        auto p = judgeOfflineRun(OfflineRun(0, reduced));
        immutable joined = p.join("\n");
        assert(joined.canFind(m),
            format("removing the phase %(%s%) from a run did not make the "
                 ~ "judge name it. Problems were:\n%s", [m], joined));
    }

    // (f) the ok-row floor: a run that exits 0, prints the terminal line and
    //     every marker, and checks nothing else. This is exactly the shape an
    //     early `sys.exit(0)` produces, and status alone calls it a pass.
    {
        string s;
        foreach (m; kPhaseMarkers)
            s ~= "ok  : " ~ m ~ "\n";
        s ~= kTerminalLine ~ "\n";
        auto p = judgeOfflineRun(OfflineRun(0, s));
        immutable joined = p.join("\n");
        assert(joined.canFind("structural floor"),
            "a run with almost no checks must trip the ok-row floor: " ~ joined);
        assert(joined.canFind("provenance_manifest.json entry"),
            "it must ALSO trip the manifest pin — the two failures have "
          ~ "different causes and a reader needs both: " ~ joined);
    }

    // (g) the manifest floor on its own: a full run whose manifest block has
    //     been quietly dropped. Total rows stay respectable, so only the
    //     manifest term can catch this.
    {
        string s;
        foreach (m; kPhaseMarkers)
            s ~= "ok  : " ~ m ~ "\n";
        foreach (i; 0 .. 120)
            s ~= format("ok  : unrelated check %d\n", i);
        s ~= kTerminalLine ~ "\n";
        auto p = judgeOfflineRun(OfflineRun(0, s));
        immutable joined = p.join("\n");
        assert(!joined.canFind("structural floor"),
            "this cell must isolate the MANIFEST term — the ok-row floor "
          ~ "fired too, so it proves nothing: " ~ joined);
        assert(joined.canFind("provenance_manifest.json entry"),
            "a run with no manifest rows must trip the manifest pin: " ~ joined);
        assert(joined.canFind("DELETED"),
            "and it must say which DIRECTION the record moved: " ~ joined);
    }

    // (h) the other direction of the same pin: one row too many. This is the
    //     "the manifest must list every fixture" reading task 3140 rejected,
    //     and it would arrive silently under a floor. Deleting a row and
    //     adding one are different defects and get different sentences.
    {
        immutable extra = good ~ "ok  : manifest entry 'stem_new' lints clean "
                               ~ "via make_provenance ()\n";
        auto p = judgeOfflineRun(OfflineRun(0, extra));
        immutable joined = p.join("\n");
        assert(joined.canFind("provenance_manifest.json entry")
               && joined.canFind("ADDED"),
            "an ADDED manifest row must be caught and named as an addition: "
          ~ joined);
    }
}

// ---------------------------------------------------------------------------
// 3 — THE PLUMBING CARRIES A FAILURE. Needs only a `python3`.
//
// Unittest 2 judges values this module made up. This one proves the values
// unittest 1 judges really come from a subprocess: that a non-zero exit and
// the text on its stdout both arrive intact. Without it, a `runPython` that
// dropped the status (or the output) would leave unittest 1 permanently green
// — the "the run never happened" failure mode, one level down.
// ---------------------------------------------------------------------------
unittest
{
    if (!haveReachablePythonForPlumbing())
    {
        stderr.writeln("[provenance_offline_lane] SKIPPED the plumbing witness: "
                     ~ "no usable `" ~ kPython ~ "` on PATH. unittest 2 still "
                     ~ "proved the judge; what is unproven here is only that a "
                     ~ "subprocess failure reaches it.");
        return;
    }

    immutable stem = buildPath(tempDir(),
        format("vibe3d_prov_lane_%d", thisProcessID));

    // (a) a script that fails, naming a file. Status AND text must arrive.
    {
        immutable path = stem ~ "_fail.py";
        write(path, "import sys\n"
                  ~ "print(\"FAIL: tests/fixtures/named_by_the_run.json is bare\")\n"
                  ~ "sys.exit(1)\n");
        scope (exit) { if (exists(path)) remove(path); }

        immutable run = runPython(kPython, path);
        assert(run.status == 1,
            format("the subprocess exit status did not reach the caller: got "
                 ~ "%d, expected 1. unittest 1's judgement of the real file "
                 ~ "would be blind to a failure.", run.status));

        auto p = judgeOfflineRun(run);
        immutable joined = p.join("\n");
        assert(joined.canFind("named_by_the_run.json"),
            format("the failing row's FILE NAME did not survive the trip from "
                 ~ "the subprocess to the assert message. That name is the "
                 ~ "whole point of the gate (backlog 2970's mutation clause). "
                 ~ "Problems were:\n%s", joined));
    }

    // (b) a script that exits 0 having checked nothing — the vacuous pass.
    {
        immutable path = stem ~ "_vacuous.py";
        write(path, "print(\"" ~ kTerminalLine ~ "\")\n");
        scope (exit) { if (exists(path)) remove(path); }

        immutable run = runPython(kPython, path);
        assert(run.status == 0, "the vacuous script must exit 0 — that is its point");

        auto p = judgeOfflineRun(run);
        assert(p.length >= 1,
            "a script that exits 0 and prints only the terminal line was "
          ~ "accepted. `status == 0` is then the whole gate, and an emptied "
          ~ "Python file would pass it.");
    }
}

/// Named apart from the unittest so the skip reads as a decision, not a
/// swallowed exception.
private bool haveReachablePythonForPlumbing()
{
    return haveReachablePython(kPython);
}
