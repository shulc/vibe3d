# Interactive-tool perf harness

`run.d` is the single entry point for vibe3d's perf tooling, with four
subcommands:

- **`ops`** (bare invocation == `ops`) — the interactive `move` / `rotate` /
  `scale` tools benchmarked across a selection × falloff × symmetry × ACEN ×
  snap matrix, synthesizing real gizmo drags and reading per-stage timers out
  of `/api/perf`, PLUS the one-shot command benches (`commandApply` timer):
  `delete`/`remove` across modes/extents and the wider tool set added
  2026-08-18 — per-face `bevel`, `inset`, `polyExtrude`, `smoothShift`,
  `thicken`, `subdivide`, `triple`, `mirror`, `collapse`, the deform trio
  `smooth`/`jitter`/`quantize`, `edgeExtend`, `edgeExtrude`, `vertexBevel`,
  `vertexExtrude`. Command sanity reads `/api/layers` (counts +
  `mutationVersion`), not the full `/api/model` dump — the 5×-growth
  commands push past the model bridge's serialization timeout. See
  `doc/perf_harness_plan.md` for the full design.
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

**Relative invariants (I1a–I4)** are same-run ratios that do not drift with
hardware. They run ALWAYS (no baseline / mismatched machine included) and are
what `run_all.d`'s perf lane checks. Thresholds are generous gross-regression
guards, tuned with margin off observed ratios.

One of them is NOT a ratio, on purpose. **I1b** is an absolute ceiling in
nanoseconds per vertex visited, because the falloff clause it belongs to used
to be `falloff=radial ≤ 6× baseline` and a ratio to the baseline case cannot
tell "falloff got worse" from "the no-falloff arm got better". On 2026-08-24
the second happened — the no-falloff arm was hoisted 4× faster — and the gate
reddened at 6.85× with the falloff arm unmoved. The pair that replaced it:

* **I1a** — per tool, the dearest whole-mesh falloff shape within 3.0× of the
  cheapest. Scale-free, so hardware and a noisy host cancel; blind to a
  regression that hits every shape equally, which is what I1b is for.
* **I1b** — per tool, no falloff case over 90 ns of `kernelApply` per vertex
  it visited (grid fixture only, since an absolute number describes a
  fixture). Its detail line also PRINTS the falloff arm's cost against the
  uniform arm — ~6.8× as of 2026-08-24 — reported and deliberately not gated.

Derivations, and the 168-measurement history both numbers come from, are in
`lib/baseline.d` beside the constants.

**Count invariants (I5–I7)** assert control flow, not time, and so are exact
rather than tuned. I5: `snapCursor` was called at all. I6: a one-shot command
case recorded a `commandApply`. I7 (task 1350) is the snap VISIBILITY mask, in
three clauses:

* **I7a**, on every `snap=*` case whose selection is `whole`: the mask is
  never REACHED. A whole-mesh drag's moving set is the entire mesh, so
  `kindExcluded` drops every candidate before a consultation can happen —
  consultations must be exactly 0, and therefore builds too. This is the
  clause that catches the mask being made eager again (including by the small
  refactor: hoisting the accessor to the top of `walkSource`).
* **I7b**, on cases that declare `exercisesVisibility`: the mask really is
  consulted AND a MASK-GATED candidate really won. The second half counts
  `snapHitGeom`, not "something snapped" — the grid/workplane tier and the
  LINE/PLANE constraints all set `snapped` without ever consulting the mask,
  so an all-false mask would otherwise pass while the query got cheaper. See
  `move/snap=vertex+partial`, whose camera flip and one-vertex moving set are
  both load-bearing.
* **I7c**, on every `snap=*` case: at most one mask build per SOURCE WALK,
  i.e. `builds ≤ queries × (1 primary + N visible background layers)`. The
  background count is measured per case from `/api/layers`, so a multi-layer
  case would not false-fail it.

