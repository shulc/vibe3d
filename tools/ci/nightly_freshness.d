#!/usr/bin/env rdmd
/**
 * tools/ci/nightly_freshness.d — is the nightly-perf lane actually running,
 * or just quiet? (task 2040, extended by task 2580)
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
 * WHAT TERM 1 CHECKS: the age of the most recent run of a workflow (any
 * event, any conclusion — an in-progress or even a failed run still proves
 * delivery happened; this tool is silent on whether the run was GOOD, only
 * on whether one occurred at all. Whether it passed is
 * `doc/tasks/work/1840-...`'s job).
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
 * TASK 2580 — TERM 1 ALONE HAS A HOLE: "figures are fresh" is not "the
 * schedule is delivering". `checkFreshness` above counts the last run of
 * ANY event on purpose (decision #3 in the 2040 card: a manual dispatch does
 * refresh the numbers, so it should count). But that means a manual dispatch
 * ALSO resets `checkFreshness`'s clock even though `cron` itself may have
 * stopped firing entirely — and that is exactly what happened on
 * 2026-08-28: three manual dispatches on the afternoon of the 27th kept term
 * 1 reading "22.3h ago — fresh" while the *schedule* had not delivered a
 * single run in over a day (2026-08-28 had NO SCHEDULED RUN AT ALL). Two
 * different questions were being answered by one number:
 *
 *   question                          | measured by                | term
 *   -----------------------------------|-----------------------------|------
 *   are the figures stale?             | age of last run, ANY event  | 1 (2040)
 *   is the schedule delivering?        | age of last SCHEDULE event, | 2 (2580)
 *                                       | plus its drift from the slot|
 *
 * TERM 2 (`checkScheduleHealth`, below) answers the second question. It
 * reads the SAME `event` field term 1's report already carried but never
 * gated on, filters to `event == "schedule"`, and applies its OWN threshold
 * to the age of the newest one. A `workflow_dispatch` cannot reset this
 * clock, by construction — so a schedule that has genuinely stopped
 * delivering cannot hide behind an operator running the lane by hand,
 * however many times.
 *
 * THE TWO THRESHOLDS ARE DIFFERENT IN KIND, NOT JUST TWO NUMBERS. Term 1's
 * threshold answers "when do the figures start lying" — any delivery,
 * scheduled or manual, resets it. Term 2's threshold answers "when has the
 * MECHANISM stopped" — only a `schedule`-triggered delivery resets it, so
 * repeated manual dispatches cannot mask a broken cron from it, ever. Both
 * are still built from the SAME exact-term formula
 * (`freshnessThresholdHours`: cron period × tolerated misses + drift
 * buffer) rather than two independently fitted numbers, but each has its
 * OWN `missedNightsTolerated` dial (`kDefaultMissedNightsTolerated` vs.
 * `kDefaultScheduleMissedNightsTolerated`) so a future change to one cannot
 * silently move the other. They default to the same value (1) today because
 * nothing yet argues for divergence — see the task card's "Решения,
 * принятые на месте" for the reasoning, and `--schedule-missed-nights-
 * tolerated` to change term 2 alone without touching term 1.
 *
 * DRIFT AS A QUANTITY, NOT AN ANECDOTE (task 2580, item 2). Six real
 * schedule-triggered arrivals are on record against the 00:30 UTC target:
 * 02:01, 02:08, 02:10, 02:04, 02:09 (94-100 min drift, the routine case) and
 * 10:10 (580 min, the one-time outlier that set `kDriftBufferHours`). This
 * tool computes the MEDIAN and MAXIMUM of whatever schedule-run history it
 * can see and prints both beside term 2's verdict every time it runs — a
 * lane arriving a reliable 90-100 minutes late is a different animal from
 * one arriving whenever, and only a distribution can tell the two apart.
 * The reproduction of the six-sample figures above (median 98.5min, max
 * 580.0min) lives in `computeDriftStats`'s own unittest.
 *
 * GATE OR REPORT (task 2580, item 3) — THE OWNER'S CALL, NAMED HERE, NOT
 * DECIDED HERE. A cron that stops delivering is not the fault of whoever
 * opened the pull request that happens to run next; failing THEIR build
 * punishes the wrong person. But a number that only ever gets printed is
 * exactly the shape task 2040 exists to reject — that is how this exact hole
 * went unnoticed for a day. The two are not the same risk: term 1 already
 * gates `ci.yaml`'s aggregate pass/fail (see the workflow file) because a
 * genuinely stale figure IS a merge-relevant fact about THIS build. Term 2's
 * failure mode is different in kind (see above) — it survived report-only
 * for exactly one day in the observed incident, not indefinitely, because
 * ci.yaml runs many times a day. **This tool computes and PRINTS term 2's
 * verdict and drift stats unconditionally, every run** (so it is never
 * merely absent from the log the way it was before this task); whether that
 * verdict also flips this process's own exit code is the ONE flag below,
 * `--gate-schedule-health` (default false — report only). Flipping it is a
 * one-line change at the call site (`ci.yaml`'s `run:` line for this step),
 * not a code change. Mechanically there is no free middle ground: this
 * step's OWN exit code is what `ci.yaml`'s final aggregate gate already
 * reads for term 1 (`steps.nightly_freshness.outcome`), so with gating OFF
 * a stopped schedule does NOT turn this step red — it is invisible in the
 * Actions UI's outcome column, by construction, same as before this task.
 * `ci.yaml` compensates the honest way: the step's stdout is piped through
 * `tee` into a log the job-summary step reads back and surfaces as its own
 * line UNCONDITIONALLY (not merely on request) — see that workflow's
 * comments. RECOMMENDATION (mine, not the owner's): leave it report-only.
 * The always-printed summary line is what keeps this from being "a number
 * that only prints when someone goes looking" (task 2040's own complaint);
 * gating would additionally fail EVERY push/PR for as long as the schedule
 * stays broken, for a failure whose fix is never in that PR's own diff.
 * Turn gating on only if the summary line proves to keep getting missed the
 * way the ungated figure-freshness number once did.
 *
 * PROXY: this host reaches the GitHub API through a proxy (`HTTPS_PROXY`);
 * direct egress times out. `gh` (Go's net/http) honours `HTTP_PROXY` /
 * `HTTPS_PROXY` / `NO_PROXY` from the environment on its own — this file
 * spawns it with an INHERITED environment and adds no `--noproxy`, no env
 * override, no bypass of any kind. That is deliberate: hard-coding a bypass
 * here is exactly what made three unrelated lanes red for a day (see the
 * card). If the proxy is broken host-wide, this tool fails LOUDLY (exit 2,
 * distinct from a genuine stale verdict) rather than guessing. (Separately,
 * and NOT addressed by this file: task 2570 records that the CI runner
 * itself has intermittent egress trouble reaching the results endpoint —
 * unrelated failure mode, on a different host, not fixed here. Fetching
 * both terms from ONE `gh run list` call, below, at least halves this
 * tool's own exposure to any such flakiness rather than doubling it.)
 *
 * Usage:
 *   ./tools/ci/nightly_freshness.d
 *       Real check: last run of perf.yaml in $GITHUB_REPOSITORY (falling
 *       back to the `origin` remote). Prints term 1 (figure freshness),
 *       then term 2 (schedule health) and its drift stats. Exit code is
 *       governed by term 1 alone unless --gate-schedule-health is passed.
 *   ./tools/ci/nightly_freshness.d --workflow sanitizer.yaml --repo o/r
 *       Same, for a different workflow/repo (generalizes past task 2040's
 *       scope of just nightly-perf; not wired into any lane by this task).
 *   ./tools/ci/nightly_freshness.d --print-threshold
 *       Print term 1's computed threshold in hours and exit. No network.
 *   ./tools/ci/nightly_freshness.d --print-schedule-threshold
 *       Print term 2's computed threshold in hours and exit. No network.
 *   ./tools/ci/nightly_freshness.d --last-run-iso TS [--now-iso TS]
 *       Offline/test seam for term 1: skip the network fetch, judge TS.
 *   ./tools/ci/nightly_freshness.d --schedule-run-isos TS1,TS2,... [--now-iso TS]
 *       Offline/test seam for term 2 (task 2580): skip the network fetch,
 *       judge the newest of TS1,TS2,... (newest-first) and derive drift
 *       stats from the whole list. Independent of --last-run-iso — a test
 *       can set term 1 fresh while term 2 is stale, or vice versa.
 *   ./tools/ci/nightly_freshness.d --gate-schedule-health
 *       Fold term 2's verdict into this process's own exit code too (see
 *       "GATE OR REPORT" above).
 *
 * Exit codes: 0 fresh, 1 stale (a night looks missing), 2 could not tell
 * (bad args, `gh` failed, unparseable response, no repo/workflow resolved).
 * Code 2 is deliberately its own thing: this tool must never let "I could
 * not check" read as "it's fine" (a silent green) NOR as "it's broken" (a
 * false stale verdict) — both are exactly the disguise task 2040 exists to
 * remove, just in a different spot. Term 2 by itself can only push the exit
 * code to 1 (stale) when `--gate-schedule-health` is set — its own hard
 * fetch/parse errors do the same code-2 refusal, but ONLY when gating is on;
 * report-only mode never lets term 2 change this process's exit code, by
 * design (see "GATE OR REPORT").
 */

