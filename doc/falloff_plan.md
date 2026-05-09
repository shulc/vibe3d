# Falloff Plan — Phase 7.5 of `phase7_plan.md`

Detailed breakdown for the WGHT (Weight / Falloff) Tool Pipe stage.
Mirrors the structure of `snap_plan.md`. Phase 7.5 in the parent doc
budgeted ~550 LOC; this expanded plan covers ~950 LOC across 7
subphases (the lasso input mode + viewport gizmos add the extra
volume).

---

## Goal

Add **soft selection / falloff** to vibe3d, matching MODO's
falloff system at the "useful subset" level:

- Per-vertex weight in `[0, 1]` published by a `FalloffStage` so
  Move / Rotate / Scale can multiply their per-vertex transforms by
  it.
- Five built-in types (matching MODO's most-used):
  `none`, `linear`, `radial`, `screen`, `lasso`.
- Numeric attrs settable via `tool.pipe.attr falloff <name> <value>`.
- Visual gizmos in the viewport to adjust the falloff without the
  property panel (drag linear endpoints, drag radial sphere, drag
  screen circle, redraw lasso).
- Auto-size on activation: when a falloff is selected with an active
  Move/Rotate/Scale, its bounds default to the selection's bbox so
  the user gets an immediately useful starting point.

After this lands, a Move tool with selection of one vertex and a
radial falloff produces a rubber-sheet pull — a building block
modeling primitive vibe3d currently lacks.

---

## MODO source-of-truth (verified locally)

### SDK (`LXSDK_661446/include/lxtool.h`)

```c
// The falloff packet is set by falloff tools.
typedef struct vt_ILxFalloffPacket {
    LXxMETHOD( double, Evaluate )(self, LXtFVector pos, LXtPointID vrx, LXtPolygonID poly);
    LXxMETHOD( double, Screen   )(self, LXtObjectID vts, int x, int y);
} ILxFalloffPacket;

#define LXsP_TOOL_FALLOFF      "tool.falloff"
#define LXu_FALLOFFPACKET      "B0EA09EB-..."   // ILxFalloffPacket
```

The packet is consumer-facing: tools only see two pure functions
(`Evaluate(worldPos, vert, poly)` for in-mesh falloff,
`Screen(viewport, x, y)` for screen-space falloff). The actual
falloff types live in the falloff stage that publishes this packet.
Vibe3d will mirror this — a value-typed `FalloffPacket` with a
free `evaluateFalloff()` function that switches on type.

### Falloff tools (`resrc/commonforms.cfg`)

Each falloff is its own `tool.set falloff.<name> on` entry. MODO
exposes Linear / Cylinder / Radial / Airbrush / Screen / Element /
Noise / Curvature / Vertex Map / Path / Lasso / Image. Of these, the
modeling-relevant ones are Linear / Radial / Screen / Lasso /
Element — vibe3d ships the first four in 7.5; Element is a follow-up
because it requires a runtime click-to-pick gesture similar to what
SnapStage already needed for live cursor coupling.

### Bundled help (`help/pages/modeling/selection_falloffs.html`)

Captured the property names + behaviour for each type:

- **Linear**: Start X/Y/Z, End X/Y/Z, Shape Preset, In/Out (Custom),
  Mix Mode. Auto-Size scales the line to the selection bbox along
  one of its axes.
- **Radial**: Center X/Y/Z, Size X/Y/Z (per-axis radii — ellipsoid),
  Shape Preset, In/Out, Mix Mode. Auto-Size scales to half the
  selection bbox extent.
- **Screen**: Center X/Y (pixels), Size (pixel radius), Transparent
  (defaults off — facing-only), Mix Mode.
- **Lasso**: Style (Lasso / Rectangle / Circle / Ellipse), Soft
  Border (pixels), Mix Mode. Polygon / shape is drawn at activation.

`Mix Mode` is for combining multiple falloffs (MODO's "Add" entry
in the menu). Out of scope for 7.5; a single active falloff replaces
any previous one.

### Activation behaviour

> "If a tool is active when setting a falloff, the act of simply
> selecting the falloff type automatically scales the falloff to
> the bounding box size of the active selection."

Vibe3d will follow this convention — `setAttr type` triggers an
auto-size pass against the current selection's bbox.

### Shape presets

> Linear, Ease-In, Ease-Out, Smooth, Custom (with In/Out values).

In math terms (where t ∈ [0,1] is normalized distance):

- Linear   →  `1 - t`
- Ease-In  →  `1 - t²`
- Ease-Out →  `(1 - t)²`
- Smooth   →  `1 - smoothstep(0, 1, t)` = `1 - (3t² - 2t³)`
- Custom   →  Bézier-ish blend driven by `in_` / `out_` ∈ [0,1].
              Concretely: cubic Hermite with tangents proportional
              to `in_` (at t=0) and `out_` (at t=1).

---

## Vibe3d adaptation

| MODO concept              | Vibe3d implementation                                   |
|---------------------------|---------------------------------------------------------|
| `FalloffPacket` (COM)     | Plain struct + free `evaluateFalloff()` (matches SnapPacket pattern) |
| `tool.set falloff.linear` | `tool.pipe.attr falloff type linear`                    |
| Falloff property form     | Renderable via existing `params` mechanism              |
| Auto-Size on activation   | `setAttr("type", ...)` recomputes start/end/center/size |
| Mix Mode (Add)            | Out of scope — single active falloff                    |
| Element falloff           | Out of scope — adds runtime click-to-pick gesture       |
| Vertex Map / Image / Path | Out of scope — vibe3d has no vmap / texture / curve infra |

The `FalloffPacket` is *value-typed* (no `Object` derived), keeping
it cheap to copy and serialise. Tools call:

```d
float w = evaluateFalloff(state.falloff, worldPos, vertIdx, viewport);
```

Returning `1.0` when `!state.falloff.enabled` makes the call a
no-op for any tool that hasn't been wired — mirrors the SNAP
short-circuit pattern.

---

## Architecture

### Packets (`source/toolpipe/packets.d`, extended)

```d
enum FalloffType : uint {
    None    = 0,
    Linear  = 1,
    Radial  = 2,
    Screen  = 3,
    Lasso   = 4,
}

enum FalloffShape : ubyte {
    Linear  = 0,
    EaseIn  = 1,
    EaseOut = 2,
    Smooth  = 3,
    Custom  = 4,    // uses in_ / out_
}

enum LassoStyle : ubyte {
    Freehand = 0,
    Rectangle = 1,
    Circle = 2,
    Ellipse = 3,
}

struct FalloffPacket {
    bool          enabled;
    FalloffType   type        = FalloffType.None;
    FalloffShape  shape       = FalloffShape.Smooth;

    // Linear
    Vec3          start       = Vec3(0, 0, 0);
    Vec3          end         = Vec3(0, 1, 0);

    // Radial — center + per-axis ellipsoid radii.
    Vec3          center      = Vec3(0, 0, 0);
    Vec3          size        = Vec3(1, 1, 1);

    // Screen — center in window pixels + pixel radius.
    float         screenCx    = 0;
    float         screenCy    = 0;
    float         screenSize  = 64;
    bool          transparent = false;   // 7.5 ships only "facing-only=false"
                                          // (no ray-cast for back-face check)

    // Lasso — polygon / shape parameters in window pixels.
    LassoStyle    lassoStyle  = LassoStyle.Freehand;
    float[]       lassoPolyX;   // freehand: arbitrary length
    float[]       lassoPolyY;
    float         softBorderPx = 16;

    // Custom shape (when shape == Custom): cubic-Hermite tangents.
    float         in_         = 0.5f;
    float         out_        = 0.5f;
}

struct ToolState {
    // ... existing ...
    FalloffPacket falloff;
}
```

`Vec2` would be cleaner for lasso polygon points but vibe3d's `math.d`
doesn't currently expose it; reusing two `float[]` arrays avoids
adding a new type for one consumer.

### Stage (`source/toolpipe/stages/falloff.d`, new)

```d
class FalloffStage : Stage {
    Mesh*     mesh_;       // for auto-size on type switch
    EditMode* editMode_;

    // attrs settable via tool.pipe.attr falloff <name> <value>
    FalloffType  type;
    FalloffShape shape;
    Vec3 start, end;
    Vec3 center, size;
    float screenCx, screenCy, screenSize;
    bool  transparent;
    LassoStyle lassoStyle;
    float[] lassoPolyX, lassoPolyY;
    float   softBorderPx;
    float   in_, out_;

    override TaskCode taskCode() { return TaskCode.Wght; }
    override ubyte    ordinal()  { return ordWght; }
    override string   id()       { return "falloff"; }

    override void evaluate(ref ToolState state) {
        state.falloff.enabled = (type != FalloffType.None);
        // ... copy all attrs onto state.falloff ...
    }

    override bool setAttr(string name, string value);
    override string[2][] listAttrs() const;

    // Auto-size hook called by setAttr("type", ...) — sizes the
    // falloff to the current selection bbox so the new type is
    // immediately useful.
    private void autoSize();
}
```

Registered in `app.d:initToolPipe()` alongside WORK / ACEN / SNAP.

### Falloff math (`source/falloff.d`, new)

Mirrors `snap.d` — pure functions, no GL / no ImGui:

```d
/// Evaluate falloff weight at world `pos`. `vertIdx` is the index
/// into mesh.vertices for cases where future falloff types want it
/// (Element, Vertex Map). `vp` provides the projection for screen-
/// space types. Returns 1.0 when `!cfg.enabled` — caller can blindly
/// multiply per-vertex deltas without short-circuiting.
float evaluateFalloff(const ref FalloffPacket cfg,
                      Vec3 pos,
                      int  vertIdx,
                      const ref Viewport vp);
```

Internals dispatch on `cfg.type`:

- **Linear**: project `(pos - start)` onto axis `(end - start)`,
  clamp `t = clamp(dot/|axis|², 0, 1)`, return `applyShape(1 - t)`.
- **Radial**: compute ellipsoid distance
  `d² = ((pos.x - center.x) / size.x)² + …`; return `applyShape(d²)`
  via `1 - clamp(sqrt(d²), 0, 1)`.
- **Screen**: project `pos` to window pixels, distance from
  `(screenCx, screenCy)`; return `applyShape(distance / screenSize)`.
  When `transparent == false` and the vert's projected NDC z is past
  the far-side pivot (camera-facing test using vert normal — phase 2
  follow-up), weight = 0.
- **Lasso**: project `pos` to window pixels; if inside polygon, 1.0;
  else compute screen-distance to nearest polygon edge and apply
  `applyShape(distance / softBorderPx)`. Use the existing
  `pointInPolygon2D` from `math.d`.

`applyShape(t)` is the per-shape attenuation curve listed in the
"Shape presets" section above.

### Tool integration points

Move / Rotate / Scale opt in via a new virtual:

```d
class Tool {
    bool consumesFalloff() const { return false; }
}
class TransformTool : Tool {
    override bool consumesFalloff() const { return true; }
}
```

(MoveTool, RotateTool, ScaleTool inherit `true`; BevelTool, all
primitive create-tools, PenTool keep the default `false`.)

Per-tool changes:

- **MoveTool.applyDeltaImmediate**: replace
  `mesh.vertices[vi] += delta` with
  `mesh.vertices[vi] += delta * weight(vi)`.
- **MoveTool.applyPerClusterDelta**: same — multiply each cluster's
  per-vert delta by `weight(vi)`.
- **RotateTool.applyRotationVec**: `rotateVec(vert, pivot, axis,
  angle * weight(vi))`. Per-vertex angle creates a "twist" effect,
  which is exactly what falloff + rotate is for.
- **RotateTool.applyAbsoluteFromOrigCpuOnly**: same per-vert angle
  weighting, applied to each axis component.
- **RotateTool.commitWholeMeshRotation**: as above; whole-mesh path
  switches from a single matrix to a per-vert loop when falloff is
  enabled (cheap — vert count is bounded by mesh size).
- **ScaleTool.applyScaleAxesFactor / commitWholeMeshScale**:
  per-vert scale factor blended via `1 + (factor - 1) * weight(vi)`.
- **ScaleTool.applyScaleFromActivationCpuOnly**: same blending in
  the activation→current path.

`weight(vi)` is a thin wrapper:

```d
float weight(int vi) {
    if (!state.falloff.enabled) return 1.0f;
    return evaluateFalloff(state.falloff,
                           mesh.vertices[vi], vi, cachedVp);
}
```

State is captured into the tool at drag start (one
`pipeline.evaluate` call) so per-vertex math doesn't re-walk the
pipeline every iteration.

Whole-mesh GPU bypass paths (`gpuMatrix` translates / rotates /
scales via a single uniform) **must** turn off when falloff is
active — the transform is no longer uniform across verts. The CPU
per-vertex path takes over; deferred GPU upload stays unchanged.

### Visual feedback (`source/falloff_render.d`, new)

Mirrors `snap_render.d`. One overlay per type:

- **Linear**: line from `start` to `end`, plus two `BoxHandler`s at
  the endpoints for drag manipulation. Cyan tint, dashed for the
  "outside" range past start/end.
- **Radial**: wireframe ellipsoid (3 great circles in the basis
  axes) at `center` with radii `size`. Plus 6 small handles on the
  ±X/±Y/±Z surface points for axis-locked size drag.
- **Screen**: solid screen-space disc at `(screenCx, screenCy)`
  radius `screenSize`. Drawn via ImGui foreground draw list.
- **Lasso**: closed polyline of the lasso poly + an offset polyline
  at `softBorderPx` for the soft-border preview.

Handle drag math reuses `axisDragDelta` / `screenAxisDelta` from
`drag.d`; lasso point editing is screen-space-direct.

### HTTP / argstring commands

```text
tool.pipe.attr falloff type      <none|linear|radial|screen|lasso>
tool.pipe.attr falloff shape     <linear|easeIn|easeOut|smooth|custom>
tool.pipe.attr falloff in        <float>
tool.pipe.attr falloff out       <float>
tool.pipe.attr falloff start     <x,y,z>
tool.pipe.attr falloff end       <x,y,z>
tool.pipe.attr falloff center    <x,y,z>
tool.pipe.attr falloff size      <x,y,z>
tool.pipe.attr falloff screenCx  <px>
tool.pipe.attr falloff screenCy  <px>
tool.pipe.attr falloff screenSize<px>
tool.pipe.attr falloff lassoStyle<freehand|rect|circle|ellipse>
tool.pipe.attr falloff lassoPoly <"x1,y1;x2,y2;..."> # freehand only
tool.pipe.attr falloff softBorder<px>
```

Plus convenience commands matching MODO's `tool.set falloff.linear on`:

```text
falloff.set <type>     # type == none disables; matches MODO menu
falloff.toggle         # toggle on/off keeping last type
```

`/api/falloff` (mirroring `/api/snap`) — POST a world point + screen
pixel + viewport, get back the weight for the current falloff
config. Useful for headless tests that probe weight at arbitrary
coordinates without wiring up a full Move drag.

### Status-bar pulldown (`config/statusline.yaml`)

Add a **Falloff** button between SNAP and Work Plane:

- Click: cycle through types (matches MODO's keyboard cycling
  in `inmapdefault.cfg`'s `cmd tool.set falloff.next on`).
- Alt-click: open the Options popup with type selection + shape
  preset.
- Button face shows current type's name (`dynamicLabel: true`).
- Button is "pressed" when type != none (new `checked: notEquals "none"`).

---

## Subphases

Each subphase = one commit. Build + test gate at every step.

### 7.5a — FalloffStage skeleton + None type (~150 LOC)

- `source/toolpipe/stages/falloff.d` with the stage class and
  `FalloffPacket` published (`type=None`, `enabled=false`).
- Stage registered alongside WORK / ACEN / SNAP in `initToolPipe()`.
- `tool.pipe.attr falloff type none` round-trips through `setAttr`
  / `listAttrs`.
- `evaluateFalloff` returns 1.0 always (no types implemented yet).
- Tools' `consumesFalloff` virtual added; existing tools are
  unaffected (`Tool.consumesFalloff` defaults to `false`, transform
  tools ignore the call until 7.5b lands the per-vert weighting).
- Unit test: `tests/test_toolpipe_falloff.d` — stage registered,
  default packet has `enabled=false`.

### 7.5b — Linear type + Move integration (~220 LOC)

- `evaluateFalloff` linear branch.
- `applyShape` helper covering all 5 presets.
- `setAttr` parses `start` / `end` / `shape` / `in_` / `out_`.
- Auto-size on `setAttr("type", "linear")`: anchor `start` to
  selection bbox min along Y, `end` to bbox max along Y. (MODO
  picks an axis based on workplane normal — copy that.)
- MoveTool wires `applyDeltaImmediate` to multiply by
  `evaluateFalloff(...)` when `state.falloff.enabled`.
- MoveTool.wholeMeshDrag path falls back to per-vertex CPU when
  falloff is enabled (gpuMatrix bypass stays only for falloff-off).
- Unit tests: linear weight at start = 1.0, at end = 0.0, midpoint
  per shape preset.

### 7.5c — Radial type + Rotate / Scale integration (~190 LOC)

- `evaluateFalloff` radial branch (ellipsoid math).
- `setAttr` parses `center` / `size`.
- Auto-size on `setAttr("type", "radial")`: `center =
  selectionBBoxCenter`, `size = halfExtents`.
- Rotate / Scale tools weighted per-vertex (`angle * weight`,
  `1 + (factor-1) * weight`).
- Whole-mesh GPU bypass paths for Rotate / Scale also force
  per-vertex CPU when falloff is enabled.
- Unit tests: radial weight = 1.0 at center, 0.0 at size boundary,
  shape-preset midpoint.

### 7.5d — Screen type (~140 LOC)

- `evaluateFalloff` screen branch (project pos to window, distance
  in pixels, attenuate by `screenSize`).
- `setAttr` parses `screenCx` / `screenCy` / `screenSize` /
  `transparent`.
- Auto-size on `setAttr("type", "screen")`: project selection bbox
  centroid, place `(screenCx, screenCy)` there; `screenSize` =
  bbox screen radius (pixels).
- Move / Rotate / Scale already use the weight function —
  zero per-tool changes.
- Unit tests: screen weight at exact pixel center = 1.0, at border
  = 0.0; verts behind camera get weight = 0 when transparent=false.

### 7.5e — Lasso type + lasso input mode (~200 LOC)

- `evaluateFalloff` lasso branch using `pointInPolygon2D` +
  point-to-polyline screen distance.
- `setAttr lassoPoly "x1,y1;x2,y2;..."` for freehand polygon
  encoding (MODO uses a similar `,`/`;` delimited form for arrays).
- `setAttr lassoStyle <rect|circle|ellipse>` plus 4-corner shorthand
  for shaped lassos.
- Lasso input mode: when `type == lasso` AND no polygon defined yet,
  the next LMB-drag in the viewport draws the lasso. This mode lives
  in a new `LassoFalloffInputHandler` activated when the falloff
  type is set to lasso and the polygon is empty.
- The `falloff.set lasso` command fires the input mode; user draws
  the polygon, releases, the polygon lands in `state.falloff.lassoPolyX/Y`.
- Unit tests: lasso weight inside / outside / soft-border zone.

### 7.5f — Status-bar pulldown + property form (~140 LOC)

- `config/statusline.yaml`: new "Falloff" button with type-selection
  popup and the same `dynamicLabel` + `checked.notEquals "none"`
  pattern as Action Center. Uses the buttonset machinery already in
  place.
- `falloff.set <type>` and `falloff.toggle` argstring commands.
- Property panel section for the active falloff (re-uses `Param[]`
  the same way primitive tools expose their attrs — minimal new UI
  code).

### 7.5g — Viewport gizmos (~100 LOC)

- `source/falloff_render.d`: `drawFalloffOverlay(packet, vp)` that
  draws the type-specific overlay (linear line + endpoint handles,
  radial ellipsoid, screen disc, lasso polyline).
- Each transform tool's `draw()` calls `drawFalloffOverlay` after
  its own gizmo draw — same convention as `drawSnapOverlay`.
- Drag handles for endpoints / center / size / screen radius / lasso
  vertices: uses existing `BoxHandler` + `axisDragDelta`. On handle
  release, the new value is pushed through `falloff.setAttr` so HTTP
  / scripts see the same state.

---

## Decisions (resolved)

1. **Single active falloff vs Add-mode mixing.**
   *Decision:* single. Mix mode (MODO's "Add") is rare in modeling
   workflows and adds nontrivial multi-falloff plumbing. If a user
   wants both, they apply one drag, then change falloff type for the
   next.

2. **Whole-mesh GPU bypass with falloff active.**
   *Decision:* fall through to the per-vertex CPU path. Per-vert
   transforms can't be expressed as a single uniform; rendering the
   mid-drag preview correctly requires the CPU mutation + deferred
   upload that the partial-selection path already handles.

3. **`consumesFalloff` opt-in vs default-on.**
   *Decision:* opt-in. Move / Rotate / Scale opt in via the
   `TransformTool` base override (`true`). BevelTool, primitive
   create-tools, PenTool keep `false`. Per the open question in
   `phase7_plan.md`: a radial falloff applied to "Create Box" doesn't
   correspond to anything meaningful — primitive geometry isn't
   per-vertex.

4. **Auto-size axis for Linear.**
   *Decision:* workplane normal. Y for the auto workplane, axis1 for
   workplane-locked. Matches the MODO convention where the line
   "stands up" out of the construction plane.

5. **Screen-space center coordinate origin.**
   *Decision:* window-space pixels (top-left = 0,0; matches existing
   `Viewport.x/.y/.width/.height` semantics from `math.d`). Easier
   to write tests against than NDC.

6. **Lasso polygon storage.**
   *Decision:* two `float[]` arrays for X / Y, kept in lockstep.
   `Vec2` would read better but isn't worth adding to `math.d` for
   one consumer.

7. **`/api/falloff` test endpoint.**
   *Decision:* yes — analogous to `/api/snap`. Lets the unit suite
   probe weights at arbitrary world / screen positions without
   driving a full Move drag through `/api/play-events`.

---

## Open questions

1. **Soft Border for Linear / Radial.** MODO's panel doesn't
   surface a separate soft-border for these types — the
   attenuation IS the falloff. Lasso has it because the polygon
   is binary inside/outside. Keep linear/radial soft-border-less
   and use the shape preset for tuning?

2. **Falloff persistence across tool switches.** When the user
   activates Move with linear falloff, then switches to Rotate,
   should the falloff state carry over? MODO's behaviour: yes —
   the falloff is a global state attached to the Tool Pipe, not
   per-tool. Vibe3d's `FalloffStage` lives globally, so this falls
   out for free; just confirm in tests.

3. **Lasso polygon serialisation.** The `"x1,y1;x2,y2;..."` form is
   ad-hoc. argstring's grammar doesn't natively handle nested
   structures, but it does pass quoted strings through unmodified.
   Keep the `;`-delimited form for now; consider a proper JSON-like
   nested form when adding more multi-value attrs in future stages.

4. **Falloff with ACEN.Local clusters.** When a Local-mode pivot
   produces multiple disjoint clusters, should each cluster get its
   own falloff anchor (per-cluster center) or share the global
   falloff? Defer: ship single-cluster falloff in 7.5; per-cluster
   is a follow-up if user needs it.

5. **Symmetry interaction.** Phase 7.6 (SYMM) hasn't landed yet, so
   no decision needed during 7.5. Note: the symmetric mirror copy
   of a vert should evaluate the falloff at the mirrored position,
   not the original — naturally falls out of `evaluateFalloff(pos)`
   if SYMM iterates over mirror copies before transforming.

---

## Sizes

| Subphase | LOC | Cumulative |
|----------|-----|------------|
| 7.5a Skeleton + None              | 150 | 150  |
| 7.5b Linear + Move                | 220 | 370  |
| 7.5c Radial + Rotate / Scale      | 190 | 560  |
| 7.5d Screen                       | 140 | 700  |
| 7.5e Lasso + input mode           | 200 | 900  |
| 7.5f Status-bar + property form   | 140 | 1040 |
| 7.5g Viewport gizmos              | 100 | 1140 |

Plan totals ~1140 LOC vs. `phase7_plan.md`'s ~550 LOC budget. The
overrun is mostly in lasso (~200 LOC for input mode + polygon
math) and viewport gizmos (~100 LOC). The original budget assumed
no input mode and no gizmos — both end up necessary for a usable
feature.

---

## Migration safety

- Default `falloff.type = None` and `enabled = false`. All transform
  tools see `weight == 1.0` and behave exactly as today.
- `consumesFalloff()` defaults to `false`; non-transform tools (Box
  / Sphere / etc.) take zero changes.
- `FalloffStage` registered always (matches WORK / ACEN / SNAP).
  Tools query the packet and short-circuit when `!enabled` —
  zero overhead on the off path.
- New `source/falloff.d` and `source/falloff_render.d` modules;
  existing tools opt-in by adding the `evaluateFalloff` call.
- modo_diff / blender_diff suites don't exercise falloff — expected
  to stay green at every commit.
- The whole-mesh GPU bypass change in 7.5b/7.5c is gated on
  `state.falloff.enabled` so the gpuMatrix fast path is preserved
  for the common falloff-off case.

---

## Where this lands relative to phase7_plan.md

`doc/phase7_plan.md` lists 7.5 as "Falloff (Weight)" at ~550 LOC.
This expanded plan adds:

- Lasso input mode (was lumped under "lasso falloff").
- Viewport gizmos for non-screen falloff types (was implicit in
  "tool.set falloff.linear on" UX).
- `/api/falloff` test endpoint (was "unit test: …" with no headless
  probe channel).
- Per-shape custom Bézier shape (was "shape preset" without
  enumeration).
- Auto-size behaviour on type switch (was "scales the falloff to
  the bounding box of the active selection" in MODO docs but not
  called out as a code path).

Total grew from ~550 LOC → ~1140 LOC (7 commits). The original
phase7_plan stays the source-of-truth for the overall phase 7
roadmap; this doc is the detailed breakdown for 7.5.
