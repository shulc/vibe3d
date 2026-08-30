// The nightly-freshness detector (task 2040): a check that must redden on a
// FAKED-OLD last-run date and stay green on a fresh one — reading the API
// and only printing the age is explicitly not good enough (the card's own
// words: that is green whether the run is stale OR missing, which is the
// exact defect this task exists to remove).
//
// Same black-box discipline as `run_test_space_preflight_test.d` (task
// 2080): `tools/ci/nightly_freshness.d` is a standalone rdmd script, never
// imported as a module, so this drives it as a subprocess through its own
// CLI seams — the same shape `run_test.d --check-space PATH
// --space-floor-mib N` uses: the comparison is REAL, only the input is
// supplied under test control.
//
//   1. `--last-run-iso` / `--now-iso`: the offline seam. THE witness the
//      card demands, both directions, deterministic, no network — this is
//      the block that must never go quietly green.
//   2. `--print-threshold`: the exact-term formula (cron period x tolerated
//      misses + drift buffer), pure, no network.
//   3. `--fake-no-runs`: a workflow that has NEVER run at all is a real,
//      distinct answer (not a parse error, not fresh-by-omission) and must
//      read as missing like any other absence.
//   4. A graceful-skip LIVE smoke test: a real `gh run list` call against
//      this repository's own `origin` remote, through whatever proxy this
//      host is configured with (no bypass — see the tool's own header).
//      Skips loudly (not silently) when `gh`/network/auth is unavailable,
//      same discipline as the unshare/tmpfs witness in
//      `run_test_space_preflight_test.d` skipping when unprivileged mount
//      namespaces are unavailable. This block cannot assert a fixed
//      pass/fail verdict (the real repository's freshness changes daily,
//      and other lanes' worktrees share it) — it asserts the MECHANISM
//      produced a sane, non-negative age, which is enough to prove the
//      live path is wired at all without making `dub test` depend on the
//      real nightly-perf lane's actual health.
//
// TASK 2580 (blocks 5-9 below) — figure freshness alone has a hole: a manual
// `workflow_dispatch` resets block-1's clock even though the SCHEDULE itself
// may have stopped delivering entirely (the 2026-08-28 incident: three
// manual dispatches on one afternoon kept term 1 reading "fresh" while cron
// had not fired in over a day). Term 2 (`checkScheduleHealth`, its own
// `--schedule-run-isos`/`--schedule-*` seams) answers that second question,
// filtered to `event == "schedule"` only, so a dispatch cannot reset it.
//
//   5. THE WITNESS: the exact masking scenario, reproduced from real
//      timestamps — term 1 stays green off a manual dispatch while term 2
//      reddens on the SAME instant because the schedule itself is stale.
//      Both directions (masked-and-caught, then genuinely-fresh), both
//      terms' messages quoted, plus the default REPORT-ONLY exit code next
//      to the GATED one to prove the "gate or report" flag actually moves
//      only what it claims to.
//   6. Term 2's own boundary (`<=`, not `<`) — same discipline as block 1's.
//   7. `--fake-no-schedule-runs`: a cron that has never delivered at all is
//      its own distinct answer for term 2, independent of term 1's own
//      `--fake-no-runs`.
//   8. `--print-schedule-threshold`: term 2's own exact-term formula, and
//      proof term 1's `--print-threshold` does NOT move when only term 2's
//      dial changes (the two thresholds are independently named, not
//      aliases of one constant).
//   9. Drift as a quantity (task 2580, item 2): the six real data points
//      the card names reproduced through the CLI, asserting the exact
//      median/max the tool prints beside term 2's verdict.
// EVERY BLOCK BUT 4 IS OFFLINE, AND STAYS OFFLINE ONLY IF IT SILENCES ALL
// THREE TERMS. Each term has its own fetch and its own offline seam
// (`--last-run-iso`/`--fake-no-runs`, `--schedule-run-isos`/
// `--fake-no-schedule-runs`, `--verdict-run-isos`/`--fake-no-verdict-runs`),
// and ONE unsilenced term is enough to make the tool resolve OWNER/REPO from
// `origin` and call `gh`. That resolution is not merely slow — it FAILS, with
// "could not resolve OWNER/REPO", in any tree whose `origin` is absent or not
// a github.com URL (exported tarball, mirror, a worktree whose remote is
// named otherwise), so an unsilenced term turns a logic test into a red on
// the checkout's remote name. Blocks 1, 3, 5, 6, 7 and 9 therefore carry a
// seam for all three terms; only block 4 deliberately goes out. The seams do
// not blunt what those blocks test: terms 2 and 3 are REPORT-ONLY unless
// --gate-schedule-health / --gate-verdict-freshness is passed, so the exit
// codes those blocks assert on are still produced by the term under test.
module tests.unit.nightly_freshness_test;

