# Phase 7.3 — Snap (SnapStage at `\x40`)

Detailed plan for the SNAP tool-pipe stage. Lands the next slot of
the Tool Pipe between WORK (`\x30`) and ACEN (`\x60`). Source-of-
truth: MODO 9.0.2 SDK + bundled help docs + `cmdhelptools.cfg`.

## Goal

Make Move / Pen / primitive Create tools optionally snap their
cursor world-position to mesh elements (vertex / edge / edge centre
/ polygon surface / polygon centre), grid points, and the workplane.
Single `X` key (hold = temporary, tap = persistent toggle) plus a
Snapping panel for type / range / mode configuration. Renders a
yellow circle on the snap target while a candidate is in range.

## MODO source-of-truth (verified locally)

### SDK

`LXSDK_661446/include/lxtool.h`:

```c
#define LXi_TASK_SNAP   LXxID4 ('S','N','A','P')
#define LXs_TASK_SNAP   "SNAP"
#define LXs_ORD_SNAP    "\x40"        // between WORK \x30 and CONS \x41
```

`LXSDK_661446/include/lxhandles.h` — the `ILxEventTranslatePacket`
interface that tools consume for snap:

```c
SetSnapRange(self, double inner, double outer);
SnapPosition(self, toolVector, const LXtVector pos, LXtVector snapPos)
    → int       // 0 = no snap, !=0 = snap fired
SetLinearSnapConstraint(self, toolVector, center, dir);
SetPlanarSnapConstraint(self, toolVector, center, dir);
```

The "snap stage" is one or more snap-type tools pushed onto the
tool pipe. Each tool publishes its snap candidates; the event-
translate layer computes the cursor's effective world position
(closest within inner range wins).

### Snap-type tools (`cmdhelptools.cfg`)

| MODO command   | What it snaps to                          |
|----------------|-------------------------------------------|
| `snap.element` | Geometry: vertex / edge / edgeCent / polygon / polyCent (mode arg). Layers (background/foreground/both), 2D snap, fixed snap, tightness. |
| `snap.grid`    | Fixed-size grid (or dynamic 3D grid). 2D snap, distance, fixed-grid toggle. |
| `snap.pivot`   | Item pivot positions.                     |
| `snap.box`     | Item bounding-box cardinals.              |

Multiple snap stages can coexist (e.g. `snap.element` + `snap.grid`
at once). The closest candidate within the inner range wins.

### Bundled help (`help/pages/modeling/snapping.html`)

- Toggle: button + `X` key. Tap = persistent, hold = temporary.
- Inner Range: pixels at which the cursor actually snaps.
- Outer Range: pixels at which the candidate target highlights
  (pre-snap feedback).
- Three independent type groups by Mode: Global / Component
  (vert/edge/poly) / Items. Each Mode keeps its own bitmask.
- Coordinate Rounding: None / Normal / Fine / Fixed / Forced Fixed
  (with Fixed Increment scalar).
- Layers selector: Background / Active / Both — restricts which
  meshes contribute snap candidates.
- 2D Snap: ortho-only — snap on the viewport plane (uncoupled
  depth).
- Fixed Snap: cursor jumps between snap candidates instead of
  interpolating.
- Snapping snaps the *tool handle*, not the geometry directly. The
  Action Center determines what the handle is anchored to. Docs
  recommend `actr.selectauto` for typical vertex-snap workflows.

## Vibe3d adaptation

We are not building MODO; we are building a focused subset.

**In-scope** (matches existing mesh model):
- Vertex / Edge / Edge-centre / Polygon-surface / Polygon-centre
  geometry snap.
- Grid snap (dynamic + fixed-increment).
- Workplane snap (snap to workplane plane intersection — useful
  for tilted workplanes).
- Inner / outer pixel ranges.
- `X` key toggle (hold = temporary on/off, tap = persistent).
- Visual feedback: yellow circle on target + candidate highlight.

**Out-of-scope** (no analogue in vibe3d yet):
- `snap.pivot`: no item pivots — single mesh.
- `snap.box`: deferred (no item-layer concept; could snap to mesh
  bbox cardinals later).
- Layers (background/foreground/both): single mesh, irrelevant.
- 2D snap: vibe3d has no orthographic-only viewports.
- Fixed Snap: deferred (mode A/B; "interpolating" is the default).
- Coordinate Rounding (None/Normal/Fine/Fixed): deferred.
- Pen-only modes (World Axis / Straight Line / Right Angle): we have
  no Pen-Extrude tool yet; defer until Phase 7.8.