**Absolute baseline** compares each case's `kernelApply` median against
`baseline.json` (default tolerance +30%, `--tolerance`) — or, for a case with
a row in `baseline_debt.json`, against its **ledgered debt** (see below).
`pipeTotal` is NOT compared absolutely (it is pipeAcen-dominated and jitters
run-to-run; pipeline overhead is watched relatively by I4). Sub-microsecond
selection cases are excluded (baseline under `ABS_NOISE_FLOOR_US` = 50 µs;
a percentage comparison there is timer granularity). **The `snap=*` cases are
no longer excluded** — task 1460 falsified the stated reason with the
harness's own data: all seven snap rows in `baseline.json` carry
`vertsTouched = 2009780`, bit-identical to `move/baseline`, because a `whole`
case means an empty selection means the whole mesh and snapping alters the
DELTA, not the SET. They were hiding a +34…+40 % regression.

## `baseline_debt.json` — the debt ledger (task 1460)

`baseline.json` was recorded 2026-06-07 and the 2026-08-19 tree was measurably
slower than it on ~30 cases. The two obvious repairs were both wrong, and which one was
wrong was **measured, not argued**: task 1460 Phase 0 checked out `f06c91b7`
(the commit that wrote the baseline), built it identically with the same
`ldc2`, and ran its own harness on this host at the same `n=316`. The old code
reproduced its own baseline at **median ratio 1.02** with **one** absolute
regression, against 19 on that day's main, and `vertsTouched` is bit-identical
across both. So:

* **the baseline is honest** — regenerating it would freeze two months of real
  loss as the new normal and make it invisible for good;
* **but leaving `ops` out of the nightly gate** (what the lane did until 1460)
  means a NEW regression on top of the old one reddens nothing either.

The ledger is the third option. Every unresolved, gate-worthy debt is pinned
at its measured value, with an owner, a date, its observed spread and its
sample count, and the gate compares against that pin. New loss on a ledgered
case is red immediately; the old loss stays written down instead of forgotten.
After rebasing task 1460 on 2026-09-03, the last three clean n=316 history rows
(2026-08-31 through 2026-09-02) put 22 original pins below the paid line on all
three runs. Commit `e25530a4` had hoisted the invariant transform work those
cases were charging per vertex. Those 22 rows were therefore removed as the
ledger's own expiry rule requires; 15 ledgered debts and one measured-but-not-
ledgered row remain.

The comparison runs in **both directions**, because a ledger's failure mode is
rot — an entry that outlives its regression re-admits the loss for free:

```
no entry        red   iff  cur > baseline*(1+tol)          (unchanged)
entry, high     red   iff  cur > debt*(1+tol)
entry, low      NOTICE     cur < debt*(1-k)  AND  cur <= baseline*(1+tol)
                red   iff  that notice holds on N consecutive comparable runs
```

`k = 0.10`, `N = 3` (`DEBT_IMPROVED_K` / `DEBT_IMPROVED_STREAK_N` in
`lib/baseline.d`). Three things about that low edge are load-bearing and each
has a measured reason:

* **it is relative to the DEBT, never to the baseline.** With one shared
  tolerance the two edges would be `base*(1+tol)` and `debt*(1+tol)`, whose
  green band has ratio width exactly `debt/base` — so every entry with
  `debt/base <= 1.30` is red on BOTH clauses **at the value it was just
  pinned at**. That is six of the cases the ledger exists to hold
  (`*/symmetry=X` at 1.285–1.292, `*/falloff=linear` at 1.241–1.255) and
  within 0.9 % of a seventh. Debt-relative, the green band is 1.44× wide for
  every entry whatever its ratio.
* **the streak.** `scale/falloff=cylinder` has nine recorded n=316 history
  rows and six of them sit below a baseline-relative "paid" line, so a
  one-shot rule would have deleted that entry on most nights of the past week
  for an improvement nobody made.
* **the `cur <= baseline*(1+tol)` conjunct**, which makes PARTIAL payment
  silent. Paying only the second of the two drift windows is worth −8…−9 % on
  `move/baseline` — landing at ~17 000 µs against a 13 791 µs baseline and an
  18 459 µs pin. Without the conjunct that reads as "debt paid, delete the
  entry" with +22 % still outstanding, and deleting it legalises that +22 %
  forever.

Two more properties worth knowing before editing the file:

