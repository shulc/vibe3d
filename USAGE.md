# Vibe3D — Tools & Controls

Full reference for every tool and keyboard shortcut. For an overview of the
project see the [README](README.md). Keyboard shortcuts are configurable in
`config/shortcuts.yaml` (`config/shortcuts_macos.yaml` on macOS); the keys below
are the defaults. Every tool also exposes numeric parameter entry in the **Tool
Properties** panel (a YAML-driven forms engine), so any drag can be dialed in
exactly.

## Tools

### Transform — direct manipulation

| Tool | Hotkey | Description |
|---|---|---|
| **Move** | `W` | Translate the selection along an axis, plane, or freely via the gizmo. Numeric entry in the property panel; pipeline-driven action center / axis / falloff. |
| **Rotate** | `E` | Rotate around X / Y / Z or the camera-facing axis. Hold Ctrl to snap to 15° increments. |
| **Scale** | `R` | Scale along one axis, in a plane, or uniformly from the gizmo center. |
| **Transform** | `Y` | Unified tool that exposes the Move, Rotate and Scale gizmo banks simultaneously (T / R / S). |
| **Element Move** | `T` | Transform preset with action center + falloff pinned to **Element** — moves each connected cluster about its own center. |
| **Flex** | — | Soft-selection transform (T+R+S) under a selection falloff. |

### Create — procedural primitives

Each Create tool drops an interactive gizmo plus a parameter panel; every value
is editable numerically. Ctrl-click a Create button for a unit-sized instance.

| Tool | ID | Description |
|---|---|---|
| **Box** | `prim.cube` | Cuboid with per-axis segments and optional rounded edges (radius / segmentsR / sharp axis). |
| **Sphere** | `prim.sphere` | UV-sphere (Globe), QuadBall or Tessellation methods; radius, pole axis, longitude / latitude resolution. |
| **Ellipsoid** | `prim.ellipsoid` | Sphere with independent per-axis radii. |
| **Cylinder** | `prim.cylinder` | Radius, height along the chosen axis, sides and segment count. |
| **Tube** | `prim.tube` | Hollow cylinder — outer / inner radius, height, sides, optional caps. |
| **Cone** | `prim.cone` | Linearly tapered cone; disc base + apex vertex. |
| **Capsule** | `prim.capsule` | Cylinder with proportional hemispherical end-caps; collapses cleanly to a sphere when the caps consume the full length. |
| **Torus** | `prim.torus` | Quad-only torus with major / minor radius and major / minor segment counts. |
| **Arc** | `prim.arc` | Open arc / ring segment — radius, start / end angle, segments. |
| **Pen** | `pen` | Click-to-place vertex tool for building polygons / line strips / quad strips on the construction work-plane. Any committed point is numerically editable. |
| **Vertex** | `prim.vertex` | Place a single vertex. |

### Vertex tools

| Tool / command | ID | Description |
|---|---|---|
| **Bevel** | `mesh.vertexBevel` | Interactive vertex bevel — replace a vertex with a small face/fan. |
| **Extrude** | `mesh.vertexExtrude` | Extrude selected vertices. |
| **Merge** | `vert.merge` | Interactively weld vertices together. |
| Join · Add Vertex · Center · Collapse · Split | `vert.join` · `mesh.addVertex` · `mesh.centerVertices` · `mesh.collapse` · `mesh.vertexSplit` | Command-driven vertex edits. |

### Edge tools

| Tool / command | ID | Hotkey | Description |
|---|---|---|---|
| **Bevel** | `edge.bevel` | `B` | Round or chamfer the selected edges; drag for width, panel for segments. |
| **Slide** | `edge.slide` | — | Slide edges along their neighboring faces. |
| **Extrude** | `edge.extrude` | — | Extrude the selected edges along their averaged normal; drag to set extrusion and width. |
| **Extend** | `edge.extend` | `Z` | Add a new strip of geometry off the selected boundary edges (additive, non-manifold) with per-vertex meet against incident face planes; supports per-segment rotation / scale. |
| **Bridge Tool** | `mesh.bridgeTool` | — | Interactively bridge two edge loops / rings. |
| Add Loop · Add Point · Bridge · Spin · Join · Split | `mesh.addLoop` · `mesh.addPoint` · `mesh.bridge` · `mesh.spinEdge` (`V`) · `mesh.edgeJoin` · `mesh.split_edge` | Command-driven edge edits. |

