# Phase 7 Plan — Tool Pipe architecture

## Goal

Refactor vibe3d's tool system from monolithic per-tool implementations
into a **stack of composable stages** that mirror MODO 9's Tool Pipe
(`Modo902/help/.../tool_pipe.html`, `LXSDK_661446/include/lxtool.h`).
Each modeling tool becomes a thin "actor" body that consumes packets
exposed by the stack — Action Center, Action Axis, Falloff, Snap,
Symmetry, Workplane, etc. — instead of hard-coding center / axis /
weighting itself.

After phase 7:

- Every existing transform tool (Move / Rotate / Scale) and every new
  Tier-1+ command (Edge Extrude, Mirror, Bridge, Loop Slice…) inherits
  Action Center, Snap, Falloff, Symmetry, Workplane for free.
- A single global tool-pipe state replaces the scattered per-tool
  `cachedVp`, `pickMostFacingPlane`, `bbox-center` defaults.
- UI: minimal property-panel dropdowns per stage (full Tool Pipe
  viewport panel deferred — orthogonal to the architecture).

## Source of truth

Concrete artifacts that drive design decisions:

- `Modo902/help/.../tool_pipe.html` — user-visible model of the pipe
  (E/V/A columns, stage swap context menu, presets).
- `Modo902/help/.../modeling/action_centers.html` — semantics of each
  Action Center type (Selection / Origin / Element / Local / Auto Axis
  / Selection Center Auto Axis…).
- `Modo902/help/.../modeling/selection_falloffs.html` — falloff types
  and how they layer on tools.
- `Modo902/help/.../modeling/snapping.html` — snap-to types (Vertex /
  Edge / Face / Grid / Workplane / Background / Guide), inner/outer
  range, auto-disable rules.
- `Modo902/help/.../modeling/constraints_cut.html` — constraint modes
  (None / Guide / Background / Primitive).
- `LXSDK_661446/include/lxtool.h` — canonical task codes, ordering,
  packet UUIDs and the `LXsP_TOOL_*` packet name strings. Pin every
  stage in vibe3d to a name that matches a `LXsP_TOOL_*` so future
  parity (or Python script bridging) is straightforward.

The SDK's `lx_tool.hpp` shows the runtime contract: tools call
`vts.GetPacket(LXsP_TOOL_*)` to read state from upstream stages and
write through their own packet to downstream consumers. Vibe3d will
implement an analogous in-process API.

## Pipeline stage table

Pulled from `lxtool.h` ordering codes (`LXs_ORD_*`). Sorted by
canonical pipe order (lower hex = earlier in the pipe).

| Order | Task | Description | Vibe3d phase |
|---|---|---|---|
| `\x30` | **WORK** | Workplane — global construction-plane state | 7.1 |
| `\x31` | **SYMM** | Symmetry across X/Y/Z | 7.6 |
| `\x38` | **CONT** | Content — out of scope (asset placement) | — |
| `\x39` | **STYL** | Style — out of scope | — |
| `\x40` | **SNAP** | Snapping (vertex/edge/face/grid/work/bg) | 7.3 |
| `\x41` | **CONS** | Constraint-to-surface (background/guide/primitive) | 7.4 |
| `\x60` | **ACEN** | Action Center — origin for transforms | 7.2 |
| `\x70` | **AXIS** | Action Axis — orientation | 7.2 |
| `\x80` | **PATH** | Path generator (Pen Extrude / Curve Extrude) | 7.8 |
| `\x90` | **WGHT** | Weight / Falloff (soft selection) | 7.5 |
| `\xB0..B2` | **PINK / NOZL / BRSH** | Paint stages | OOS (no painting) |
| `\xC0` | **PTCL** | Particle generator | OOS |
| `\xD0` | **SIDE** | Side selector | Defer |
| `\xD8` | **EFFR** | Effector | OOS |
| `\xF0` | **ACTR** | Actor — the tool body | 7.0 (skeleton) |
| `\xF1` | **POST** | Post-process (auto-cleanup, weld) | 7.7 |

Out-of-scope items have no vibe3d counterpart (paint, particles,
asset content). PINK/NOZL/BRSH/PTCL/EFFR are reserved as schema
values but never enabled.

## Packet types vibe3d will implement

All names match `LXsP_TOOL_*` from `lxtool.h` for future SDK parity.