import std.algorithm : startsWith, endsWith, map, sort;
import std.array     : appender, array;
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
/// Shared by both terms: it is a property of the CRON ITSELF, not of which
/// event type a term filters for.
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
/// evidence to fold in here — not a reason to keep the old number. Shared by
/// both terms: the measurement that set this WAS a `schedule`-event
/// delivery, so it is already term 2's own quantity, not borrowed.
enum double kDriftBufferHours = 12.0;

/// How many consecutive missed nights term 1 (figure freshness) treats as
/// broken. This is the ONE dial the task 2040 card names as the owner's, not
/// mine ("Порог N: сколько пропущенных ночей подряд считаем поломкой").
/// Proceeding with 1 (redden on the FIRST missed night) — see that task
/// card's "Решения, принятые на месте" for the reasoning and how to flip
/// this to 2.
enum int kDefaultMissedNightsTolerated = 1;

/// Term 2's OWN dial (task 2580) — independently named and independently
/// overridable (`--schedule-missed-nights-tolerated`) so a future change to
/// term 1's tolerance cannot silently move term 2's, or vice versa. Defaults
/// to the same value as term 1 today (1) because the incident this task
/// responds to was exactly ONE missed scheduled night — see the file
/// header's "THE TWO THRESHOLDS ARE DIFFERENT IN KIND" for why an equal
/// default is not the same claim as "these are the same threshold".
enum int kDefaultScheduleMissedNightsTolerated = 1;

