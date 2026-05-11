# Vibe3D

A polygonal 3D mesh editor inspired by MODO and LightWave3D. Written in D using OpenGL 3.3 Core Profile, SDL2 and Dear ImGui.

![vibe3d](https://github.com/user-attachments/assets/105f697f-b65f-45b1-b240-f20641aa7984)

## Features

- Polygon editing in three modes: **Vertices**, **Edges**, **Polygons** (toggle with `1`/`2`/`3` or `Space`)
- Interactive transform gizmos: **Move** (W), **Rotate** (E), **Scale** (R)
- **Bevel** (B) — polygon inset/shift and edge bevel
- **Create** tools — Box, Sphere, Cylinder, Cone, Capsule, Torus, Pen
- **Deform** tools — falloff-driven Soft Drag / Move / Rotate / Scale, plus Twist, Swirl, Shear, Taper, Bulge
- Numeric input for transform parameters in the ImGui properties panel
- Rectangle drag-selection; Shift adds, Ctrl removes
- Connected selection — flood-fill of adjacent components (`]`)
- Loop / ring / between / expand / contract selection
- Subdivision Surface — Catmull-Clark algorithm (Shift+D)
- Frame-to-fit: whole scene (A) or selection only (Shift+A)
- Adaptive gizmo sizing (screen-space scale); 9 size steps (`-` / `=`)
- Geometric visibility test: back-facing faces, edges and vertices are not pickable
- Snap rotation with 15° increments when holding Ctrl
- Symmetry, snapping, action-center and axis modes driven by a MODO-style ToolPipe
- Falloff types: linear, radial, screen — with on-screen handles
- Undo / redo command history (`Ctrl+Z` / `Ctrl+Shift+Z`)
- OpenGL VBO/VAO rendering with optimizations (GPU offset drag, partial vertex upload)
- Event recording to JSON (F1/F2) and playback (`--playback <file>`)
- HTTP server for automated testing (`--test`)

## Tools

### Transform — direct manipulation

| Tool | Hotkey | Description |
|---|---|---|
| **Move** | `W` | Translate the selection along an axis, plane or freely via the gizmo. Numeric input in the property panel; ToolPipe-driven action center / axis / falloff. |
| **Rotate** | `E` | Rotate the selection around X / Y / Z or the camera-facing axis. Hold Ctrl to snap to 15°. |
| **Scale** | `R` | Scale the selection along one axis, in a plane, or uniformly from the gizmo center. |
| **Move Elem** | — | Move tool preset with action center + axis pinned to **Element**, mirroring MODO's Element Move. |

### Edit

| Tool | Hotkey | Description |
|---|---|---|
| **Bevel** | `B` | Polygons mode: shift the face along its normal (Arrow handle) and inset along the face tangent (Cubic-Arrow handle). Edges mode: bevel the selected edge, dragging the resulting strip width along the edge-adjacent normal. |

### Create — procedural primitives

Each Create tool drops an interactive gizmo and a parameter panel. Parameters mirror MODO's `prim.*` headless schemas verbatim where applicable, so the same wire format works for both the GUI and the `modo_diff` reference suite.

| Tool | ID | Description |
|---|---|---|
| **Box** | `prim.cube` | Cuboid with per-axis segments and optional rounded edges (radius / segmentsR / sharp axis). |
| **Sphere** | `prim.sphere` | UV-sphere (Globe), QuadBall or Tessellation methods; per-axis radii, pole axis, longitude / latitude resolution. |
| **Cylinder** | `prim.cylinder` | Per-axis radii (XY = elliptical cross-section), height along the chosen axis, sides and segment count. |
| **Cone** | `prim.cone` | Linearly tapered cone (no truncated-cone mode, matching MODO `prim.cone`); ellipse base + apex vertex. |
| **Capsule** | `prim.capsule` | Cylinder with proportional hemispherical end-caps (`endsize` × avg perpendicular radius); collapses cleanly to a sphere when the caps consume the full length. |
| **Torus** | `prim.torus` | Quad-only torus with major / minor radius and major / minor segment counts. |
| **Pen** | `pen` | Click-to-place vertex tool for building polygons / line strips / quad strips ("Make Quads") on the construction work-plane. Numeric edit of any committed point. |

### Deform — falloff-driven transforms

The Deform sub-tab exposes presets that combine a base transform tool with a pre-configured falloff stage in the ToolPipe. Drag the falloff handles in the viewport to control which vertices the deformation reaches and how strongly.

| Preset | Base | Falloff | Description |
|---|---|---|---|
| **Soft Drag**   | Move   | screen | Drag in screen space with a screen-radius falloff. |
| **Soft Move**   | Move   | radial | Translate with a 3D radial falloff anchored at the gizmo center. |
| **Soft Rotate** | Rotate | radial | Rotate with a radial falloff. |
| **Soft Scale**  | Scale  | radial | Scale with a radial falloff. |
| **Shear**       | Move   | linear | Move along an axis, weighted by a linear falloff across the selection. |
| **Twist**       | Rotate | linear | Rotate around an axis, weighted linearly along that axis. |
| **Swirl**       | Rotate | radial | Rotate around an axis with a radial falloff. |
| **Taper**       | Scale  | linear | Scale weighted linearly along an axis. |
| **Bulge**       | Scale  | radial | Scale weighted radially from a center. |

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
| Move tool (toggle) | `W` |
| Rotate tool (toggle) | `E` |
| Scale tool (toggle) | `R` |
| Bevel tool (toggle) | `B` |

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
| Catmull-Clark subdivision | Shift + `D` |
| Delete | `Delete` |
| Remove | `Backspace` |
| Undo / Redo | `Ctrl+Z` / `Ctrl+Shift+Z` |
| Toggle snap | `X` |
| Shrink gizmo | `-` |
| Grow gizmo | `=` |
| Start recording events | `F1` |
| Stop recording | `F2` |
| Quit | `Esc` |

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

## Build and run

Requires [DUB](https://dub.pm/) and a D compiler (DMD or LDC), plus an installed SDL2.

```sh
dub build
./vibe3d
```

### Runtime flags

| Flag | Description |
|---|---|
| `--test` | Start with HTTP server for automated testing |
| `--playback events.log` | Replay a recorded event session |
| `--no-http` | Run without the HTTP server |
| `--http-port 9090` | HTTP server port (default: 8080) |

## Testing

Tests are D programs that drive a running vibe3d instance through its HTTP API.

```sh
./run_all.d --no-build           # full pre-commit suite (unit + blender + modo + acen)
./run_test.d                     # unit tests only
./run_test.d -j 4                # parallel — 4 workers
./run_test.d test_bevel          # one test (also: bevel, tests/test_bevel.d)
./run_test.d bevel selection     # a subset
./run_test.d -v test_bevel       # stream the test's stdout/stderr
./run_test.d --keep              # leave vibe3d running after tests finish
./run_test.d --no-build          # skip `dub build`
```

Reference-comparison suites:

```sh
rdmd tools/blender_diff/run.d              # compare geometry against Blender
rdmd tools/modo_diff/run.d                 # compare geometry against MODO (requires modo_cl)
./tools/modo_diff/run_acen_drag.py -j 4    # MODO action-center drag parity
```

Test files: `tests/test_*.d`. Recorded event sessions: `tests/events/*.log`.

## Dependencies

- [bindbc-sdl](https://github.com/BindBC/bindbc-sdl) — SDL2 bindings
- [bindbc-opengl](https://github.com/BindBC/bindbc-opengl) — OpenGL bindings
- [d_imgui](https://github.com/shulc/imgui) — Dear ImGui for D

## License

MIT
