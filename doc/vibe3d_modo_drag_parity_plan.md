# vibe3d ↔ MODO drag-output numeric parity

## Goal

Extend `tools/modo_diff/run_acen_drag.py` so that for every case JSON
the harness drives BOTH MODO **and** vibe3d through the same operation
and asserts that the resulting mesh matches MODO's, vertex by vertex.

Today the matrix verifies that MODO behaves as we predict. vibe3d's
own behaviour is exercised by `tests/test_toolpipe_*.d` against
internal expectations, NOT against MODO. This plan closes the loop:
once green, vibe3d's drag outputs are bit-for-bit (within tolerance)
the same numbers MODO produces, on the same case.

## Status snapshot (2026-05-07)

| Phase | Cells | Status |
|---|---|---|
| 0 — case JSONs as ground truth                                     | 54   | ✅ done |
| 1 — `/api/toolpipe/eval` exposes pipe state                        | —    | ✅ done |
| 2 — `check_vibe3d_parity.py` runs vibe3d alongside MODO            | 54   | ✅ done |
| 3 — close behavioural gaps (ACEN.Border, Scale/Rotate AXIS.Local)  | 4–6  | ✅ done |
| 4 — full matrix green (pivot + per-cluster axes)                   | 54   | ✅ **54/54** — all 9 `auto` cases now closed via synthetic click + Python-replicated screenToWorkPlane prediction. Per-cluster basis verified for ACEN.Local + asymmetric. |

Three validation layers, run in order:

1. **MODO behaviour** — `run_acen_drag.py` (54 cells): real MODO
   instance under Xvfb produces the expected pivot/delta for each
   ACEN/AXIS preset.
2. **vibe3d pipeline state** — `check_vibe3d_parity.py` (45 cells,
   9 `auto` skipped): vibe3d's pipeline output matches the same
   prediction (center, per-cluster pivots, per-cluster basis).
3. **vibe3d end-to-end drag** — `check_vibe3d_drag.py` (4 cells):
   synthesises real SDL_MOUSEBUTTONDOWN/MOTION/UP events through
   `/api/play-events`, drives the actual tool. Validates the path
   below the pipeline output: arrow-handle picking, screen→world
   delta projection, per-cluster delta application in
   {Move,Scale,Rotate}.applyXxx. Currently covers:
   - move_top_y_arrow (sanity: full Move-tool round trip)
   - move_asymmetric_local_x (per-cluster axes consumed for Move)
   - scale_asymmetric_local_x (per-cluster axes consumed for Scale)
   - rotate_asymmetric_local_x (per-cluster axes consumed for Rotate)

(1 ∧ 2 ∧ 3) ⇒ vibe3d ≡ MODO at every layer that's testable without
running both engines on identical camera state.

## What we already have

- 54 case JSONs under `tools/modo_diff/drag_cases/*.json`. Each one is
  `(tool, pattern, acen_mode, drag=[x, y, dx, dy])`.
- After running a case, MODO writes:
  - `/tmp/modo_drag_state.json` — pre-drag verts, selection, clusters,
    border verts.
  - `/tmp/modo_drag_result.json` — post-drag verts + `tool_amount`
    (from `tool.attr ... ?`).
- `vibe3d` already exposes HTTP API for testing (`source/http_server.d`
  — `/api/reset`, `/api/play-events`, `/api/selection`, `/api/camera`,
  `/api/model`).

## Phase 1 — vibe3d HTTP endpoints for headless drag

Three new endpoints in `source/http_server.d`. Self-contained, no
event recording.

1. **`POST /api/scene/primitive`**
   ```json
   { "type": "cube" | "sphere", "segments": 1 }
   ```
   Resets scene, builds the primitive at origin with the same default
   parameters MODO's `prim.cube` / `prim.sphere` use (radius 0.5).

2. **`POST /api/selection/by-vert-sets`**
   ```json
   {
     "edit_mode": "polygon",
     "vert_sets": [
       [[-0.5, 0.5, -0.5], [0.5, 0.5, -0.5],
        [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5]]
     ]
   }
   ```
   Selects polygons whose vertex positions match the listed set, modulo
   ordering. Mirrors what `modo_drag_setup.py` does on MODO side.