import std.conv        : to;
import std.exception   : enforce;
import std.file        : exists;
import std.path        : buildPath, dirName;
import std.process     : Config, execute, environment;
import std.string      : indexOf, strip;

private enum repoRoot   = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum toolPath   = buildPath(repoRoot, "tools", "ci", "nightly_freshness.d");

private struct Run { int status; string output; }

private Run rdmd(string[] rest)
{
    string[string] env;
    foreach (k, v; environment.toAA) env[k] = v;
    auto r = execute(["rdmd", toolPath] ~ rest, env, Config.none, size_t.max, repoRoot);
    return Run(r.status, r.output);
}

// ---------------------------------------------------------------------------
// 1. THE WITNESS: the offline seam, both directions, deterministic.
// ---------------------------------------------------------------------------
unittest
{
    enforce(exists(toolPath), toolPath ~ " not found — repo root misderived");

    // GREEN: last run 7 hours ago against the default (1-missed-night)
    // threshold — nowhere near stale. `--fake-no-schedule-runs` (task 2580)
    // and `--fake-no-verdict-runs` (term 3) keep this block's original
    // no-network guarantee: without them, term 2 / term 3 would fall through
    // to a REAL `gh run list` call since no schedule- or verdict-side offline
    // seam is otherwise given here, quietly reintroducing a network dependency
    // this block never had before — and, worse, a dependency on the REMOTE
    // NAME: `defaultRepoSlug()` refuses outright in any tree whose `origin`
    // is not a github.com URL (an exported tarball, a mirror, a worktree with
    // a differently-named remote), so the block reddened there with
    // "could not resolve OWNER/REPO" and not with anything it is about.
    // Both seams are REPORT-ONLY for their own terms, so they silence the
    // fetch WITHOUT touching the exit code this block asserts on: term 1 is
    // the only term that gates unless --gate-schedule-health /
    // --gate-verdict-freshness is passed, and this block passes neither.
    {
        auto r = rdmd([
            "--last-run-iso", "2026-08-28T02:00:00Z",
            "--now-iso",       "2026-08-28T09:00:00Z",
            "--fake-no-schedule-runs",
            "--fake-no-verdict-runs",
        ]);
        assert(r.status == 0, "a 7h-old run was refused as stale:\n" ~ r.output);
        assert(r.output.indexOf("fresh") >= 0,
            "a fresh run's message does not say \"fresh\": " ~ r.output);
    }

    // RED: THE FAKED DATE THE CARD SPECIFIES. Last run two days plus change
    // ago (this is literally the card's own incident: last real run
    // 2026-08-26T02:09Z, read as current on 2026-08-27/28). Must exit
    // non-zero and say MISSING, not merely print a number.
    {
        auto r = rdmd([
            "--last-run-iso", "2026-08-26T02:09:00Z",
            "--now-iso",       "2026-08-28T09:00:00Z",
            "--fake-no-schedule-runs",
            "--fake-no-verdict-runs",
        ]);
        assert(r.status == 1, "a stale run (task 2040's own incident date) did "
            ~ "not redden — exit " ~ r.status.to!string ~ ":\n" ~ r.output);
        assert(r.output.indexOf("MISSING") >= 0,
            "a stale run's message does not say MISSING: " ~ r.output);
        // The anti-vacuity check this whole task is about: a checker that
        // ONLY prints the age is exactly the thing the card refuses. Prove
        // this one does not merely report — it also names what to do next.
        assert(r.output.indexOf("Check delivery") >= 0,
            "a stale verdict must say what to check, not just the number: " ~ r.output);
    }

    // Exact boundary: threshold hours, `<=` not `<` — proven against a real
    // formula-derived threshold, not a hand-picked one.
    {
        // threshold for missed=1 is 24 + 12 = 36h (see the tool's own
        // kCronPeriodHours / kDriftBufferHours).
        auto atBoundary = rdmd([
            "--last-run-iso", "2026-08-27T00:00:00Z",
            "--now-iso",       "2026-08-28T12:00:00Z",  // exactly 36h
            "--fake-no-schedule-runs",
            "--fake-no-verdict-runs",
        ]);
        assert(atBoundary.status == 0, "exactly-at-threshold was refused:\n" ~ atBoundary.output);

        auto pastBoundary = rdmd([
            "--last-run-iso", "2026-08-26T23:59:59Z",
            "--now-iso",       "2026-08-28T12:00:00Z",  // 36h + 1s
            "--fake-no-schedule-runs",
            "--fake-no-verdict-runs",
        ]);
        assert(pastBoundary.status == 1,
            "one second past threshold was NOT refused:\n" ~ pastBoundary.output);
    }
}

