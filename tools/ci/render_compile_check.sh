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
mapfile -t VERSIONS  < <(dub describe --config="$CFG" --compiler="$DC" --data=versions            --data-list 2>/dev/null)
mapfile -t IMPORTS   < <(dub describe --config="$CFG" --compiler="$DC" --data=import-paths        --data-list 2>/dev/null)
mapfile -t STRIMPS   < <(dub describe --config="$CFG" --compiler="$DC" --data=string-import-paths --data-list 2>/dev/null)
mapfile -t DFLAGS    < <(dub describe --config="$CFG" --compiler="$DC" --data=dflags              --data-list 2>/dev/null)

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
  echo "render_compile_check: this is a source error, not a missing renderer library:" >&2
  echo "render_compile_check: nothing here links, so no build artifact can be at fault." >&2
  exit 1
fi

echo "render_compile_check: OK — every source file type-checks under --config=$CFG."
exit 0
