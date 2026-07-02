# Interactive-tool perf harness

`run.d` is the single entry point for vibe3d's perf tooling, with four
subcommands:

- **`ops`** (bare invocation == `ops`) — the interactive `move` / `rotate` /
  `scale` tools benchmarked across a selection × falloff × symmetry × ACEN ×
  snap matrix, synthesizing real gizmo drags and reading per-stage timers out
  of `/api/perf`. See `doc/perf_harness_plan.md` for the full design.
- **`frames`** — per-frame smoothness scenarios reading `/api/frames` (task
  0195). See "`frames`" below.
- **`flame`** — attaches `perf record` to a running vibe3d and profiles ONE
  ops case or frames scenario, producing a flamegraph-ready folded-stack
  file (task 0197). See "`flame`" below.
- **`--trend`** — prints per-case median drift from the local run history,
  no vibe3d launch/build. See "History and `--trend`" below.

```bash
rdmd tools/perf/run.d                       # == `ops`, full matrix, n=316 (~100K faces)
rdmd tools/perf/run.d --no-build --n 64     # fast smoke run
rdmd tools/perf/run.d --n 64 --update-baseline   # capture baseline.json
rdmd tools/perf/run.d --n 64                # check against baseline + invariants
rdmd tools/perf/run.d --no-absolute         # relative invariants only
rdmd tools/perf/run.d --tolerance 0.5       # looser absolute threshold (+50%)
```

## Layout

```
tools/perf/run.d           subcommand dispatch + case tables + invariant
                            checkers ("policy" — kept here, not extracted)
tools/perf/lib/http.d       HTTP plumbing (reset/select/script/command/
                            play-events/perf/frames/model)
tools/perf/lib/drag.d       vec/matrix + projection + drag/eventlog
                            synthesis (a standalone copy — see D1 below)
tools/perf/lib/lifecycle.d  vibe3d process lifecycle (build/launch/
                            teardown, the `perf` buildType)
tools/perf/lib/stats.d      median/p95/ms/JSON-number helpers + the
                            FrameProbe record/stats shapes
tools/perf/lib/baseline.d   RunHeader/header-mismatch guard + the ops and
                            frames baseline.json reader/writers +
                            invariant-threshold constants
tools/perf/lib/flame.d      perf(1) record/attach/report choreography +
                            the profile-fp build
tools/perf/lib/history.d    per-host run-history JSONL append/read/`--trend`
```

`run.d` imports these as plain `import lib.xxx;` — a bare `rdmd
tools/perf/run.d` (no `-I`, exactly how `run_all.d` invokes it) resolves
them because rdmd adds the root file's own directory as an import root, so
`import lib.http;` finds `tools/perf/lib/http.d` automatically.

**D1 — why `lib/drag.d` duplicates `tests/drag_helpers.d`.** `lib/drag.d` is
a small self-contained copy of the same vec/matrix/projection/eventlog-
synthesis helpers `tests/drag_helpers.d` provides — deliberately NOT a
shared import. `tools/perf/` (an rdmd unit) and `tests/` (`run_test.d`'s
dmd static-lib build, which globs every `tests/*_helpers.d` into every test
binary) are separate compilation universes; true dedup would mean adding an
`-I tools/perf/lib` to the shared test-compile path, out of scope for a
"no behavior change" consolidation. See
`doc/perf_tooling_consolidation_plan.md` design decision D1 for the full
rationale.

## Regression detection — two levels

**Relative invariants (I1–I4)** are same-run ratios that do not drift with
hardware. They run ALWAYS (no baseline / mismatched machine included) and are
what `run_all.d`'s perf lane checks. Thresholds are generous gross-regression
guards, tuned with margin off observed n=64 ratios.

**Absolute baseline** compares each case's `kernelApply` median against
`baseline.json` (default tolerance +30%, `--tolerance`). `pipeTotal` is NOT
compared absolutely (it is pipeAcen-dominated and jitters run-to-run; pipeline
overhead is watched relatively by I4). The `snap=*` cases and sub-microsecond
selection cases are excluded from the absolute comparison (their moving-set
size / timing is not stable run-to-run).

