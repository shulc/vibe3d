# Pen Plan — full MODO-parity interactive Pen tool

## Goal

Reproduce the behavior of MODO 902's `pen` tool as documented in
`Modo902/help/content/help/pages/modeling/create_geometry/pen.html`,
inside vibe3d's PenTool. The original phase-6 plan covered only a
minimal Polygons-mode subset; this plan replaces 6.9 with the full
feature set MODO ships, deferring only items that have no vibe3d
counterpart (UV system, backdrop items, spline geometry).

There is no headless / modo_diff path: `pen` is a plugin tool not
loadable in modo_cl. Validation comes from unit tests built around
recorded SDL event logs that exercise each option, plus an
interactive integration test of the property panel.

## Source of truth

Two artifacts:

1. `Modo902/help/.../create_geometry/pen.html` — user-facing description
   of every option and interaction.
2. The MODO GUI itself, observed manually — fills in details the doc
   leaves implicit (e.g. the exact direction Make Quads picks for the
   "fourth corner", the default Merge distance).

modo_cl can't load `pen` so the interactive feel and edge cases are
verified by hand on the running MODO 9 install rather than by JSON
diff.

## Editing model (cross-cutting, all Type modes)

Every `pen` subphase below builds on this core state machine.

- **Idle**: no in-progress sequence. Mover gizmo hidden. No vertex
  selected.
- **Drawing**: there is at least one in-progress vertex. Construction
  plane is *locked* — chosen by `pickMostFacingPlane` at the moment
  the very first vertex of the current sequence is placed; subsequent
  cursor positions project onto that plane regardless of camera
  changes.
- **VertexSelected**: substate of Drawing where one of the in-progress
  vertices is the "current point" — rendered yellow per architectural
  decision C.1 (default cyan → yellow on hover / selection). Set by
  hovering over a vertex when LMB is pressed (without dragging), or
  by editing `Current Point` numerically.

Click semantics (Polygons / Lines / Spline / Subdiv / Polyline):
| Action | Result |
|---|---|
| LMB-click on empty plane | Append a new vertex to the in-progress sequence. |
| LMB-press on existing in-progress vertex | Mark it as the current point; arms drag-or-insert. |
| LMB-drag from existing in-progress vertex | Relocate that vertex on the plane. |
| LMB-drop dragged vertex on another in-progress vertex | Weld — drop the dragged one, replace its index with the target's everywhere in the boundary list. |
| LMB-click on empty plane while a vertex is current | Insert a new vertex *after* the current one in the sequence. |
| Shift+LMB-click | Commit the current sequence (if valid) and start a new one. |
| Double-click / Enter | (vibe3d convention) Commit the current sequence. |
| Backspace | Remove the last vertex from the in-progress sequence. |
| Esc / RMB | Cancel — drop all in-progress vertices, return to Idle. |
| Tool deactivate | If valid in-progress sequence exists, commit it. |

Vertices mode is degenerate: each click immediately commits a single
vertex. There is no "in-progress sequence" — every click is an atomic
operation.

## Type modes

| Mode | Vibe3d implementation | Notes |
|---|---|---|
| **Polygons** | n-gon face on commit; min 3 verts. | Primary mode. |
| **Lines** | 2-vertex polygon per click pair (first click anchors, second commits the segment, third starts new segment from the previous endpoint). | Polygons of length 2. |
| **Vertices** | Single vertex per click; no face. | No "Drawing" state. |
| **Spline patches** | **No vibe3d equivalent** — no spline geometry exists in the mesh schema. Decision: hide this mode from the schema enum until splines are added. | |
| **Subdivision Surfaces** | n-gon face with `isSubpatch[fi] = true` on commit. | Same as Polygons + flag. |
| **Polyline** | **No vibe3d equivalent** — no polyline / curve geometry exists. Decision: alias to Lines OR hide from schema. Pick one in 6.9.0 design review. | |

The schema's `type` enum is string-backed (matches MODO wire format
when parity becomes possible later): `polygons` / `lines` / `vertices`
/ `subdiv`.

## Tool options

Every option below maps 1:1 with MODO's tool panel. Out-of-scope
items have no vibe3d implementation.