// ---------------------------------------------------------------------------
// 2. --print-threshold: the exact-term formula, pure, no network.
// ---------------------------------------------------------------------------
unittest
{
    // Default: 1 tolerated miss * 24h cron period + 12h drift buffer.
    {
        auto r = rdmd(["--print-threshold"]);
        assert(r.status == 0, r.output);
        assert(r.output.strip == "36.0", "default threshold changed without this test "
            ~ "being updated — got: " ~ r.output.strip);
    }
    // Tolerating 2 consecutive misses: exactly double the period term.
    {
        auto r = rdmd(["--print-threshold", "--missed-nights-tolerated", "2"]);
        assert(r.status == 0, r.output);
        assert(r.output.strip == "60.0", "got: " ~ r.output.strip);
    }
    // The formula moves with its inputs, not just with the constant it
    // starts from — proves this is a computation, not a memorized string.
    {
        auto r = rdmd(["--print-threshold", "--cron-period-hours", "10",
                        "--drift-buffer-hours", "1", "--missed-nights-tolerated", "3"]);
        assert(r.status == 0, r.output);
        assert(r.output.strip == "31.0", "got: " ~ r.output.strip);
    }
}

// ---------------------------------------------------------------------------
// 3. A never-ran workflow is treated as missing, not as an error and not as
//    fresh — a real, distinct answer this tool must not collapse into
//    either neighbor.
// ---------------------------------------------------------------------------
unittest
{
    // --fake-no-runs: no network, no repo needed — drives the "zero runs
    // ever" branch directly. A workflow that has genuinely never fired is a
    // REAL, distinct answer (not a parse error, not "fresh" by omission),
    // and it must read as stale/missing like any other absence.
    // --fake-no-schedule-runs (task 2580) and --fake-no-verdict-runs (term 3)
    // keep this block network-free too: --fake-no-runs alone only silences
    // TERM 1's fetch, and the other two would still resolve OWNER/REPO and
    // call out. Both are report-only, so the exit-1 asserted below is still
    // term 1's own verdict.
    auto r = rdmd(["--fake-no-runs", "--fake-no-schedule-runs",
                   "--fake-no-verdict-runs"]);
    assert(r.status == 1, "a workflow with zero recorded runs was not treated "
        ~ "as missing:\n" ~ r.output);
    assert(r.output.indexOf("NO recorded runs") >= 0,
        "the zero-runs verdict does not say so plainly: " ~ r.output);
}

// ---------------------------------------------------------------------------
// 4. LIVE smoke test (graceful skip): a real `gh run list` call, through
//    whatever proxy is configured, against this checkout's own `origin`.
//    Proves the wiring, not a fixed verdict — the real lane's freshness
//    changes daily and this test must not become a second, accidental
//    nightly-lane gate. Since task 2580, the SAME live call also exercises
//    term 2 (it shares one `gh run list` fetch with term 1 — see the tool's
//    own header) — its report-only-by-default verdict is printed into
//    `r.output` but, deliberately, plays no part in the `r.status` assertion
//    below, for the same "not a fixed verdict" reason as term 1.
// ---------------------------------------------------------------------------
unittest
{
    import std.stdio : stderr;

    auto probe = execute(["gh", "--version"]);
    if (probe.status != 0) {
        stderr.writeln("nightly_freshness_test: SKIPPED live smoke — `gh` is not "
            ~ "on PATH on this host. The offline-seam block above already proved "
            ~ "the comparison/witness; this block additionally proves the real "
            ~ "fetch path where the host permits it.");
        return;
    }

    auto r = rdmd([]);  // exactly how ci.yaml would invoke it: no flags at all
    if (r.status == 2) {
        stderr.writeln("nightly_freshness_test: SKIPPED live smoke — the live "
            ~ "fetch could not complete on this host (no auth / no network / "
            ~ "proxy unreachable from this sandbox), reported as exit 2 "
            ~ "(distinct from a stale verdict) exactly as designed:\n" ~ r.output);
        return;
    }

    // Whatever the verdict, it must be backed by a real, non-negative,
    // finite age it actually computed — not a default/fallback number.
    assert(r.output.indexOf("last ran") >= 0 && r.output.indexOf("h ago") >= 0,
        "live default invocation did not report a real computed age:\n" ~ r.output);
    assert(r.status == 0 || r.status == 1,
        "live default invocation exited outside {fresh, stale}: " ~ r.status.to!string
      ~ "\n" ~ r.output);
}

