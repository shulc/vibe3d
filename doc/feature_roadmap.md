# Feature roadmap — what's missing vs MODO

Audit of vibe3d's modeling capabilities against MODO 9 (`Modo902/help/`),
prioritized by foundational dependency + user value + complexity.

## Inventory (current state, 2026-04-30)

### What vibe3d has

| Group | Implementation |
|---|---|
| Primitives | `makeCube`, `makeDiamond`, `makeOctahedron`, `makeLShape` (test fixtures only) + interactive `BoxTool` (drag-base + drag-height cuboid) |
| Edit modes | Vertices, Edges, Polygons (keys 1/2/3) |
| Transform tools | Move, Rotate, Scale (gizmo handles) |
| Bevel | Edge bevel (segments, super_r, miter inner Sharp/Arc, asymmetric, width modes Offset/Width/Depth/Percent); Polygon bevel = inset+extrude with group_polygons (MODO accumulated-shift) |
| Subdivide | Catmull-Clark (full mesh and per-selected-face); faceted subdivide; subpatch toggle |
| Mesh ops | `mesh.split_edge`, `mesh.move_vertex` |
| Selection ops | loop, ring, more, less, expand, contract, invert, connect, between |
| File I/O | LXO load/save (`commands/file/`) |
| Playback | Event log record/replay for deterministic tests |
| HTTP API | `/api/model`, `/api/selection`, `/api/select`, `/api/command`, `/api/transform`, `/api/reset`, `/api/bevvert`, `/api/play-events*`, `/api/recorded-events`, `/api/camera` |
| Test infrastructure | `run_test.d` (unit), `tools/blender_diff/` (Blender comparison), `tools/modo_diff/` (MODO comparison) |

### Plans already in `doc/`

- `bevel_blender_refactor_plan.md` — Phase 0-6 done.
- `bevel_rebevel_fix_plan.md` — bevel pass-on-bevel-output.
- `inner_arc_miter_plan.md` — Arc miter for reflex corners.
- `primitives_plan.md` — interactive Create tools (sphere, cylinder, cone, …).
- `test_coverage_plan.md` — gaps in test coverage.
- `modo_diff_capture_workflow.md` — capturing new modo_diff cases.

The roadmap below picks up where these leave off — features outside
the scope of the existing plans.

---

## Tier 0 — system infrastructure (must precede Tier 1)

These aren't new commands; they're system-wide infrastructure that
every command needs to integrate with. Building them first means every
later feature inherits the behavior for free; building them late means
retrofitting every command afterwards.

### 0.1 Command history (recording)

Every mutating operation (`Command.apply`, transform drag, selection
change, edit-mode change) is appended to a per-session history list.
Each entry stores:

- `commandId` — name of the registered command (`mesh.bevel`,
  `mesh.delete`, `mesh.poly_bevel`, …) or a transform/selection token
  for direct-manipulation events.
- `paramsJson` — the params blob that was applied (for HTTP commands)
  or a delta for transforms.
- `revertPayload` — opaque per-command revert state (mirroring
  `BevelOp.faceSnaps` + `origVertices` + `origEdges` already on
  `BevelOp`, and `PolyBevelOp`'s snapshot fields).
- `timestamp`, `mutationVersion` (already tracked on `Mesh`).

Two design constraints worth pinning down up front:

- **Granularity at interactive drag**: BevelTool already builds
  `BevelOp` once on apply and re-evaluates positions on each drag
  via `updateEdgeBevelPositions` / `updatePolyBevelPositions`. The
  history entry should land *once* at apply time, then mutate the
  same entry's "final params" on each drag tick (or on
  `onMouseButtonUp`) — not produce one entry per mouse-motion event.