- Intersection (edge × polygon): complex, defer.
- Presets system: deferred (MODO has it; we can add later via
  popup_state).

## Architecture

### Packets (`toolpipe/packets.d`, extended)

```d
struct SnapPacket {
    bool  enabled;            // master on/off (X key state)
    uint  enabledTypes;       // bitmask, see SnapType below
    float innerRangePx;       // default 8
    float outerRangePx;       // default 24
    bool  fixedGrid;          // grid snap uses fixedGridSize
    float fixedGridSize;      // grid step in world units when fixedGrid
}

enum SnapType : uint {
    Vertex     = 1 << 0,
    Edge       = 1 << 1,
    EdgeCenter = 1 << 2,
    Polygon    = 1 << 3,
    PolyCenter = 1 << 4,
    Grid       = 1 << 5,
    Workplane  = 1 << 6,
}

// Result of a single snap query — populated by snap.snapCursor()
// (called by tools on every motion event), NOT a pipeline-published
// packet (the pipeline can't precompute the snap because it depends
// on the live cursor position).
struct SnapResult {
    Vec3   worldPos;          // snapped position, or input if !snapped
    Vec3   highlightPos;      // pre-snap candidate (within outerRange)
    bool   snapped;           // true if input was within innerRange of a candidate
    bool   highlighted;       // true if any candidate within outerRange
    SnapType targetType;      // which type fired (for highlight rendering)
    int    targetIndex;       // mesh element index (vert/edge/face) or -1
}
```

`enabledTypes` defaults to `Vertex | EdgeCenter | PolyCenter | Grid`
(the typical "geometry + grid" combo MODO ships). `enabled` defaults
to `false` (off) — matches MODO's default "no snap" state.

### Stage (`toolpipe/stages/snap.d`)

`SnapStage : Stage` — registered at `ordSnap = 0x40`. Owns the
configuration scalars (inner / outer / enabledTypes / fixedGridSize).
`evaluate()` just publishes the packet — no per-frame mesh walk
(snap candidates are computed lazily inside `snapCursor` because
they depend on the cursor position).

Attributes (HTTP / `tool.pipe.attr`):
- `enabled` (bool)
- `types` (CSV string: `"vertex,edgeCenter,polyCenter,grid"`)
- `innerRange` (float, px)
- `outerRange` (float, px)
- `fixedGrid` (bool)
- `fixedGridSize` (float, world units)

### Snap math (`source/snap.d`, new)

Single free function that tools call:

```d
SnapResult snapCursor(Vec3 cursorWorld, int screenX, int screenY,
                      const ref Viewport vp,
                      const ref Mesh mesh,
                      const ref SnapPacket cfg,
                      // verts to exclude (the dragged element itself
                      // would otherwise snap to itself):
                      const(uint)[] excludeVerts = null);
```

Internally walks each enabled snap type and collects candidates in
**screen space**; closest pixel-distance wins:

| Type        | Candidate generation                                |
|-------------|-----------------------------------------------------|
| Vertex      | project every mesh vertex; reject excluded         |
| Edge        | for each edge: closest point on segment to cursor (screen-space) |
| EdgeCenter  | midpoint of each edge                              |
| Polygon     | closest point on each face (screen-space, fan-tri) |
| PolyCenter  | centroid of each face                              |
| Grid        | quantise cursorWorld to grid step (dynamic / fixed) |
| Workplane   | project cursor ray onto workplane plane            |

Pixel-distance threshold: `≤ innerRange` snaps; `≤ outerRange`
highlights. Works in screen space (matches MODO's pixel-range
semantic; depth-independent).

### Tool integration points

Tools that produce a world-space cursor position pass it through
`snapCursor` and use the returned `worldPos`. Affected tools:

- `tools/move.d`         — drag plane intersection point
- `tools/pen.d`          — click world point on workplane
- `tools/box.d`          — base / height drag points
- `tools/sphere.d`       — base / radius drag points
- `tools/cylinder.d`     — base / height drag points
- `tools/cone.d`         — base / radius / height
- `tools/capsule.d`      — base / height
- `tools/torus.d`        — base / outer / inner radius
- `tools/transform.d`    — click-outside relocate (already projects
                           via `screenToWorkPlane` / new
                           `computeClickRelocateHit`)

For each, the integration is one extra call: replace `worldPos`
with `snapCursor(worldPos, mx, my, vp, mesh, snapCfg).worldPos`
when snap is enabled.

### Visual feedback

A new overlay handler `SnapHighlightHandler` (or inline in
`source/app.d` draw pass) renders:
- Yellow circle (8 px radius) at `SnapResult.highlightPos` when
  `highlighted` (outer-range hit but not yet snapped).