/// The cron's own target time-of-day, read off `perf.yaml`'s
/// `cron: '30 0 * * *'` — used only for the drift measurement (task 2580),
/// never for the freshness age comparison itself.
enum string kCronTargetUtc = "00:30";

/// How many of the most recent runs (any event) to fetch in the one live
/// `gh run list` call this tool makes, so enough `schedule`-only history
/// survives the client-side filter for a meaningful median/max (task 2580).
/// 30 comfortably covers a month of nightly schedule runs even with several
/// manual dispatches interleaved; term 1 only ever looks at entry [0]
/// regardless of this value, so raising it cannot change term 1's answer.
enum int kScheduleHistoryLimit = 30;

/// The whole threshold, as one small formula so changing any input is a
/// one-line edit, not a re-derivation. Used by BOTH terms (task 2580): term
/// 1 calls it with `kDefaultMissedNightsTolerated`, term 2 with
/// `kDefaultScheduleMissedNightsTolerated` — same shape, independently
/// dialed inputs, per the file header.
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
///
/// TERM 1 (task 2040) — "are the figures stale": `lastRun` is the newest run
/// of ANY event type. See `checkScheduleHealth` below for term 2 (task
/// 2580), which asks a different question over a differently-filtered
/// `lastRun` and therefore gets its OWN message, not a relabeled copy of
/// this one.
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
// TASK 2580 — TERM 2: is the schedule itself still delivering?
// ---------------------------------------------------------------------------

/// Same comparison shape as `checkFreshness` (age vs. threshold, `<=` at the
/// boundary), but its OWN message: this answers "has the schedule stopped
/// delivering", not "are the figures stale". `lastScheduleRun` must already
/// be filtered to `event == "schedule"` by the caller — a `workflow_dispatch`
/// must never reach this function, or it would inherit exactly the blind
/// spot this term exists to close (the 2026-08-28 incident: three manual
/// dispatches on one afternoon kept `checkFreshness` green for a day while
/// the schedule had stopped firing).
FreshnessVerdict checkScheduleHealth(SysTime now, SysTime lastScheduleRun,
                                      double thresholdHours, string workflowLabel) pure
{
    const durHours = (now - lastScheduleRun).total!"seconds" / 3600.0;
    const ok = durHours <= thresholdHours;
    string msg;
    if (ok) {
        msg = format("nightly_freshness: %s schedule delivery last ran %.1fh ago "
                    ~ "(threshold %.1fh) — delivering.", workflowLabel, durHours, thresholdHours);
    } else {
        msg = format(
            "nightly_freshness: %s schedule delivery last ran %.1fh ago, past the "
          ~ "%.1fh threshold — CRON STOPPED (task 2580). A manual `workflow_dispatch` "
          ~ "can keep the plain freshness check above reading fresh while the "
          ~ "SCHEDULE itself has not fired in this long — this term counts only "
          ~ "event=schedule runs, so a manual dispatch cannot reset it. Check the "
          ~ "workflow's `on.schedule.cron` entry is still present and the repository "
          ~ "has had recent activity (GitHub disables schedules on stale repos).",
            workflowLabel, durHours, thresholdHours);
    }
    return FreshnessVerdict(ok, durHours, thresholdHours, msg);
}