// ---------------------------------------------------------------------------
// 5. TASK 2580 — THE WITNESS: the exact masking scenario, from real captured
//    timestamps. A manual `workflow_dispatch` at 2026-08-27T13:02Z keeps
//    term 1 fresh; the last SCHEDULE run (2026-08-27T10:10Z) ages past its
//    own, independent threshold at the same instant. Both directions, both
//    terms' messages quoted, plus report-only vs. gated exit codes.
// ---------------------------------------------------------------------------
unittest
{
    enum dispatchIso = "2026-08-27T13:02:00Z";  // resets term 1's clock
    enum scheduleIso = "2026-08-27T10:10:00Z";  // does NOT reset term 2's clock
    enum maskedNowIso = "2026-08-29T00:00:00Z"; // 34.97h since dispatch, 37.83h since schedule

    // REPORT-ONLY (default): term 1 reads fresh, term 2 reads CRON STOPPED,
    // in the SAME invocation — and the process still exits 0, because term
    // 2 does not gate on its own by default (task 2580, item 3).
    {
        auto r = rdmd([
            "--last-run-iso", dispatchIso,
            "--schedule-run-isos", scheduleIso,
            "--now-iso", maskedNowIso,
            "--fake-no-verdict-runs",
        ]);
        assert(r.status == 0, "default (report-only) must not fail the process "
            ~ "on a stale schedule alone:\n" ~ r.output);
        assert(r.output.indexOf("— fresh.") >= 0,
            "term 1 did not read fresh off the manual dispatch:\n" ~ r.output);
        assert(r.output.indexOf("CRON STOPPED") >= 0,
            "term 2 was fooled by the fresh manual dispatch — the exact hole "
          ~ "task 2580 exists to close:\n" ~ r.output);
    }

    // GATED: the SAME masked scenario, but --gate-schedule-health folds
    // term 2 into the exit code — now it must redden even though term 1
    // alone is fine. Proves the gate/report choice really is the one flag
    // the header promises, not a deeper code path.
    {
        auto r = rdmd([
            "--last-run-iso", dispatchIso,
            "--schedule-run-isos", scheduleIso,
            "--now-iso", maskedNowIso,
            "--gate-schedule-health",
            "--fake-no-verdict-runs",
        ]);
        assert(r.status == 1, "gated mode must redden on a stopped schedule "
            ~ "even though term 1 (any event) is fresh:\n" ~ r.output);
    }

    // REVERSE DIRECTION: shortly after a genuine schedule delivery, both
    // terms agree and are both fresh — proves the hole closed here is
    // specifically "manual dispatch masks a broken schedule", not "the two
    // terms always disagree".
    {
        auto r = rdmd([
            "--last-run-iso", dispatchIso,
            "--schedule-run-isos", scheduleIso,
            "--now-iso", "2026-08-27T14:00:00Z",
            "--fake-no-verdict-runs",
        ]);
        assert(r.status == 0, r.output);
        assert(r.output.indexOf("— fresh.") >= 0, r.output);
        assert(r.output.indexOf("— delivering.") >= 0,
            "term 2 did not read delivering shortly after a genuine schedule run:\n"
          ~ r.output);
    }
}