- **Tagging selection / mode changes**: arguably user-visible; should
  be undoable. But each individual click would bloat history. Coalesce
  consecutive selection ops in the same mode into one entry (replace
  the latest entry's "after" snapshot).

Files touched: `source/command.d` (base class gets a `revertPayload`
slot or returns one from `apply`); each `commands/*` file (declare
revert logic explicitly — many already have it as a private helper);
`source/app.d` (history list, drives by `commandHandler`); `source/http_server.d`
(optional: expose `/api/history` for tests).

### 0.2 Undo / redo

Two stacks (`undo`, `redo`). On `apply()` push to undo + clear redo.
On `Ctrl+Z`: pop undo entry, run its `revert(mesh, payload)`, push to
redo. On `Ctrl+Y` / `Ctrl+Shift+Z`: pop redo, re-apply, push to undo.

Per-command revert pattern (already established by edge bevel + poly
bevel):

```d
abstract class Command {
    // existing apply()
    abstract bool apply();

    // NEW — per-command undo. Default: no-op for non-mutating ops
    // (selection / edit-mode toggles handle their state separately).
    bool revert() { return false; }
}
```

Mesh ops with non-trivial revert (bevel, poly_bevel, subdivide, future
delete / merge / extrude / mirror) snapshot the pre-apply state into a
struct held inside the command instance — then `revert` restores from
the struct.

Selection / edit-mode changes use a different undo path: snapshot
`selectedVertices/Edges/Faces` arrays + edit-mode + selection counters
into a small struct.

Test strategy: every new command from Tier 1+ ships with a
`tests/test_<cmd>_undo.d` that exercises apply → revert → apply →
diff and asserts the geometry round-trips bit-for-bit.

Validation: an integration test that runs a long sequence of mixed ops
(bevel → poly_bevel → delete → merge → undo all → assert mesh ==
initial) catches any command that forgot to snapshot something.

### 0.3 Persistent history (optional follow-up)

Once the in-memory undo/redo works, a sister feature: save the
session's command history alongside the LXO file (or as a parallel
`.history` JSON), so reopening a project preserves undoable steps.
This is also useful for crash recovery. Keep this as a Tier-3 nice-to-
have until the core stack is stable.

### 0.4 Interaction with existing event log

`source/eventlog.d` already records SDL events for deterministic test
playback. That's a different layer (raw input replay vs semantic
command undo). They should NOT be merged — but the history entries
could carry an event-log timestamp pointer for cross-debugging
("which user input produced this mutation?"). Optional.

### Sequencing constraint

**Build 0.1 + 0.2 BEFORE Tier 1 items.** Every Tier 1 command
(`mesh.delete`, `mesh.merge_verts`, `mesh.poly_extrude`,
`mesh.edge_extrude`) needs to integrate with the history+undo system
on day one. Adding undo afterwards means revisiting each command, and
the bevel commands have already shown how messy retroactive
snapshot-collection is.

Estimated cost: 1-2 weeks for 0.1+0.2 together, dominated by audit of
every existing command for proper snapshot/revert. Tier 1 then
proceeds at the original 3-day-per-item pace.

---

## Tier 1 — foundational (3-day items each)

These are basic editing primitives that almost every modeling op
eventually depends on. Order is by dependency.

### 1.1 Delete element (`mesh.delete`)

MODO `delete_remove.html` — three modes:

- **Delete vertex**: remove vert + all faces incident to it; bordering
  edges may either die or be reconnected.
- **Delete edge**: remove edge; merge the two adjacent faces into one
  n-gon (or leave a hole if `keep_hole=true`).
- **Delete face**: remove face polygon; orphan verts/edges optionally
  cleaned up.

Without delete, mesh editing is one-way (only additive). HTTP command
`mesh.delete` + UI button + keyboard shortcut (Del / Backspace).

Validation: blender_diff has `bmesh.ops.delete(geom=..., context=...)` so
direct comparison is straightforward.

### 1.2 Merge vertices (`mesh.merge_verts`)

MODO `mesh_cleanup.html` — collapse a set of vertices to a single point
(centroid by default) OR auto-merge any pair within distance ε. Already
half-implemented: `Mesh.weldCoincidentVertices(eps)` exists in
`source/mesh.d:113` (used by edge bevel post-pass). Need the user-facing
`mesh.merge_verts` command + UI.

