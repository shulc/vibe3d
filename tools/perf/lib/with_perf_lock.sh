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
# `run_test.d` has the same problem one level down (two test runs on one
# host) and solves it the same way with its own lock file — see that
# module's "Cross-process run lock" section. This is a SEPARATE lock file:
# a perf run and a test run may legitimately overlap (different resource
# budgets), so sharing one lock would serialize two things that do not need
# to be serialized.
#
# Usage:
#   with_perf_lock.sh <timeout-seconds> -- <command> [args...]
#
# On success: waits up to <timeout-seconds> for the lock, then runs the
# command with the lock held for the command's entire lifetime (the lock's
# fd is inherited across exec and released automatically — even on a crash
# or SIGKILL — when the command's process exits).
#
# On timeout: prints a named error to stderr and exits 1 WITHOUT running the
# command. This must never degrade to "run anyway" or "skip quietly and
# exit 0" — either one measures under contention (the first) or reports a
# green that means "did not run" (the second), both of which this project
# treats as a defect shape worth naming rather than a convenience.
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

lock_path=/tmp/vibe3d-perf.lock

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

echo "with_perf_lock: acquired $lock_path — running: $*" >&2

# exec, not a plain call: fd 9 (and therefore the lock) is inherited across
# exec and released by the kernel the moment this process's last fd to the
# lock file closes, i.e. exactly when the command below exits for any
# reason (normal exit, error, or being killed) — no separate release step
# to forget, and no window where a crash leaks the lock.
exec "$@"