* **entries are keyed on `historyKey`, not on the case name.** `checkAbsolute`
  looks the baseline up by `historyKey` (`name@n<meshN>` once a case pins a
  size, task 1373 F1.7), so a name-keyed entry would silently stop matching the
  moment a case acquired a pin — the exact way a case "vanishes" that 1460
  exists to close. `reconcileDebt` walks the LEDGER's keys once per run and
  fails on any entry that no longer names a live case; that check cannot live
  in `judge`, which is only ever called for cases that exist.
* **`ledgered: false` records without suppressing.** A case whose own
  reproduction spread is wider than its regression cannot carry a single
  pinned value without flapping, so it is written into the file with the
  reason and keeps comparing against the baseline.

An absent `baseline_debt.json` means an empty ledger and the pre-1460
behaviour exactly, so a dev machine or a fresh clone loses nothing.

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
instead of `/api/perf`. It runs seven scenarios, each resetting the frame
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
- **`tab-cold`** (task 1374) — the FIRST Tab on a heavy cage: the cost the
  LRU(2) topology cache exists to avoid paying twice. Warms the `OsdAccel`
  scratch buffers with one throwaway toggle, resets the scene (which now drops
  BOTH cache layers — `deactivate()` + `SubpatchPreview.dropTopologyCache()`
  in the `scene.reset` hook), then toggles again and measures. **F-I8** asserts the build really was cold (`subpatchPreview.count
  == 1` AND `subpatchTopoMiss == 1` AND `subpatchTopoHit == 0`, plus the
  chosen refinement level at the calibration point); **F-I9** bounds the
  window's total GC allocation and its frame count.

  Two things about it are load-bearing and easy to undo by accident:

  * It is registered **LAST** in `allScenarios`. `tab-subpatch` is today the
    process's first `buildPreview` — the three scenarios before it never call
    one — so it measures a virgin cold build by position alone. Insert
    `tab-cold` above it and `tab-subpatch` silently becomes a warm build
    against a populated cache: its baseline entry moves and **F-I5 stays
    green throughout**. Nothing here can detect that; the ordering is the
    only guard.
  * "Cold" means **cold topology, warm buffers**. `OsdAccel`'s ~dozen
    `scratch*` fields keep their capacity across `clear()` and are untouched
    by `destroyCache()`, so no in-process reset can reproduce a freshly
    launched process's allocation state. A user's real first Tab costs more
    than this scenario reports. The scenario PINS the warm-buffer regime (via
    its warm-up toggle) rather than inheriting whatever ran first. Measured,
    that pin holds where it matters: the window's allocation MINUS the
    per-frame ImGui floor is 79 137 568 B to within one page across nine runs,
    solo and inside the full lane alike. What is NOT pinned is the window's
    frame COUNT (47–89 observed), and since each frame carries 211 168 B of
    chrome, that is ±9 MB of F-I9's subject — which is why F-I9 bounds the
    frame count too. To measure the virgin build, relaunch the process per
    repeat.

  In DEV runs `tab-cold` reports a standing absolute-budget failure
  (`K_FRAMES_P99_MS = 33` vs a p99 in the hundreds of ms), exactly as
  `tab-subpatch` already does. CI is unaffected: `--ci` implies
  `--no-absolute`.