### Polygon tools

| Tool / command | ID | Hotkey | Description |
|---|---|---|---|
| **Extrude** | `poly.extrude` | `Shift+X` | Extrude the selected faces. |
| **Bevel** | `poly.bevel` / `mesh.bevel` | `Shift+B` | Bevel / inset the selected faces. |
| **Inset** | `mesh.polyInsetTool` | — | Inset faces inward, creating a border ring. |
| **Smooth Shift** | `mesh.smoothShiftTool` | — | Shift faces along smoothed normals (shell-style). |
| **Thicken** | `mesh.thickenTool` | — | Smooth Shift preset that adds thickness. |
| **Stroke Extrude** | `tool.strokeExtrude` | — | Extrude faces along a dragged screen stroke. |
| Spikey · Reduce · Make Polygon · Split · Triple (`Shift+T`) · Quadruple · Flip (`F`) · Set Part · Set Material (`M`) · Merge · Unify · Detriangulate | `mesh.spikey` · `mesh.reduce` · `mesh.makePolygon` · `mesh.splitFace` · `mesh.triple` · `mesh.quadruple` · `mesh.flip` · `mesh.setPart` · `mesh.setMaterial` · `mesh.mergeFaces` · `poly.unify` · `mesh.detriangulate` | Command-driven polygon edits. |

### Slice & topology

| Tool / command | ID | Hotkey | Description |
|---|---|---|---|
| **Loop Slice** | `mesh.loopSliceTool` | `Alt+C` | Insert one or more edge loops around a ring; drag to position, panel for count. |
| **Slice** | `mesh.sliceTool` | `Shift+C` | Knife-cut across the mesh along a drawn line. |
| **Edge Slice** | `mesh.edgeSliceTool` | — | Slice along a chosen edge path. |
| Julienne · Axis Slice · Screen Slice | `mesh.julienne` · `mesh.axisSlice` · `mesh.screenSlice` | Command-driven grid / plane cuts. |

### Subdivision, subpatch & remesh

| Command | ID | Hotkey | Description |
|---|---|---|---|
| **Subdivide** | `mesh.subdivide` | `D` | Catmull-Clark subdivision, applied immediately. |
| **Faceted** | `mesh.subdivide_faceted` | `Shift+D` | Linear (faceted) subdivision. |
| **Subpatch** | `mesh.subpatch_toggle` | `Tab` | Toggle live subpatch (subdivision-surface) preview on the selected faces. |
| **Clean Up** · **Fix Orientation** | `mesh.cleanup` · `mesh.fixOrientation` | — | Remove degenerate geometry; unify face winding. |
| **Remesh (Quad)** | `mesh.remesh.open` | — | Retopologize into quads via an external helper (see note below). |

### Duplicate & array

| Tool / command | ID | Hotkey | Description |
|---|---|---|---|
| **Mirror Tool** | `mesh.mirrorTool` | `Shift+V` | Interactive mirror across a chosen plane. |
| **Array** | `mesh.arrayTool` | — | Linear array of copies. |
| **Radial Array Tool** | `mesh.radialArrayTool` | — | Circular array of copies about an axis. |
| **Radial Sweep Tool** | `mesh.radialSweepTool` | — | Sweep the selection around an axis. |
| Duplicate · Mirror · Radial Array · Radial Sweep · Duplicate Layer | `mesh.duplicate` · `mesh.mirror` · `mesh.radial_array` · `mesh.sweep` · `layer.duplicate` | Command-driven duplication. |

### Align

| Tool | ID | Description |
|---|---|---|
| **Radial Align** | `xfrm.radialAlignTool` | Align the selection onto a common circle / axis. |
| **Linear Align** | `xfrm.linearAlignTool` | Flatten / align the selection onto a common line or plane. |

### UV

| Command | ID | Description |
|---|---|---|
| Project · Relax · Fit | `uv.project` · `uv.relax` · `uv.fit` | Create / relax / fit UVs for the selection. |
| Flip · Rotate · Mirror · Pack | `uv.flip` · `uv.rotate` · `uv.mirror` · `uv.pack` | Modify the active UV map. |
| Delete · Rename · Copy · Clear | `uv.delete` · `uv.rename` · `uv.copy` · `uv.clear` | Manage UV maps. |

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
| **Soft Transform** | `xfrm.softTransform` | T+R+S · radial | Unified move + rotate + scale under a radial falloff. |
| **Uniform Scale** | `xfrm.scaleUniform` | Scale · — | Scale locked to a single uniform factor. |
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
| **Flex**        | `xfrm.flex`      | T+R+S · selection | Unified transform (translate + rotate + scale) under a selection falloff. |

