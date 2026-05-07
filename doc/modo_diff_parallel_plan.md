# Parallel `run_acen_drag.py -j N`

## Goal

Run the 54-cell drag matrix on N MODO instances in parallel. Today
each case takes ~3–4 s sequential → ~3 min full matrix. With `-j 8`
on a typical workstation we'd expect ~30 s; with `-j 32` (CI box)
under 10 s. Same machinery should later cover the 200+ cells from
`move_scale_rotate_drag_test_plan.md` Phases 1–6.

## Status snapshot (2026-05-07)

| Phase | Status |
|---|---|
| 0 — sequential baseline (current)              | ✅ done |
| 1 — per-worker tmp paths in scripts            | ⬜ |
| 2 — per-worker MODO config dir + Xvfb display  | ⬜ |
| 3 — orchestrator pool + case queue             | ⬜ |
| 4 — robustness (one-worker crash ≠ matrix lost)| ⬜ |

## Constraints to design around

- **MODO is single-tenant per process** — one Xvfb display, one
  command bar, one `~/.luxology/Content` cache. Parallelism = N
  separate MODO processes, not N threads inside one.
- **Shared filesystem state** — `/tmp/modo_drag_state.json` and
  `/tmp/modo_drag_result.json` must not clash across workers.
- **MODO scripts directory** — currently `~/.luxology/Scripts/`
  (user) and `Modo902/extra/Scripts/` (system); both shared. Workers
  need either a private dir per worker or the scripts must be
  worker-aware (preferred — scripts already take CLI args via
  `lx.args()`).
- **Resource budget** — each MODO instance ≈ 600 MB RAM. `-j 32` =
  ~20 GB. Make `-j` user-controlled with sensible default (e.g.
  `min(8, cpu_count())`).
- **MODO licensing** — Foundry node-locked licenses generally allow
  multiple local processes; verify on the dev box before relying on
  it. If the license is single-instance, `-j 1` is the only option
  and the plan is moot.

## Phase 1 — per-worker tmp paths in scripts

`modo_drag_setup.py` and `modo_dump_verts.py` write to fixed paths.
Make them parameterizable via env var (read before MODO load):

```python
TMP = os.environ.get("MODO_DRAG_TMP", "/tmp")
state_path  = f"{TMP}/modo_drag_state.json"
result_path = f"{TMP}/modo_drag_result.json"
```

The orchestrator launches MODO with `MODO_DRAG_TMP=/tmp/worker_$WID`
in the env. The verifier consumes the per-worker paths via a CLI flag
(it already takes `result_path` as `argv[1]`).

Risk: `lx.eval` runs after MODO load — env var must be present at
launch time, not at script eval time. Guard by also passing the path
as an argument: `@modo_drag_setup.py $TMPDIR ...`. (Adds one extra
arg; setup script already handles `lx.args()` slicing.)

## Phase 2 — per-worker MODO config dir + Xvfb display

Today launch_modo() in `run_acen_drag.py` uses fixed `DISPLAY=:99`
and the user's home `~/.luxology/`. Per-worker:

```
display = ":{99 + worker_id}"
user_dir = f"/tmp/worker_{worker_id}/.luxology"
content_dir = MODO_CONTENT  # shared, read-only
scripts = f"{user_dir}/Scripts"
```

Setup steps per worker:
1. Start Xvfb on `display`.
2. Start matchbox-window-manager on `display`.
3. Clone (or symlink) `~/.luxology/Content` into `user_dir/Content`
   (read-only — contents-cache, large, shared).
4. Copy the harness scripts into `user_dir/Scripts`.
5. Launch MODO with `DISPLAY=display`,
   `LXP_USER_PATH=user_dir/.luxology` (MODO 9 env var), and
   `MODO_DRAG_TMP=/tmp/worker_{id}`.
6. Wait for the worker's viewport ready (per-display screenshot
   diff).

Click + xdotool calls already accept `DISPLAY` from env — wrap them
into a `Worker` class that holds `self.display` and uses it in every
xdo / mouse_drag / cmd_bar call.

## Phase 3 — orchestrator pool + case queue

```
def main():
    cases = collect_cases(filters)
    workers = [Worker(i) for i in range(args.j)]
    for w in workers:
        w.boot()  # parallel: Xvfb + MODO + ready-check

    queue   = mp.Queue()
    results = mp.Queue()
    for c in cases:
        queue.put(c)

    threads = [threading.Thread(target=worker_loop,
                                args=(w, queue, results))
               for w in workers]
    for t in threads: t.start()

    collected = []
    for _ in cases:
        collected.append(results.get())
    for t in threads: t.join()
    for w in workers: w.shutdown()

    print_summary(collected)
```

`worker_loop` is a per-thread (NOT process) loop — each thread owns
one Worker, drains the queue. Boot of N workers in parallel via
`concurrent.futures` to hide the ~3 s `Xvfb + MODO load` cost N times.

The verifier (`verify_acen_drag.py`) is pure Python, fast, no shared
state — runs in-thread per case, writes to its result-tuple, no IPC.

## Phase 4 — robustness

A single MODO instance crashing must not abort the matrix. Per-worker
loop:
- on exception (timeout, file-not-found, MODO-dead): mark the case
  `ERROR`, restart that worker (fresh Xvfb + MODO), continue draining
  the queue.
- after 3 worker-restarts in a row without a successful case, kill
  that worker for the rest of the run (avoid pathological loops).

Per-case timeout: 30 s. If MODO hangs (e.g. our `tool.attr` per-axis
hang we found in headless), worker reads timeout → marks ERROR →
restarts.

## Risks / open questions

- **License**: as noted; `modo_cl --help` mentions floating licenses
  in some Foundry docs but Modo 9 may behave differently. Worth
  trying `-j 2` first before committing to the orchestrator complexity.
- **`/tmp` filesystem load**: 32 workers × per-case JSON I/O is fine;
  /tmp is tmpfs on Linux.
- **xdotool race**: separate DISPLAYs are independent X servers, no
  cross-contamination, but a typo in the orchestrator passing the
  wrong DISPLAY env to the wrong xdo call leads to "test passes on a
  different worker's screen". Mitigate by funnelling all xdo calls
  through `Worker.xdo()` that injects the correct env every time.
- **Output ordering**: workers finish in nondeterministic order; the
  summary should still be deterministic — sort `collected` by case
  name before printing.
- **Boot time amortization**: at `-j 32` the boot of 32 MODO
  instances takes ~3 s if parallel, ~96 s if serial. Boot must be
  parallel. Under high contention it may stretch to 10–15 s; budget
  for it.

## Recommended order

1. Phase 1 — small, independent, testable in isolation (run
   `MODO_DRAG_TMP=/tmp/foo run_acen_drag.py 'scale_*'` and verify all
   I/O lands in `/tmp/foo`).
2. Phase 2 — wrap once, test with `-j 1` first, then `-j 2`.
3. Phase 3 — only meaningful at `-j 4+`.
4. Phase 4 — once 3 is solid; flake-handling is the hardest part.

## Out of scope

- **CI integration**: this plan assumes local dev runs. Adding to
  GitHub Actions would need MODO-on-CI which we don't have.
- **Cross-machine distribution**: `-j 32` is one-machine. Sharding
  across machines (e.g. one box per pattern) is a separate project.
- **vibe3d-side parallelism**: see `vibe3d_modo_drag_parity_plan.md`.
  vibe3d is single-instance per matrix run regardless of worker
  count — the HTTP API serializes requests internally.