unittest
{
    // THE WITNESS (task 2580): the exact masking scenario from the card,
    // reproduced from real captured timestamps — a manual dispatch at
    // 2026-08-27T13:02Z keeps term 1 fresh while the last SCHEDULE run
    // (2026-08-27T10:10Z) ages past its own, independent threshold.
    // `now` is chosen inside the ~3h window where the two terms disagree:
    // 34.97h since the dispatch (< 36h, term 1 fresh) but 37.83h since the
    // schedule run (> 36h, term 2 stopped).
    auto now = SysTime.fromISOExtString("2026-08-29T00:00:00Z");
    const scheduleThreshold = freshnessThresholdHours(kDefaultScheduleMissedNightsTolerated);
    assert(scheduleThreshold == 36.0, "test assumes the default 36h — got " ~ scheduleThreshold.to!string);

    auto lastAnyEvent = SysTime.fromISOExtString("2026-08-27T13:02:00Z"); // the manual dispatch
    auto v1 = checkFreshness(now, lastAnyEvent, freshnessThresholdHours(kDefaultMissedNightsTolerated), "nightly-perf");
    assert(v1.ok, "term 1 (any event) should read fresh off the manual dispatch: " ~ v1.message);

    auto lastScheduleEvent = SysTime.fromISOExtString("2026-08-27T10:10:00Z"); // the schedule run the dispatch does NOT stand in for
    auto v2 = checkScheduleHealth(now, lastScheduleEvent, scheduleThreshold, "nightly-perf");
    assert(!v2.ok, "term 2 (schedule only) must NOT be fooled by the fresh manual dispatch: " ~ v2.message);
    assert(v2.message.canFindWord("CRON STOPPED"), v2.message);

    // Reverse direction: right after a genuine schedule delivery, both terms
    // agree and are both fresh/delivering — the hole this closes is
    // specifically "manual dispatch masks a broken schedule", not "the two
    // terms always disagree".
    auto justAfter = SysTime.fromISOExtString("2026-08-27T14:00:00Z");
    auto v3 = checkFreshness(justAfter, lastAnyEvent, freshnessThresholdHours(kDefaultMissedNightsTolerated), "nightly-perf");
    auto v4 = checkScheduleHealth(justAfter, lastScheduleEvent, scheduleThreshold, "nightly-perf");
    assert(v3.ok, v3.message);
    assert(v4.ok, v4.message);
    assert(v4.message.canFindWord("delivering"), v4.message);

    // Exact boundary, same discipline as checkFreshness's own test: <=, not <.
    auto atBoundary = SysTime.fromISOExtString("2026-08-26T00:00:00Z"); // 36h before...
    auto nowForBoundary = SysTime.fromISOExtString("2026-08-27T12:00:00Z"); // ...this
    auto vb1 = checkScheduleHealth(nowForBoundary, atBoundary, 36.0, "w");
    assert(vb1.ok, vb1.message);
    auto pastBoundary = SysTime.fromISOExtString("2026-08-25T23:59:59Z"); // 36h + 1s
    auto vb2 = checkScheduleHealth(nowForBoundary, pastBoundary, 36.0, "w");
    assert(!vb2.ok, vb2.message);
}

/// One data point of schedule drift: how many minutes past the cron's own
/// target time-of-day `run` landed. Only the TIME OF DAY matters — the
/// schedule fires once nightly, so "how late" is measured against the
/// target clock time, not the previous run. Can go negative if a run
/// somehow landed before the target (never observed in this project's own
/// history; left signed rather than clamped so a future negative value is
/// visible as data, not silently discarded).
struct CronTarget { int hour; int minute; }

double scheduleDriftMinutes(SysTime run, CronTarget target)
{
    // NOT pure: SysTime.hour/.minute/.second can consult the OS timezone
    // database (impure by the compiler's own accounting) even though every
    // caller here only ever passes a UTC-parsed SysTime.
    const minutesOfDay = run.hour * 60.0 + run.minute + run.second / 60.0;
    return minutesOfDay - (target.hour * 60.0 + target.minute);
}

/// Parses "HH:MM" (the `--cron-target-utc` flag / `kCronTargetUtc` default).
/// Throws on anything else rather than guessing a target.
CronTarget parseCronTarget(string hhmm) pure
{
    auto parts = hhmm.split(":");
    enforce(parts.length == 2, "cron target must be HH:MM, got: " ~ hhmm);
    return CronTarget(parts[0].to!int, parts[1].to!int);
}