### 1.3 Polygon Extrude as a standalone tool

We already have polygon bevel = inset+extrude. MODO splits the two
operations: `polygon_extrude.html` extrudes the selection along the
group normal (no inset, optional duplicate-and-move). Ours is buried
inside the Bevel tool with a single `Shift` slider. Pull out:

- `mesh.poly_extrude` HTTP command with `distance` parameter.
- New tool `PolyExtrudeTool` (or extend BevelTool's UI to expose pure
  extrude shortcut).

Cheap because the math is already in `applyPolyBevel(mesh, faces, 0,
distance, group)` — exposing a UX-clean entry point is the work.

### 1.4 Edge Extrude (`mesh.edge_extrude`)

MODO `edge_extrude.html` — turns a SELECTED EDGE into a new face by
duplicating it offset along a direction (typically face normal). For an
isolated edge V0-V1, creates new V0', V1' and a quad [V0, V1, V1', V0'].
For a selection of multiple connected edges, all the new endpoints are
shared at junctions.

This is the "primitive" for building geometry from edges (e.g.,
extending a cap, building a strip out from a curve).

### 1.5 More primitives (link to existing `primitives_plan.md`)

`primitives_plan.md` covers Sphere, Cylinder, Cone, Plane, Torus.
Promote it from "plan" to "tier 1" — execute it. Each new tool is
mostly geometry generation + 2-3 drag UI, no algorithmic risk.

---

## Tier 2 — common modeling ops (5-day items each)

### 2.1 Add Loop / Loop Slice (`mesh.add_loop`)

MODO `loop_slice.html` — pick an edge, the tool finds its face loop,
inserts a parallel edge across each face in the loop. Position
parameter `t ∈ [0, 1]` controls where the new loop is inserted.
Optional: count parameter for multiple parallel loops.

Foundation for: shape refinement, smoothing groups, model topology
control. Used heavily in subdivision modeling workflows.

### 2.2 Bridge (`mesh.bridge`)

MODO `bridge.html` — connect two SELECTED face loops (or two SELECTED
faces) with a strip of quads. Cardinality must match (same edge count
on both ends). With twist + segments parameters.

Foundation for: closing holes, joining 2 mesh pieces, building
cylindrical structures from end caps.

### 2.3 Mirror (`mesh.mirror`)

MODO `mirror.html` (under `duplicate_geometry/`). Mirror selected
geometry across an axis-aligned plane, with optional `merge_eps` for
welding seam vertices. Two modes:

- **Symmetric duplicate**: mirror geometry, weld seam, return one mesh.
- **Symmetric edit (live)**: every edit propagates to its mirror — this
  is "Symmetry" mode, harder.

Start with Symmetric duplicate; defer live symmetry to Tier 3.

### 2.4 Knife / Cut (`mesh.knife`)

MODO `slice_tools.html` (`slice.html`, `loop_slice.html`, `axis_slice.html`,
`pen_slice.html`). The general Knife is interactive — click on a face
to start, click on each edge / point to define a cut path, finalize on
double-click. Splits the polygons along the path, adding new verts on
intersected edges.

Algorithm is a constrained-edge-insertion problem. **Axis Slice** (a
flat cutting plane along an axis) is a simpler subset and a good
starting point.

### 2.5 Smooth (Laplacian / Taubin)

MODO `smooth.html` — iterative smoothing of selected verts toward the
average of their neighbors. Parameters: iterations, strength, optional
volume preservation (Taubin: alternating positive/negative steps).

Cheap, useful, no topology change.

---

## Tier 3 — advanced (multi-week)

### 3.1 Soft selection / Falloff

MODO `selection_falloffs.html` — transforms (Move/Rotate/Scale) affect
not just the selected verts but their neighbors in a smoothly weighted
falloff. Falloff types: linear, radial, screen, Lasso, etc.

Touches the `Tool` base class (each transform tool needs to compute
weights at apply time). Not just a new command — a system-wide change.

