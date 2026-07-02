# Interactive-tool perf harness

`run.d` benchmarks the interactive `move` / `rotate` / `scale` tools across a
selection × falloff × symmetry × ACEN × snap matrix by synthesizing real gizmo
drags and reading per-stage timers out of `/api/perf`. See
`doc/perf_harness_plan.md` for the full design.

```bash
rdmd tools/perf/run.d                       # full matrix, n=316 (~100K faces)
rdmd tools/perf/run.d --no-build --n 64     # fast smoke run
rdmd tools/perf/run.d --n 64 --update-baseline   # capture baseline.json
rdmd tools/perf/run.d --n 64                # check against baseline + invariants
rdmd tools/perf/run.d --no-absolute         # relative invariants only
rdmd tools/perf/run.d --tolerance 0.5       # looser absolute threshold (+50%)
```

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
instead of `/api/perf`. It runs three scenarios, each resetting the frame
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

```bash
rdmd tools/perf/run.d frames                       # all 3 scenarios, n=316
rdmd tools/perf/run.d frames --no-build orbit       # subset by substring
rdmd tools/perf/run.d frames --n 64                 # smaller mesh, fast smoke
rdmd tools/perf/run.d frames --update-frames-baseline   # capture frames_baseline.json
rdmd tools/perf/run.d frames --no-absolute          # counter invariants only
```

### Counter invariants F-I1 / F-I2 / F-I4 — always run, machine-stable

Reuses the SAME `Invariant` struct/verdict pattern as the ops matrix's I1–I4
above (`checkFramesInvariants`, alongside `checkInvariants`):

- **F-I1** (GATING) — `orbit-dense`: `meshCacheRebuilds == 0`.
- **F-I4** (GATING) — every scenario: `gcCollections == 0` (a stop-the-world
  collection during the measured window, counted globally across threads —
  see the GC-metric-asymmetry note in `source/perf_probe.d`).
- **F-I2** (RECORDED, NON-GATING) — `drag-falloff`'s steady-state alloc/frame
  (`steadyMaxAllocBytes` in the `/api/frames` response, warmup-skipped). This
  is **whole-frame main-thread allocation**, not drag-only — in `--test` the
  ImGui chrome panels rebuild every frame and may allocate, so a nonzero
  floor is expected. It is reported, not gated, until that floor is chased
  to a stable number in a follow-up (same spirit as the `drawEdges`
  35%/frame find referenced in the plan).

### Absolute p99/hitch budgets — baseline-host only

Behind the SAME build/mesh/viewport/host header-match guard as the ops
matrix's absolute lane (`headerMismatch`), checked against fixed generous
ceilings (not baseline-relative growth): p99 ≤ 33ms, `hitch_33ms` ≤ 2 per
scenario. `frames_baseline.json` mirrors `baseline.json`'s shape/role (a
captured reference + header for the guard) but lives in a separate file so
it never collides with the ops baseline. On a header mismatch (different
host/build/mesh/viewport), the absolute lane is skipped and only the
counter invariants gate.

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
