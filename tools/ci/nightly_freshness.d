#!/usr/bin/env rdmd
/**
 * tools/ci/nightly_freshness.d — is the nightly-perf lane actually running,
 * or just quiet? (task 2040)
 *
 * THE INCIDENT (2026-08-27, doc/tasks/work/2040-missed-nightly-is-invisible.md).
 * `nightly-perf`'s run list shows "latest = failure" identically whether last
 * night was red or last night never happened at all — GitHub's `schedule`
 * trigger is documented best-effort and can silently drop a delivery under
 * load. On the night this was found, the last completed run was from the
 * PREVIOUS night; a fix that had since landed on `main` was being judged
 * against a two-day-stale tree, and nothing said so.
 *
 * A corroborating signal was on record and unread: against `perf.yaml`'s
 * `cron: '30 0 * * *'`, four consecutive nights actually started at 02:04,
 * 02:08, 02:09 and 02:10 — 94 to 100 minutes of systematic drift. Re-measured
 * live while building this tool (2026-08-28, via `gh run list --workflow
 * perf.yaml`, real API, real proxy): 08-27's `schedule`-triggered run fired
 * at 10:10:39Z against the same 00:30 target — nearly ten hours late, and it
 * was NOT a missed night, the delivery just took that long. A checker sized
 * to the four-night sample alone (drift <= 100 min) would have READ AS RED
 * for several hours before that run ever arrived — the exact false-positive
 * shape the card warns a witness-less checker produces in the opposite
 * direction. That single data point is why this tool's default drift buffer
 * is 12h, not 2h — see `kDriftBufferHours` below.
 *
 * WHAT THIS CHECKS: the age of the most recent run of a workflow (any event,
 * any conclusion — an in-progress or even a failed run still proves delivery
 * happened; this tool is silent on whether the run was GOOD, only on whether
 * one occurred at all. Whether it passed is `doc/tasks/work/1840-...`'s job).
 *
 * WHERE THIS LIVES AND WHY (the card's three options, one chosen):
 *   - a step in a MORE FREQUENTLY RUNNING, non-schedule-triggered lane
 *     (`ci.yaml`, on `push`/`pull_request`) — CHOSEN. `push`/`pull_request`
 *     are webhook-delivered, not best-effort `schedule` cron delivery, so
 *     this checker does not inherit the exact defect it is built to catch.
 *     Given this repository's commit cadence, ci.yaml runs many times a day;
 *     the residual risk (no pushes for a long stretch => this checker is
 *     also quiet) is real but is driven by actual developer activity, not by
 *     GitHub's queue depth on an unrelated host.
 *   - a timer on the runner host itself — REJECTED. The card names why: it
 *     is silent exactly when the host is off, which is exactly the state
 *     that loses a night in the first place. A detector that shares its
 *     failure mode with the thing it detects is not a detector.
 *   - `workflow_dispatch` from another scheduled workflow instead of
 *     `schedule` — REJECTED. It moves the delivery problem, it does not
 *     remove it: the dispatching workflow is itself `schedule`-triggered and
 *     inherits the same best-effort delivery GitHub documents for `cron`.
 *
 * THE WITNESS THE CARD DEMANDS: "a check that only reads the API and prints
 * the age is not a witness — it is green when the run is missing, which is
 * the exact failure." This binary must therefore REDDEN given a stale last-
 * run date and STAY GREEN given a fresh one, provably, without needing a
 * genuinely broken `nightly-perf` lane to demonstrate it against. The two
 * test-only seams below (`--last-run-iso`, `--now-iso`) exist for exactly
 * that — they replace the network fetch with a supplied timestamp, the same
 * way `run_test.d --check-space PATH --space-floor-mib N` keeps the REAL
 * statvfs query but makes the boundary reachable on demand (task 2080). The
 * live default path (no flags) still does the real `gh run list` call; see
 * `tests/unit/nightly_freshness_test.d` for both directions, both lanes.
 *
 * PROXY: this host reaches the GitHub API through a proxy (`HTTPS_PROXY`);
 * direct egress times out. `gh` (Go's net/http) honours `HTTP_PROXY` /
 * `HTTPS_PROXY` / `NO_PROXY` from the environment on its own — this file
 * spawns it with an INHERITED environment and adds no `--noproxy`, no env
 * override, no bypass of any kind. That is deliberate: hard-coding a bypass
 * here is exactly what made three unrelated lanes red for a day (see the
 * card). If the proxy is broken host-wide, this tool fails LOUDLY (exit 2,
 * distinct from a genuine stale verdict) rather than guessing.
 *
 * Usage:
 *   ./tools/ci/nightly_freshness.d
 *       Real check: last run of perf.yaml in $GITHUB_REPOSITORY (falling
 *       back to the `origin` remote), red if older than the computed
 *       threshold.
 *   ./tools/ci/nightly_freshness.d --workflow sanitizer.yaml --repo o/r
 *       Same, for a different workflow/repo (generalizes past task 2040's
 *       scope of just nightly-perf; not wired into any lane by this task).
 *   ./tools/ci/nightly_freshness.d --print-threshold
 *       Print the computed threshold in hours and exit 0. No network call.
 *   ./tools/ci/nightly_freshness.d --last-run-iso TS [--now-iso TS]
 *       Offline/test seam: skip the network fetch, judge TS directly.
 *
 * Exit codes: 0 fresh, 1 stale (a night looks missing), 2 could not tell
 * (bad args, `gh` failed, unparseable response, no repo/workflow resolved).
 * Code 2 is deliberately its own thing: this tool must never let "I could
 * not check" read as "it's fine" (a silent green) NOR as "it's broken" (a
 * false stale verdict) — both are exactly the disguise task 2040 exists to
 * remove, just in a different spot.
 */

