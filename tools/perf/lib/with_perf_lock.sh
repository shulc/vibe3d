#!/usr/bin/env bash
# Task 2030 — host-wide mutual exclusion for a perf MEASUREMENT window.
#
# Some hosts run more than one perf lane: this repository's own scheduled
# lane, plus a companion comparison job that lives in a private sibling
# repository (see doc/tasks/ for the task that added it, if present — this
# script names no such job, only the resource it protects). Two independent
# CI runner *services* can sit on one physical machine and each accept a
# job dispatch at any moment; if both measure at once, EVERY number either
# of them prints is contention noise dressed up as a result, and the failure
# is silent — each job sees a "healthy" host and reports a plausible table.
#
# This is a dedicated advisory `flock` on a fixed path in /tmp, not a clock
# window: a window assumes one scheduler deciding who runs when, which does
# not hold once a second runner service can dispatch independently of the
# first (the CLAUDE.md "check that cannot come out differently" shape — a
# guard that only one side takes protects nothing).
#
# ---------------------------------------------------------------------------
# 2026-08-30 — THE SECOND LOCK. A CLEAN HOST IS NOT A QUIET HOST.
# ---------------------------------------------------------------------------
#
# This file used to say, in the paragraph that is now gone: "a perf run and a
# test run may legitimately overlap (different resource budgets), so sharing
# one lock would serialize two things that do not need to be serialized."
# That premise has since been MEASURED FALSE, three ways:
#
#   * `nvidia-smi pmon`, 2026-08-30: an IDLE `vibe3d --test` — booted, serving
#     HTTP, doing nothing — holds ~26% of the GPU's SM. A test run keeps a
#     fleet of those alive. "Different resource budgets" was an assumption
#     about a process that turns out never to be free.
#   * doc/tasks/backlog/3380: one HEAD, one build, seven minutes between arms
#     — a quiet host against a neighbour's `run_test -j16` moved the `flip`
#     case +64% and `clone` +28%, reproducing the nightly excursion of
#     +60%/+26% deliberately.
#   * doc/tasks/backlog/3430: the contamination detector that was supposed to
#     catch this counts PROCESSES (`pgrep -x vibe3d`, twice per eight-minute
#     run). The night of 2026-08-26 reddened five cases and raised no
#     contamination flag at all. It asks "is a foreign instance alive right
#     now"; the thing that hurts is LOAD, and a neighbour that starts after
#     the first sample and dies before the second is invisible to it.
#
# So the measuring window now takes the test runner's OWN host-wide lock as
# well (`run_test.d`'s `runLockPath()`), which is what a legitimate
# concurrent test lane on this host is already holding. Note this excludes a
# NEIGHBOUR'S TEST RUN, which is what the 3380 reproduction measured; it does
# not exclude a browser, a build, or an unrelated worker. That residual is
# what the load samples below are for, and closing it properly is card 3430's
# own recommendation (per-case /proc/loadavg + /proc/stat in the history
# record), which is a schema change and is NOT done here.
#
# TRADING ONE FALSE SIGNAL FOR ANOTHER — NAMED, NOT HAND-WAVED. A neighbour
# blocked on this lock exits after its own 600s wait with `NO TESTS RAN —
# timed out after 600s waiting for another test run on this host`, which is a
# FALSE RED for that neighbour. Three things keep this from happening, and
# they are properties of the shape, not hopes:
#
#   1. THE HOLD IS PER STEP, NOT PER JOB. This script wraps ONE command and
#      releases when that command exits. `perf.yaml` wraps three timed steps
#      separately; the untimed work between them (--trend, --lane-health,
#      the summary) runs with both locks RELEASED. The perf job's own ceiling
#      is 240 minutes and is irrelevant to the hold.
#   2. THE LONGEST HOLD IS SHORTER THAN THE NEIGHBOUR'S BUDGET. The measured
#      worst single step is `ops`, 375s including its build (run 32207177526);
#      `tools` and `frames` are shorter. 375s < 600s, so ONE hold cannot
#      exhaust a neighbour's wait. (Two consecutive holds could, since flock
#      is not FIFO — that is the residual, and it is bounded by the fact that
#      each acquisition is a fresh race the neighbour also contests.)
#   3. THE WAITING IS ASYMMETRIC, ON PURPOSE. This lane waits the caller's
#      full budget (perf.yaml passes 1200s) because it is a nightly with 240
#      minutes of ceiling and can afford to yield; the neighbour waits 600s
#      because it is somebody's interactive iteration. Perf gives way by
#      WAITING, not by measuring anyway.
#
# LOCK ORDERING, so this cannot deadlock: perf lock first, then the test lock,
# always, and `run_test.d` takes ONLY the test lock and never this one. A
# cycle needs two holders acquiring in opposite orders; there is no second
# order here.
#
# Usage:
#   with_perf_lock.sh <timeout-seconds> -- <command> [args...]
#
# On success: waits up to <timeout-seconds> for EACH lock, then runs the
# command with both held for the command's entire lifetime (their fds are
# inherited across exec and released automatically — even on a crash or
# SIGKILL — when the command's process exits).
#
# On timeout: prints a named error to stderr and exits 1 WITHOUT running the
# command. This must never degrade to "run anyway" or "skip quietly and
# exit 0" — either one measures under contention (the first) or reports a
# green that means "did not run" (the second), both of which this project
# treats as a defect shape worth naming rather than a convenience.
#
# VIBE3D_PERF_SKIP_RUNTEST_LOCK=1 takes the perf lock only — the one-line
# reversal of the 2026-08-30 change, for a host where no test lane can run.
set -euo pipefail