| Packet | Stage | Phase | Vibe3d concrete type |
|---|---|---|---|
| `tool.subject` | (input) | 7.0 | `SubjectPacket` — wraps current selection + edit mode |
| `tool.actionCenter` | ACEN | 7.2 | `ActionCenterPacket` — Vec3 origin + uint flags |
| `tool.axis` | AXIS | 7.2 | `AxisPacket` — Mat3 orientation |
| `tool.eltCenter` | ACEN/ELT | 7.2 | `ElementCenterPacket` — per-vertex callback |
| `tool.eltAxis` | AXIS/ELT | 7.2 | `ElementAxisPacket` — per-vertex callback |
| `tool.xfrm` | (output) | 7.0 | `TransformPacket` — final 4×4 |
| `tool.falloff` | WGHT | 7.5 | `FalloffPacket` — `float weight(Vec3 pos, uint vertIdx)` |
| `tool.symmetry` | SYMM | 7.6 | `SymmetryPacket` — `Vec3 mirror(Vec3 pos)` + axis flags |
| `tool.pathGenerator` | PATH | 7.8 | `PathGeneratorPacket` — sample a curve |
| `tool.content` | CONT | — | OOS |
| `tool.style` | STYL | — | OOS |
| `tool.texture` | (UV) | — | OOS (vibe3d has no UV system) |
| `tool.partGenerator` | PTCL | — | OOS |

Snap and Constraint don't expose packets in MODO — they mutate the
`subject` (Snap rewrites the cursor's world position; Constraint
projects vertices onto a surface). The vibe3d implementation
follows: SnapStage and ConstraintStage have a `Vec3 transform(Vec3 in)`
method called between user input and the rest of the pipe.

Workplane (WORK) similarly modifies the input frame rather than
exposing a packet — but it does expose its plane-frame as a global
property for Pen/Box/Sphere/etc. to read at activation.

## Architectural decisions

### A. Pipeline structure

`source/toolpipe/` directory:

```
toolpipe/
  pipeline.d            // Pipeline struct (ordered list of Stage)
  stage.d               // Stage interface (taskCode, ordinal, evaluate)
  packets.d             // Packet types (Subject, ActionCenter, Axis, ...)
  stages/
    workplane.d         // WorkplaneStage
    symmetry.d          // SymmetryStage
    snap.d              // SnapStage + per-type subclasses
    constraint.d        // ConstraintStage
    actcenter.d         // ActionCenterStage (Selection/Origin/Element/Local)
    axis.d              // AxisStage (World/Element/Action)
    falloff.d           // FalloffStage + Linear/Radial/Lasso
    post.d              // PostStage (auto-weld, etc.)
    path.d              // PathGeneratorStage
```

`Pipeline.evaluate(input) → output`: walks stages in ordinal order
(low → high), each one transforming the in-flight `ToolState` (a
struct holding cursor position, plane frame, action center, axis,
weights, etc.). Tools (ACTR) sit at ordinal `0xF0` and consume the
fully-populated state.