```bash
rdmd tools/perf/run.d frames                       # all 7 scenarios, n=316
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
  GC-metric-asymmetry note in `source/perf_probe.d`). `tab-cold` is always
  RECORDED/non-gating (a cold preview build's one-shot working set crosses a
  GC pool threshold by construction — zero collections there would mean the
  build did not happen).
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
- **F-I8** (GATING) — `tab-cold`: `subpatchPreview.count == 1` AND
  `subpatchTopoMiss == 1` AND `subpatchTopoHit == 0` (task 1374). All three
  are needed. `count` alone cannot see coldness — `Cat.subpatchPreview`'s
  scope timer opens at the TOP of `buildPreview`, above the cache lookup, so
  a 77 ms cache hit reads as one "rebuild" too; that is what the two new
  counters split. And `hit == 0` alone cannot see a build at all: the
  layer-2 reuse (`SubpatchPreview.reusablePreviewKey`) short-circuits before
  `buildPreview` is entered, showing `count == 0 / miss == 0 / hit == 0`.
  A fourth term, gated only at the `grid n=316` calibration point, pins the
  chosen refinement level (`K_TAB_COLD_CALIB_LEVEL`) — without it
  `Cat.subpatchLevelChosen` has no live witness anywhere, since
  `perfCounterSum` answers 0 for an absent key.
- **F-I9** (GATING) — `tab-cold`: the measured window's TOTAL main-thread GC
  allocation ≤ `K_TAB_COLD_ALLOC_BYTES`, **and** its frame count inside
  `K_TAB_COLD_FRAMES_LO..HI` (task 1374). Deliberately the window SUM, not the
  worst frame: two frames here are expensive (the stencil build, then the
  limit-surface upload / first draw) and which is slowest flips between runs,
  so a worst-frame bound would change its own subject with no regression
  having happened. The worst frame's bytes are reported in the detail line,
  non-gating, together with the chrome-free residual.

  The frame band is not padding — the byte bound alone is one-sided and can
  only get easier. Measured: `gcAllocBytes = 79 137 568 B + 211 168 B ×
  frameCount`, exactly, across nine runs. Replace the post-build sweep with a
  bare sleep and the window collapses to ONE frame and 7 551 520 B — which the
  byte bound passes by 13×, and only the frame band refuses. `HI = 110` sits
  below the 118 frames at which the chrome floor alone would breach the byte
  bound, so a window that GROWS is named by the frame half instead of
  misreported as an allocation regression.
- **A scenario that ERRORs now fails the run** (task 1374 review). Scenario
  results only emit invariants under `status == OK`, so before this a
  `tab-cold` that timed out printed ERROR, contributed nothing to the failure
  count, and the run exited 0 — F-I8's silent disappearance being exactly the
  unproven measurement F-I8 exists to refuse.

### `--ci` mode (task 0200)

`frames --ci` is the mode CI runs: it downgrades **F-I4 (GC) to
RECORDED/non-gating for every scenario** — the GC-collection count
false-positives on a CI host (see the note above and task 0197) and
hardening it is task 0202's job, not this flag's — and implies
`--no-absolute` (the p99/hitch budgets are baseline-host-relative and
meaningless off that host). The GATING set under `--ci` is **F-I1 / F-I5 /
F-I6a / F-I6b / F-I7 / F-I8 / F-I9** only; F-I2/F-I4 are still printed
(RECORDED) so the numbers stay visible to a human reading the CI log.

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

## `tools` — the cost of ONE preview rebuild (task 1370)

```bash
rdmd tools/perf/run.d tools --n 96          # the lane
rdmd tools/perf/run.d tools --no-build      # reuse an existing perf binary
```

Sixteen tools rebuild a **standing preview on every drag frame** and on every
interactive attribute scrub. This lane measures one such rebuild.

**The driver is not a drag.** `POST /api/script?interactive=true` with a
`tool.attr` line raises the app's interactive latch, which is the gate these
tools' `onParamChanged` sits behind (`evaluate()` is an empty body in every
one of them), so one HTTP call produces **exactly one** `rebuildPreview()`.
A synthesized drag would produce ~20 and require dividing by a frame count.
Posting the same `tool.attr` through plain `/api/command` is **inert** — the
latch never rises and the tool never rebuilds.

**What the number is.** `med` is one `rebuildPreview`, **not one preview
frame**: a real drag additionally pays the frame loop's cache invalidation,
GPU upload and draw, which this driver never triggers between calls. Treat it
as a strict lower bound on a drag frame.

**The decomposition.** Three timers, and the third column is the point:

| timer | opened in | what it is |
|---|---|---|
| `toolPreview` | each tool's `rebuildPreview()` / `rebuildCut()` | the whole call |
| `previewRestore` | `snapshot.d:MeshSnapshot.restore` | ~16 array dups + `buildLoops` |
| `previewRefresh` | `display_sync.d:refreshDisplay` | `gpu.upload` + 3 cache resizes |

```
kernel = toolPreview - previewRestore - previewRefresh
share  = kernel / toolPreview
```

Two edits in the shared callees decompose the wrapper for all sixteen tools.
It is **not** `toolPreview - cacheInvalidate - gpuUpload`: those two are
opened in app.d's MAIN FRAME LOOP, so that subtraction mixes frame-loop
samples into a command-path window and its sign depends on the frame rate.

**Measured shares** (n=96 grid, perf build, 2026-08-19) — `vert.merge` 65%,
`poly.bevel` 89%, `edge.extend` 91%, `poly.extrude`/`smoothShift` 91%,
`mesh.vertexBevel` 92%, `edge.bevel` 96%, `polyInset` 97%. The shared wrapper
is 2–35% of a rebuild, so a per-tool case CAN go red on its own kernel: a 2x
kernel regression takes `k + w` to `2k + w`, a ratio of `1 + share`, i.e.
+65% at the worst share measured — well past the +30% tolerance.

Only the `polyInset` figure comes from this lane. **The other seven were
measured once by a throwaway script**, off the same three timers but outside
`run.d`, to answer the one question that decided the scope cut; they are
recorded here as evidence, not as a standing measurement, and nothing
re-checks them. That is also why the exclusion table below counts SIXTEEN
instrumented tools while the lane ships **one case**: the instrumentation is
lane-wide, the coverage is not.

**Invariants.** `L1` — the lane produced every case it was asked for: N OK,
0 ERROR, **and `OK > 0`**. A case whose `tool.set`/selection fails prints
ERROR and would otherwise contribute nothing to the exit code; and a run
where every row SKIPs (a grid-pinned case under `--subdivcube`) satisfies
`OK == requested - SKIP` with an empty table, which is why the positive
count is its own conjunct. `I8a` — `toolPreview.count == repeats` exactly
(not `> 0`, which passes when the tool rebuilt once on activation and slept
through every repeat). `I8b` — the mesh really moved, checked for **both**
driven values and each against the **pristine** mesh, by **counts + one
vertex position and deliberately NOT `mutationVersion`** (the restore bumps
the version itself, so that term cannot fail). Both values, because the
measured window alternates them: several of these tools carry an
`if (width == 0) { restore; refresh; return; }` branch, and a row whose `v1`
lands on it keeps every count at `repeats` while feeding pure-wrapper
samples into the ranked median. Against the pristine mesh, because a
refusing rebuild restores first — so comparing `v1`'s result against `v0`'s
would read that restore as movement. `I8c` — one restore and one refresh per
rebuild, i.e. the decomposition is clean.

`no cases matched` is a FAILURE, not a quiet zero, in this lane and (since
task 1370's review) in `ops` and `frames` too: all three are invoked by name
from a scheduled workflow. It is the ops guard that catches a mistyped
SUBCOMMAND — the dispatch accepts exactly `ops|frames|flame|tools` and
leaves any other leading token as an ops case-name substring, so `run.d
tolls` is an ops run with a filter that matches nothing.

**What lands in history.** Under `kind: "tools"` (explicit, because the
name-shape fallback would file these as `ops`), two keys per case:
`<case>#previewRebuild` — the median of ONE rebuild, wrapper included — and
`<case>#kernelShare`. Neither is gated: `checkVsLast` returns early unless
the latest entry is an `ops` run, so no `tools` row is ever compared day over
day; they show up in `--trend` and nowhere else. The header records the size
the case ACTUALLY ran at (`ToolCase.meshN`), not the run's `--n`, so a run
that forgets `--n 96` still files rows comparable with the nightly's.

