# Move / Scale / Rotate: drag-test coverage against MODO

## Goal

Extend `tools/modo_diff/run_acen_drag.py` from a 54-cell ACEN-mode
slice into a thorough behavioural cross-check of the three transform
tools (Move / Scale / Rotate) against MODO 9 ground truth.

Today's harness already exercises ONE axis of variation (ACEN mode)
per tool; this plan adds the other axes — gizmo handle, AXIS mode,
selection type, falloff, drag direction / magnitude — so that a
regression in any of them flags during cross-check rather than only
when a user notices visually.

## Status snapshot (2026-05-07)

| Phase | Status | Cells |
|---|---|---|
| 0 — current baseline (ACEN modes)         | ✅ done | 54 |
| 1 — handle coverage (which gizmo dragged) | ⬜ not started | +60 ≈ 114 |
| 2 — AXIS modes                            | ⬜ not started | +90 ≈ 204 |
| 3 — selection types (vert / edge)         | ⬜ not started | +36 ≈ 240 |
| 4 — drag direction / magnitude            | ⬜ not started | +24 ≈ 264 |
| 5 — falloff (soft selection)              | ⬜ not started | +12 ≈ 276 |
| 6 — symmetry                              | ⬜ not started | +12 ≈ 288 |

A full run at the current per-cell speed (~3.5 s) would be ~17 minutes
end-to-end at Phase 6. Run subsets via `PATTERNS=` / `TOOLS=` / `MODES=`
env overrides; full matrix would be a once-per-release cross-check
rather than per-commit.

## What's already covered (Phase 0)

Matrix: 3 tools × 3 patterns × 6 ACEN modes = 54 cells.

- **tools**: scale, move, rotate
- **patterns**: single_top (cube top face), asymmetric (3 disjoint cube
  polys), sphere_top (sphere top half)
- **ACEN modes**: select, selectauto, auto, border, origin, local

Per cell: drag from `(1020, 560)` (lands on a gizmo handle for both
small sphere and larger cube) by 100 px right; verify pivot /
distance-preservation / per-cluster invariants depending on tool.

## What's missing

### Axis 1: which gizmo handle the user grabs

Each tool exposes multiple handles; currently we always grab the same
screen position which usually ends up on a single-axis or uniform
handle, but this masks bugs in the other handles' delta computation.

| Handle | Move | Rotate | Scale |
|---|---|---|---|
| X-axis arrow / ring  | dragAxis 0 | ring 0 | dragAxis 0 |
| Y-axis               | 1          | 1      | 1         |
| Z-axis               | 2          | 2      | 2         |
| XY plane             | 4          | —      | 4         |
| YZ plane             | 5          | —      | 5         |
| XZ plane             | 6          | —      | 6         |
| screen / uniform     | 3 (most-facing plane) | screen ring | center disk |

That's 7 distinct handles for Move / Scale and 4 for Rotate. With 3
patterns × 6 ACEN modes the matrix grows fast; restrict per-tool:

- Move:   7 handles × 3 patterns × 2 modes (select + auto) = 42
- Rotate: 4 handles × 3 patterns × 2 modes                 = 24
- Scale:  7 handles × 3 patterns × 2 modes                 = 42
- (overlap with Phase 0's drag-axis-0 single-mode tests counted
  once → adds ~60 new cells total)

### Axis 2: AXIS mode (separately from ACEN)

`AxisStage.Mode` has 9 values: World, Workplane, Auto, Select,
SelectAuto, Element, Local, Origin, Screen, Manual.

Lock ACEN to a single mode (Select, well-tested in Phase 0) and vary
AXIS. The basis vectors per cluster differ across modes, so e.g. a
move with Local AXIS produces per-cluster deltas, while move with
World AXIS produces a single global delta. Verifier branches per mode.

