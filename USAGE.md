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

#### Transforming whole items

Selecting a layer in the Layers panel makes **item** the current selection type.
`W` / `E` / `R` then move, rotate and scale the whole layer: the gizmo sits on
the item's pivot (its position plus its pivot offset) with world-aligned
handles, and a drag writes the layer's own transform channels — the mesh rides
along and its local vertex coordinates do not change. The numeric fields in the
Layers panel and the gizmo always show the same values. Every **selected** layer
is transformed, including a selected layer that is currently hidden, and one
drag is one undo entry no matter how many layers it moved.

In item mode you must grab a handle. An unmodified left press that misses the
gizmo is swallowed by the tool: it will not relocate the action center and it
will not switch you into a geometry mode. (Modified presses are unaffected —
Alt still orbits.) The consequence is that the off-gizmo gestures the geometry
modes offer — free screen-plane drag, arcball outside the rotate rings, plane
scale outside the handles — are not available on items.

**Item scale acts on the item's own axes, by index.** A scale handle multiplies
the scale component with the *same index* as the handle: the X handle always
writes the item's X scale. On a rotated item this is not the same as stretching
along world X — the item stretches along its own first axis instead, so the
result differs from a geometric world-axis scale. This is deliberate, not a
rounding artefact: an item stores one position, one rotation, one scale and one
pivot, and for an arbitrary rotation there is no per-axis scale in that form
that reproduces a world-axis stretch. One rule applies at every pose rather
than a rule that silently changes at particular angles. When you need a true
world-axis stretch, scale the geometry in a vertex / edge / polygon mode
instead.

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
| Items mode | `5` |
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

#### Items mode

`5` (or the **Items** button on the status line) switches the selection type to
**Items** — you are selecting whole items (layers, image planes) rather than
geometry inside one. It is a peer of Vertices / Edges / Polygons, not a fourth
"edit mode": the geometry mode you were in is remembered, so `1`/`2`/`3` put you
back exactly where you were.

Items mode is what decides **what a transform edits**:

* In Vertices / Edges / Polygons, Move / Rotate / Scale deform the mesh —
  they move vertices.
* In Items, the same tools edit the item's own **transform channels**
  (`pos` / `rot` / `scl`, the ones the Properties and Channels panels show as
  numbers). The mesh rides along; its local coordinates are untouched.

So "move the whole object" and "move the geometry inside the object" are the
same gizmo in two modes, and the status line always says which one you are in.
The gizmo sits on the item's own pivot, its handles are world-aligned, and a
whole drag is one undo step — the same step you get from typing the number into
the panel.

Selecting an item in the Items panel also makes Items the current type (it always
has). What `5` adds is the ability to switch **into** the mode without touching
the selection.

##### Clicking an item in the viewport

In Items mode, clicking in the viewport selects the item under the cursor —
including a **backdrop image plane**, which has no geometry to click but is
picked by its rectangle. The item under the cursor also pre-highlights as you
move over it, so you can see what a click will take before you take it.

| Action | Chord |
|---|---|
| Select the item under the cursor (replacing the selection) | `LMB` |
| Add it to the selection | `Shift`+`LMB` |
| Remove it from the selection | `Ctrl`+`LMB` |

The same chords as geometry selection, and the same rules apply as everywhere
else in Items mode:

* **The item you can see wins.** Where several meshes overlap, the click takes
  the one nearest the camera. A backdrop always loses to a mesh over it, even
  when the backdrop is nearer — backdrops are drawn behind everything, so the
  mesh is what that pixel actually shows.
* **Clicking empty space does nothing.** It does not clear the item selection
  (one item is always selected), and — unlike a geometry mode — it does not
  clear your vertex / edge / polygon selection either. Switch back with
  `1`/`2`/`3` and your geometry selection is exactly where you left it.
* Selecting a backdrop or another item that carries no mesh does not change
  which mesh the modelling tools edit. That stays on the last mesh item you
  selected.

**Worth knowing:** clicking a row in the Items panel also switches you to Items
mode — it always has — so the very next viewport click selects an item too. If
you meant to go back to editing points, press `1`/`2`/`3` first; the geometry
type you were in is remembered, and so is the geometry you had selected.

### Visibility (hiding geometry)

