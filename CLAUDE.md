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
./run_test.d                    # all tests
./run_test.d test_bevel         # one test (also accepts: bevel, tests/test_bevel.d)
./run_test.d bevel selection    # subset
./run_test.d -v test_bevel      # stream the test's stdout/stderr
./run_test.d --keep             # leave vibe3d running after tests finish (for debugging)
./run_test.d --no-build         # skip `dub build`
```

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

### Recommended order before commit

1. `./run_test.d --no-build` (unit, ~10s).
2. `rdmd tools/blender_diff/run.d --no-build` (Blender, ~2 min).
3. `rdmd tools/modo_diff/run.d --no-build` (MODO, ~30s; only if MODO is installed).

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
