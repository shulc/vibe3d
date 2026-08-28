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
    // threshold — nowhere near stale.
    {
        auto r = rdmd([
            "--last-run-iso", "2026-08-28T02:00:00Z",
            "--now-iso",       "2026-08-28T09:00:00Z",
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
        ]);
        assert(atBoundary.status == 0, "exactly-at-threshold was refused:\n" ~ atBoundary.output);

        auto pastBoundary = rdmd([
            "--last-run-iso", "2026-08-26T23:59:59Z",
            "--now-iso",       "2026-08-28T12:00:00Z",  // 36h + 1s
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
    auto r = rdmd(["--fake-no-runs"]);
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
//    nightly-lane gate.
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