Stages are registered globally; the pipe holds an active subset
(default = a "Standard Modeling" preset matching today's behaviour).

### B. Packet bridge for existing tools

Every existing tool (Box/Sphere/Cylinder/Cone/Capsule/Torus/Pen/
Move/Rotate/Scale/Bevel/Subdivide-faceted/etc.) is wrapped as an
`ActorStage`. Phase 7.0 adds a thin shim:

- `ToolPipeContext` — single global instance.
- `Tool.draw(...)` and `Tool.onMouseButtonDown(...)` are passed the
  pipe context implicitly via a thread-local pointer (avoids
  signature-cascade through every existing tool).
- Tools query: `pipeCtx.actionCenter()`, `pipeCtx.axis()`,
  `pipeCtx.snap(cursor)`, `pipeCtx.falloffWeight(pos)`, etc.
- Default stages return identity values so behaviour is unchanged
  until a non-default stage is activated.

### C. Wire format

Stages and presets named with MODO's `LXsP_TOOL_*` strings. HTTP /
argstring API: `tool.pipe.set <stageOrdinal> <stageId>` + `tool.pipe.attr
<stageId> <attr> <value>`. Mirrors `tool.set` / `tool.attr` for the
existing actor tools.

Future MODO-Python bridge can map 1:1.

### D. Single-stage-per-task constraint

Like MODO, each task slot holds at most one stage at a time:
swapping ACEN from "Selection Center" to "Element" replaces the
existing stage. This avoids ambiguous resolution when multiple
falloffs / centers stack, and mirrors MODO's UX (the Tool Pipe
viewport's "Swap Tool" context menu).

Multiple stages CAN exist if their task codes differ — the stack
might hold {WORK, SNAP, ACEN, AXIS, FALLOFF, ACTR}. But never two
ACENs.

### E. Fallthrough behaviour for legacy tools

Existing tools (BoxTool's `pickMostFacingPlane`, every cube/sphere/
cylinder/etc.) have their own plane / center logic baked in. Phase
7.1 introduces WORK as the *authoritative* workplane source; tools
migrate one-by-one to consume it. During migration, `WorkplaneStage`
returns the same plane `pickMostFacingPlane` would compute, so each
tool's behaviour is unchanged at every step.

### F. UI minimal-viable

No Tool Pipe viewport in phase 7 — that's a separate UI sprint.
Instead, each stage exposes its own property-panel widgets (e.g.
the active falloff has a "Type" dropdown plus type-specific params).
The active stage list is a compact read-only string in the status
bar: `WORK · ACEN(sel) · AXIS(world) · FALLOFF(none) · ACTR(move)`.

### G. Scope of selection-set updates

Snap / Action Center / Falloff all want to react to the current
selection (Action Center "Selection Center" recomputes when
selection changes; Falloff "Lasso" depends on a screen-space lasso
shape). Pipe stages get a `mutationVersion` from the mesh +
`selectionVersion` from the selection arrays; they cache their
output keyed on these versions and only recompute on change.

### H. Test infrastructure

Pipeline operates on a deterministic input → output mapping.
Tier-1 tests:

- Activate a stage via `tool.pipe.set ACEN selectionCenter`.
- Run a transform.
- Assert resulting mesh has the expected geometry (compare to a
  pre-recorded baseline).

Each new stage gets one unit test of its own evaluation function
(no mesh — pure math) plus integration tests via the active tool
that consumes its packet.

### I. Migration safety

Phase 7 touches every tool. To stay green:

- Each subphase MUST keep `run_test.d --no-build` and
  `rdmd tools/modo_diff/run.d --no-build` green at their pre-7
  baselines (43 unit / 74 modo_diff / 30 blender_diff).
- New tests added per subphase exercise the new stage's behaviour
  without changing existing tool semantics.

## Subphase breakdown

Each subphase = one commit. Build + test gate at every step.

### 7.0 — Pipeline skeleton + Subject packet + ACTR wrapper

- New `source/toolpipe/` directory with `pipeline.d`, `stage.d`,
  `packets.d`.
- `Stage` interface: `uint taskCode`, `string id`, `byte ordinal`,
  `void evaluate(ref ToolState)`.
- `Pipeline` struct: `Stage[] stages` sorted by ordinal; `evaluate`
  walks all and produces a fully-populated `ToolState`.
- `ToolPipeContext` global singleton accessible to tools via a
  thread-local pointer (set in app.d's main loop).
- `SubjectPacket` constructed at pipe start from current mesh +
  selection + edit mode.
- Each existing Tool is wrapped as an `ActorStage` at ordinal `0xF0`
  via a small shim — they keep working unchanged.
- HTTP commands: `tool.pipe.list`, `tool.pipe.set`, `tool.pipe.attr`
  (no-op for now since no non-actor stages exist).
- Unit test: `tests/test_toolpipe_skeleton.d` — register a dummy
  stage, assert ordering + invocation count.

Size: ~400 LOC.

### 7.1 — Workplane (WORK)

- `WorkplaneStage` at ordinal `\x30`. Holds `Vec3 normal`, `Vec3
  axis1/axis2`, plus an "auto" mode that re-computes from the
  current camera (matches today's `pickMostFacingPlane`).
- Modes: `auto`, `worldX`, `worldY`, `worldZ`, `screen`, `selection`.
- Pen / Box / Sphere / Cylinder / Cone / Capsule / Torus migrate
  from local `pickMostFacingPlane` to `pipeCtx.workplane()`. Default
  mode `auto` keeps current behaviour.
- HTTP: `tool.pipe.attr workplane mode <mode>`.
- Unit test: cube creation with workplane forced to `worldY` regardless
  of camera; verify face winding.

Size: ~250 LOC.

### 7.2 — Action Center + Action Axis + Element variants

- `ActionCenterStage` at `\x60` with modes:
  - `selection` (bbox center; current default for Move/Rotate/Scale)
  - `origin` (world 0,0,0)
  - `element` (per-element pivot; uses ElementCenterPacket)
  - `local` (selected vertex's own coord)
  - `selectionAutoAxis` (selection center + axis aligned to bounds)
- `AxisStage` at `\x70` with modes: `world`, `local`, `element`,
  `auto`.
- `ElementCenterPacket` / `ElementAxisPacket` for per-vert callbacks.
- Move / Rotate / Scale tools query `pipeCtx.actionCenter()` and
  `pipeCtx.axis()` instead of computing bbox themselves.
- New tools enabled by this:
  - **CC.1 Element Move**: Move + ACEN=`element` + AXIS=`element`.
- Unit tests: action-center mode switches; element-mode produces
  per-element transforms.

Size: ~500 LOC.

### 7.3 — Snap

- `SnapStage` at `\x40` with type-toggles (multi-select; MODO has
  Vertex / Edge / Face / Grid / Workplane / Background / Guide as
  independent flags).
- Snap acts on the cursor's world-space position before
  `actionCenter`. Each enabled type contributes a candidate; the
  closest within `outerRange` wins.
- Visual feedback: highlight the snap target in the viewport
  (yellow circle + edge glow).
- Hold `X` keyboard to toggle (matches MODO).
- Tools that take a world-space position (Move drag, Pen click, Box
  base/height drag) feed through snap.
- Unit test: snap-to-vertex picks the nearest existing vert during
  a drag.

Size: ~600 LOC.

### 7.4 — Constraint

- `ConstraintStage` at `\x41`. Modes: `none`, `background` (project
  to a separate background mesh), `primitive` (cone / cylinder /
  sphere).
- Constraint runs after Snap, before Action Center: every vertex
  the actor wants to move first gets projected onto the constraint
  surface.
- Background mesh stored in `Mesh.background` (a second Mesh
  alongside the editable one).
- Unit test: drag a vertex onto a primitive sphere constraint;
  verify the result lies on the sphere surface.

Size: ~450 LOC.

### 7.5 — Falloff (Weight)

- `FalloffStage` at `\x90`. Types: `none`, `linear`, `radial`,
  `lasso`, `screen`.
- `FalloffPacket` — `float weight(Vec3 pos, uint vertIdx)`. Tools
  multiply per-vertex transforms by this weight.
- Linear: gradient between two world-space points.
- Radial: Gaussian at action center, configurable radius.
- Lasso: 1.0 inside the lasso polygon, 0.0 outside, smooth at edge.
- Move / Rotate / Scale all consume Falloff automatically. The
  bevel tools and primitive tools ignore it (they're not
  per-vertex; document and skip).
- Unit test: radial falloff from a center; verify verts at increasing
  distance get decreasing displacement.

Size: ~550 LOC.

### 7.6 — Symmetry

- `SymmetryStage` at `\x31`. Per-axis flags (X / Y / Z); pivot at
  origin or at action center.
- `SymmetryPacket` — `Vec3[] mirror(Vec3 pos)` returning 0..3
  mirrored copies (one per active axis combination).
- Tools loop over the mirror-copies and apply the same transform to
  each. Vertex pairing by world position with a tolerance.
- New tool enabled: **Tier 2.3 Mirror (live)**. Symmetric edits
  propagate while drawing.
- Unit test: move a vertex with X-symmetry on; verify the mirrored
  vertex moves the opposite way.

Size: ~500 LOC.

### 7.7 — Post-process (POST)

- `PostStage` at `\xF1`. Runs *after* the actor mutates the mesh.
- Default actions (toggleable):
  - `autoWeld` (within `mergeDist`)
  - `removeZeroAreaFaces`
  - `cleanupOrphans`
- The current bevel post-pass weld in `Mesh.weldCoincidentVertices`
  is the prototype — generalise.
- Unit test: bevel that produces coincident verts → POST auto-merges.

Size: ~250 LOC.

### 7.8 — Path generator (PATH)

- `PathGeneratorStage` at `\x80`. Provides a parametric curve `t →
  Vec3` for tools that need it.
- Initial source: a polyline drawn by the Pen tool (curve mode).
- New tool enabled: **Pen Extrude** — extrude the selected
  geometry along the path generator.
- `PathGeneratorPacket` — `Vec3 sample(float t)` + `int segments()`.
- Unit test: extrude a quad along a 5-vertex polyline → 4 strip
  segments.

Size: ~400 LOC (lightweight; foundation for future curve work).

### 7.9 — Status-bar UI + property-panel hookup

- Status-bar shows: `WORK · ACEN · AXIS · FALLOFF · SNAP · ACTR`,
  each clickable to open a small popup that swaps the stage.
- Property panel: when a stage is active, its tool-specific
  attributes appear in a dedicated section above the actor's own
  attributes.
- No full Tool Pipe viewport — that comes later.

Size: ~300 LOC.

## Out of scope

- **Tool Pipe viewport panel** (matches MODO's E/V/A column UI). UX
  polish; defer until usage demands it.
- **Tool presets** (save/load named pipe configurations). Defer.
- **Auto-Drop**, **Lock**, **Select Through** flags. Defer.
- **Brush / Nozzle / Pink (paint stages)**. No painting in vibe3d.
- **Particle generator (PTCL)**. No particle system.
- **Effector (EFFR)**. No effector / deformer chain.
- **Texture / UV packet**. No UV system.
- **Persistent pipe state across sessions**. Default re-load on
  startup; saved presets a Tier-3 follow-up.

## Open questions

1. **Workplane vs construction-plane in Pen** — Pen currently picks a
   plane at first click and locks it. With WORK as the global source,
   should Pen lock its OWN copy at activation (current behaviour) or
   follow WORK changes mid-edit? Proposed: lock at activation, so
   mid-edit camera moves don't twist the polygon.
2. **Snap target selection when multiple types match** — if Vertex
   AND Edge both have a candidate within range, which wins? MODO
   probably has a priority; verify in GUI.
3. **Falloff with primitive tools** — does a radial falloff make
   sense applied to "Create Box"? In MODO, falloff is a global
   modifier so technically yes. Vibe3d default: actor tools opt-in
   to falloff via a `Tool.consumesFalloff()` virtual.
4. **Constraint backbround mesh source** — vibe3d has only one
   editable Mesh in the scene. Need to add a `backgroundMesh` slot
   or accept any imported mesh as a constraint target.
5. **Symmetry pivot when ACEN = Element** — does symmetry mirror
   each per-element pivot, or use a single global pivot regardless
   of ACEN mode? Likely the latter (matches MODO behaviour).
6. **POST auto-cleanup interaction with undo** — auto-weld changes
   the mesh after the user-visible operation. Should undo revert
   both the actor edit AND the auto-cleanup as a single step?
   Proposed: yes — POST is part of the same transaction.
7. **Cursor-to-snap-target hysteresis** — to avoid jittery snap
   toggling at the boundary of `outerRange`. MODO uses inner /
   outer ranges; verify the exact semantics.

## Success metrics

- All 9 subphases land as separate commits.
- Build + unit suite + modo_diff + blender_diff stay green at every
  gate (43 unit / 74 modo_diff / 30 blender_diff baselines).
- Each new stage demonstrably works via a property-panel toggle in
  the running GUI — verified by hand for at least one combination
  (e.g. Move + Element ACEN; Move + Radial Falloff; Move + Snap to
  Vertex; Move + Symmetry X).
- New tools unlocked by the architecture work end-to-end:
  - Element Move (after 7.2)
  - Live Mirror (after 7.6)
  - Pen Extrude along curve (after 7.8)

## Size

Phase 7 ≈ 4000-5500 LOC across 10 commits — comparable in scope to
Phase 6 + Phase 5 combined. Most of the cost is the architectural
plumbing in 7.0 (cross-cuts every existing tool); subsequent stages
build on that foundation at ~300-600 LOC each.

Subphase rough breakdown:
- 7.0 Pipeline skeleton — ~400 LOC + tests
- 7.1 Workplane — ~250 LOC + tests
- 7.2 Action Center + Axis (+ Element) — ~500 LOC + tests
- 7.3 Snap — ~600 LOC + tests
- 7.4 Constraint — ~450 LOC + tests
- 7.5 Falloff — ~550 LOC + tests
- 7.6 Symmetry — ~500 LOC + tests
- 7.7 Post-process — ~250 LOC + tests
- 7.8 Path generator — ~400 LOC + tests
- 7.9 Status-bar UI + panel hookup — ~300 LOC

Tier-3 follow-ups deferred (Tool Pipe viewport, presets,
persistent state) ≈ another 1000 LOC at a later sprint.