3 tools × 9 AXIS modes × 3 patterns = 81 cells (drop Manual = 72).
Plus a handful of fail-mode coverage where AxisStage degrades to
something else (Element when nothing's selected, etc.).

### Axis 3: selection type

Phase 0 only selects polygons. ACEN.Local in particular has separate
code paths for vertex / edge / polygon selection. To cover them:

- `vert_path`: select 4 vertices on top of cube — vertex graph
- `edge_path`: select a loop of edges — edge graph
- `multi_face`: already covered by `asymmetric`
- `single_face`: already covered by `single_top`

Selection-type axis × 3 tools × 3 ACEN modes (select / local / element)
= 36 new cells. Element mode in particular is unverified for vert /
edge selections.

### Axis 4: drag direction and magnitude

Currently always +100 px right. Cover:

- Negative drag (-100 px) — should produce mirror result
- Large drag (+500 px) — exercises numerical stability
- Diagonal drag (+100, +100) — exercises plane-drag projection
- Tiny drag (+5 px) — sub-handle threshold; verify nothing happens
  for thresholded handles

3 tools × 2 patterns × 4 directions = 24 cells. Mostly smoke-style
(does the result LOOK right) rather than per-pivot-exact since MODO's
exact drag scaling is a function of camera distance.

### Axis 5: falloff (soft-selection)

When a falloff is active, only selected verts get the FULL transform;
nearby verts get a weighted partial. vibe3d has a FalloffStage in the
pipe; MODO has equivalent `falloff.*`. To cross-check:

- Falloff modes: none, linear, smooth, screen-radius
- Pattern: select one cube vertex; falloff radius covers half the
  cube → verify weighted neighbours' positions

3 tools × 4 falloff modes = 12 cells.

### Axis 6: symmetry

`SymmetryStage` mirrors operations across X / Y / Z. With sym=X and a
move on a +X-side vertex, the -X mirror vertex should also move.

3 tools × 4 sym modes (off, X, Y, Z) = 12 cells.

## Implementation order

The biggest gap is **handle coverage** (Phase 1) — currently any
handle other than the default screen-aligned axis at (1020, 560) is
untested. A bug in any per-axis path would only show up if the user
manually clicks that handle.

1. **Phase 1 (handle coverage)** — add a `handle` parameter to
   `modo_drag_setup.py` + `run_acen_drag.py`. The setup script picks
   up the gizmo position from the live ACEN center, then computes
   target screen coords for each handle (project gizmo basis to
   screen, offset along that axis). Verifier: same per-handle
   distance / pivot / delta checks as Phase 0 but per-handle.
2. **Phase 2 (AXIS modes)** — add AXIS mode parameter to setup;
   verifier learns per-AXIS-mode predictions for axis vector.
3. **Phase 3 (selection types)** — `vert_path` / `edge_path` patterns.
4. **Phase 4 (direction / magnitude)** — drag-vector parameter.
5. **Phase 5 (falloff)** + **Phase 6 (symmetry)** — small fixed-cell
   matrices, mostly smoke + bbox sanity.

## Risks / open questions

- **Drag-position calibration**: as the matrix grows, more handles
  land at unfamiliar screen coords — already exposed by sphere/rotate
  failing at the (1000, 580) position because it hit a dead zone.
  Fix once at the orchestrator: query the live ACEN pivot via the
  state JSON, project to screen using the camera matrix from a
  WorkplaneStage probe, then offset by ±N px along the requested
  handle's projected basis.
- **Verifier divergence**: each new axis (AXIS modes, falloff, sym)
  needs its own assertion shape. The verifier is one file already
  approaching 400 lines; consider splitting per-tool / per-mode at
  Phase 2.
- **Runtime**: Phase 1-3 add ~150 cells × 3.5 s ≈ 9 min on top of the
  current 3 min — full matrix grows to ~12 min. Acceptable for a
  release-time check. CI would need a small cherry-picked smoke
  subset.
- **MODO behavioural quirks already documented** (memory:
  `vibe3d_acen_divergences.md`, `modo_acen_select_headless.md`)
  apply at every new axis too. Expect to learn 2-3 new per-mode
  divergences per phase.

## Cross-check verification matrix (target, all phases done)

|         | Phase 0 | Phase 1 | Phase 2 | Phase 3 | Phase 4 | Phase 5 | Phase 6 |
|---------|--------:|--------:|--------:|--------:|--------:|--------:|--------:|
| cells   |      54 |    +60  |    +90  |    +36  |    +24  |    +12  |    +12  |
| running |      54 |    114  |    204  |    240  |    264  |    276  |    288  |

Each phase commits to its own subdir under `tools/modo_diff/cases/`
or as a new pattern in the existing `modo_drag_setup.py`. Predictions
for new modes go into the verifier; per-mode docstrings explain the
expected invariant.

## Out of scope (call-outs)

- **vibe3d-side cross-check**: this plan tests MODO behaviour against
  predicted invariants. Verifying that *vibe3d* produces the SAME
  numbers MODO does is a separate effort — would require dumping
  vibe3d mesh state via `/api/model` after a synthesised drag, then
  comparing JSON to MODO's output. Possible but a different tool.
- **Tool Properties UI inputs**: numeric "X / Y / Z" fields,
  drop-downs etc. The harness currently exercises only mouse drag;
  Tool Properties would need additional xdotool plumbing to text-fields.
- **Undo / redo correctness**: drag-then-undo state. Touched by
  `tests/test_undo_redo.d` for vibe3d directly; cross-checking MODO
  on undo behaviour is rarely useful (we don't share the same undo
  history format).
