#!/usr/bin/env bash
# render_compile_check.sh — compile-only gate for `--config=with-render` (task 0723).
#
# WHY THIS EXISTS
# ---------------
# The render configuration is built by hand (`workflow_dispatch` on build.yml)
# because a full build fetches a multi-gigabyte renderer checkout, compiles it,
# and bundles the runtime libraries. Between two manual runs the configuration
# can stop compiling for any length of time — and a configuration nobody built
# looks exactly like a configuration nobody broke. That is how three call sites
# under source/render/ drifted away from the pinned ImGui binding's API and
# stayed broken with every lane green.
#
# The breakage was at D COMPILATION, not at link. Compilation needs only the
# dependencies' D SOURCE. Linking is what needs the multi-gigabyte artifacts.
# So compilation moves into the ordinary gate and the full link stays on demand.
#
# WHY NOT `dub build --config=with-render --build=syntax`
# -------------------------------------------------------
# It does work, and it is ~8s on a warm machine. But it goes through dub's
# BUILD path, so every dependency's preBuildCommands run first, and for the
# render dependencies those commands initialise a submodule, configure CMake
# and compile a renderer. Measured on this tree, the resulting package
# directory is 6.1 GB, of which the D source dub actually needs is 496 KB —
# the rest is produced by preBuildCommands. That gate is cheap exactly as long
# as the runner's cache survives and becomes an hours-long job the first time
# it does not. A gate with that shape gets routed around, which is the disease
# this task is treating, one level up.
#
# So this checks the thing that actually rotted — OUR sources against the
# dependencies' D APIs — and nothing else:
#   * `dub describe` resolves and FETCHES dependency sources but runs NO
#     preBuildCommands (measured from a completely empty DUB_HOME: 9.7 MB
#     fetched, 17.9 s wall);
#   * `dmd -o-` type-checks our sources against them, emitting no object code.
#
# Measured cost (dmd 2.112, this tree, 390 source files):
#   warm dependency cache   ~3 s
#   empty DUB_HOME          ~18 s, 9.7 MB fetched
#
# WHAT IT DOES NOT CHECK: linking, and therefore any runtime behaviour. A
# missing renderer library, an ABI mismatch, or a backend that crashes on
# start is out of scope here and stays with the on-demand build-render job.
#
# Usage:  tools/ci/render_compile_check.sh [config]     (default: with-render)
# Exit:   0 = every source file type-checks, 1 = at least one did not.

# NOT `set -e`. The interesting outcome of this script is a NON-ZERO compiler
# exit, and under `set -e` that aborts before the closing diagnostic — a real
# failure then reads as the tool itself falling over (task 0714 hit exactly
# this while running its own negative control).
set -uo pipefail

CFG="${1:-with-render}"
DC="${DC:-dmd}"

# Repo root, so the script works from anywhere.
cd "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../.." || exit 1

command -v "$DC" >/dev/null 2>&1 || {
  echo "render_compile_check: compiler '$DC' not found on PATH" >&2; exit 1; }

echo "render_compile_check: type-checking --config=$CFG with $DC -o- (no codegen, no link)"

# --data-list flattens the whole resolved dependency tree, which is what the
# -I / -J / -version sets need to be.
# Each of these is a SEPARATE dub invocation that can fail on its own, and a
# failure here is silent by construction: dub writes to stderr, exits non-zero,
# and mapfile still succeeds with an EMPTY array. The result is not a missing
# gate but an INVERTED one — with no `-version=` flags the bindbc-opengl
# bindings hide every symbol behind GL_33, and dmd then reports
# `undefined identifier glGenVertexArrays` in OUR file. That reads as a source
# regression, and the closing diagnostic below used to assert exactly that.
# Observed on the CI runner 2026-09-02, and reproduced here by running a second
# dub concurrently: `dub describe --config=with-render` exits 1 with nothing on
# stderr but blank `Warning` lines.
#
# So: keep the exit status, and floor the population. An empty import path set
# or an empty version set is an ENVIRONMENT failure and says so.
describe_list() {
  local what="$1" errf out rc
  errf=$(mktemp) || return 1
  # stderr goes to a FILE, never merged into stdout: dub prints bare `Warning`
  # lines even on success, and merging them puts them into the flag arrays —
  # 16 import paths became 42 and the compile then failed on the garbage.
  out=$(dub describe --config="$CFG" --compiler="$DC" --data="$what" --data-list 2>"$errf")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    {
      echo "render_compile_check: ENVIRONMENT — dub describe --data=$what exited $rc"
      echo "render_compile_check: this is NOT a source error; dub said:"
      grep -vE '^[[:space:]]*Warning[[:space:]]*$' "$errf" | tail -5
    } >&2
    rm -f "$errf"
    return 1
  fi
  rm -f "$errf"
  printf '%s\n' "$out"
}