## `run_all.d` lanes

The DEFAULT `run_all.d` perf lane runs `--n 64 --no-absolute` (the fast
relative invariants only). There is also an OPT-IN lane for the absolute
comparison:

```bash
./run_all.d --only perf-abs            # n=316, ~5 min, ABSOLUTE vs committed baseline
./run_all.d --only perf-abs --no-build # reuse an already-built perf binary
```

`perf-abs` runs `rdmd tools/perf/run.d --n 316` (no `--no-absolute`), so it
performs the full ~100K-face matrix and the absolute comparison against the
committed `baseline.json` in addition to the invariants. It is NEVER part of
the default `./run_all.d` set — it runs ONLY when explicitly selected with
`--only perf-abs`. Keep it out of routine pre-commit runs; reach for it when
you want to validate against the 100K baseline on the baseline's host.

## `frames` — per-frame smoothness scenarios (task 0195)

`rdmd tools/perf/run.d frames` is a sibling subcommand that reads
`/api/frames` (the `FrameProbe` ring buffer — per-frame phase timings +
GC deltas from the `app.d` main loop; see `doc/frame_probe_scenarios_plan.md`)
instead of `/api/perf`. It runs six scenarios, each resetting the frame
ring immediately before its measured window:

- **`orbit-dense`** — Alt+LMB camera orbit around a dense mesh, no selection,
  no tool. Exercises the draw path; F-I1 target is **0 mesh-cache rebuilds**
  (camera-only invalidation must never touch mesh caches or trigger a GPU
  upload).
- **`hover-sweep`** — a plain mouse sweep (no button) across the mesh.
  Exercises per-frame `pickVertices`/`pickEdges`/`pickFaces` hover
  resolution.
- **`drag-falloff`** — a whole-mesh `move` drag with a radial falloff
  configured. Exercises the tool/events phases with per-vertex falloff
  evaluation every motion event; **F-I2** (steady-state whole-frame,
  main-thread alloc/frame, warmup-skipped) is read off this scenario.
- **`tab-subpatch`** (task 0200) — Tab-toggle subpatch preview ON over the
  whole cage, then hold (no further toggle). Exercises the OSD preview
  rebuild path; **F-I5** asserts `subpatchPreview.count` (an `/api/perf`
  timer's `count` field, not its `ns` — a build-independent invocation
  count) stays a small bounded constant (expected 1, `K_SUBPATCH_REBUILD=2`)
  while held, catching a per-frame rebuild storm.
- **`lasso-dense`** (task 0200) — RMB lasso covering the central 60% of the
  viewport over a dense grid, Polygons mode. Selection is Marks-class
  (`change_bus.d`), not Geometry/Position, so it must not touch the mesh
  cache; **F-I6a** asserts `meshCacheRebuilds == 0`, **F-I6b** asserts the
  lasso actually engaged (`selected polygons > 0` — exact count is not
  portable across GPUs/rasterizers). The scenario looks at the grid from
  BELOW (`lib.http.setCameraElevation`) — see that function's doc comment
  for why the default above-plane camera silently selects zero faces.
- **`undo-spam`** (task 0200) — `kUndoSpamN` (8) small per-gesture `move`
  drags, then `kUndoSpamN` paced `POST /api/undo` calls. **F-I7** asserts the
  new `undoApply` counter (`source/perf_probe.d` `Cat.undoApply`, bumped once
  per successful `undo()` at `command_history.d:1090`) equals exactly N —
  immune to main-loop frame batching, unlike `meshCacheRebuilds` which only
  bounds `[1, N]`.

```bash
rdmd tools/perf/run.d frames                       # all 6 scenarios, n=316
rdmd tools/perf/run.d frames --no-build orbit       # subset by substring
rdmd tools/perf/run.d frames --n 64                 # smaller mesh, fast smoke
rdmd tools/perf/run.d frames --update-frames-baseline   # capture frames_baseline.json
rdmd tools/perf/run.d frames --no-absolute          # counter invariants only
rdmd tools/perf/run.d frames --ci --n 64            # CI mode (see below)
```