import std.algorithm : startsWith, endsWith;
import std.array     : appender;
import std.conv      : to;
import std.datetime  : SysTime, Clock, UTC, DateTimeException;
import std.exception : enforce, collectException;
import std.format    : format;
import std.getopt    : getopt, config;
import std.json      : JSONValue, parseJSON, JSONType, JSONException;
import std.process   : execute, environment, Config;
import std.stdio     : writeln, writefln, stderr;
import std.string    : strip, split;

// ---------------------------------------------------------------------------
// Exact-term threshold (never a fitted number).
// ---------------------------------------------------------------------------

/// `perf.yaml`'s own `cron: '30 0 * * *'` — once per calendar day. An EXACT
/// term read off the workflow file, not a measured average interarrival.
enum double kCronPeriodHours = 24.0;

/// How late a delivery can be and still be "just late", not "missing".
/// Measured, not guessed: `doc/tasks/work/2040-...`'s own four-night sample
/// showed <=100 minutes of drift; re-measured live while building this tool
/// (2026-08-28, real `gh run list --workflow perf.yaml` over the real proxy)
/// showed a schedule-triggered run land at 10:10:39Z against the 00:30
/// target — 9h40m late, and genuinely not a missed night. 12h (half the
/// cron period) clears that outlier with headroom without adopting "wait
/// indefinitely", which is a missing run's own failure mode, not this
/// checker's. If GitHub's delivery drift ever exceeds this, that is new
/// evidence to fold in here — not a reason to keep the old number.
enum double kDriftBufferHours = 12.0;

/// How many consecutive missed nights this checker treats as broken. This is
/// the ONE dial the task card names as the owner's, not mine ("Порог N:
/// сколько пропущенных ночей подряд считаем поломкой"). Proceeding with 1
/// (redden on the FIRST missed night) — see the task card's "Решения,
/// принятые на месте" for the reasoning and how to flip this to 2.
enum int kDefaultMissedNightsTolerated = 1;

/// The whole threshold, as one small formula so changing any input is a
/// one-line edit, not a re-derivation.
double freshnessThresholdHours(int missedNightsTolerated,
                                double cronPeriodHours = kCronPeriodHours,
                                double driftBufferHours = kDriftBufferHours) pure
{
    return cronPeriodHours * missedNightsTolerated + driftBufferHours;
}

unittest
{
    // 1 tolerated miss => one cron period plus the drift buffer.
    assert(freshnessThresholdHours(1) == 24.0 + 12.0);
    // 2 tolerated misses => two periods plus the same buffer.
    assert(freshnessThresholdHours(2) == 48.0 + 12.0);
    // The formula, not a memorized constant: a narrower/wider period or
    // buffer must move the answer by exactly that much.
    assert(freshnessThresholdHours(1, 12.0, 3.0) == 15.0);
}

// ---------------------------------------------------------------------------
// The decision, as one pure function over two timestamps and a threshold.
// ---------------------------------------------------------------------------

