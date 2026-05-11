# Deform Tools Plan

Port of MODO's `frm_modoTools_Deform` palette to vibe3d. Phased
plan that leverages the existing Move/Rotate/Scale + FalloffStage
+ ACEN/AXIS/SYMM infrastructure.

## MODO source-of-truth catalog

`/home/ashagarov/Program/Modo902/resrc/701_frm_modotools.cfg:885-1139`
defines `frm_modoTools_Deform`. The tools it exposes:

| MODO tool          | MODO command                | What it does                                |
|--------------------|-----------------------------|---------------------------------------------|
| Element Move       | `tool.set ElementMove`      | Pick + drag element under cursor            |
| Flex               | `tool.set Flex`             | Transform + Selection-Border ACEN + falloff |
| Magnet             | `tool.set xfrm.magnet`      | Push selection toward a target vertex       |
| Soft Drag          | `tool.set xfrm.softDrag`    | Move + Screen falloff                       |
| Shear              | `tool.set xfrm.shear`       | Move + Linear falloff                       |
| Smooth             | `tool.set xfrm.smooth`      | Laplacian smoothing                         |
| Jitter             | `tool.set xfrm.jitter`      | Random per-vertex offset                    |
| Quantize           | `tool.set xfrm.quantize`    | Snap to 3D grid                             |
| Soft Selection M/R/S/T | `tool.set SoftSelection*` | Transform + Radial falloff (4 variants)   |
| Twist              | `tool.set xfrm.twist`       | Rotate + Linear falloff                     |
| Bend               | `tool.set Bend`             | Two-handle spine + angle bend               |
| Vortex             | `tool.set xfrm.vortex`      | Rotate + Cylindrical falloff                |
| Swirl              | `tool.set Swirl`            | Rotate + Radial falloff                     |
| Push               | `tool.set xfrm.push`        | Move along per-vertex normal                |
| Sculpt             | `tool.set tool.sculpt`      | Brush deformation                           |
| Taper              | `tool.set xfrm.taper`       | Scale + Linear falloff                      |
| Bulge              | `tool.set xfrm.pole`        | Scale + Radial falloff                      |
| Flare              | `tool.set Flare`            | Push + Linear falloff                       |
| Radial Align       | `tool.set xfrm.radialAlign` | Verts → circle in plane                     |
| Linear Align       | `tool.set xfrm.linearAlign` | Verts → line                                |

## What already exists in vibe3d

- `MoveTool` / `RotateTool` / `ScaleTool` (transform tools).
- `FalloffStage` with types: `None`, `Linear`, `Radial`, `Screen`, `Lasso`.
- `ActionCenterStage`: `Auto`, `Select`, `Element`, `Local`, `Origin`,
  `Screen`, `Border`, `Manual`, `None`. **Selection-Border** is the
  same `Border` mode used by MODO Flex.
- `AxisStage`: `Auto`, `World`, `Workplane`, `Select`, `Element`,
  `Screen`, `Local`.
- `SymmetryStage` (phase 7.6) — symmetric edit propagation.

## Phased plan

Order: cheapest first, each phase a single commit. All new commands
declare `supportedModes()` to auto-disable buttons in modes where
they don't apply.

### D.1 — Tool presets (~150 LOC total) ✦

Each preset = existing tool + `FalloffStage.setAttr("type", ...)`.
Factory wraps the existing Move/Rotate/Scale, configures falloff
once on activate. No new mechanics.

| Preset id            | Base tool | Falloff config                              |
|----------------------|-----------|---------------------------------------------|
| `xfrm.softDrag`      | move      | `type=screen, transparent=true`             |
| `xfrm.softMove`      | move      | `type=radial`                               |
| `xfrm.softRotate`    | rotate    | `type=radial`                               |
| `xfrm.softScale`     | scale     | `type=radial`                               |
| `xfrm.twist`         | rotate    | `type=linear`                               |
| `xfrm.swirl`         | rotate    | `type=radial`                               |
| `xfrm.shear`         | move      | `type=linear`                               |
| `xfrm.taper`         | scale     | `type=linear`                               |
| `xfrm.bulge`         | scale     | `type=radial`                               |

Side-panel: new "Deform" page in `config/buttons.yaml`. Status-bar
unchanged (these are page-level, not workflow-level).

### D.2 — Mesh-level headless ops (~530 LOC total)