Hiding takes part of a mesh out of the way **without deleting it**. Hidden
geometry is not drawn, does not occlude what is behind it, cannot be picked by
click or drag-rect, is not snapped to, and is left untouched by every mesh
operation. It is what you reach for when you model inside a volume: hide the
back of a head and you stop fighting it while you work on the face.

| Action | Key |
|---|---|
| Hide Selected | `H` |
| Isolate (hide unselected) | `Shift+H` |
| Invert Hidden | `Ctrl+H` |
| Unhide All | `U` |

The same four commands sit under **Visibility** on the **Selection** tab of the
command panel.

What hiding does, precisely:

- **It works per component type.** Hiding polygons hides those polygons; a
  vertex or an edge becomes hidden only once *every* polygon using it is hidden
  — or, for a loose point with no polygon at all, when it is hidden in its own
  right. So hiding two polygons of a cube hides no vertex and no edge, and all
  8 vertices stay selectable.
- **Hidden geometry leaves the selection.** Hiding what you had selected leaves
  you with an empty selection, and nothing you cannot see can be selected
  afterwards — not by clicking, not by a rectangle, not through the symmetry
  auto-add.
- **An empty selection means "everything visible".** Commands that fall back to
  the whole mesh when nothing is selected act on the *visible* whole mesh, so
  hiding is also a way to scope an operation.
- **Hide, Isolate and Invert Hidden only ever add to what is already hidden**;
  `U` (Unhide All) is what takes hiding away. One consequence is worth knowing
  before it surprises you: isolating onto something that is *already* hidden
  blanks the viewport, because the hidden set then covers the whole mesh. That
  is intended behaviour, not a bug — and it is why a hidden count is always on
  screen (`Hidden: 4 vert, 6 poly` on the command row, `4/0/6 hidden` beside the
  selection counts). An empty viewport with a hidden count is a mesh that `U`
  brings straight back, not a mesh you lost.
- **Undo puts it back in one step.** A hide and the deselection it causes are a
  single `Ctrl+Z`.
- **Hiding does not survive save and reload.** It is session state, not document
  content: save a document with half of it hidden, reopen it, and everything is
  visible again. Nothing is lost — only the hiding is forgotten. The same holds
  for File → New, for `.v3d` and for every interchange format.

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

## Reference images

A **reference-image plane** puts a drawing or a photograph into the scene as a
flat, axis-aligned quad you model against — the front and side views of a
character, a blueprint, a scale reference. It is an ordinary item in the Layers
panel with its own transform, so it is placed with the ordinary Move / Rotate /
Scale gizmo in item mode; there is no separate dialog.

**Its world size is your model's scale, and that is the point of the feature.**
The plane's extent is the image's pixel dimensions times **Pixel Size** (metres
per pixel, default `0.01`). A 512 × 256 image at the default is 5.12 m × 2.56 m
— so if you know the reference is a person 1.8 m tall, set Pixel Size until the
plane measures 1.8 m and everything you model against it comes out life-size.
Get this right before you start and the model needs no rescaling afterwards.

To set one up:

1. **Load the image.** `Load...` in the **Images** panel. The image is a
   document resource of its own — several planes can share one.
2. **Add the plane.** `+Plane` in the Layers panel makes a `front` plane with
   no image yet.
3. **Point it at an image.** The **Image** dropdown in the item properties
   lists every loaded image; pick one.
4. **Place it.** Select the plane's row and use `W` / `E` / `R`. The panel's
   numeric fields and the gizmo show the same values.

The plane's own channels:

| Channel | Default | What it does |
|---|---|---|
| **Projection** | Front | Which axis the plane faces: Top, Bottom, Front, Back, Left, Right. |
| **Show in Perspective** | on | Whether it is drawn in perspective views as well as in its own orthographic one. |
| **Pixel Size** | 0.01 | Metres per image pixel — the scale control described above. |
| **Keep Aspect** | on | See below; it changes *which* size law applies. |
| **Brightness** / **Contrast** / **Transparency** | 0 | Make a faint pencil drawing readable, or fade the plane back behind the wireframe. |
| **Invert** | off | Flip the colours, so a dark drawing on a dark background becomes visible. |
| **Flip Horizontal** | off | Mirror the image. Only the picture flips — the plane does not move. |
| **Smooth** | off | Interpolate between pixels instead of showing them as blocks. |