struct FreshnessVerdict {
    bool ok;             // true = fresh, false = stale/missing
    double ageHours;
    double thresholdHours;
    string message;      // always names the workflow, the age and the threshold
}

/// Pure: no clock read, no process spawn. `now` and `lastRun` are both
/// supplied. This is the function the witness in
/// `tests/unit/nightly_freshness_test.d` drives directly through the CLI's
/// `--last-run-iso`/`--now-iso` seam — real arithmetic, injected inputs,
/// exactly the shape `run_test.d --check-space` uses for its own boundary
/// (task 2080): the query/comparison is real, only the input is supplied.
FreshnessVerdict checkFreshness(SysTime now, SysTime lastRun, double thresholdHours,
                                 string workflowLabel) pure
{
    const durHours = (now - lastRun).total!"seconds" / 3600.0;
    const ok = durHours <= thresholdHours;
    string msg;
    if (ok) {
        msg = format("nightly_freshness: %s last ran %.1fh ago (threshold %.1fh) — fresh.",
                      workflowLabel, durHours, thresholdHours);
    } else {
        msg = format(
            "nightly_freshness: %s last ran %.1fh ago, past the %.1fh threshold — "
          ~ "MISSING. This is not a report of a red run: it means no run exists "
          ~ "recent enough to trust its numbers. A stale figure this old would be "
          ~ "read as current by anything that only looks at \"latest\" (task 2040). "
          ~ "Check delivery (GitHub Actions schedule queue, the runner's own "
          ~ "availability) before reading any number this lane last produced.",
            workflowLabel, durHours, thresholdHours);
    }
    return FreshnessVerdict(ok, durHours, thresholdHours, msg);
}

unittest
{
    // ok/negative are the whole point: symmetric, boundary-exact.
    auto now = SysTime.fromISOExtString("2026-08-28T09:00:00Z");

    // Exactly at the threshold: still fresh (<=, not <).
    auto atBoundary = SysTime.fromISOExtString("2026-08-27T09:00:00Z"); // 24h back
    auto v1 = checkFreshness(now, atBoundary, 24.0, "w");
    assert(v1.ok, v1.message);

    // One second past: stale.
    auto pastBoundary = SysTime.fromISOExtString("2026-08-27T08:59:59Z");
    auto v2 = checkFreshness(now, pastBoundary, 24.0, "w");
    assert(!v2.ok, v2.message);

    // A genuinely fresh run (this tool's own scale: hours, not days).
    auto fresh = SysTime.fromISOExtString("2026-08-28T02:00:00Z");
    auto v3 = checkFreshness(now, fresh, 36.0, "w");
    assert(v3.ok, v3.message);

    // A two-day-old run against the 1-missed-night default threshold.
    auto stale = SysTime.fromISOExtString("2026-08-26T02:09:00Z");
    auto v4 = checkFreshness(now, stale, freshnessThresholdHours(1), "nightly-perf");
    assert(!v4.ok, v4.message);
    assert(v4.message.canFindWord("MISSING"), v4.message);
}

private bool canFindWord(string haystack, string needle)
{
    import std.algorithm : canFind;
    return haystack.canFind(needle);
}

// ---------------------------------------------------------------------------
// Extracting a timestamp out of `gh run list --json ...` output — pure once
// the JSON text is in hand, so it is testable on canned text with no `gh`
// on PATH and no network.
// ---------------------------------------------------------------------------

/// `json` is the raw stdout of `gh run list --json createdAt,... --limit 1`
/// (a JSON array). Returns the first entry's `createdAt`. Throws on
/// malformed JSON or a shape without that field; returns "" (never throws)
/// for a syntactically valid EMPTY array — a workflow that has genuinely
/// never run is a real, distinct answer, not a parse failure.
string extractLastRunIso(string json)
{
    auto parsed = parseJSON(json);
    enforce(parsed.type == JSONType.array,
            "gh run list did not return a JSON array: " ~ json);
    if (parsed.array.length == 0) return "";
    const first = parsed.array[0];
    enforce(first.type == JSONType.object && "createdAt" in first.object,
            "gh run list's first entry has no createdAt: " ~ json);
    return first.object["createdAt"].str;
}

