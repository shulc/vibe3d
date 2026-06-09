# Vibe3D — Tools & Controls

Full reference for every tool and keyboard shortcut. For an overview of the
project see the [README](README.md). Keyboard shortcuts are configurable in
`config/shortcuts.yaml` (`config/shortcuts_macos.yaml` on macOS); the keys below
are the defaults.

## Tools

### Transform — direct manipulation

| Tool | Hotkey | Description |
|---|---|---|
| **Move** | `W` | Translate the selection along an axis, plane, or freely via the gizmo. Numeric entry in the property panel; pipeline-driven action center / axis / falloff. |
| **Rotate** | `E` | Rotate around X / Y / Z or the camera-facing axis. Hold Ctrl to snap to 15° increments. |
| **Scale** | `R` | Scale along one axis, in a plane, or uniformly from the gizmo center. |
| **Transform** | `Y` | Unified tool that exposes the Move, Rotate and Scale gizmo banks simultaneously (T / R / S). |
| **Move Elem** | — | Move preset with action center + axis pinned to **Element**. |

### Create — procedural primitives

Each Create tool drops an interactive gizmo plus a parameter panel; every value
is editable numerically.

| Tool | ID | Description |
|---|---|---|
| **Box** | `prim.cube` | Cuboid with per-axis segments and optional rounded edges (radius / segmentsR / sharp axis). |
| **Sphere** | `prim.sphere` | UV-sphere (Globe), QuadBall or Tessellation methods; per-axis radii, pole axis, longitude / latitude resolution. |
| **Cylinder** | `prim.cylinder` | Per-axis radii (elliptical cross-section), height along the chosen axis, sides and segment count. |
| **Cone** | `prim.cone` | Linearly tapered cone; ellipse base + apex vertex. |
| **Capsule** | `prim.capsule` | Cylinder with proportional hemispherical end-caps; collapses cleanly to a sphere when the caps consume the full length. |
| **Torus** | `prim.torus` | Quad-only torus with major / minor radius and major / minor segment counts. |
| **Pen** | `pen` | Click-to-place vertex tool for building polygons / line strips / quad strips ("Make Quads") on the construction work-plane. Any committed point is numerically editable. |

### Edge tools

| Tool | ID | Description |
|---|---|---|
| **Edge Extrude** | `edge.extrude` | Extrude the selected edges along their averaged normal; drag to set extrusion and width. |
| **Edge Extend** | `edge.extend` | Add a new strip of geometry off the selected boundary edges (additive, non-manifold) with per-vertex meet against incident face planes; supports per-segment rotation / scale. |

### Deform — falloff-driven transforms

The Deform tools combine a base transform with a falloff stage in the tool
pipeline. Drag the falloff handles in the viewport to control which vertices the
deformation reaches and how strongly. With an empty selection the deformer
affects the whole mesh.

| Tool / preset | ID | Base · Falloff | Description |
|---|---|---|---|
| **Soft Drag**   | `xfrm.softDrag`  | Move · screen   | Drag in screen space with a screen-radius falloff. |
| **Soft Move**   | `xfrm.softMove`  | Move · radial   | Translate with a 3D radial falloff anchored at the gizmo center. |
| **Soft Rotate** | `xfrm.softRotate`| Rotate · radial | Rotate with a radial falloff. |
| **Soft Scale**  | `xfrm.softScale` | Scale · radial  | Scale with a radial falloff. |
| **Push**        | `xfrm.push`      | — · falloff     | Translate each vertex along its smoothed per-vertex normal. |
| **Bend**        | `xfrm.bend`      | — · falloff     | Bend the geometry, rotating each vertex around a perpendicular axis through a spine direction. |
| **Smooth**      | `xfrm.smooth`    | — · falloff     | Laplacian relaxation — move each vertex toward the average of its edge neighbors. |
| **Jitter**      | `xfrm.jitter`    | — · falloff     | Random per-vertex displacement, weighted independently per axis. |
| **Quantize**    | `xfrm.quantize`  | — · falloff     | Snap each vertex to a regular grid (per-axis step). |
| **Shear**       | `xfrm.shear`     | Move · linear   | Move along an axis, weighted by a linear falloff across the selection. |
| **Twist**       | `xfrm.twist`     | Rotate · linear | Rotate around an axis, weighted linearly along that axis. |
| **Swirl**       | `xfrm.swirl`     | Rotate · radial | Rotate around an axis with a radial falloff. |
| **Taper**       | `xfrm.taper`     | Scale · linear  | Scale weighted linearly along an axis. |
| **Bulge**       | `xfrm.bulge`     | Scale · radial  | Scale weighted radially from a center. |
| **Flare**       | `xfrm.flare`     | Push · linear   | Push along normals weighted by a linear falloff. |
| **Vortex**      | `xfrm.vortex`    | Rotate · cylinder | Rotate with a cylindrical falloff. |
| **Flex**        | `xfrm.flex`      | T+R+S · falloff | Unified transform (translate + rotate + scale) under a falloff. |

## Controls

### Camera

| Action | Keys / mouse |
|---|---|
| Orbit | Alt + LMB |
| Pan | Alt + Shift + LMB |
| Zoom | Ctrl + Alt + LMB |
| Frame whole scene | `A` |
| Frame selection | Shift + `A` |

### Modes and tools

| Action | Key |
|---|---|
| Vertices mode | `1` |
| Edges mode | `2` |
| Polygons mode | `3` |
| Cycle mode | `Space` |
| Move tool | `W` |
| Rotate tool | `E` |
| Scale tool | `R` |
| Transform tool (T+R+S) | `Y` |
| Cancel / clear active tool | `Esc` |

### Selection

| Action | Keys / mouse |
|---|---|
| Select | LMB / drag-rect |
| Add to selection | Shift + LMB / drag |
| Remove from selection | Ctrl + LMB / drag |
| Connected selection | `]` |
| Invert selection | `[` |
| Expand / Contract | Shift + Up / Down |
| More / Less | Up / Down |
| Loop / Ring | `L` / Alt + `L` |
| Between | Shift + `G` |

### Mesh operations

| Action | Key |
|---|---|
| Catmull-Clark subdivision | `D` |
| Delete | `Delete` |
| Remove | `Backspace` |
| Undo / Redo | `Ctrl+Z` / `Ctrl+Shift+Z` |
| Toggle snap | `X` |
| Shrink / Grow gizmo | `-` / `=` |
| Start / Stop recording events | `F1` / `F2` |

### File

| Action | Key |
|---|---|
| New | `Ctrl+N` |
| Open | `Ctrl+O` |
| Save | `Ctrl+S` |
| Quit | `Ctrl+Q` |

### Move / Scale gizmo

| Action | Mouse |
|---|---|
| Translate / scale along axis | Drag arrow (X / Y / Z) |
| Translate / scale in plane | Drag ring (XY / YZ / XZ) |
| Free translate / uniform scale | Drag the center |
| Constrain to axis while dragging a plane | Ctrl + drag plane |

### Rotate gizmo

| Action | Mouse |
|---|---|
| Rotate around axis | Drag arc (X / Y / Z) |
| Rotate around camera axis | Drag outer arc |
| Snap to 15° | Ctrl + drag |