// ---------------------------------------------------------------------------
// 6. Term 2's own boundary: exactly at the threshold is still delivering
//    (<=, not <); one second past is CRON STOPPED. Same discipline as
//    block 1's term-1 boundary, over the independently-derived term-2
//    threshold (36.0h by default — see block 8).
// ---------------------------------------------------------------------------
unittest
{
    auto atBoundary = rdmd([
        "--last-run-iso", "2026-08-27T12:00:00Z",   // term 1 not under test here
        "--schedule-run-isos", "2026-08-26T00:00:00Z",
        "--now-iso", "2026-08-27T12:00:00Z",         // exactly 36h
        "--fake-no-verdict-runs",
    ]);
    assert(atBoundary.output.indexOf("— delivering.") >= 0,
        "exactly-at-threshold schedule run was refused:\n" ~ atBoundary.output);

    auto pastBoundary = rdmd([
        "--last-run-iso", "2026-08-27T12:00:00Z",
        "--schedule-run-isos", "2026-08-25T23:59:59Z",
        "--now-iso", "2026-08-27T12:00:00Z",         // 36h + 1s
        "--fake-no-verdict-runs",
    ]);
    assert(pastBoundary.output.indexOf("CRON STOPPED") >= 0,
        "one second past term 2's threshold was NOT refused:\n" ~ pastBoundary.output);
}

// ---------------------------------------------------------------------------
// 7. `--fake-no-schedule-runs`: a schedule that has never delivered at all
//    is its own distinct answer for term 2 (not a parse error, not "fresh"
//    by omission), independent of term 1's own `--fake-no-runs`.
// ---------------------------------------------------------------------------
unittest
{
    auto r = rdmd([
        "--fake-no-schedule-runs",
        "--fake-no-verdict-runs",
        "--last-run-iso", "2026-08-28T00:00:00Z",
        "--now-iso",       "2026-08-28T01:00:00Z",
    ]);
    assert(r.status == 0, "report-only default: a missing schedule history "
        ~ "must not fail the process on its own:\n" ~ r.output);
    assert(r.output.indexOf("NO recorded schedule-triggered runs") >= 0,
        "the zero-schedule-runs verdict does not say so plainly: " ~ r.output);

    auto rGated = rdmd([
        "--fake-no-schedule-runs",
        "--fake-no-verdict-runs",
        "--last-run-iso", "2026-08-28T00:00:00Z",
        "--now-iso",       "2026-08-28T01:00:00Z",
        "--gate-schedule-health",
    ]);
    assert(rGated.status == 1, "gated mode must redden when the schedule has "
        ~ "never delivered at all:\n" ~ rGated.output);
}

// ---------------------------------------------------------------------------
// 8. `--print-schedule-threshold`: term 2's own exact-term formula — and
//    proof term 1's `--print-threshold` does NOT move when only term 2's
//    dial changes (two independently-named thresholds, not one constant
//    wearing two flags).
// ---------------------------------------------------------------------------
unittest
{
    {
        auto r = rdmd(["--print-schedule-threshold"]);
        assert(r.status == 0, r.output);
        assert(r.output.strip == "36.0", "default schedule-health threshold "
            ~ "changed without this test being updated — got: " ~ r.output.strip);
    }
    {
        auto r = rdmd(["--print-schedule-threshold", "--schedule-missed-nights-tolerated", "2"]);
        assert(r.status == 0, r.output);
        assert(r.output.strip == "60.0", "got: " ~ r.output.strip);
    }
    // Independence: term 1's threshold must be untouched by term 2's dial.
    {
        auto r = rdmd(["--print-threshold", "--schedule-missed-nights-tolerated", "5"]);
        assert(r.status == 0, r.output);
        assert(r.output.strip == "36.0", "term 1's threshold moved when only "
            ~ "term 2's dial changed — they must be independent: " ~ r.output.strip);
    }
    // And the reverse: term 2's threshold untouched by term 1's dial.
    {
        auto r = rdmd(["--print-schedule-threshold", "--missed-nights-tolerated", "5"]);
        assert(r.status == 0, r.output);
        assert(r.output.strip == "36.0", "term 2's threshold moved when only "
            ~ "term 1's dial changed: " ~ r.output.strip);
    }
}