unittest
{
    assert(parseCronTarget("00:30") == CronTarget(0, 30));
    assert(parseCronTarget("23:59") == CronTarget(23, 59));
    assert(collectException!Exception(parseCronTarget("0030")) !is null);
}

struct DriftStats { double medianMinutes; double maxMinutes; size_t count; }

/// Pure median/max over an already-computed drift sample (task 2580, item
/// 2 — "measure the drift as a quantity, not an anecdote"). `drifts` must be
/// non-empty; a workflow with zero schedule runs in the visible window is
/// its own distinct state, reported separately by the caller in `main()`,
/// never smuggled in here as a zero-sample DriftStats.
DriftStats computeDriftStats(double[] drifts) pure
{
    enforce(drifts.length > 0, "computeDriftStats: no samples");
    auto sorted = drifts.dup;
    sorted.sort();
    const n = sorted.length;
    const median = (n % 2 == 1) ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0;
    return DriftStats(median, sorted[$ - 1], n);
}

unittest
{
    // The card's own six real data points (task 2580): four routine nights
    // (91/94/98/99/100 min — the original 2040 sample plus one more) and the
    // one measured outlier (580 min, the 10:10:39Z delivery that set
    // kDriftBufferHours). Reproduced here as the exact reference figures the
    // card asks this tool to print: median 98.5min, max 580.0min.
    const target = CronTarget(0, 30);
    auto times = [
        "2026-08-22T02:01:00Z", "2026-08-23T02:10:00Z", "2026-08-24T02:08:00Z",
        "2026-08-25T02:04:00Z", "2026-08-26T02:09:00Z", "2026-08-27T10:10:00Z",
    ];
    double[] drifts;
    foreach (t; times) drifts ~= scheduleDriftMinutes(SysTime.fromISOExtString(t), target);

    // Individual drifts, exactly: 91, 100, 98, 94, 99, 580.
    assert(drifts == [91.0, 100.0, 98.0, 94.0, 99.0, 580.0], drifts.to!string);

    const stats = computeDriftStats(drifts);
    assert(stats.count == 6);
    assert(stats.medianMinutes == 98.5, stats.medianMinutes.to!string); // (98+99)/2
    assert(stats.maxMinutes == 580.0, stats.maxMinutes.to!string);

    // A single sample: median == that sample == max.
    const one = computeDriftStats([42.0]);
    assert(one.medianMinutes == 42.0 && one.maxMinutes == 42.0 && one.count == 1);

    assert(collectException!Exception(computeDriftStats([])) !is null);
}

// ---------------------------------------------------------------------------
// Extracting timestamps out of `gh run list --json ...` output — pure once
// the JSON text is in hand, so it is testable on canned text with no `gh`
// on PATH and no network.
// ---------------------------------------------------------------------------

/// `json` is the raw stdout of `gh run list --json createdAt,... --limit N`
/// (a JSON array, newest-first). Returns the first entry's `createdAt`.
/// Throws on malformed JSON or a shape without that field; returns "" (never
/// throws) for a syntactically valid EMPTY array — a workflow that has
/// genuinely never run is a real, distinct answer, not a parse failure.
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

/// All `createdAt` values (newest-first, matching `gh run list`'s own order)
/// whose `event` field equals `eventName` (task 2580). This reads the SAME
/// JSON payload `extractLastRunIso` reads for term 1 — the live path in
/// `main()` makes exactly one `gh run list` call and derives both terms from
/// it, rather than doubling this tool's own exposure to task 2570's
/// intermittent results-endpoint flakiness.
string[] extractRunsFilteredByEvent(string json, string eventName)
{
    auto parsed = parseJSON(json);
    enforce(parsed.type == JSONType.array,
            "gh run list did not return a JSON array: " ~ json);
    auto result = appender!(string[]);
    foreach (entry; parsed.array) {
        enforce(entry.type == JSONType.object
                && "createdAt" in entry.object && "event" in entry.object,
                "gh run list entry missing createdAt/event: " ~ json);
        if (entry.object["event"].str == eventName)
            result.put(entry.object["createdAt"].str);
    }
    return result.data;
}