- Yellow disc + outer ring at `SnapResult.worldPos` when `snapped`.
- The hit type drives the colour / shape (vertex = disc, edge =
  short bar, face = triangle outline) — small detail, can ship
  uniform yellow in 7.3d.

Plumbed via the same overlay path as Move/Rotate handles. Tool's
`draw()` calls into the snap renderer with the last `SnapResult`
captured in `onMouseMotion`.

### `X` key handling (`source/app.d`)

- Key-down `X`: toggle `snapCfg.enabled`. Remember the pre-press
  value in a transient `snapWasEnabled` field.
- If a Move/Pen/Create drag is active when `X` is pressed: treat as
  a "hold" — pressing toggles the temporary state, releasing
  reverts.
- Detection of hold-vs-tap: timer (250 ms) — if the key-up arrives
  within the timer, it's a tap (persistent toggle); else it's a
  hold-release (revert to pre-press state).

Matches MODO's documented `X` semantic ("Hold it down during an
action to temporarily disable Snapping for that action").

## Subphases

Each subphase is a single coherent commit. Sizes are LOC estimates
including tests and comments.

### 7.3a — SnapStage skeleton + Vertex snap (~180 LOC)

- Add `SnapStage` to `toolpipe/stages/snap.d`. Publishes the
  packet, stores config scalars, accepts the `enabled` /
  `innerRange` / `outerRange` / `types` setAttrs.
- Register in `app.d` next to ACEN.
- Add `source/snap.d` with `snapCursor()` supporting only
  `SnapType.Vertex`.
- Wire `tools/move.d`'s drag motion through `snapCursor` (gated by
  `snapCfg.enabled`).
- HTTP: extend `/api/state` JSON with the snap packet.
- Unit test (`tests/test_toolpipe_snap.d`): drag a vert near another
  vert; assert the dragged vert lands exactly on the target.

### 7.3b — Edge / EdgeCenter / Polygon / PolyCenter (~180 LOC)

- Extend `snap.d` with the four geometry candidate generators
  (closest-point-on-segment, midpoint, closest-point-on-tri-fan,
  centroid).
- Per-type unit test in `test_toolpipe_snap.d`.
- Bench check: ensure 1 k-vert mesh stays sub-frame for snap walk
  (no spatial accel yet — measure, defer BVH if needed).

### 7.3c — Grid snap + Workplane snap (~140 LOC)

- Grid: snap world position to nearest grid step. Two modes:
  - Dynamic (default): grid step adapts to camera zoom (matches
    the visible grid-helper rendering in `source/shader.d`).
  - Fixed: grid step = `fixedGridSize` regardless of zoom.
- Workplane snap: project the click ray onto the workplane plane
  (= what `screenToWorkPlane` already does, made into a snap
  candidate so it competes with the geometry candidates).
- Tests: drag with grid snap → resulting vert is on a grid point.

### 7.3d — Visual feedback (~140 LOC)

- `SnapHighlightHandler` (new file `source/handlers/snap.d`).
  Yellow circle + disc renderer, takes a `SnapResult` per frame.
- `tools/move.d` (and other integrated tools) keep the last
  `SnapResult` in a private field; `draw()` forwards to the
  highlight handler.
- HTTP: extend selection / state endpoints with `lastSnap`
  (highlightPos / snapped / targetIndex) so test runs can verify
  feedback without a screenshot diff.
- Test: drag near a vert and assert the API reports the expected
  `highlighted` and `targetIndex`.

### 7.3e — `X` keybind + Snapping panel UI (~120 LOC)

- Wire `X` key in `source/app.d` event loop with the tap / hold
  logic.
- Status-bar Snapping button (toggle indicator + open-popup).
- Snapping Options popup (ImGui) — checkboxes for each `SnapType`,
  inner/outer sliders, fixed-grid toggle + size input.
- popup_state path `snap/...` for persisted UI state.
- Test: toggle snap via `/api/command snap.toggle`; verify the
  packet's `enabled` flag flips.

### 7.3f — Move / Pen / Create-tool integration (~140 LOC)

- Plumb `snapCursor` into:
  - `tools/pen.d` clicks
  - `tools/box.d`, `sphere.d`, `cylinder.d`, `cone.d`,
    `capsule.d`, `torus.d` — base / height / radius drags
  - `tools/transform.d`'s `computeClickRelocateHit` for
    click-outside-gizmo relocation
- Per-tool unit test: drag-create a primitive with snap; verify
  the corner / centre lands on the target vertex.

**Total:** ~900 LOC across 6 commits.

## Decisions (resolved)