Pure math + undo through `MeshSnapshot`. No new tools.

| Command id            | Algorithm                                                 | ~LOC |
|-----------------------|-----------------------------------------------------------|------|
| `mesh.smooth`         | Laplacian: `v' = avg(neighbors)`, params: iters, strength | 150  |
| `mesh.jitter`         | `v' = v + rand(±range) * weight`, params: range, seed     | 80   |
| `mesh.quantize`       | `v' = round(v / step) * step`, params: step XYZ           | 80   |
| `mesh.linear_align`   | Interpolate selected verts along endpoint-to-endpoint line | 100  |
| `mesh.radial_align`   | Project onto circle: centroid + plane fit, equal-angle    | 120  |

All polygon/edge/vertex-mode aware via `supportedModes()`.

### D.3 — Push tool (~150 LOC)

Move along per-vertex normal. Two pieces:
- `Mesh.vertexNormal(vi)` — area-weighted sum of incident face normals.
- `PushTool : TransformTool` — drag → scalar distance; `applyDelta`
  applies `normal[vi] * distance * falloffWeight` per vertex.

Unlocks Flare = Push + Linear falloff (+0 LOC after preset config).

### D.4 — Cylindrical falloff + Vortex (~120 LOC)

`FalloffType.Cylindrical` added to `toolpipe/packets.d`. Math:
weight = ramp(dist-from-axis, radius) * ramp(|axial-projection|, length/2).
Auto-size from selection bbox: pick longest principal axis as the
cylinder axis, fit radius/length to selection. After this Vortex
becomes a preset (Rotate + cylindrical, +0 LOC).

### D.5 — Element Move (~200 LOC)

Hover-pick under cursor (vibe3d's `hoveredVertex/Edge/Face` is
already populated by `pickVertices/Edges/Faces` each frame). New
`ElementMoveTool` drags only that element; selection is NOT
mutated. Tool overlays a small gizmo on the hovered element so
the user knows what'll move.

### D.6 — Bend tool (~250 LOC)

Two-handle gizmo: spine line + angle disc. Math: project each
selected vert onto the spine to get parameter `t`, then rotate
the vert around the (spine-perpendicular) bend center by
`angle * (t - t_anchor)`. Bend center = midpoint of spine by default.

### D.7 — Flex tool (~150 LOC)

Depends on a new `FalloffType.SelectionLinear` — weight = 1 for
verts on the selection boundary, decays by edge-hop distance. ACEN
mode = `Border` (already implemented). Flex itself is a preset
(Move/Rotate/Scale + selection-linear-falloff + ACEN border).

### D.8 — Sculpt brush (~400 LOC)

Brush-mode continuous deformation. Cursor = brush center in screen
space; on mouse motion while held, push/pull verts in screen-space
radius along screen normal (or surface normal). Brush radius +
strength sliders in Tool Properties. New input pipeline (continuous
mouseMotion → repeated mini-deltas).

## Out of scope for v1

- `xfrm.magnet` — variant of `xfrm.softDrag`; cosmetic preset, can
  ride alongside D.1 later.
- Interactive `xfrm.smooth` / `xfrm.jitter` / `xfrm.quantize` —
  headless commands from D.2 cover the function; interactive
  variants are UX-only and can land after D.5.
- `SoftSelection*` — already a deprecated MODO preset (subsumed
  by FalloffStage). vibe3d's preset names align with the modern
  `xfrm.*` MODO convention.
- Symmetry Tool (legacy MODO deformer) — superseded by vibe3d's
  SYMM stage (phase 7.6).

## Recommended sequence

1. **D.1** (~150 LOC, ~half day)  — 9 preset tools, closes ~50% of MODO Deform palette.
2. **D.2** (~530 LOC, ~2 days)    — 5 headless ops, broadens mesh tooling.
3. **D.3** + Flare preset (~150)  — opens normal-based ops.
4. **D.4** + Vortex preset (~120) — closes rotate-deform sub-palette.
5. **D.5** (~200)                 — pick-and-drag UX.
6. **D.7** (~150)                 — Flex, depends on selection-linear falloff.
7. **D.6** (~250)                 — Bend, most maths-heavy non-brush tool.
8. **D.8** (~400)                 — Sculpt; brush mode is its own subsystem.

Cumulative (excluding Sculpt): ~1700 LOC across 7 subphases.