unittest
{
    // The card's own captured run-history shape (task 2580): three manual
    // dispatches, one late schedule run, one earlier successful dispatch,
    // then older schedule runs — newest first, exactly as `gh run list`
    // returns it.
    enum sample = `[` ~
        `{"createdAt":"2026-08-27T13:02:05Z","event":"workflow_dispatch","status":"completed","conclusion":"failure"},` ~
        `{"createdAt":"2026-08-27T12:43:59Z","event":"workflow_dispatch","status":"completed","conclusion":"failure"},` ~
        `{"createdAt":"2026-08-27T11:06:00Z","event":"workflow_dispatch","status":"completed","conclusion":"failure"},` ~
        `{"createdAt":"2026-08-27T10:10:39Z","event":"schedule","status":"completed","conclusion":"failure"},` ~
        `{"createdAt":"2026-08-27T06:40:00Z","event":"workflow_dispatch","status":"completed","conclusion":"success"},` ~
        `{"createdAt":"2026-08-26T02:09:00Z","event":"schedule","status":"completed","conclusion":"failure"}` ~
        `]`;
    assert(extractRunsFilteredByEvent(sample, "schedule") ==
           ["2026-08-27T10:10:39Z", "2026-08-26T02:09:00Z"]);
    assert(extractRunsFilteredByEvent(sample, "workflow_dispatch").length == 4);
    assert(extractRunsFilteredByEvent("[]", "schedule") == []);
    assert(collectException!Exception(extractRunsFilteredByEvent("not json", "schedule")) !is null);
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
/// `limit` defaults to 1 (term 1's own historical need); `main()` passes a
/// larger value (task 2580) so the SAME call also carries enough
/// `schedule`-only history for term 2's age check and drift stats.
string ghRunListJson(string repo, string workflow, int limit = 1)
{
    auto r = execute([
        "gh", "run", "list",
        "--repo", repo,
        "--workflow", workflow,
        "--limit", limit.to!string,
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

    // task 2580 — term 2's own inputs, independent of term 1's above.
    int scheduleMissedNightsTolerated = kDefaultScheduleMissedNightsTolerated;
    double scheduleThresholdOverride = -1.0;
    string scheduleRunIsosArg;  // test/offline seam: comma-separated, newest-first
    bool fakeNoScheduleRuns;    // test/offline seam
    bool printScheduleThreshold;
    bool gateScheduleHealth;    // the ONE-LINE gate/report switch, see file header
    string cronTargetUtc = kCronTargetUtc;
    int scheduleHistoryLimit = kScheduleHistoryLimit;

    auto helpInfo = getopt(args,
        "repo",        "OWNER/REPO to query (default: $GITHUB_REPOSITORY, "
                      ~ "else parsed from the `origin` git remote)",          &repo,
        "workflow",    "workflow file to check (default: perf.yaml)",        &workflow,
        "workflow-label", "human label for messages (default: nightly-perf)", &workflowLabel,
        "missed-nights-tolerated", "(task 2040 — the owner's dial, see the "
                      ~ "file header) consecutive missed nights before TERM 1 "
                      ~ "reddens (default 1)",                                &missedNightsTolerated,
        "cron-period-hours", "override the cron period used in both terms' "
                      ~ "threshold formula (default 24, from perf.yaml's own cron)", &cronPeriodHours,
        "drift-buffer-hours", "override the late-but-not-missing allowance "
                      ~ "used by both terms (default 12 — see kDriftBufferHours)", &driftBufferHours,
        "threshold-hours", "skip the formula entirely and use this many "
                      ~ "hours as TERM 1's threshold (diagnostic/override)",  &thresholdOverride,
        "last-run-iso", "(test/offline seam) judge THIS timestamp for TERM 1 "
                      ~ "instead of calling `gh` — the fake-age witness uses this", &lastRunIso,
        "now-iso",     "(test/offline seam) use THIS as \"now\" for both "
                      ~ "terms instead of the real clock",                    &nowIso,
        "print-threshold", "print TERM 1's computed threshold in hours and "
                      ~ "exit; no network call",                              &printThreshold,
        "fake-no-runs", "(test/offline seam) simulate a workflow with ZERO "
                      ~ "recorded runs at all for TERM 1 -- skips the network "
                      ~ "call, goes straight to the \"no runs\" verdict (stale)", &fakeNoRuns,
        // --- task 2580: term 2 (schedule health) ---
        "schedule-missed-nights-tolerated", "(task 2580 — TERM 2's own dial, "
                      ~ "independent of --missed-nights-tolerated) consecutive "
                      ~ "missed SCHEDULED nights before term 2 reddens (default 1)", &scheduleMissedNightsTolerated,
        "schedule-threshold-hours", "skip the formula entirely and use this "
                      ~ "many hours as TERM 2's threshold (diagnostic/override)", &scheduleThresholdOverride,
        "schedule-run-isos", "(test/offline seam, task 2580) comma-separated, "
                      ~ "newest-first createdAt timestamps of event=schedule "
                      ~ "runs — skips the network fetch for TERM 2 only "
                      ~ "(independent of --last-run-iso)",                    &scheduleRunIsosArg,
        "fake-no-schedule-runs", "(test/offline seam, task 2580) simulate "
                      ~ "ZERO recorded schedule-triggered runs for TERM 2 "
                      ~ "only -- skips the network call for term 2",          &fakeNoScheduleRuns,
        "print-schedule-threshold", "print TERM 2's computed threshold in "
                      ~ "hours and exit; no network call",                    &printScheduleThreshold,
        "cron-target-utc", "HH:MM the cron is supposed to fire at, for the "
                      ~ "drift measurement only (default 00:30, perf.yaml's "
                      ~ "own cron: '30 0 * * *')",                            &cronTargetUtc,
        "schedule-history-limit", "how many of the most recent runs (any "
                      ~ "event) the ONE live `gh run list` call fetches, so "
                      ~ "enough schedule-only history survives the filter "
                      ~ "for drift stats (default 30)",                       &scheduleHistoryLimit,
        "gate-schedule-health", "(task 2580 — the owner's \"gate or report\" "
                      ~ "dial, see the file header) fold TERM 2's verdict "
                      ~ "into this process's own exit code too. Default "
                      ~ "false: term 2 is always PRINTED but never changes "
                      ~ "the exit code on its own",                           &gateScheduleHealth,
    );
    if (helpInfo.helpWanted) {
        import std.getopt : defaultGetoptPrinter;
        defaultGetoptPrinter("nightly_freshness: is the last run of a workflow "
            ~ "recent enough to trust (task 2040), and is its SCHEDULE still "
            ~ "delivering (task 2580)?", helpInfo.options);
        return kExitFresh;
    }

    const threshold = thresholdOverride >= 0.0
        ? thresholdOverride
        : freshnessThresholdHours(missedNightsTolerated, cronPeriodHours, driftBufferHours);
    const scheduleThreshold = scheduleThresholdOverride >= 0.0
        ? scheduleThresholdOverride
        : freshnessThresholdHours(scheduleMissedNightsTolerated, cronPeriodHours, driftBufferHours);

    if (printThreshold) {
        writefln("%.1f", threshold);
        return kExitFresh;
    }
    if (printScheduleThreshold) {
        writefln("%.1f", scheduleThreshold);
        return kExitFresh;
    }

    CronTarget target;
    {
        auto ex = collectException!Exception(target = parseCronTarget(cronTargetUtc));
        if (ex !is null) {
            stderr.writeln("nightly_freshness: --cron-target-utc is not HH:MM: ", cronTargetUtc);
            return kExitError;
        }
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

    // One shared live fetch (task 2580) serves BOTH terms, so this tool
    // makes at most one `gh run list` call regardless of how many terms need
    // the network — see the file header's PROXY section on why that matters
    // for task 2570's exposure, separately from the reason it is simply less
    // wasteful.
    const term1NeedsNetwork = !fakeNoRuns && lastRunIso.length == 0;
    const term2NeedsNetwork = !fakeNoScheduleRuns && scheduleRunIsosArg.length == 0;

    string resolvedRepo;
    string sharedJson;
    bool sharedJsonFetched;
    string sharedJsonError;

    if (term1NeedsNetwork || term2NeedsNetwork) {
        resolvedRepo = repo.length ? repo : defaultRepoSlug();
        if (!resolvedRepo.length) {
            stderr.writeln("nightly_freshness: could not resolve OWNER/REPO — pass "
                ~ "--repo, or set $GITHUB_REPOSITORY, or run inside a checkout whose "
                ~ "`origin` remote points at github.com");
            return kExitError;
        }
        auto ex = collectException!Exception(
            sharedJson = ghRunListJson(resolvedRepo, workflow, scheduleHistoryLimit));
        if (ex !is null) {
            sharedJsonError = ex.msg;
        } else {
            sharedJsonFetched = true;
        }
    }

    // ---- TERM 1 (task 2040): unchanged behavior, now fed by sharedJson ----
    bool term1Ok;
    if (fakeNoRuns) {
        writefln("nightly_freshness: %s (%s) has NO recorded runs at all "
               ~ "[--fake-no-runs, test seam] — treating as missing (age is "
               ~ "effectively infinite).", workflowLabel, workflow);
        term1Ok = false;
    } else {
        string lastIso = lastRunIso;
        if (!lastIso.length) {
            if (!sharedJsonFetched) {
                stderr.writeln("nightly_freshness: could not fetch run history: ",
                    sharedJsonError.length ? sharedJsonError : "unknown error");
                return kExitError;
            }
            auto ex2 = collectException!Exception(lastIso = extractLastRunIso(sharedJson));
            if (ex2 !is null) {
                stderr.writeln("nightly_freshness: could not parse `gh run list` output: ", ex2.msg);
                return kExitError;
            }
        }
        if (!lastIso.length) {
            writefln("nightly_freshness: %s (%s) has NO recorded runs at all in %s — "
                   ~ "treating as missing (age is effectively infinite).",
                     workflowLabel, workflow, resolvedRepo.length ? resolvedRepo : "?");
            term1Ok = false;
        } else {
            SysTime lastRun;
            auto ex3 = collectException!Exception(lastRun = SysTime.fromISOExtString(lastIso));
            if (ex3 !is null) {
                stderr.writeln("nightly_freshness: last-run timestamp is not parseable: ", lastIso);
                return kExitError;
            }
            const verdict1 = checkFreshness(now, lastRun, threshold,
                                             format("%s (%s)", workflowLabel, workflow));
            writeln(verdict1.message);
            term1Ok = verdict1.ok;
        }
    }

    // ---- TERM 2 (task 2580): always computed and PRINTED; only gates the ----
    // ---- exit code when --gate-schedule-health is set.                  ----
    bool term2Ok = true;
    bool term2HardError;

    string[] scheduleIsos;
    if (fakeNoScheduleRuns) {
        writefln("nightly_freshness: %s (%s) has NO recorded schedule-triggered "
               ~ "runs at all [--fake-no-schedule-runs, test seam] (task 2580) — "
               ~ "treating schedule delivery as missing (age is effectively infinite).",
                 workflowLabel, workflow);
        term2Ok = false;
    } else {
        if (scheduleRunIsosArg.length) {
            scheduleIsos = scheduleRunIsosArg.split(",").map!(s => s.strip).array;
        } else if (!sharedJsonFetched) {
            writeln("nightly_freshness: could not fetch schedule-run history for the "
                ~ "task 2580 term: " ~ (sharedJsonError.length ? sharedJsonError : "unknown error"));
            term2Ok = false;
            term2HardError = true;
        } else {
            auto ex4 = collectException!Exception(
                scheduleIsos = extractRunsFilteredByEvent(sharedJson, "schedule"));
            if (ex4 !is null) {
                writeln("nightly_freshness: could not parse schedule-run history for the "
                    ~ "task 2580 term: " ~ ex4.msg);
                term2Ok = false;
                term2HardError = true;
            }
        }

        if (!term2HardError) {
            if (scheduleIsos.length == 0) {
                writefln("nightly_freshness: %s (%s) — no schedule-triggered run found "
                       ~ "in the most recent %d fetched runs (task 2580); the schedule "
                       ~ "may be disabled, or widen --schedule-history-limit.",
                         workflowLabel, workflow, scheduleHistoryLimit);
                term2Ok = false;
            } else {
                SysTime[] scheduleRuns;
                bool parseFailed;
                string badIso;
                foreach (iso; scheduleIsos) {
                    SysTime t;
                    auto ex5 = collectException!Exception(t = SysTime.fromISOExtString(iso));
                    if (ex5 !is null) { parseFailed = true; badIso = iso; break; }
                    scheduleRuns ~= t;
                }
                if (parseFailed) {
                    writeln("nightly_freshness: a schedule-run timestamp was not "
                        ~ "parseable (task 2580): " ~ badIso);
                    term2Ok = false;
                    term2HardError = true;
                } else {
                    const verdict2 = checkScheduleHealth(now, scheduleRuns[0], scheduleThreshold,
                                                           format("%s (%s)", workflowLabel, workflow));
                    writeln(verdict2.message);
                    term2Ok = verdict2.ok;

                    double[] drifts;
                    foreach (t; scheduleRuns) drifts ~= scheduleDriftMinutes(t, target);
                    const stats = computeDriftStats(drifts);
                    writefln("nightly_freshness: %s (%s) schedule drift (task 2580): "
                           ~ "median %.1fmin (%.1fh), max %.1fmin (%.1fh) over %d "
                           ~ "schedule-triggered run%s, against target %02d:%02d UTC.",
                             workflowLabel, workflow, stats.medianMinutes, stats.medianMinutes / 60.0,
                             stats.maxMinutes, stats.maxMinutes / 60.0, cast(int) stats.count,
                             stats.count == 1 ? "" : "s", target.hour, target.minute);
                }
            }
        }
    }

    // ---- GATE OR REPORT (task 2580, item 3) — the one line. ----
    if (gateScheduleHealth && term2HardError) {
        // A term-2 fetch/parse failure, WITH gating turned on, is "could not
        // tell" — never silently folded into "stale" or "fine". Mirrors
        // term 1's own code-2 discipline above.
        return kExitError;
    }
    bool overallOk = term1Ok;
    if (gateScheduleHealth) overallOk = overallOk && term2Ok;
    return overallOk ? kExitFresh : kExitStale;
}