if [ $# -lt 2 ] || [ "$2" != "--" ]; then
    echo "usage: with_perf_lock.sh <timeout-seconds> -- <command> [args...]" >&2
    exit 2
fi

timeout_s="$1"
shift 2   # drop "<timeout>" and "--"

if [ $# -eq 0 ]; then
    echo "usage: with_perf_lock.sh <timeout-seconds> -- <command> [args...]" >&2
    exit 2
fi

# The two env names below are a TEST SEAM and nothing else — the same shape
# `run_test.d --check-space PATH` and `nightly_freshness.d --last-run-iso` use:
# the flock, the wait and the refusal are all real, only the file they act on
# is supplied. `tests/unit/perf_lock_test.d` needs them because the REAL
# run-test lock is routinely held by a live test lane on this very host, so a
# behavioural test against the real path is a coin flip. No workflow sets
# them; block 1 of that test asserts the DEFAULTS are the real paths, which is
# the half that would otherwise rot.
lock_path="${VIBE3D_PERF_LOCK_PATH:-/tmp/vibe3d-perf.lock}"
# The default MUST match run_test.d's `runLockPath()`
# (tempDir() ~ "vibe3d-run-test.lock"). If that ever moves, this file silently
# stops excluding test runs and every number stays plausible — which is why
# `tests/unit/perf_lock_test.d` asserts the two agree by reading run_test.d's
# own source rather than a literal typed twice.
runtest_lock_path="${VIBE3D_PERF_RUNTEST_LOCK_PATH:-/tmp/vibe3d-run-test.lock}"

# Card 3430's residual, made visible rather than assumed away: neither lock
# excludes a browser, a build or an unrelated worker. This is a PRE-WINDOW
# sample only — this script `exec`s its command, so there is no "after" to
# print here, and the during/after sampling the card actually asks for
# (/proc/loadavg + /proc/stat per CASE, in the history record) is a schema
# change that belongs in tools/perf/run.d, not here. What this one line buys
# is that a night that started under load says so in the step log instead of
# reading as a clean result.
echo "with_perf_lock: loadavg BEFORE the measuring window: $(cat /proc/loadavg)" >&2

echo "with_perf_lock: acquiring $lock_path (timeout ${timeout_s}s)..." >&2

# Open (create if absent) fd 9 on the lock file, then take an exclusive,
# BLOCKING-with-timeout flock on that fd. `flock -w` returns 1 immediately
# once the wait elapses without ever running anything — no race with the
# command that follows.
exec 9>"$lock_path"
if ! flock -w "$timeout_s" 9; then
    echo "with_perf_lock: REFUSED — $lock_path is still held by another perf" \
         "measurement on this host after ${timeout_s}s. Two perf runs sharing" \
         "one host produce contention numbers on both; refusing to run rather" \
         "than measuring under load. If this fires repeatedly, a job is stuck" \
         "holding the lock — find it with 'fuser $lock_path' or 'lsof" \
         "$lock_path' and investigate that job, do not just raise the" \
         "timeout." >&2
    exit 1
fi

echo "with_perf_lock: acquired $lock_path" >&2

if [ "${VIBE3D_PERF_SKIP_RUNTEST_LOCK:-0}" = "1" ]; then
    echo "with_perf_lock: NOTE: VIBE3D_PERF_SKIP_RUNTEST_LOCK=1 — measuring" \
         "WITHOUT excluding a concurrent test run on this host. An idle" \
         "'vibe3d --test' alone was measured at ~26% SM on 2026-08-30, so" \
         "any number produced under this flag is comparable only with other" \
         "numbers produced under it." >&2
else
    echo "with_perf_lock: acquiring $runtest_lock_path (timeout ${timeout_s}s)..." >&2
    exec 8>"$runtest_lock_path"
    if ! flock -w "$timeout_s" 8; then
        holder=$(cat "$runtest_lock_path" 2>/dev/null | tr -d '\n')
        echo "with_perf_lock: REFUSED — $runtest_lock_path is still held after" \
             "${timeout_s}s (${holder:-holder unknown}). A test run is live on" \
             "this host: an idle 'vibe3d --test' alone holds ~26% SM" \
             "(nvidia-smi pmon, 2026-08-30), and a neighbour's 'run_test -j16'" \
             "moved this lane's flip case +64% in a deliberate reproduction" \
             "(doc/tasks/backlog/3380). A number measured beside one is" \
             "contention noise, so this refuses rather than measuring. If it" \
             "fires repeatedly, find the holder with 'fuser" \
             "$runtest_lock_path' — do not just raise the timeout, and do not" \
             "set VIBE3D_PERF_SKIP_RUNTEST_LOCK to get past it." >&2
        exit 1
    fi
    echo "with_perf_lock: acquired $runtest_lock_path" >&2
fi

echo "with_perf_lock: running: $*" >&2

# exec, not a plain call: fds 9 and 8 (and therefore both locks) are inherited
# across exec and released by the kernel the moment this process's last fd to
# each lock file closes, i.e. exactly when the command below exits for any
# reason (normal exit, error, or being killed) — no separate release step to
# forget, and no window where a crash leaks a lock.
exec "$@"
