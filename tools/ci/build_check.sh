#!/usr/bin/env bash
# build_check.sh — run the gating Build and say WHICH KIND of failure it was.
#
# WHY THIS EXISTS (task 3960)
# ---------------------------
# `Build` has no continue-on-error, so when it fails, unit + integration +
# frames all read `skipped` and the run summary reads `failure`. Measured over
# the 24 red CI runs of 2026-08-28..2026-09-03:
#
#   12  Set up job — "Failed to resolve action download info", HTTP timeout
#                    100s. The workflow never started. Nothing was measured.
#    2  Build      — dub could not fetch a git dependency. Four steps skipped.
#                    Nothing was measured.
#    8  the test steps ran and something was genuinely red.
#    2  neither (own line in the task file).
#
# So 14 of 24 reds meant "we learned nothing", and all 14 looked exactly like
# the 8 that meant "something is broken". That is the defect: a red that teaches
# people to press re-run without reading is worse than a green over work that
# was never done — the green lulls once, the red trains.
#
# This script cannot help the 12: nothing of ours runs before `Set up job`, and
# a runner that cannot reach GitHub to download actions is out of the
# workflow's reach entirely. It is named here so the gap is a written line and
# not an omission.
#
# THE CONVENTION, shared with tools/ci/render_compile_check.sh
# -----------------------------------------------------------
#   exit 2  ENVIRONMENT — we learned nothing. Not a verdict on the code.
#   exit 1  SOURCE      — the tree really does not build.
#   exit 0  built, and the stamp run_test.d --no-build needs was written.
#
# The classification is written to $GITHUB_STEP_SUMMARY under two DIFFERENT
# headings, and to build_class.txt for the final gate step to read, because the
# distinction is worthless if it only exists in a log nobody opens.
set -uo pipefail

CLASS_FILE="${BUILD_CLASS_FILE:-build_class.txt}"
LOG=$(mktemp)

emit_summary() {
  local heading="$1" body="$2"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    echo ""
    echo "$heading"
    echo ""
    echo "$body"
    echo ""
    echo '```'
    tail -n 20 "$LOG"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
}

echo "build_check: dub build --compiler=dmd"
dub build --compiler=dmd 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

if [ "$rc" -ne 0 ]; then
  # The environment family, by dub's own words. These are failures to OBTAIN or
  # RESOLVE inputs — they say nothing about whether our sources compile.
  # 'Unable to fetch' is the exact string from run 33715226371, reproduced
  # locally in a scratch DUB_HOME with the network forced dead.
  if grep -qE "Unable to fetch|Could not resolve|Failed to download|unable to access .*github|Could not connect to server|Connection timed out|error: RPC failed|The remote end hung up" "$LOG"; then
    echo "ENVIRONMENT" > "$CLASS_FILE"
    {
      echo "build_check: ENVIRONMENT — dub could not obtain its inputs (exit $rc)."
      echo "build_check: this is NOT a source error. NOTHING WAS MEASURED by this run."
      echo "build_check: the unit, integration and frame steps below are skipped for"
      echo "build_check: want of a binary, not because they failed."
    } >&2
    emit_summary \
      "### ⚠️ Build — ENVIRONMENT failure: nothing was measured" \
      "dub could not obtain its inputs. This run makes **no statement about the code**: the unit, integration and frame lanes were skipped for want of a binary. Re-running is legitimate here — and only here."
    exit 2
  fi

  echo "SOURCE" > "$CLASS_FILE"
  {
    echo "build_check: FAIL — the tree does not build (dub exit $rc)."
    echo "build_check: dub obtained its inputs, so this is a SOURCE error."
    echo "build_check: an environment failure exits 2, not 1."
  } >&2
  emit_summary \
    "### ❌ Build — SOURCE failure: the tree does not build" \
    "dub resolved and fetched every dependency, then the compiler refused our sources. **Do not re-run this** — it will fail again."
  exit 1
fi

# The integration lane runs --no-build and refuses a ./vibe3d it cannot tie to
# the sources on disk (task 0678). This writes the stamp that guard reads.
if ! ./run_test.d --write-stamp; then
  echo "SOURCE" > "$CLASS_FILE"
  echo "build_check: built, but --write-stamp failed" >&2
  exit 1
fi

echo "OK" > "$CLASS_FILE"
echo "build_check: OK — built, stamp written."
exit 0