**Mesh size is frozen, not searched.** `TOOLCASE_NMAX = 96` in `run.d`,
chosen once under the perf build against a 200 ms/rebuild ceiling. Recomputing
it per run would make the number incomparable night to night. The curve is
steep — 4x the faces costs 13x, and 2.4x more costs 41x again — so raising it
buys timeout risk, not resolution.

**Coverage: 16 of the 21 tools the task statement counted.** The five that
are not family-1, with reasons:

| tool | why not |
|---|---|
| `mesh.clone` | `rebuildPreview(Vec3 delta)` is called only from `onMouseMotion`, and the tool has no `params()` — neither the attr driver nor a handle drag reaches it |
| `prim.cube` / `sphere` / `torus` | `primitive_create_tool` is Idle until a viewport gesture, and its preview restores a private `previewMesh` into a separate `previewGpu` |
| `mesh.mirrorTool` | `rebuildPreviewMesh` — private `previewMesh` + `previewGpu`, never touches the document mesh or the caches |
| `mesh.bridgeTool` | same private-preview architecture |

**A note for whoever writes the missing-instrumentation sentinel**: scanning
for `void rebuildPreview(` gets it wrong in BOTH directions. It is blind to
`rebuildPreviewMesh` by construction and blind to `LoopSliceTool.rebuildCut()`
— which IS family-1 and IS instrumented — by name, so it cannot see the two
tools most likely to be forgotten. It also matches
`create/primitive_create_tool.d:458` (`void rebuildPreview()`) and
`alignment/clone_tool.d:200` (`void rebuildPreview(Vec3 delta)`), both
deliberately uninstrumented per the table above — so it reports two FALSE
POSITIVES as well. Four wrong answers out of a one-line grep; the guard has
to key on the family (restores a snapshot into the DOCUMENT mesh, then
`refreshDisplay`), not on the method name.

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

