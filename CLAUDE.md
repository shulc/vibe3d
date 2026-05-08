# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Vibe3D is a 3D polygon mesh editor written in **D**, inspired by MODO and LightWave3D. It uses OpenGL 3.3 Core Profile for rendering, SDL2 for windowing/input, and Dear ImGui for UI panels.

## Build & Run

```bash
dub build            # Build the project
./vibe3d             # Run the editor

# Runtime flags
./vibe3d --test                   # Start with HTTP server for automated testing
./vibe3d --playback events.log    # Replay a recorded event session
./vibe3d --no-http                # Run without HTTP server
./vibe3d --http-port 9090         # Custom HTTP port (default: 8080)
```

## Running Tests

### Unit tests (`./run_test.d`)

Tests are D programs compiled with `dmd -unittest` and exercised via an HTTP API against a running vibe3d instance. The runner (`run_test.d`, an `rdmd` script) handles `dub build`, test compilation, vibe3d lifecycle, and reports pass/fail counts:

```bash
./run_test.d                    # all tests (single worker)
./run_test.d -j 4               # parallel — 4 workers, ~2.5× faster
./run_test.d -j 8               # 8 workers — see flake note below
./run_test.d test_bevel         # one test (also accepts: bevel, tests/test_bevel.d)
./run_test.d bevel selection    # subset
./run_test.d -v test_bevel      # stream the test's stdout/stderr
./run_test.d --keep             # leave vibe3d running after tests finish (for debugging)
./run_test.d --no-build         # skip `dub build`
```

Each worker gets its own port + scratch dir, so parallel runs don't trip over each other. **Flake note:** at higher `-j` values three pre-existing race-condition flakes surface intermittently (`test_selection`, `test_http_endpoint`, `test_toolpipe_axis`); they pass in isolation and at `-j 1`. The unified `run_all.d` excludes them by default so a green run actually means "no regressions"; pass `--exclude` to `run_test.d` directly to skip them when running the unit suite alone.

The runner kills any stale `vibe3d --test` before starting, waits for the HTTP server to become responsive, and tears vibe3d down on exit (including SIGINT).

Test files live in `tests/test_*.d`. Pre-recorded event logs (JSON Lines) are in `tests/events/*.log`.

### Reference comparison: `tools/blender_diff/`

Compares vibe3d's geometry output against Blender for the same JSON case. Each case lists ops (`bevel`, `polygon_bevel`, `subdivide`, `split_edge`, `move_vertex`, `polygon_bevel`); the orchestrator runs both engines headless and reports per-vertex distance.

```bash
rdmd tools/blender_diff/run.d                              # all cases
rdmd tools/blender_diff/run.d --no-build                   # skip dub build
rdmd tools/blender_diff/run.d cube_corner_w02_s4           # one case
rdmd tools/blender_diff/run.d --keep                       # leave vibe3d alive after
```

Per-case status: `PASS` (within tolerance), `FAIL` (regression), `XFAIL` (`expected_fail: true` in the JSON, gap is documented), `XPASS` (XFAIL closed — remove the marker), `ERROR` (dump or diff crashed). Exit code is `FAIL + XPASS + ERROR`.

Requires `blender` on PATH. Cases live in `tools/blender_diff/cases/*.json`.

### Reference comparison: `tools/modo_diff/`

Sister suite for MODO 9 (`modo_cl` headless). Same case schema, currently scoped to `polygon_bevel` ops.

```bash
rdmd tools/modo_diff/run.d                                 # all cases
rdmd tools/modo_diff/run.d --no-build poly_bevel_top_face  # subset
```

Default MODO paths assume the local install at `/home/ashagarov/Program/Modo902/modo_cl`. Override via env if needed:

```bash
MODO_BIN=/path/to/modo_cl \
MODO_LD_LIBRARY_PATH=/path/to/libidn-stub-dir \
MODO_NEXUS_CONTENT=~/.luxology/Content \
rdmd tools/modo_diff/run.d
```

Headless MODO quirks (foundrycrashhandler pipe-deadlock, Python script invocation via `#python` shebang + `@filename`, selection via `modo.Polygon.select()` not `select.element`) are documented in `tools/modo_diff/README.md`. Workflow for capturing a new case from an interactive MODO session is in `doc/modo_diff_capture_workflow.md`.

### ACEN drag verification: `tools/modo_diff/run_acen_drag.py`

Drives a real `xfrm.move` / `TransformRotate` / `xfrm.scale` mouse drag in headless MODO via `xdotool`, dumps the resulting verts, and runs `verify_acen_drag.py` to check that each cluster moved consistently with the active `actr.<mode>` preset (Auto/Select/SelectAuto/Border/Element/Local/Origin/None — the last via `tool.clearTask`). Cases live in `tools/modo_diff/drag_cases/*.json`; each declares `tool`, `pattern`, `acen_mode`, optional `drag` pixel coords and `step_px` granularity.

```bash
./tools/modo_diff/run_acen_drag.py                 # all cases, single MODO
./tools/modo_diff/run_acen_drag.py -j 4            # parallel — 4 MODO + Xvfb workers (~3.7× faster)
./tools/modo_diff/run_acen_drag.py move_single_top_auto    # subset by stem
./tools/modo_diff/run_acen_drag.py 'move_*_none'           # glob
./tools/modo_diff/run_acen_drag.py --keep          # leave Xvfb / MODO running after
```

Each worker gets its own Xvfb display (`:99 + worker_id`) plus tmpdir, so workers don't fight over the global state.json the dump scripts produce. `-j 8` is supported but offers diminishing returns past `-j 4` on most hosts.

### Cross-engine drag parity: `tools/modo_diff/cross_engine_drag.py`