unittest
{
    // A real captured shape (task 2040, 2026-08-28, `gh run list
    // --workflow perf.yaml --limit 3 --json databaseId,createdAt,status,
    // conclusion,event` against this repository, through the real proxy).
    enum sample = `[{"conclusion":"failure","createdAt":"2026-08-27T13:02:05Z",` ~
        `"databaseId":33074758175,"event":"workflow_dispatch","status":"completed"},` ~
        `{"conclusion":"failure","createdAt":"2026-08-27T12:43:59Z","databaseId":` ~
        `33073277968,"event":"workflow_dispatch","status":"completed"}]`;
    assert(extractLastRunIso(sample) == "2026-08-27T13:02:05Z");

    assert(extractLastRunIso("[]") == "");

    assert(collectException!Exception(extractLastRunIso("not json")) !is null);
    assert(collectException!Exception(extractLastRunIso(`[{"no_createdAt":1}]`)) !is null);
}

// ---------------------------------------------------------------------------
// Impure edges: the real clock, the real `gh` call, repo-slug resolution.
// ---------------------------------------------------------------------------

/// `$GITHUB_REPOSITORY` (set by Actions) first; falls back to parsing the
/// `origin` git remote for local/manual runs. Returns "" if neither
/// resolves — callers must treat that as a hard refusal, not a guess.
string defaultRepoSlug()
{
    const fromEnv = environment.get("GITHUB_REPOSITORY", "");
    if (fromEnv.length) return fromEnv;

    auto r = execute(["git", "remote", "get-url", "origin"]);
    if (r.status != 0) return "";
    return parseRepoSlugFromRemoteUrl(r.output.strip);
}

/// Pure parse of the two common `origin` URL shapes:
///   git@github.com:OWNER/REPO.git
///   https://github.com/OWNER/REPO.git
/// Returns "" for anything else (not a github.com remote, unrecognized
/// shape) rather than guessing.
string parseRepoSlugFromRemoteUrl(string url)
{
    string rest;
    if (url.startsWith("git@github.com:")) {
        rest = url["git@github.com:".length .. $];
    } else if (url.startsWith("https://github.com/")) {
        rest = url["https://github.com/".length .. $];
    } else if (url.startsWith("ssh://git@github.com/")) {
        rest = url["ssh://git@github.com/".length .. $];
    } else {
        return "";
    }
    if (rest.endsWith(".git")) rest = rest[0 .. $ - 4];
    return rest;
}

unittest
{
    assert(parseRepoSlugFromRemoteUrl("git@github.com:shulc/vibe3d.git") == "shulc/vibe3d");
    assert(parseRepoSlugFromRemoteUrl("https://github.com/shulc/vibe3d.git") == "shulc/vibe3d");
    assert(parseRepoSlugFromRemoteUrl("https://github.com/shulc/vibe3d") == "shulc/vibe3d");
    assert(parseRepoSlugFromRemoteUrl("ssh://ai/home/ashagarov/Code/bare/vibe3d.git") == "");
}