`ops` entries carry a SECOND key for every `snap=*` case,
`<case>#snapQuery`, holding that case's `snapQuery` median (task 1350). The
absolute comparison now watches the transform kernel for these cases, but it
does not watch the snap query itself; I5 only checks that `snapCursor` was
CALLED. Before this key, a 20x regression in the query (2.4 ms → 56 ms per
drag) therefore rode in behind a fully green lane. The key needs no new gate:
`--vs-last` compares by key.

```bash
rdmd tools/perf/run.d --trend               # last 20 runs (default)
rdmd tools/perf/run.d --trend --last 5      # last 5 runs
```

`--trend` reads the history file for the CURRENT host and prints a
per-case/scenario table of first→last median drift plus a coarse ASCII
sparkline — no vibe3d launch, no build, pure file read. Entries carry a
`kind` tag (`ops`/`frames`; older tag-less lines are classified by case-name
shape) and the table only includes runs COMPARABLE with the most recent one
(same kind / buildType / meshType / n / faceCount / viewport) — an n=64
smoke run next to the n=316 matrix would otherwise fabricate thousand-percent
"drift" out of the config change alone.

### `--vs-last` — the day-over-day gate

```bash
rdmd tools/perf/run.d --vs-last                        # exit 1 on any regression
rdmd tools/perf/run.d --vs-last --vs-last-threshold 0.3 --vs-last-floor 500
```

Compares the latest history entry against the previous COMPARABLE `ops` run
and exits nonzero when any per-case kernel median grew past **that case's own
band** (task 2420 — before it, one threshold of +20% for every case). Cases
where both sides sit under the floor (default 200 µs) are skipped —
sub-100µs medians jitter multiplicatively.

**The band, and why it is not one number.** Measured over this host's whole
recorded history — 21 comparable `n=316` runs, 1299 consecutive-run
comparisons — the old +20% sat exactly on the p90 of the noise (p50 1.9%,
p75 4.9%, p90 14.4%, p95 41.3%), so it was simultaneously too loose for the
73 of 90 cases whose median move is under 5% and too tight for a noisy
handful. Raising it only widens the first hole. The gate now asks whether a
case moved further than THIS CASE moves:

* **the run's common mode** (`runScale`) — the median of every compared
  case's cur/prev ratio, divided out. It is 0.98-1.01 on 19 of 20 recorded
  pairs and does nothing; on the one pair where the host itself got 6%
  slower over four days it is 1.061 and it stops 21 cases reddening for a
  fact about the machine. Blind spot, stated: a regression that slows every
  case equally is divided out — that is the absolute lane's job (I1a/I1b and
  `baseline.json`), as it was before.