Re-runs each ACEN drag case against vibe3d through the SAME camera + screen pixels (HTTP `/api/camera`, `/api/play-events`) and compares post-drag vertex positions to MODO's. Useful to verify behavioural alignment at the drag-formula level — orthogonal to the per-stage state checks in `verify_acen_drag.py`.

```bash
./tools/modo_diff/cross_engine_drag.py --launch-vibe3d                           # all cases
./tools/modo_diff/cross_engine_drag.py --launch-vibe3d --step-px 1000 'move_*'   # force N=1 (single-event drag — bypasses MODO's quadratic accumulation)
./tools/modo_diff/cross_engine_drag.py --launch-vibe3d move_single_top_none      # one case
```

`--launch-vibe3d` spawns a vibe3d subprocess pinned to the same 1426×966 viewport MODO uses (cross-engine projection match). Without it, you must start `./vibe3d --test --viewport 1426x966` yourself first.

### One-shot wrapper: `./run_all.d`

Fans out to all four suites and prints a single PASS/FAIL summary. Excludes the documented flaky tests by default (`test_selection`, `test_toolpipe_axis`) so a green run actually means "no regressions".

```bash
./run_all.d                              # all suites, -j 4
./run_all.d --no-build                   # forwarded to each suite
./run_all.d -j 8                         # higher parallelism for unit + ACEN
./run_all.d --only unit                  # one suite at a time
./run_all.d --skip modo --skip acen      # skip MODO suites (e.g. on a host without MODO)
RUN_ALL_EXCLUDE=test_selection ./run_all.d   # override the default exclusions
```

### Recommended order before commit

`./run_all.d --no-build` is the canonical pre-commit run. The individual suite invocations below are still listed for cases where you want only one of them:

1. `./run_test.d --no-build -j 4` (unit, ~10s with 4 workers; supports `--exclude <name>` to skip flakes one at a time).
2. `rdmd tools/blender_diff/run.d --no-build` (Blender, ~2 min).
3. `rdmd tools/modo_diff/run.d --no-build` (MODO bevel/prim, ~30s; only if MODO is installed).
4. `./tools/modo_diff/run_acen_drag.py -j 4` (ACEN drag, only when ACEN/AXIS or transform tools were touched).

A clean change should keep all three suites at their previous PASS / XFAIL counts. New XPASS means an `expected_fail` marker can be cleaned up; new FAIL is a regression.

## Architecture

### Core Systems

**`source/app.d`** — Main loop: initializes SDL2/OpenGL/ImGui, dispatches SDL events to the active tool and handlers, renders mesh + gizmos + UI. Owns global state (mesh, selection, edit mode, active tool, camera view).

**`source/mesh.d`** — Mesh data structure (vertices, edges, faces with deduplication), Catmull-Clark subdivision, and a cube factory. Edges are stored deduplicated; faces reference vertex/edge indices.

**`source/view.d`** — Camera controller using spherical coordinates (azimuth/elevation/distance). Orbit (`Alt+LMB`), pan (`Alt+Shift+LMB`), zoom (`Ctrl+Alt+LMB`), frame-to-fit. Produces view/projection matrices.

**`source/viewcache.d`** — Screen-space caches (`VertexCache`, `EdgeCache`, `FaceBoundsCache`) that project geometry once per frame and invalidate when view/projection changes. Used for picking without repeated matrix math.

**`source/handler.d`** — Base `Handler` class for interactive 3D overlays. `ArrowHandler` and `ConeHandler` implement the transform gizmo axes. Handles mouse hover/drag in screen space.

**`source/tool.d`** + **`source/tools/`** — Abstract `Tool` base; `MoveTool`, `RotateTool`, `ScaleTool` implementations. Tools receive events first, then handlers do. Tools own their gizmo handlers.

**`source/shader.d`** — OpenGL shader compilation helpers and the concrete shaders: solid/lit (Blinn-Phong), checker overlay (face selection highlight), grid (ground plane).

**`source/eventlog.d`** — `EventLogger` records SDL events as JSON Lines. `EventPlayer` replays them, overriding mouse position for deterministic playback. Has `version(unittest)` mock hooks.

**`source/http_server.d`** — Minimal HTTP/1.1 server running in a background thread. REST endpoints: `/api/reset`, `/api/play-events`, `/api/play-events/status`, `/api/selection`, `/api/camera`, `/api/model`. Used exclusively for test automation.

**`source/math.d`** — `Vec3`, `Vec4`, matrix types, `lookAt`, perspective projection, and transform utilities.

**`source/editmode.d`** — `EditMode` enum: `Vertices`, `Edges`, `Polygons` (toggled with keys 1/2/3).

### Event & Input Flow

```
SDL Events
   │
   ├─→ EventLogger (records to JSON)
   │
   └─→ Active Tool (consumes if handled)
          └─→ Handlers (gizmo axes, etc.)
                └─→ Scene picking / selection
```

During playback, `EventPlayer` injects synthetic SDL events from the log, and mouse position is overridden to match recorded coordinates.

### Picking Strategy

- **Vertices/Edges:** projected to screen space via `ViewCache`; closest within a pixel threshold is selected.
- **Faces:** screen-space bounding box from `FaceBoundsCache`; backface-culled via face normal vs. view direction dot product.
- Geometry that is off-screen or back-facing is not pickable.

### Test Strategy

Tests use the HTTP API to:
1. Reset app state (`/api/reset`)
2. Play back a recorded event log (`/api/play-events`)
3. Poll until playback completes (`/api/play-events/status`)
4. Assert the resulting selection or camera state (`/api/selection`, `/api/camera`)

This decouples tests from the UI thread and makes them deterministic via event logs.