3. **`POST /api/toolpipe/apply-drag`**
   ```json
   {
     "tool":      "move" | "scale" | "rotate",
     "acen_mode": "select" | "selectauto" | "auto" | "border"
                | "origin" | "local",
     "axis_mode": "world" | "select" | "selectauto" | "local"
                | "auto" | "screen",
     "drag": { "x": 1020, "y": 560, "dx": 100, "dy": 0 }
   }
   ```
   Drives the live tool pipeline:
   - sets ACEN + AXIS,
   - calls the tool's `onMouseDown` at `(x, y)`, then `onMouseMove`
     at `(x+dx, y+dy)`, then `onMouseUp` — same code path as
     interactive use,
   - returns the post-drag mesh inline:
   ```json
   { "verts": [[x,y,z], ...] }
   ```

   The tool needs camera state. Default to a known camera (the same one
   `modo_drag_setup.py` ends up at after MODO's app-launch, see
   `doc/modo_diff_capture_workflow.md`). Add:

4. **`POST /api/camera`** (extension of existing GET) — set
   az/el/distance/target for deterministic playback.

### Risks
- The synthetic mouseDown/mouseUp must not depend on SDL re-entrancy.
  Today tools receive `SDL_Event`; the new endpoint should bypass SDL
  by calling tool methods directly. May expose hidden state coupling.
- `select.by-vert-sets` has to deal with vertex deduplication — match
  by world position with TOL 1e-4.
- Camera must match MODO's exactly. Easiest: fix vibe3d's startup
  camera to the same az/el/distance MODO ends with after `view3d.fit`.

---

## Phase 2 — orchestrator runs vibe3d for each case

`tools/modo_diff/run_acen_drag.py` gains a vibe3d branch:

```
run_case():
    # MODO (existing)
    cmd_bar(@modo_drag_setup ...)
    mouse_drag(...)
    cmd_bar(@modo_dump_verts ...)
    modo_post = json.load("/tmp/modo_drag_result.json")["verts"]

    # vibe3d (new)
    requests.post("/api/scene/primitive",       {type, segments})
    requests.post("/api/selection/by-vert-sets",{vert_sets})
    requests.post("/api/camera",                {az, el, distance, target})
    vibe_post = requests.post("/api/toolpipe/apply-drag",
                              {tool, acen_mode, axis_mode, drag}).json()["verts"]

    diff = compare(modo_post, vibe_post, tol=0.01)
    return diff.ok
```

Compare: same Hungarian-style nearest-pair pairing as
`verify_acen_drag.py` so we don't depend on identical vertex ordering.
Report per-case max distance + which vertex.

`./run_test.d` already manages a vibe3d lifecycle for unit tests. The
parity orchestrator pulls the same lifecycle helpers (start vibe3d
once per matrix run, kill at exit).

### What the matrix becomes
- Each case has THREE outcomes: MODO-PASS, vibe3d-PASS, parity-PASS
  (vibe3d output ≈ MODO output).
- Per-case status `PASS` only when all three are green.
- New status `MODO-PASS / vibe3d-MISMATCH` flags the divergences that
  Phase 3 needs to close.

---

## Phase 3 — close behavioural gaps

`acen_modo_parity_plan.md` Phase 4 is "🟡 partial" — Scale/Rotate
per-cluster basis still TODO. Expect those cells to land in
`vibe3d-MISMATCH` after Phase 2:
- `scale_asymmetric_local` (per-cluster axes)
- `rotate_asymmetric_local`
- `scale_sphere_top_local` (per-cluster basis on smooth surface)
- `rotate_sphere_top_local`

Other potential gaps (only visible once Phase 2 lands):
- AXIS.Auto mapping when workplane is auto (we pin to world XYZ —
  MODO may differ for sphere geometry).
- xfrm.move's local-frame interpretation if vibe3d's drag delta uses
  world rather than tool axes.
- Drag-amount calibration: 100 px in MODO ↔ 100 px in vibe3d depends
  on identical camera. If off, ALL cells fail; fix Phase 1 camera
  first.

For each gap: align vibe3d to match MODO (preferred), or document the
divergence in a memory note + mark the case as `XFAIL` in the JSON
(consistent with `tools/blender_diff/`'s convention).

---

## Phase 4 — full matrix green

54 / 54 cells PASS on all three axes. CI smoke subset (~6 cells)
can be promoted into per-commit `./run_test.d` flow if MODO-side
isn't required (it is — so this stays release-time).

## Out of scope

- **MODO `polygon_bevel` / `subdivide` etc.** — covered by the older
  `tools/modo_diff/run.d` harness against `modo_cl` headless. That
  one is for mesh-op parity, not interactive-drag parity.
- **Falloff / symmetry** — covered by Phase 5/6 of
  `move_scale_rotate_drag_test_plan.md`.
- **Tool Properties UI numeric input** — same plan, also out of scope.
- **vibe3d's own internal toolpipe semantics** — `tests/test_toolpipe_*`
  cover that. This plan is purely about MODO equivalence.