* **the case's own sample spread**, `#kernelP95Us / median` over that run's
  own repeats. Measured 2026-08-28, four consecutive runs at one HEAD on a
  quiet host: `remove/vertices/whole` reads p95/median 1.09-1.43 and swings
  29.5% (17382→22512 µs) with nothing changed, while every
  `falloff=radial|linear|cylinder` case reads 1.002-1.035 and holds inside
  2%. One column separates them; no threshold does.
* **`--vs-last-band-sigma` × the case's own PRIOR between-run spread**
  (default 5), for rows predating that column, computed from runs STRICTLY
  EARLIER than the one being judged.
* floored at `--vs-last-band-floor` (default +5%): the smallest move that can
  ever be called a regression. A +10% plant in a case whose noise is under 1%
  reds; the old gate was silent on it.

`--vs-last-flat` reproduces the pre-2420 single-threshold verdict, so the two
gates can be A/B'd over one history file. `#snapQuery` keys keep their own
**+60%** as the *no-history fallback* (`--vs-last-snap-threshold`): measured over ten
consecutive runs their worst consecutive-run step is +17.7%
(`move/snap=edge`), so +20% would flake nightly, while +60% is still a factor
of 33 — about one and a half orders of magnitude — below the regression the
key exists for (that one was +2000%). Lowering `--vs-last-threshold` below
+60% lowers the snap keys with it, so an operator hunting a small regression
is not locked out of the keys they are hunting. The derivation, with the
per-case numbers, is at `kSnapQueryVsLastThreshold` in `lib/history.d`; the
band's own derivation, its rejected alternatives and the term that was built
and then deleted for being inert are at the head of `lib/vslast.d`, and its
witness is `tests/unit/perf_vslast_gate_test.d` (which runs in
`dub test --config=tests`, the first thing under `tools/perf/` that runs in a
gate lane at all — see D1). Like `--trend` it
is a pure history read. This is the gating signal of the **nightly-perf
workflow** (`.github/workflows/perf.yaml`): it stays meaningful while the
absolute lane carries known debt, because it answers a different question —
"did TONIGHT's run regress against last night's?". (The absolute lane is no
longer *knowingly red*: task 1460 pinned the debt in `baseline_debt.json` and
`ops` gates again.)

**Contaminated runs never gate, in either direction (task 1840).** A run that
measured while a foreign vibe3d was alive on the host writes its history entry
stamped `"contaminated":true` (the entry is still written — it is the record
of what that night's host did). `--vs-last` then:

* refuses to gate FROM such an entry — it prints `NO VERDICT (FAIL)` with the
  offending pids and exits nonzero, because a green here would mean "did not
  check", not "nothing regressed";
* skips such entries when looking BACKWARD for a reference, so an inflated
  night cannot turn honest numbers into fake improvements and give a real
  regression the same room to hide in.

The worked example is 2026-08-24: one stray `./vibe3d` made `flip/polygons/
whole` read +57%, `magnet/vertices/whole` +39% and `mergeFaces/polygons/half`
+22%; re-measured on a quiet host at the same HEAD, all three came back.

## Nightly runs (`.github/workflows/perf.yaml`)

A scheduled workflow (03:30 MSK) runs the full n=316 `ops` matrix + `frames
--ci` on the dedicated `perf-fedora` self-hosted runner — the baseline host,
where the absolute comparison is valid. The runner is a systemd **user**
service (`~/.config/systemd/user/github-runner-perf.service`) bound to
`graphical-session.target`, so jobs render through the real display/GPU; it
is online only while the owner's session is. **All five signals gate** since
task 1460 — `ops` (absolute vs baseline + debt ledger), `lane-health`,
`--vs-last`, `tools` and `frames --ci`. Every step after `ops` carries
`if: always()` so an ops-red still prints the rest of the lane's diagnosis;
`vslast` acquired that guard in the same commit that made `ops` gating, and
without it the day-over-day comparison would go missing on exactly the nights
the lane went red. Run
history persists in `~/perf-history/` on the runner host (symlinked into the
workspace, out of `actions/checkout`'s clean sweep). Every other Linux CI
job targets the `ci-vm` label, so nothing else lands on this runner.

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