# The status must reach the script, so capture first and split second: `exit`
# inside a process substitution exits only that subshell, which is how the
# first attempt at this fix ran on to compile with empty flags anyway.
read_into() {
  local __name="$1" __what="$2" __raw
  __raw=$(describe_list "$__what") || exit 2
  if [ -z "$__raw" ]; then eval "$__name=()"; else mapfile -t "$__name" <<< "$__raw"; fi
}

read_into VERSIONS versions
read_into IMPORTS  import-paths
read_into STRIMPS  string-import-paths
read_into DFLAGS   dflags

# Population floors. `dmd` accepts an empty flag set happily and then blames our
# sources for what the flags would have declared: with no `-version=`, the
# bindbc-opengl bindings hide every symbol behind GL_33 and dmd reports
# `undefined identifier glGenVertexArrays` in OUR file. Observed on the CI
# runner 2026-09-02; the closing diagnostic used to assert that very reading.
[ "${#IMPORTS[@]}" -gt 0 ] || {
  echo "render_compile_check: ENVIRONMENT — no import paths resolved for --config=$CFG" >&2; exit 2; }
[ "${#VERSIONS[@]}" -gt 0 ] || {
  echo "render_compile_check: ENVIRONMENT — no version identifiers resolved for --config=$CFG" >&2
  echo "render_compile_check: without them the GL bindings hide their symbols and dmd blames our sources" >&2
  exit 2; }

# Source files come from dub's own file list for the ROOT package only, keyed
# on role: dub also reports `unusedSource` entries (129 of them here — the
# tests/unit/ tree that only the `tests` configuration compiles), and a naive
# directory walk would either miss configuration-specific source paths or pick
# those up. Dependency sources are deliberately NOT compiled: they are not ours
# to type-check, and this tree builds with warningsAsErrors.
mapfile -t SOURCES < <(
  dub describe --config="$CFG" --compiler="$DC" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
root = next(p for p in d["packages"] if p["name"] == d["rootPackage"])
for f in root["files"]:
    if f.get("role", "source") == "source":
        print(f["path"])
'
)

if [ "${#SOURCES[@]}" -eq 0 ]; then
  echo "render_compile_check: dub describe --config=$CFG returned no source files" >&2
  echo "render_compile_check: (dependency resolution failed, or the configuration does not exist)" >&2
  exit 1
fi

ARGS=(-o- -vcolumns)
# dub.json sets warningsAsErrors + debugMode; mirror them so this refuses
# exactly what a real build refuses.
ARGS+=(-w -debug)
for v in "${VERSIONS[@]}"; do [ -n "$v" ] && ARGS+=("-version=$v"); done
for p in "${IMPORTS[@]}";  do [ -n "$p" ] && ARGS+=("-I$p");        done
for p in "${STRIMPS[@]}";  do [ -n "$p" ] && ARGS+=("-J$p");        done
for f in "${DFLAGS[@]}";   do [ -n "$f" ] && ARGS+=("$f");          done

echo "render_compile_check: ${#SOURCES[@]} source files, ${#IMPORTS[@]} import paths"

"$DC" "${ARGS[@]}" "${SOURCES[@]}"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "render_compile_check: FAIL — --config=$CFG does not compile (dmd exit $rc)." >&2
  echo "render_compile_check: nothing here links, so no build artifact can be at fault." >&2
  echo "render_compile_check: the ${#IMPORTS[@]} import paths and ${#VERSIONS[@]} version" >&2
  echo "render_compile_check: identifiers above were resolved and non-empty, so this is a" >&2
  echo "render_compile_check: SOURCE error — an environment failure exits 2, not 1." >&2
  exit 1
fi

echo "render_compile_check: OK — every source file type-checks under --config=$CFG."
exit 0