/// The real network call. No env override, no `--noproxy` — see the file
/// header. Returns the raw stdout (a JSON array) on a clean `gh` exit;
/// throws with `gh`'s own stderr folded in otherwise, so a proxy failure and
/// an auth failure read differently from a "the workflow doesn't exist".
string ghRunListJson(string repo, string workflow)
{
    auto r = execute([
        "gh", "run", "list",
        "--repo", repo,
        "--workflow", workflow,
        "--limit", "1",
        "--json", "createdAt,status,conclusion,event",
    ]);
    enforce(r.status == 0,
        format("gh run list --repo %s --workflow %s exited %d:\n%s",
               repo, workflow, r.status, r.output));
    return r.output;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

enum int kExitFresh = 0;
enum int kExitStale = 1;
enum int kExitError = 2;

int main(string[] args)
{
    string repo;
    string workflow = "perf.yaml";
    string workflowLabel = "nightly-perf";
    int missedNightsTolerated = kDefaultMissedNightsTolerated;
    double cronPeriodHours = kCronPeriodHours;
    double driftBufferHours = kDriftBufferHours;
    double thresholdOverride = -1.0; // -1 = derive from the three above
    string lastRunIso;   // test/offline seam
    string nowIso;       // test/offline seam
    bool printThreshold;
    bool fakeNoRuns;     // test/offline seam

    auto helpInfo = getopt(args,
        "repo",        "OWNER/REPO to query (default: $GITHUB_REPOSITORY, "
                      ~ "else parsed from the `origin` git remote)",          &repo,
        "workflow",    "workflow file to check (default: perf.yaml)",        &workflow,
        "workflow-label", "human label for messages (default: nightly-perf)", &workflowLabel,
        "missed-nights-tolerated", "(task 2040 — the owner's dial, see the "
                      ~ "file header) consecutive missed nights before this "
                      ~ "reddens (default 1)",                                &missedNightsTolerated,
        "cron-period-hours", "override the cron period used in the threshold "
                      ~ "formula (default 24, from perf.yaml's own cron)",    &cronPeriodHours,
        "drift-buffer-hours", "override the late-but-not-missing allowance "
                      ~ "(default 12 — see kDriftBufferHours)",               &driftBufferHours,
        "threshold-hours", "skip the formula entirely and use this many "
                      ~ "hours as the threshold (diagnostic/override)",       &thresholdOverride,
        "last-run-iso", "(test/offline seam) judge THIS timestamp instead of "
                      ~ "calling `gh` — the fake-age witness uses this",      &lastRunIso,
        "now-iso",     "(test/offline seam) use THIS as \"now\" instead of "
                      ~ "the real clock",                                     &nowIso,
        "print-threshold", "print the computed threshold in hours and exit; "
                      ~ "no network call",                                    &printThreshold,
        "fake-no-runs", "(test/offline seam) simulate a workflow with ZERO "
                      ~ "recorded runs at all -- skips the network call, goes "
                      ~ "straight to the \"no runs\" verdict (stale)",        &fakeNoRuns,
    );
    if (helpInfo.helpWanted) {
        import std.getopt : defaultGetoptPrinter;
        defaultGetoptPrinter("nightly_freshness: is the last run of a workflow "
            ~ "recent enough to trust? (task 2040)", helpInfo.options);
        return kExitFresh;
    }

    const threshold = thresholdOverride >= 0.0
        ? thresholdOverride
        : freshnessThresholdHours(missedNightsTolerated, cronPeriodHours, driftBufferHours);

    if (printThreshold) {
        writefln("%.1f", threshold);
        return kExitFresh;
    }

    SysTime now;
    if (nowIso.length) {
        auto ex = collectException!Exception(now = SysTime.fromISOExtString(nowIso));
        if (ex !is null) {
            stderr.writeln("nightly_freshness: --now-iso is not a parseable timestamp: ", nowIso);
            return kExitError;
        }
    } else {
        now = Clock.currTime(UTC());
    }

    if (fakeNoRuns) {
        writefln("nightly_freshness: %s (%s) has NO recorded runs at all "
               ~ "[--fake-no-runs, test seam] — treating as missing (age is "
               ~ "effectively infinite).", workflowLabel, workflow);
        return kExitStale;
    }

    string lastIso = lastRunIso;
    if (!lastIso.length) {
        // Live path: resolve the repo, call `gh`, extract the timestamp.
        const resolvedRepo = repo.length ? repo : defaultRepoSlug();
        if (!resolvedRepo.length) {
            stderr.writeln("nightly_freshness: could not resolve OWNER/REPO — pass "
                ~ "--repo, or set $GITHUB_REPOSITORY, or run inside a checkout whose "
                ~ "`origin` remote points at github.com");
            return kExitError;
        }
        string json;
        auto ex = collectException!Exception(json = ghRunListJson(resolvedRepo, workflow));
        if (ex !is null) {
            stderr.writeln("nightly_freshness: could not fetch run history: ", ex.msg);
            return kExitError;
        }
        auto ex2 = collectException!Exception(lastIso = extractLastRunIso(json));
        if (ex2 !is null) {
            stderr.writeln("nightly_freshness: could not parse `gh run list` output: ", ex2.msg);
            return kExitError;
        }
        if (!lastIso.length) {
            writefln("nightly_freshness: %s (%s) has NO recorded runs at all in %s — "
                   ~ "treating as missing (age is effectively infinite).",
                     workflowLabel, workflow, resolvedRepo);
            return kExitStale;
        }
    }

    SysTime lastRun;
    {
        auto ex = collectException!Exception(lastRun = SysTime.fromISOExtString(lastIso));
        if (ex !is null) {
            stderr.writeln("nightly_freshness: last-run timestamp is not parseable: ", lastIso);
            return kExitError;
        }
    }

    const verdict = checkFreshness(now, lastRun, threshold,
                                    format("%s (%s)", workflowLabel, workflow));
    writeln(verdict.message);
    return verdict.ok ? kExitFresh : kExitStale;
}