// ---------------------------------------------------------------------------
// 9. Drift as a quantity, not an anecdote (task 2580, item 2): the card's
//    own six real data points (02:01, 02:08, 02:10, 02:04, 02:09, 10:10
//    against the 00:30 UTC target), reproduced through the CLI. Median
//    98.5min, max 580.0min — the exact figures the tool must print beside
//    term 2's verdict, matching `computeDriftStats`'s own inline unittest
//    in the tool file.
// ---------------------------------------------------------------------------
unittest
{
    auto r = rdmd([
        "--schedule-run-isos",
        "2026-08-27T10:10:00Z,2026-08-26T02:09:00Z,2026-08-25T02:04:00Z," ~
        "2026-08-24T02:08:00Z,2026-08-23T02:10:00Z,2026-08-22T02:01:00Z",
        "--now-iso",       "2026-08-27T11:00:00Z",
        "--fake-no-runs",  // term 1 irrelevant to this assertion; keep fully offline
        "--fake-no-verdict-runs",   // and term 3, same reason
    ]);
    assert(r.output.indexOf("median 98.5min") >= 0,
        "drift median wrong or missing:\n" ~ r.output);
    assert(r.output.indexOf("max 580.0min") >= 0,
        "drift max wrong or missing:\n" ~ r.output);
    assert(r.output.indexOf("over 6 schedule-triggered runs") >= 0,
        "drift sample count wrong or missing:\n" ~ r.output);
    assert(r.output.indexOf("target 00:30 UTC") >= 0,
        "drift target time-of-day missing:\n" ~ r.output);
}

// ---------------------------------------------------------------------------
// 10. TERM 3 (2026-08-30) — THE WITNESS: a lane that DELIVERS and MEASURES
//     NOTHING. This is the block that must never go quietly green, and its
//     whole force is that terms 1 and 2 are asserted GREEN in the same
//     invocation, off the same timestamps, at the same instant.
//
//     The state is real, not constructed: on 2026-08-30 `nightly-tsan`'s
//     cron had delivered every night, so a run existed (term 1 fresh) and it
//     was a `schedule` run (term 2 delivering) — and every one of them
//     refused at its window guard before a single test executed, so the last
//     run that CONCLUDED success was 2026-08-25. Extending terms 1 and 2 to
//     this lane and stopping there would have added two greens that cannot
//     come out differently on the one failure on record.
// ---------------------------------------------------------------------------
unittest
{
    // The five refused deliveries, newest first, and the last night that
    // actually produced a verdict behind them.
    enum refused = "2026-08-29T19:37:00Z,2026-08-28T19:02:00Z,"
                 ~ "2026-08-27T01:20:00Z,2026-08-26T00:52:00Z,2026-08-25T17:04:00Z";
    enum lastVerdict = "2026-08-25T17:04:00Z";
    enum now = "2026-08-30T04:00:00Z";

    auto r = rdmd([
        "--workflow", "tsan.yaml", "--workflow-label", "nightly-tsan",
        "--cron-target-utc", "17:00",
        "--last-run-iso",     "2026-08-29T19:37:00Z",
        "--schedule-run-isos", refused,
        "--verdict-run-isos",  lastVerdict,
        "--now-iso",           now,
    ]);
    assert(r.output.indexOf("last ran 8.4h ago") >= 0,
        "term 1 must be GREEN here — if it is not, this block is no longer "
        ~ "the discriminating cell it claims to be:\n" ~ r.output);
    assert(r.output.indexOf("— delivering.") >= 0,
        "term 2 must be GREEN here, same reason:\n" ~ r.output);
    assert(r.output.indexOf("LANE SILENT") >= 0,
        "term 3 must REDDEN on a lane that delivers and measures nothing — "
        ~ "this is the entire point of the term:\n" ~ r.output);
    assert(r.output.indexOf("last produced a VERDICT 106.9h ago") >= 0,
        "term 3's age is wrong or missing:\n" ~ r.output);
    assert(r.status == 0, "report-only by default: term 3 must not move the "
        ~ "exit code on its own (same owner decision as terms 1 and 2):\n" ~ r.output);

    // The gate flag, and only the gate flag, moves it.
    auto rGated = rdmd([
        "--workflow", "tsan.yaml", "--workflow-label", "nightly-tsan",
        "--last-run-iso",     "2026-08-29T19:37:00Z",
        "--schedule-run-isos", refused,
        "--verdict-run-isos",  lastVerdict,
        "--now-iso",           now,
        "--gate-verdict-freshness",
    ]);
    assert(rGated.status == 1, "gated mode must redden on a silent lane:\n" ~ rGated.output);

    // REVERSE DIRECTION — without this, "LANE SILENT" could be unconditional
    // and every assertion above would still pass. A lane that produced a
    // verdict last night is green on all three terms.
    auto rOk = rdmd([
        "--workflow", "tsan.yaml", "--workflow-label", "nightly-tsan",
        "--last-run-iso",     "2026-08-29T17:30:00Z",
        "--schedule-run-isos", "2026-08-29T17:30:00Z",
        "--verdict-run-isos",  "2026-08-29T17:30:00Z",
        "--now-iso",           now,
        "--gate-verdict-freshness",
    ]);
    assert(rOk.status == 0, "a lane that measured last night must stay green "
        ~ "even under --gate-verdict-freshness:\n" ~ rOk.output);
    assert(rOk.output.indexOf("— measuring.") >= 0, rOk.output);
    assert(rOk.output.indexOf("LANE SILENT") < 0,
        "term 3 reddened on a healthy lane — it is not discriminating, it is "
        ~ "just always red:\n" ~ rOk.output);

    // THE NUMBER THIS THRESHOLD IS ARGUED AGAINST. The measured MAXIMUM
    // schedule delivery drift is 693.6min = 11.56h (live run of this tool,
    // 2026-08-30). A lane delivering that late and then producing a verdict
    // must stay GREEN, or term 3 would be reddening on lateness rather than
    // on silence — and would then fire on exactly the nights edit 1 exists
    // to let through.
    auto rDrift = rdmd([
        "--workflow", "tsan.yaml", "--workflow-label", "nightly-tsan",
        "--last-run-iso",     "2026-08-29T04:33:36Z",
        "--schedule-run-isos", "2026-08-29T04:33:36Z",
        "--verdict-run-isos",  "2026-08-29T04:33:36Z",   // 17:00 + 693.6min
        "--now-iso",           now,
        "--gate-verdict-freshness",
    ]);
    assert(rDrift.status == 0, "the worst measured delivery drift must not "
        ~ "trip term 3:\n" ~ rDrift.output);
}