### 3.2 Action Centers

MODO `action_centers.html` — alternate pivot points for transforms:
Selection center, Origin, Element, Local. Today vibe3d uses the
selection bounding-box center implicitly. Adding the choice changes
gizmo placement + transform application math.

### 3.3 Boolean operations (Union / Subtract / Intersect)

MODO `boolean.html`. The big one — requires a robust geometric solver.
External libs (Carve, libigl, Blender's BooleanModifier) are the
realistic path. Pure D implementation from scratch is months of work.

Defer: until we have a real use case. Not on the critical path.

### 3.4 Snap

MODO `snap.html` (under interaction). Vertex / Edge / Face snap during
transform drag. Important UX feature for hard-surface modeling.

Modular: each snap type adds a candidate position to the drag math;
the tool picks the closest within threshold.

### 3.5 UV mapping

Entirely new subsystem — UV coordinates on faces, UV editor, unwrap
algorithms (planar, cylindrical, Angle-Based-Flattening). Easily a
month of work; not blocking modeling features. Defer until we need
texturing.

---

## Cross-cutting work (2-day items)

### CC.1 Element Move

MODO `element_move.html` — drag a single vert / edge / face along its
implied "natural" axis (vert: along its normal; edge: perpendicular to
its midpoint normal; face: along face normal). Tighter UX than
generic Move with a custom-aimed gizmo.

### CC.2 Edge Slide

MODO `edge_slide.html` — slide an edge along its perpendicular within
the adjacent faces. Constrained Move where the constraint surface is
the union of the two adjacent face planes.

### CC.3 Mesh Cleanup operations

MODO `mesh_cleanup.html`:

- Merge close vertices (we have `weldCoincidentVertices`, expose).
- Remove zero-area faces.
- Remove unused vertices (orphans). We have `compactUnreferenced`,
  expose.
- Triangulate / Quadrangulate.
- Reverse face winding.

Each is a small command; bundle into a single `mesh.cleanup` with
flags.

### CC.4 Make polygon (`make_polygon.html`)

Given 3+ selected verts, create a face. Useful for closing holes
manually.

---

## Suggested execution order

For maximum unblock:

1. **Tier 0.1 + 0.2 History + Undo/Redo** — system-wide infrastructure;
   everything below depends on it integrating cleanly. Audit existing
   bevel / poly_bevel revert helpers, generalize, expose via Ctrl+Z/Y.
2. **Tier 1.1 Delete** — needed before everything else.
3. **Tier 1.2 Merge verts** — partially done, finish.
4. **Tier 1.5 Primitives** — execute `primitives_plan.md`.
5. **CC.4 Make polygon** + **CC.3 Mesh cleanup** — bundle as small commands.
6. **Tier 1.3 Poly Extrude** + **Tier 1.4 Edge Extrude** — pull out from bevel.
7. **Tier 2.3 Mirror** (without live symmetry).
8. **Tier 2.1 Add Loop** + **Tier 2.5 Smooth**.
9. **Tier 2.2 Bridge**.
10. **CC.1 Element Move** + **CC.2 Edge Slide**.
11. **Tier 2.4 Knife / Axis Slice**.

Stop here unless there's a concrete need for boolean / soft selection /
UV / persistent history. Each Tier-3 / 0.3 item is a separate project.

---

## Per-feature test strategy

For each new feature, the validation cycle is:

1. **Unit test** in `tests/test_<feature>.d` — HTTP-driven scenario
   asserting vertex/edge/face counts + boundary check.
2. **blender_diff case** in `tools/blender_diff/cases/<feature>_*.json`
   — bit-for-bit position match with Blender (when there's a clean
   bmesh.ops counterpart).
3. **modo_diff case** for features where MODO has the closest
   semantics (poly bevel did this nicely).

`run_test.d --no-build` + `rdmd tools/blender_diff/run.d --no-build`
+ `rdmd tools/modo_diff/run.d --no-build` is the pre-commit gate.