### Counter invariants F-I1 / F-I2 / F-I4 / F-I5 / F-I6 / F-I7 — always run, machine-stable

Reuses the SAME `Invariant` struct/verdict pattern as the ops matrix's I1–I4
above (`checkFramesInvariants`, alongside `checkInvariants`):

- **F-I1** (GATING) — `orbit-dense`: `meshCacheRebuilds == 0`.
- **F-I4** (GATING in dev, RECORDED/non-gating under `--ci`) — every
  scenario: `gcCollections == 0` (a stop-the-world collection during the
  measured window, counted globally across threads — see the
  GC-metric-asymmetry note in `source/perf_probe.d`). `drag-falloff` is
  always RECORDED/non-gating (it legitimately allocates enough to trip a
  collection).
- **F-I2** (RECORDED, NON-GATING) — `drag-falloff`'s steady-state alloc/frame
  (`steadyMaxAllocBytes` in the `/api/frames` response, warmup-skipped). This
  is **whole-frame main-thread allocation**, not drag-only — in `--test` the
  ImGui chrome panels rebuild every frame and may allocate, so a nonzero
  floor is expected. It is reported, not gated, until that floor is chased
  to a stable number in a follow-up (same spirit as the `drawEdges`
  35%/frame find referenced in the plan).
- **F-I5** (GATING) — `tab-subpatch`: `subpatchPreview.count` bounded
  `1..K_SUBPATCH_REBUILD` (task 0200).
- **F-I6a/F-I6b** (GATING) — `lasso-dense`: `meshCacheRebuilds == 0` +
  `selected polygons > 0` (task 0200).
- **F-I7** (GATING) — `undo-spam`: `undoApply == kUndoSpamN` exactly
  (task 0200).

### `--ci` mode (task 0200)

`frames --ci` is the mode CI runs: it downgrades **F-I4 (GC) to
RECORDED/non-gating for every scenario** — the GC-collection count
false-positives on a CI host (see the note above and task 0197) and
hardening it is task 0202's job, not this flag's — and implies
`--no-absolute` (the p99/hitch budgets are baseline-host-relative and
meaningless off that host). The GATING set under `--ci` is **F-I1 / F-I5 /
F-I6a / F-I6b / F-I7** only; F-I2/F-I4 are still printed (RECORDED) so the
numbers stay visible to a human reading the CI log.

```bash
rdmd tools/perf/run.d frames --no-build --ci --n 64
```

CI builds the `perf-count` buildType (`dub build --build=perf-count
--compiler=dmd` — debug + `version=PerfProbe`, no optimizer, dmd-buildable —
see dub.json) and runs this against it (`.github/workflows/ci.yaml`'s
`frames-invariants` step), joining the job's fail gate alongside the unit
and integration lanes.

### Absolute p99/hitch budgets — baseline-host only

Behind the SAME build/mesh/viewport/host header-match guard as the ops
matrix's absolute lane (`headerMismatch`), checked against fixed generous
ceilings (not baseline-relative growth): p99 ≤ 33ms, `hitch_33ms` ≤ 2 per
scenario. `frames_baseline.json` mirrors `baseline.json`'s shape/role (a
captured reference + header for the guard) but lives in a separate file so
it never collides with the ops baseline. On a header mismatch (different
host/build/mesh/viewport), the absolute lane is skipped and only the
counter invariants gate.

## `flame` — attach `perf record` to one case or scenario (task 0197)