| Option | Vibe3d behavior | Phase |
|---|---|---|
| `type` (enum) | See Type modes table. | 6.9.0 (polygons), 6.9.2 (lines/vertices), 6.9.3 (subdiv). |
| `currentPoint` (int) | Index in the in-progress sequence; reading reflects the highlighted vertex; writing changes which vertex Position X/Y/Z edits. | 6.9.1 |
| `posX/Y/Z` (float×3) | Coordinates of the current point. Read = report current vertex world pos; write = move that vertex. | 6.9.1 |
| `flip` (bool) | At commit time, reverse the boundary vertex order so the face's outward normal flips. | 6.9.2 |
| `close` (bool) | Lines / Polyline only: at commit time, add an edge between the last and first vertex, closing the loop. | 6.9.4 |
| `merge` (bool) | When a new vertex is placed within `mergeDist` (compile-time constant; pick after MODO probing) of an existing in-progress OR scene vertex, snap to that vertex's index instead of creating a new one. | 6.9.4 |
| `makeQuads` (bool) | Polygons mode: after the first 2 verts, each new click places 2 verts to form a quad strip. Ctrl override = single triangle. | 6.9.5 |
| `wallMode` (enum: off/inner/outer/both) | Polygons / Lines: at commit, extrude the polyline into wall polygons offset by `offset`. | 6.9.6 |
| `offset` (float) | Wall thickness. `both` doubles the effective offset. | 6.9.6 |
| `inset` (float) | Wall Mode != off: bevel each corner inward by this amount. | 6.9.7 |
| `segments` (int) | Inset > 0: number of corner-bevel subdivisions. 1 = flat corner. | 6.9.7 |
| `showAngles` (bool) | Render corner-angle labels in degrees over active geometry. | 6.9.8 |
| `showHandles` (bool) | Render axis handles on each in-progress vertex for direct per-axis drag. | 6.9.8 |
| `showNumbers` (bool) | Render vertex sequence numbers in the viewport. | 6.9.8 |
| `selectNew` (bool) | Post-commit, auto-select the new face / vertex / edge. | 6.9.8 |
| `makeUVs` (bool) | **Out of scope** — vibe3d has no UV system. Hide from schema. | — |
| `projectTo` (enum) | **Out of scope** — depends on UV system. | — |

## Architectural decisions

### A. PenTool as a long-lived in-progress session

Unlike Box/Sphere/Cylinder/Cone/Capsule/Torus, Pen does NOT auto-
deactivate after a single shape. The tool stays active across many
polygons; commits flow into history one entry per shape. State
across commits:

- Construction plane re-picked at the *first* vertex of each new
  sequence (after a Shift+click or double-click commit).
- `selectNew` post-commit selection is opt-in and accumulates if the
  user makes several shapes with it on.
- Undo per commit: each shape is one history entry.

### B. In-progress sequence as a separate buffer

