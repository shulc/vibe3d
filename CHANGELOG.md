# Changelog

All notable changes to Vibe3D. The version a build reports is printed by
`vibe3d --version` and shown in `File ▸ About…`.

Nightly builds carry the version of the release they follow, so use the build
date in `--version` to tell one nightly from another.

## 0.0.2 — 2026-08-09

The first release with a real editor behind it. 0.0.1 was a viewport with three
gizmos; this one is a modelling application: a document made of items, a full
mesh toolkit, an interactive tool layer, and a test suite that holds it in
place.

### Document, layers and items

- Documents hold **multiple layers**, with foreground/background derived from
  the item selection. Background layers draw dimmed, stay snappable, and are
  read-only.
- The layer model generalised into a **scene item tree** — an item is no longer
  necessarily a mesh. Items nest under parents, carry their own parameters, and
  have their own undoable transform.
- **Reference / backdrop images** are the first non-mesh item kind: load,
  replace, reload and remove an image, place it in the scene, and save it with
  the document.
- **Hiding geometry**: Hide, Unhide All, Isolate and Invert, per selection type.
  Hidden geometry is excluded from picking, drawing and every mesh operation's
  operand set, survives topology-changing edits, and is fully undoable.
- Native **`.v3d`** JSON document format is the default save format and the
  lossless source of truth.

### Modelling

- A large mesh toolkit: bridge, collapse, edge spin, thicken, weld, symmetrize,
  align, triangulate/quadrangulate and decimate, plus several slicing tools
  (axis, grid, screen-space and edge slice).
- **Bevel** for vertices, edges and polygons, including dihedral-aware round
  fillets, 3-way and N-way junction rounding, free-end caps and open-boundary
  edges.
- **Topology Pen** — a point/edge/loop construction tool with a gesture
  vocabulary on mouse-button and modifier combinations: draw a face, move or
  re-snap a vertex, remove a face, add/move/duplicate a loop, slide along an
  edge, smooth, split, and a Fill mode that fills the grid cell under the
  cursor. Snaps to a background surface for retopology.
- Interactive tools with live preview and their own gizmos: Loop Slice (with
  tension, capping, gap and N-gon support), Slice, Edge Slice, Mirror, Array,
  Radial Array, Radial Sweep, Polygon Inset, Bridge, Smooth Shift and Thicken.
- New primitives (arc, tube, ellipsoid), a geometry clipboard, a magnet
  deformer, and per-vertex weight maps.
- A **UV toolkit**: planar/box/cylindrical/spherical projection, flip, mirror,
  rotate, relax, conformal unwrap, fit and pack.
- **Subpatch** (smoothed cage) editing and Catmull-Clark subdivision, with
  Remesh for automatic retopology.

### Transform, falloff and snapping

- Move, Rotate and Scale rebuilt on one shared transform kernel, so all three
  compose the same way. Mid-drag undo, absolute panel values across chained
  drags, and one gesture-frame model throughout.
- Multiple **action-centre** modes: per-cluster local frames, automatic
  placement, click-to-relocate, parent-relative, and snapped to the work plane.
- Drag anywhere on the selection, not only on a handle, in every pivot mode.
- **Soft selection**: falloffs are stackable with a mix-mode combiner, have
  per-shape property panels, include a weight-map type, and stay editable with
  no tool active.
- **Snapping** to six target types with scope filtering, backed by a
  screen-space grid; line and plane guide constraints; geometry moving with the
  current drag is excluded from its own snap targets.

### Selection

- A generalised selection-type model — Vertex, Edge, Polygon and Item — with
  most-recently-used ordering.
- Loop, ring, between, connected, grow/shrink and invert selection; lasso
  select with occlusion; multi-item selection.

### Viewports and display

- **Multiple viewports** in single, split and quad layouts, each with its own
  camera, framebuffer and accelerated face picking.
- A **dockable UI**: every panel can be docked, undocked and resized, and the
  layout persists between sessions.
- Orthographic projection, numpad view shortcuts, a trackball camera mode with
  release momentum, and per-viewport display style.

### Panels and UI

- Tool parameters are described in YAML and rendered by a shared forms engine,
  with DPI-aware scaling.
- A **Channels** panel listing every parameter of the selected item, writing
  through the same path as the properties form.
- An **Items** panel showing the scene tree — a document root, children indented
  by real parenting, a glyph per item kind, and one add button with a
  kind-picking menu.

### Undo

- Undo distinguishes UI state (such as selection) from model edits, tracks
  changes per mutation rather than by snapshot, and coalesces a continuous drag
  into a single step. UI, model and tool-lifecycle records unwind in strict
  last-in-first-out order, and the History panel/API show every such step.

### File formats

- Import and export **OBJ, glTF, FBX and LWO** alongside native `.v3d`.
  Multi-part files import as one layer per part, and export preserves layers.

### Platforms and packaging

- Linux **AppImage** (self-contained, no system SDL2 or GTK needed), Windows zip
  and installer, macOS `.app` bundles for both Intel and Apple Silicon, plus a
  Windows 7-capable variant.
- Optional **image-to-3D generation** add-on, and an optional render-backend
  build.
- Nightly builds published from CI.

### Performance

- A profiling harness with per-stage timers and CI regression gates, near-O(1)
  snapping and falloff weighting, and removal of several accidental O(n²)
  selection paths.

### This release

- `vibe3d --version` prints the version, build configuration, platform and build
  date, and needs no display — so it answers on a headless machine or one where
  the editor will not start. `File ▸ About…` shows the same block with a Copy
  button. The release tag is verified against the version in the source, so a
  build cannot report a version it was not cut from.

## 0.0.1 — 2026-03-30

The original prototype.

- 3D viewport with an orbit/pan/zoom camera over a ground grid, Blinn-Phong
  shaded.
- Vertex, Edge and Polygon selection modes; click, drag-box and connected
  select, with add and remove modifiers.
- Move, Rotate and Scale gizmos with per-axis and per-plane drag handles.
- Catmull-Clark subdivision.
- Fit-to-view and fit-to-selection framing.
- Input event recording and deterministic replay.
- Linux, Windows and macOS builds from CI.

Two follow-up tags shipped on top of it:

- **`v0.0.1-win-fix`** (2026-04-25) — despite the name, a second wave of feature
  work as well as a Windows build repair: the headless HTTP automation server
  the test suite is built on, interchange import/export, edge and polygon bevel,
  ring/loop/between/grow/shrink selection commands, lasso select, subpatch mode,
  and a YAML-driven side panel.
- **`v0.0.1-config-bundle`** (2026-04-25) — ships `config/` alongside the binary
  in the release archives, which had been missing.