`rdmd tools/perf/run.d flame <name>` profiles ONE ops case (drag or one-shot
command — any name from the `ops` table, e.g. `move/baseline`,
`delete/vertices/half`) or ONE `frames` scenario (`orbit-dense`,
`hover-sweep`, `drag-falloff`) with `perf record --call-graph dwarf`
attached, driving the target through the SAME synthesis the `ops`/`frames`
runners use so the profiled workload matches the measured one. The task
0200 scenarios (`tab-subpatch`/`lasso-dense`/`undo-spam`) are **not yet**
wired into `flame`'s capture loop — passing one of those names fails fast
with "did not match any ops case or frames scenario" rather than silently
capturing an idle no-op window.

```bash
rdmd tools/perf/run.d flame move/baseline            # ops drag case, 8s capture (default)
rdmd tools/perf/run.d flame drag-falloff              # frames scenario
rdmd tools/perf/run.d flame delete/vertices/half --capture 15 --freq 4999
rdmd tools/perf/run.d flame move/baseline --no-build  # reuse an existing binary as-is
```

**The build is `profile-fp`, not `perf`.** `flame` builds `dub build
--build=profile-fp` (optimized + frame pointers, dub.json's `profile-fp`
buildType) — NOT the PerfProbe-instrumented `perf` buildType `ops`/`frames`
use, and NOT a plain `dub build` (debug/unoptimized — bounds-checks and
asserts stay on, so the flamegraph would localize to bounds-check /
un-inlined-wrapper noise instead of the real hot line). The exact build
command is echoed to stdout. After a `flame` run, `./vibe3d` is the
profile-fp binary; a following `ops`/`frames` run WITHOUT `--no-build`
rebuilds the right one automatically (with `--no-build` it silently reuses
whatever's there — `flame` warns about this up front).

Output lands in `tools/perf/flame/out/` (gitignored): `perf.data` (raw
capture), `perf.txt` (`perf report --stdio --no-children`), and
`folded.txt` — folded stacks via `stackcollapse-perf.pl` if it's on `PATH`
(the [FlameGraph](https://github.com/brendangregg/FlameGraph) toolkit),
otherwise a raw `perf script` dump for later collation. Requires `perf`
(`linux-perf` / the distro's perf userspace tools) on `PATH`; `flame` exits
with a clear message if it's absent, before building or launching anything.

A single drag/command repeated for the full capture window can drift the
mesh/gizmo off-camera (e.g. `move/baseline` translates the whole mesh every
rep) — `flame` detects this mid-capture and resets to a fresh mesh with the
same configuration, keeping the capture window full instead of aborting.

## History and `--trend` (task 0197)

Every `ops` and `frames` run (not `flame`, not `--trend` itself) appends one
JSON line to `tools/perf/history/<host>.jsonl` (gitignored — machine-
specific, like `.test_timings.json`): the run header (buildType/compiler/
host/meshType/n/faceCount/viewport/repeats) + a timestamp + a per-case
median map (`kernelApplyMedianUs` for `ops`, `p99Ms` for `frames`).

```bash
rdmd tools/perf/run.d --trend               # last 20 runs (default)
rdmd tools/perf/run.d --trend --last 5      # last 5 runs
```

`--trend` reads the history file for the CURRENT host and prints a
per-case/scenario table of first→last median drift plus a coarse ASCII
sparkline — no vibe3d launch, no build, pure file read.

## `baseline.json` is committed but MACHINE-SPECIFIC

`baseline.json` is committed as the reference (a full n=316 / 100K run). Its
header records `buildType` / `compiler` / `host` / `meshType` / `n` /
`faceCount` / `viewport` / `repeats`; the **build-mismatch guard** in `run.d`
refuses the absolute comparison (prints a warning, falls back to relative
invariants) when any of those differ. The `host` field identifies the machine
the baseline was captured on: when the baseline records a host and the current
run is on a DIFFERENT host (even with the same toolchain), the guard prints a
`host <a> vs <b>` mismatch and auto-skips the absolute leg, falling back to the
hardware-stable relative invariants. (A legacy baseline with no `host` field
records an empty string and is NOT host-checked, so it still compares on the
other fields.) To compare absolutely on another machine, re-capture with
`--update-baseline`; the relative invariants need no baseline and are
hardware-stable.