## Tool pipeline (status bar)

The status bar hosts the stages that modify every transform. Most are pulldowns;
Alt-click for granular options.

| Control | Options |
|---|---|
| **Action Center** | Automatic · Selection · Selection Border · Selection Center Auto Axis · Element · Screen · Origin · Local — plus granular Center → / Axis → submenus. |
| **Snap** (`X`) | Master toggle + per-type checkboxes: Vertex, Edge, Edge Center, Polygon, Polygon Center, Grid, Workplane, and Fixed Grid. |
| **Falloff** | Type pulldown: Linear · Radial · Cylinder · Screen · Lasso · Element · Selection · Vertex Map. Alt-click to stack multiple falloff instances with mix modes. |
| **Symmetry** | Off · X · Y · Z · Workplane. |
| **Work Plane** | Auto · World X/Y/Z · Align To Selection · Reset. |
| **AI** | Toggle the modeling copilot's candidate ranking on/off. |

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
| Move / Rotate / Scale | `W` / `E` / `R` |
| Transform (T+R+S) | `Y` |
| Element Move | `T` |
| Edge Bevel / Polygon Bevel | `B` / `Shift+B` |
| Polygon Extrude / Edge Extend | `Shift+X` / `Z` |
| Mirror Tool | `Shift+V` |
| Loop Slice / Slice | `Alt+C` / `Shift+C` |
| Reset active tool | `Ctrl+D` |
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
| Drop selection | `Esc` |

### Mesh operations

| Action | Key |
|---|---|
| Catmull-Clark subdivision | `D` |
| Faceted subdivision | `Shift+D` |
| Subpatch toggle | `Tab` |
| Triple polygons | `Shift+T` |
| Flip polygons | `F` |
| Spin edge | `V` |
| Set material | `M` |
| Copy / Paste / Cut | `Ctrl+C` / `Ctrl+V` / `Ctrl+X` |
| Delete | `Delete` |
| Remove | `Backspace` |
| Undo / Redo | `Ctrl+Z` / `Ctrl+Shift+Z` |
| Toggle snap | `X` |
| Shrink / Grow gizmo | `-` / `=` |
| Start / Stop recording events | `F1` / `F2` |

> On macOS the modifier keys use `Cmd` instead of `Ctrl` (e.g. `Cmd+Z` to undo),
> and Delete is `Backspace` / `Cmd+Backspace`. See `config/shortcuts_macos.yaml`.

### File

| Action | Key |
|---|---|
| New | `Ctrl+N` |
| Open | `Ctrl+O` |
| Save | `Ctrl+S` |
| Save As | `Ctrl+Shift+S` |
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

## Files & formats

Vibe3D's native format is **`.v3d`** (JSON, lossless — geometry, subpatch,
layers, surfaces). Use File → New / Open / Save / Save As.

Interchange formats are available under File → Import / Export:

| Format | Import | Export |
|---|---|---|
| **OBJ** | ✓ | ✓ |
| **glTF** | ✓ | ✓ |
| **FBX** | ✓ | (deferred) |
| **LWO** | ✓ | ✓ |

OBJ / glTF / FBX go through a statically-linked assimp; LWO uses a bundled
clean-room reader/writer. Multi-part imports become one layer per part.

**Generate 3D** (File → Generate 3D) is an optional AI image→3D add-on
installed from inside the editor — see [INSTALL.md](INSTALL.md). **Remesh (Quad)**
requires an external `autoremesher_cli` helper on `PATH` (or a sibling
`D-AutoRemesher` checkout); point `VIBE3D_AUTOREMESHER_BIN` at it if it lives
elsewhere.

## Recording & playback

Press `F1` to start recording input events to `recording.jsonl` and `F2` to
stop. Replay any recorded session deterministically with:

```sh
./vibe3d --playback recording.jsonl
```

Event logs power the automated test suite (`tests/events/*.log`); see the
[README](README.md#testing) for the test harness.
