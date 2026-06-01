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

## `baseline.json` is MACHINE-SPECIFIC and LOCAL (gitignored)

Absolute timings are hardware-bound, so `baseline.json` is **not committed** —
it is gitignored and you generate your own with `--update-baseline`. Its header
records `buildType` / `compiler` / `meshType` / `n` / `faceCount` / `viewport` /
`repeats`; the **build-mismatch guard** in `run.d` refuses the absolute
comparison (prints a warning, falls back to relative invariants) when any of
those differ. NOTE: the header does NOT identify the host — so a baseline is
only meaningful on the machine that produced it. Do not copy one between
machines even if the toolchain matches; the guard cannot catch that. The
relative invariants need no baseline and are what runs in CI / `run_all.d`.