**A plane is only drawn in the view its Projection names**, plus perspective
views if Show in Perspective is on. A `front` plane is not drawn in a `back`
view — it is not mirrored into the opposite direction — and not in `top` or
`left` either. If you cannot see a plane you just made, that is the first thing
to check.

**Two things about it are worth knowing before they look like bugs.**

**With Keep Aspect on — the default — dragging one scale axis does not resize
the plane.** The plane takes the *smaller* of the two scale factors and applies
it to both, so raising one axis alone changes nothing at all and half the scale
gizmo appears inert. This is intended: it is what keeps the image from being
stretched out of proportion. Turn Keep Aspect **off** when you actually want to
stretch a reference to fit something — then the two axes act independently, and
the base size becomes the image *height* on both axes rather than its pixel
dimensions.

**A plane with no usable image draws nothing at all** — no placeholder, no
outline, just empty space where you expected a picture. The reason is always
one of four, and the item properties panel names which: *no image* (nothing
picked yet), *image removed* (the image it pointed at was deleted from the
document), *file not found* (the file has moved or been renamed; the item keeps
its path and finds it again once it is back), or *hidden* (the layer's own
visibility is off).

What a reference plane deliberately does **not** do:

- **It is never picked in the viewport.** Clicking through it selects the
  geometry behind it; a rectangle drag over it selects the vertices behind it.
  Select it from its row in the Layers panel.
- **It is not geometry.** It is not exported to OBJ / glTF / FBX / LWO, it is
  not framed by Fit, it contributes no snap points except its own pivot, and no
  mesh operation sees it.
- **There is no auto-fit** — no one-click "size this plane to the model". Set
  Pixel Size, or scale it by hand.
- **There is no "ignore the image size" mode.** The extent always comes from
  the image's pixels; the scale multiplies it.
- **A one-axis scale under Keep Aspect does nothing**, as above.

## Files & formats

Vibe3D's native format is **`.v3d`** (JSON). Use File → New / Open / Save /
Save As.

A `.v3d` round-trip **keeps**: vertex coordinates (unchanged, to the last bit),
n-gon faces, per-face subpatch flags, material and part ids, surfaces, UV and
weight maps, the item list — every item, of every kind, including ones that
carry no mesh — with each item's name, visibility and selection, which item is
the edit target and which holds the item-selection focus, item parenting, each
item's full transform (position, rotation, scale and pivot, all four exactly as
authored), the loaded image list with each image's file path and settings, and
the references from an item to an image.

It **does not keep**: a reference to an image that has already been deleted
from the document. Such a reference survives in memory (so undoing the delete
restores it) but has nothing to point at in the file, so it comes back unset
rather than broken. An image's pixel dimensions and format are not stored
either — they are re-read from the file each time the document is opened, so
they can never be stale.

**Image paths are stored relative to the document** when the image sits beside
it or in the folder above; anything further away is stored as a full path. Move
a document and its images together and it still finds them. If an image file is
missing when the document is opened, the document still opens: the image keeps
its path and is marked as missing, and Reload picks it up once the file is back.

A scale component whose magnitude falls outside 0.0001 … 1000000 is clamped
into that range when the file is read, keeping its sign, because a value beyond
it makes the item's matrix unusable.

**Documents saved by earlier versions of Vibe3D do not open.** The format was
deliberately broken rather than carrying two readers; the editor says which
version the file is and which version it reads, and that the file is not
damaged.

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

## Which build am I running?

`File ▸ About…` shows the version, the build configuration
(`modeling` / `modeling-noai` / `with-render`), the platform and the build
date, with a **Copy** button so it can be pasted into a bug report.

The same block prints from the terminal, and needs no display — so it also
answers on a headless machine, or on one where the editor will not start:

```sh
./vibe3d --version
```

```
vibe3d 0.0.2
build: modeling
platform: linux-x86_64
built: Aug  9 2026
```

Please include it when reporting a problem: nightly builds all share a version
number, and the build date is what tells them apart. Release notes for each
version are in the [CHANGELOG](CHANGELOG.md).