The in-progress polygon's vertices live in a `PenSequence` struct
*outside* the scene mesh. They are projected to the construction
plane and rendered as a preview overlay (similar to other Create
tools' `previewMesh`). On commit, the buffer's vertices and a face
are added atomically to the scene mesh; a snapshot is captured pre-
commit and recorded post-commit.

Rationale: keeps the scene mesh clean while drawing, and makes
Backspace / Esc trivial (mutate the buffer; scene mesh is untouched).

### C. Construction-plane lock

Plane is captured once via `pickMostFacingPlane(vp)` at the first
vertex of each sequence. Locked for the duration of that sequence so
the polygon stays planar even if the user orbits the camera mid-
draw. Unlock on commit / cancel.

### C.1 Preview rendering colors

In-progress vertices are rendered as small screen-space dots
(BoxHandler-style markers, sized via `gizmoSize`) with two states:

- **Default / unselected: cyan** `(0.0, 0.9, 0.9)` — every in-progress
  vertex while the cursor isn't over it.
- **Current / hovered: yellow** `(1.0, 0.9, 0.0)` — the vertex marked
  as `currentPoint` (set by hover-on-press, drag, or numeric edit
  via the property panel). Matches MODO's "they'll turn yellow when
  the mouse is directly over them" from `pen.html`.

The in-progress edges connecting vertices use the standard wireframe
color (no highlight). On commit, the vertex markers disappear (the
geometry becomes regular mesh, rendered through the usual path).
Hover-detection radius for "current" promotion: same pixel threshold
as vertex-pick (~6 px, see `pickVertices`).

### D. Vertex weld and merge

- Drag-weld: when the user drags an in-progress vertex onto another,
  the dragged vertex is removed from the buffer and every reference
  in the boundary becomes the target's index.
- Auto-merge (option): when a new vertex's projected position is
  within `MERGE_DIST` of an existing in-progress vertex, it snaps
  to it. Optionally also extend to scene-mesh vertices (so a Pen
  polygon can attach to existing geometry) — this matches MODO's
  Merge option semantics; verify in modo GUI which set it considers.

### E. Make Quads geometry

Documented direction: "automatically places vertices to create quads
with each new click after the first two vertices have been set."

Algorithm (to be probed against MODO):
1. After 2 verts (segment v1→v2 set up), the next click places a vert
   at the cursor (v3). The fourth corner v4 is computed as v1 + (v3 −
   v2), so v1-v2-v3-v4 is a parallelogram.
2. The committed face is [v1, v2, v3, v4]; the strip continues with
   the next click consuming (v3, v4) as the new edge.

This is the natural quad-strip parameterization. **Verify against
MODO** before 6.9.5 — the doc doesn't fully specify which side of the
edge the fourth corner sits on.

### F. Wall Mode geometry

For each segment of the in-progress polyline (after commit), extrude
perpendicular by `offset` in the construction-plane in-plane normal
direction:

- `inner`: offset toward one side of the polyline (TBD which — verify
  in MODO).
- `outer`: opposite side.
- `both`: extrude both sides; effective offset doubles to span the
  full wall width.

Inset bevels each corner: at convex corners, the wall's outer edge is
chamfered inward by `inset`; `segments` controls the number of bevel
ring rows.

## Subphase breakdown

Each subphase is one commit. Build / unit suite must stay green at
each gate.

### 6.9.0 — Skeleton + Polygons mode (MVP)

Replaces the original phase-6.9 plan's full scope with a smaller
seed.

- `PenTool` with state machine (Idle / Drawing). LMB click adds a
  vertex; double-click / Enter commits; Backspace removes last; Esc
  / RMB cancels.
- Construction plane locked at first click via
  `pickMostFacingPlane`.
- `params()` returns a `type` enum schema entry (only `polygons` for
  now; later subphases enable other values).
- Preview rendering: in-progress polygon shown as wireframe (open
  loop until commit) with cyan vertex markers; the cursor-hovered
  vertex flips to yellow per decision C.1.
- No vertex editing yet (drag-relocate, weld, insert) — comes in
  6.9.1.
- No `applyHeadless`. No modo_diff.
- Unit test: recorded event log builds a triangle and a quad;
  asserts mesh has the expected face count + winding.

### 6.9.1 — Vertex editing (drag, weld, insert) + Current Point

- LMB-press on an existing in-progress vertex selects it (sets
  `currentPoint`).
- Drag-from-vertex relocates on the plane.
- Drop on another in-progress vertex welds (replace index, prune
  buffer).
- Click-away while a vertex is current = insert AFTER it.
- Property panel: `Current Point` (int), `Position X/Y/Z` (float×3)
  editable; mutating either updates the buffer and re-renders the
  preview.
- Unit test: event log that picks a vertex, drags it, drops on
  another vertex (weld), then inserts a new vertex mid-sequence.

### 6.9.2 — Vertices + Lines + Flip

- `type=vertices`: each click commits a single vertex (no in-progress
  state); useful for point clouds.
- `type=lines`: 2-click pairs commit a 2-vert polygon. After commit,
  the next click anchors a new line from the previous endpoint
  (continuous strip).
- `flip` (bool): at commit, reverse the vertex sequence.
- Unit test: vertex cloud (5 clicks → 5 verts); line strip (5
  clicks → 4 segments); flipped polygon (verify face normal).

### 6.9.3 — Subdivision Surfaces mode

- `type=subdiv`: same as polygons but face committed with
  `isSubpatch[fi] = true`.
- Unit test: build a quad in subdiv mode; verify
  `mesh.isSubpatch[lastFace]` is true.

### 6.9.4 — Close + Merge

- `close` (bool): lines / polyline mode only. On commit (auto on tool
  deactivate), add a closing edge from the last vert back to the
  first.
- `merge` (bool): new vertex within `MERGE_DIST` of an in-progress
  OR scene vertex snaps to it. Verify MODO's Merge target set
  (in-progress only? in-progress + scene?) before implementing.
- Unit test: closed line loop; merged vertex (auto-weld during
  click).

### 6.9.5 — Make Quads

- `makeQuads` (bool): Polygons mode only. After first 2 verts, each
  new click extends the strip by one quad. Ctrl override = single
  triangle.
- **Probe MODO first** to confirm the fourth-corner direction
  (parallelogram vs perpendicular extrude vs other).
- Unit test: 5-click event log builds a 4-quad strip; verify face
  count and topology.

### 6.9.6 — Wall Mode + Offset

- `wallMode` (enum: off/inner/outer/both): post-commit polyline
  extrusion.
- `offset` (float): wall thickness.
- **Probe MODO first** to nail down the inner/outer side convention
  on the construction plane.
- Unit test: line strip → wall polygons; verify wall-quad count and
  symmetric Both mode.

### 6.9.7 — Inset + Segments

- `inset` (float): bevel each Wall Mode corner.
- `segments` (int): bevel subdivision count.
- Unit test: wall with 1 corner; inset > 0; verify bevel ring count.

### 6.9.8 — Show options + Select New

- `showAngles`, `showHandles`, `showNumbers`: viewport overlays.
- `selectNew`: auto-select the committed face / line / vertex.
- Per-vertex axis handles in `showHandles` allow direct drag-along-
  axis (separate from 6.9.1's free vertex drag).
- Interactive only — no easy unit test for overlay rendering;
  `selectNew` is testable via `/api/selection`.

### 6.9.9 — Spline patches / Polyline (deferred)

- `spline` and `polyline` enum values: schema-reserved but
  unimplemented until vibe3d adds spline / curve geometry. Either
  hide from the enum or wire to throw "not supported" if invoked
  via headless.

## Out of scope (vibe3d-side)

- `makeUVs`, `projectTo`: vibe3d has no UV system.
- Backdrop Item projection: vibe3d has no backdrops.
- Spline patches geometry: no spline mesh type in vibe3d. Schema
  value reserved (6.9.9).
- Polyline geometry: no curve mesh type in vibe3d. Schema value
  reserved (6.9.9).

## Open questions

1. **Make Quads fourth-corner direction**: parallelogram, perpendicular
   extrude on plane, or something else? Probe MODO GUI before 6.9.5.
2. **Wall Mode side convention**: which side of the polyline does
   `inner` extrude toward — left of segment direction, or relative to
   the polygon's signed area? Probe before 6.9.6.
3. **Merge target set**: in-progress only, or include scene
   vertices? The doc says "vertices within close proximity to each
   other when created" — ambiguous. Probe MODO.
4. **Default merge distance**: not in MODO panel; pick a sensible
   default (proposed: 0.001 in scene units, or a fraction of the
   construction plane's screen scale).
5. **Construction plane re-pick on Shift+click**: re-pick from
   current camera, or keep locked plane? Default proposal: re-pick.
6. **Polyline vs Lines aliasing**: drop Polyline entirely (return
   error if user picks it via headless), or alias to Lines?
   Proposed: drop until vibe3d adds curve geometry.

## Success metrics

- All 9 subphases land as separate commits.
- Build + unit suite green at each gate.
- Polygons / Lines / Vertices / Subdiv modes work interactively in
  vibe3d's GUI; verified manually on representative shapes.
- Wall Mode + Inset produce reasonable wall geometry (visual parity
  with MODO; no JSON diff possible).
- Open questions 1-6 resolved through MODO GUI probing during the
  relevant subphase.

## Size estimate

Total ≈ 1500-2000 LOC across 9 commits.

| Subphase | LOC (rough) | Notes |
|---|---|---|
| 6.9.0 | ~300 | State machine, plane lock, preview rendering, basic tests. |
| 6.9.1 | ~250 | Vertex drag/weld/insert + property-panel hookup. |
| 6.9.2 | ~150 | Vertices / Lines modes + Flip. |
| 6.9.3 | ~30 | Subdiv tagging. |
| 6.9.4 | ~150 | Close + Merge. |
| 6.9.5 | ~150 | Make Quads (probe + algo). |
| 6.9.6 | ~250 | Wall Mode (probe + extrusion). |
| 6.9.7 | ~200 | Inset + Segments. |
| 6.9.8 | ~150 | Show options + Select New. |
| 6.9.9 | ~10 | Reserve schema values; throw on use. |