1. **One stage, bitmask types** vs **stage-per-type (MODO)**.
   *Decision:* one `SnapStage` with `enabledTypes` bitmask. MODO's
   stage-per-type model is more flexible but adds pipe-management
   complexity (factory commands per type, ordering between snap
   stages) for no observable win in our scope. The bitmask matches
   the original `phase7_plan.md` 7.3 sketch.

2. **Where snap math lives.**
   *Decision:* free function `snap.snapCursor()` in `source/snap.d`.
   The stage publishes config; the math runs on demand in tools.
   Reason: snap depends on the live cursor position, so it can't be
   precomputed by the pipeline (which evaluates once per frame).

3. **Self-exclusion during drag.**
   *Decision:* `snapCursor` takes an `excludeVerts` slice. The
   dragged element passes its own indices so the candidate walk
   skips them. Without this, single-vert drag always snaps to
   itself (zero distance).

4. **Inner / outer range units.**
   *Decision:* screen pixels (matches MODO + matches the existing
   handler hit-test convention in `source/handler.d`). Internally
   compute screen-space distance from cursor to projected
   candidate.

5. **Layers selector.**
   *Decision:* skip. Single mesh — no foreground/background
   distinction. If we add background-mesh support (Phase 7.4
   Constraint mentions it), revisit.

6. **`X` key tap / hold disambiguation.**
   *Decision:* time-based — under 250 ms = tap (persistent toggle),
   over = hold (revert on release). Matches the MODO behaviour
   described in `snapping.html`.

7. **Highlight rendering placement.**
   *Decision:* per-tool, not in the global render pass. Each tool
   keeps its own `SnapResult` and forwards to the highlight handler
   in its `draw()`. Reason: only the tools that consume snap know
   when a snap query was made, and the snap state is fundamentally
   per-tool (Move's drag snap ≠ Pen's click snap).

8. **Default enabled types.**
   *Decision:* `Vertex | EdgeCenter | PolyCenter | Grid` — matches
   the typical first-time snap configuration users want for
   geometry alignment.

## Open questions

- Snap target-type colour / shape (vertex vs edge vs face) —
  currently planned uniform yellow. Distinguish later if user
  feedback demands.
- BVH for snap candidate filtering — defer until profiling shows
  the linear walk dominating frame time on large meshes.
- Snap during Rotate / Scale drag — unclear what semantic it
  would have. MODO's snap fires on Move-class operations and
  primitive creation; rotate/scale snap to angle/factor steps,
  not geometry. Out of scope for 7.3.
- Snap state persistence between sessions — defer to a general
  user-prefs subsystem (not yet present).

## Sizes

| Subphase | LOC  | Test LOC | Description |
|----------|------|----------|-------------|
| 7.3a     | ~180 | ~60      | SnapStage + Vertex + Move drag |
| 7.3b     | ~180 | ~80      | Edge / EdgeCenter / Polygon / PolyCenter |
| 7.3c     | ~140 | ~60      | Grid + Workplane |
| 7.3d     | ~140 | ~50      | Visual feedback |
| 7.3e     | ~120 | ~40      | X key + Snapping popup UI |
| 7.3f     | ~140 | ~80      | Pen / Create-tool integration |
| **Total**| **~900** | **~370** | |

Ships across 6 commits over the phase.

## Migration safety

- Default `snapCfg.enabled = false` reproduces current Move /
  Rotate / Scale / Pen / Create behaviour exactly. New tests added
  per subphase exercise the new stage; existing tests must pass
  unchanged at every commit.
- `SnapStage` registered always (matches WORK / ACEN pattern).
  Tools query the packet and short-circuit when `!enabled` —
  zero overhead on the non-snap path.
- `source/snap.d` is new; existing tools opt-in by adding the
  `snapCursor()` call. Tools without the call see no change.
- modo_diff / blender_diff suites don't exercise snap (they
  drive geometry through specific ops, not interactive cursor
  motion). Expected: green at every commit.

## Where this lands relative to phase7_plan.md

`doc/phase7_plan.md` lists 7.3 as "Snap" at ~600 LOC. This expanded
plan adds:
- Workplane snap as an explicit type (was implicit in MODO via
  `snap.element` mode).
- Grid fixed/dynamic split + `fixedGridSize`.
- Per-tool integration breakdown (was lumped under "tools that
  take a world-space position").
- HTTP `lastSnap` for headless test verification.

Total grew from ~600 LOC → ~900 LOC (6 commits). The original plan
stays the source-of-truth for the overall phase 7 roadmap; this doc
is the detailed breakdown for 7.3.