// ---------------------------------------------------------------------------
// 11. `--print-verdict-threshold` and its independence from the other two
//     dials — same discipline as block 8. Three named thresholds, three
//     dials, no aliasing.
// ---------------------------------------------------------------------------
unittest
{
    {
        auto r = rdmd(["--print-verdict-threshold"]);
        assert(r.status == 0, r.output);
        assert(r.output.strip == "36.0", "got: " ~ r.output.strip);
    }
    {
        auto r = rdmd(["--print-verdict-threshold", "--verdict-missed-nights-tolerated", "2"]);
        assert(r.status == 0, r.output);
        assert(r.output.strip == "60.0", "got: " ~ r.output.strip);
    }
    // Term 3's dial must move NEITHER of the other two thresholds...
    {
        auto r = rdmd(["--print-threshold", "--verdict-missed-nights-tolerated", "5"]);
        assert(r.output.strip == "36.0", "term 1's threshold moved when only "
            ~ "term 3's dial changed: " ~ r.output.strip);
    }
    {
        auto r = rdmd(["--print-schedule-threshold", "--verdict-missed-nights-tolerated", "5"]);
        assert(r.output.strip == "36.0", "term 2's threshold moved when only "
            ~ "term 3's dial changed: " ~ r.output.strip);
    }
    // ...and neither of theirs must move term 3's.
    {
        auto r = rdmd(["--print-verdict-threshold", "--missed-nights-tolerated", "5",
                       "--schedule-missed-nights-tolerated", "5"]);
        assert(r.output.strip == "36.0", "term 3's threshold moved when only "
            ~ "the other two dials changed: " ~ r.output.strip);
    }
}

// ---------------------------------------------------------------------------
// 12. `--fake-no-verdict-runs`: a lane that has NEVER produced a successful
//     scheduled run is its own distinct answer, not a parse error and not
//     "measuring" by omission — mirroring block 7 for term 3.
// ---------------------------------------------------------------------------
unittest
{
    auto r = rdmd([
        "--fake-no-verdict-runs",
        "--last-run-iso",      "2026-08-28T00:00:00Z",
        "--schedule-run-isos", "2026-08-28T00:00:00Z",
        "--now-iso",           "2026-08-28T01:00:00Z",
    ]);
    assert(r.status == 0, "report-only default:\n" ~ r.output);
    assert(r.output.indexOf("NO successful schedule-triggered run") >= 0,
        "the never-measured verdict does not say so plainly: " ~ r.output);

    auto rGated = rdmd([
        "--fake-no-verdict-runs",
        "--last-run-iso",      "2026-08-28T00:00:00Z",
        "--schedule-run-isos", "2026-08-28T00:00:00Z",
        "--now-iso",           "2026-08-28T01:00:00Z",
        "--gate-verdict-freshness",
    ]);
    assert(rGated.status == 1, "gated mode must redden when the lane has "
        ~ "never produced a verdict at all:\n" ~ rGated.output);
}
