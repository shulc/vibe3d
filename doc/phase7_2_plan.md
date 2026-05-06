# Phase 7.2 Plan — Action Center + Action Axis

Subphase 7.2 of the Tool Pipe migration (see `phase7_plan.md` §7.2).
Replaces hard-coded `selectionCentroid*` + world-XYZ basis logic in
Move / Rotate / Scale with two pluggable Tool Pipe stages: **ACEN**
(Action Center, ordinal `0x60`) and **AXIS** (Action Axis, ordinal
`0x70`). Side effect: enables Element Move and integrates the
WorkplaneStage as a natural Axis source.

## MODO source-of-truth (verified locally)

### SDK packet shapes (`lxtool.h`)

```c
typedef struct st_LXpToolActionCenter {
    LXtVector v;          // origin point (3 floats)
} LXpToolActionCenter;

typedef struct st_LXpToolAxis {
    LXtVector axis, up, right;  // forward / up / right
    LXtMatrix m, mInv;          // 3×3 basis + inverse
    int axIndex;                // 0/1/2 = world principal axis hint, -1 = arbitrary
    int type;                   // see mode enums below
} LXpToolAxis;
```

Plus separate **element-callback packets** (`LXsP_TOOL_ELTCENTER`,
`LXsP_TOOL_ELTAXIS`) — interface objects that yield per-element data
on demand.

### Stage ordinals (canonical)

- `LXs_ORD_ACEN = "\x60"` — center stage
- `LXs_ORD_AXIS = "\x70"` — axis stage (after ACEN)

### Canonical user commands (`cmdhelptools.cfg`)

**Combined preset** (`tool.set actr.<mode>`) — sets center+axis
atomically:

| `actr.<mode>` | UserName | What it does |
|---|---|---|
| `actr.auto` | Automatic Action Center | center=avg-of-selection (or all geometry if no selection), axis=World/Workplane. Click-outside-gizmo moves center to hit point. **Not fixed.** |
| `actr.select` | Selection | center=selection-centroid, axis=selection-aligned |
| `actr.selectauto` | Selection Center Auto Axis | center=selection-centroid, axis=major world XYZ (axis-picker in Tool Properties) |
| `actr.element` | Element | per-element pivot (click on poly → that poly's normal; on edge → edge-tangent; on vert → vert-normal) |
| `actr.local` | Local | per-element-cluster — each connected selection group gets its own center+axis |
| `actr.origin` | Origin | center=(0,0,0), axis=world |
| `actr.screen` | Screen | center+axis = picture-plane (camera frame) |
| `actr.border` | Selection Border | center=border-edges-centroid, axis=avg-normal of selected. For arm-bend rotations etc. |
| `actr.pivot` | Pivot | item-level (out of scope for vibe3d — no item hierarchy) |
| `actr.parent` | Parent | item-level (out of scope) |

**Granular**: `tool.set center.<mode>` / `tool.set axis.<mode>` — for
mix-and-match (e.g. ACEN=Selection, AXIS=Workplane).

**Sub-mode for `center.select`** (`acen_select_mode` enum):
`center / top / bottom / back / front / left / right` — which side
of the bounding box serves as the center. Useful for "pin to top of
selection" style operations.

## Vibe3d adaptation (out-of-scope MODO modes elided)

We scope to: **auto, select, selectauto, element, local, origin,
screen, border**. Pivot / Parent have no analogue without an item
hierarchy.

## Architecture

### Packets (`toolpipe/packets.d`, extended)

```d
struct ActionCenterPacket {
    Vec3 center = Vec3(0, 0, 0);
    bool isAuto = true;
    int  type;                  // ACEN_*  (mirrors LXpToolAxis.type semantics)
}

struct AxisPacket {
    Vec3 right = Vec3(1, 0, 0);
    Vec3 up    = Vec3(0, 1, 0);
    Vec3 fwd   = Vec3(0, 0, 1);
    int  axIndex = -1;          // 0/1/2 = world-X/Y/Z hint, -1 = arbitrary
    int  type;                  // AXIS_*
    bool isAuto = true;
}

// New: per-element callback packets (filled by ACEN=element / AXIS=element)
alias ElementCenterFn = Vec3 delegate(uint elementIdx);
alias ElementAxisFn   = AxisBasis delegate(uint elementIdx);
struct AxisBasis { Vec3 right, up, fwd; }

struct ElementCenterPacket { ElementCenterFn fn; }
struct ElementAxisPacket   { ElementAxisFn   fn; }
```

`type` fields are int enums matching MODO `actr.<mode>` so
`tool.set actr.element on` ↔ `state.actionCenter.type == ACEN_Element`.

### Stages

```d
class ActionCenterStage : Stage {
    enum Mode { Auto, Select, SelectAuto, Element, Local, Origin, Screen, Border, Manual }
    Mode mode = Mode.Auto;
    Vec3 manualCenter;          // active when mode == Manual (= "click outside gizmo")
    int  selectSubMode;         // for Mode.Select: 0=center, 1=top, ..., 6=right (bbox side)

    override void evaluate(ref ToolState state) { ... }
}

class AxisStage : Stage {
    enum Mode { Auto, Select, SelectAuto, Element, Local, Origin, Screen, Workplane, Manual }
    Mode mode = Mode.Auto;
    Vec3 manualRight, manualUp, manualFwd;
    int  axIndex = -1;

    override void evaluate(ref ToolState state) { ... }
}
```

### Canonical commands (HTTP / argstring)

**Granular** (mix-and-match):
- `tool.set center.<mode> on` — sets ACEN
- `tool.set axis.<mode> on` — sets AXIS
- `tool.attr center.select mode top` — sub-mode for Selection (bbox top)
- `tool.attr center.auto cenX:1 cenY:0 cenZ:0` — manual center in auto mode

**Combined preset** (= one of `actr.*`):
- `tool.set actr.<mode> on` — atomically changes both center and axis
  to a paired pair

In vibe3d we map to `tool.pipe.attr`:
- `tool.pipe.attr actionCenter mode <select|auto|element|...>`
- `tool.pipe.attr actionCenter cenX:.. cenY:.. cenZ:..`
- `tool.pipe.attr actionCenter selectSubMode <center|top|bottom|...>`
- `tool.pipe.attr axis mode <auto|world|workplane|element|...>`
- + alias-command `tool.set actr.<mode>` → internally expands to the
  pair of attr-calls.

## Subphases

Each subphase = one commit. Build + test gate at every step.

### 7.2a — ActionCenterStage skeleton + select mode (~150 LOC)

**What:**
- `toolpipe/stages/actcenter.d` — stage at `ordAcen=0x60`, default
  mode=Auto.
- Auto = avg of all geometry if no selection else selection centroid
  (matches MODO "handles at center of geometry/selection").
- Select = strict selection centroid (no fallback) + sub-mode
  (center/top/bot/back/front/left/right).
- Move/Rotate/Scale.update() reads `state.actionCenter.center`
  instead of `selectionCentroid*()`.
- HTTP: `tool.pipe.attr actionCenter mode auto|select`.
- popup_state: `actionCenter/mode`.

**Test:** `test_toolpipe_acen_modes.d` — empty selection: auto =
geom-bbox-center; with selection: select = centroid; mode=top →
bbox.maxY.

### 7.2b — Origin / Screen / Manual modes (~120 LOC)

**What:**
- Origin = world (0,0,0).
- Screen = ray from camera centre intersected with workplane (matches
  MODO "picture plane").
- Manual = sticky `manualCenter` (replaces existing `centerManual`
  flag in MoveTool / RotateTool / ScaleTool).
- Click-outside-gizmo triggers `tool.pipe.attr actionCenter mode
  manual cenX:.. cenY:.. cenZ:..`.

**Test:** unit-asserts of the evaluation function (no UI), integration
test for the "click outside" path.

### 7.2c — AxisStage skeleton + world / workplane modes (~120 LOC)

**What:**
- `toolpipe/stages/axis.d` at `ordAxis=0x70`.
- World mode: returns identity (right=X, up=Y, fwd=Z, axIndex=-1).
- Workplane mode: reads upstream `state.workplane.{axis1, normal,
  axis2}` (uses WorkplaneStage as data source). axIndex=-1 (arbitrary
  basis, not principal).
- Auto = same as Workplane if not isAuto else World (MODO docs:
  "axis aligned to World OR Work Plane").
- Migrate `TransformTool.currentBasis()` → reads `state.axis`. Drop
  the helper.
- Migrate Move's most-facing-pick (for outside-click teleport) → reads
  `state.axis` (we no longer depend on basis).

**Test:** AXIS=workplane + WorkplaneStage.alignToSelection →
axisStage.right == frame.axis1 etc.

### 7.2d — Element variants (~180 LOC)

**What:**
- ACEN=Element and AXIS=Element produce `ElementCenterPacket` and
  `ElementAxisPacket` (callbacks per element, not eager arrays).
- Per-element rules (matching MODO):
  - polygon → centroid + normal-aligned basis
  - edge → midpoint + edge-tangent-aligned basis
  - vertex → coord + vertex-normal-aligned basis
- Tools consuming Element: loop over selectedElements, for each call
  the callback and apply per-element pivot/axis. For Move this is
  equivalent to "move each element independently".
- HTTP: `tool.pipe.attr actionCenter mode element` / `axis mode
  element`.

**Test:** `test_element_actr.d` — select 3 detached vertices,
ACEN=Element + AXIS=Element + Move — each vertex offsets via its own
gizmo. Result: vertex_i_after = vertex_i_before + delta_i.

### 7.2e — Local mode + Selection Border (~150 LOC)

**Local:** enumerates connected-components inside the selection (BFS
over edges of selected verts/faces) — for each it produces its own
center+axis. Same as ACEN=Element but per-cluster, not per-element.

**Border:** border-edges-of-selection (open edges where the selection
stops). Centroid of those edges = pivot. Axis = avg-normal of
selected faces. Useful for "bend arm" style rotations.

Lower priority — can be deferred to 7.2f.

**Test:** `test_actr_local.d` — select 2 disjoint quad-loops, ACEN=
Local → 2 pivots, one per loop.

### 7.2f — `actr.<mode>` combined-preset commands (~80 LOC)

**What:**
- Alias commands: `actr.auto`, `actr.select`, `actr.selectauto`,
  `actr.element`, `actr.local`, `actr.origin`, `actr.screen`,
  `actr.border`.
- Each = "macro" for `tool.pipe.attr actionCenter mode X` +
  `tool.pipe.attr axis mode Y` (exact pairs — see the table above).
- Registered in `commandFactories` (like other commands).

**Test:** `test_actr_aliases.d` — run `actr.element` → assert both
actionCenter.mode and axis.mode = element.

### 7.2g — Status-bar UI (~100 LOC)

**Popup buttons:**
- "Action Center" with items Auto/Selection/Selection Center Auto
  Axis/Element/Local/Origin/Screen/Border + checked-paths
  `actionCenter/mode`.
- "Action Axis" — parallel, mode=auto/world/workplane/element/local/
  origin/screen + `axis/mode`.
- Glow when non-default (≠ Auto).
- In `config/statusline.yaml` add after the workplane group.

**Element Move tool:** alias-tool in the registry: `move.element` =
MoveTool with pre-set ACEN=Element + AXIS=Element. Button in the side
panel.

### 7.2h — modo_diff harness: ACEN / AXIS query cross-check (~80 LOC)

**Goal:** verify vibe3d's ACEN / AXIS scalar values match MODO bit-
for-bit for static modes (Origin / Select+sub / SelectAuto / Manual /
Border / Local-single-cluster). Per-element / multi-cluster modes are
deferred — they require the `xfrm.* + actr.*` tool pipeline which has
been flaky headlessly (see `modo_dump.py:322` — current `run_rotate`
bypasses MODO's transform composition entirely for that reason).

**Two test levels covered:**

1. **Query static value** — activate the ACEN tool, read its cen/axis
   attrs, compare against vibe3d's `state.actionCenter` / `state.axis`
   scalars.
2. **ACEN + manual transform** — query ACEN value (level 1), apply
   rotation / scale around it via direct matrix math in Python (same
   approach as `run_rotate`); vibe3d does the same via MeshTransform.
   Compare resulting mesh vertices bit-for-bit.

Per-element (level 3) deferred — vibe3d unit-tests cover that side
without MODO cross-check.

**Schema extension** (`tools/modo_diff/cases/*.json`):

```json
{ "op": "query_acen", "mode": "select", "expect_field": "cen",
  "tolerance": 1e-4 }
{ "op": "query_axis", "mode": "select",
  "expect_fields": ["right", "up", "fwd"], "tolerance": 1e-4 }
```

The orchestrator runs both engines, dumps the named fields, compares
scalar-by-scalar with `tolerance`. Field shapes match the
`ActionCenterPacket` / `AxisPacket` layout (Vec3 each).

**`modo_dump.py` additions:**

```python
def run_query_acen(op):
    """Activate `center.<mode>` tool, dump cen{X,Y,Z}.
    Returns {"cenX": float, "cenY": float, "cenZ": float}.
    Selection-based modes require selection state set up by an
    earlier `select_face` / `select_edge` op in the same case."""
    mode = op["mode"]   # "select" / "origin" / "screen" / "border" / "local" / ...
    lx.eval("tool.set center.%s on 0" % mode)
    return {
        "cenX": float(lx.eval("query toolservice attrvalue ? center.%s cenX" % mode)),
        "cenY": float(lx.eval("query toolservice attrvalue ? center.%s cenY" % mode)),
        "cenZ": float(lx.eval("query toolservice attrvalue ? center.%s cenZ" % mode)),
    }

def run_query_axis(op):
    """Activate `axis.<mode>` tool, dump axisX/Y/Z + upX/Y/Z (basis)."""
    mode = op["mode"]
    lx.eval("tool.set axis.%s on 0" % mode)
    return {
        "axisX": float(lx.eval("query toolservice attrvalue ? axis.%s axisX" % mode)),
        # ... axisY, axisZ, upX, upY, upZ, rightX, rightY, rightZ
    }
```

**`vibe3d_dump.d` additions:**

```d
void runQueryAcen(JSONValue op) {
    string mode = op["mode"].str;
    httpPost("/api/command", "tool.pipe.attr actionCenter mode " ~ mode);
    auto state = httpGet("/api/toolpipe").parseJSON;
    auto ac = findStage(state, "actionCenter");
    writeOpResult({
        "cenX": ac["attrs"]["cenX"].str.to!float,
        "cenY": ac["attrs"]["cenY"].str.to!float,
        "cenZ": ac["attrs"]["cenZ"].str.to!float,
    });
}
// runQueryAxis analogous against axis stage
```

**Orchestrator (`run.d`):** extend the per-op result handler to recognise
the `query_*` ops and compare scalar dicts instead of vertex arrays.

**New `cases/`:**
- `acen_origin.json` — empty selection, ACEN=origin, expect (0,0,0).
- `acen_select_centroid.json` — cube + face selection, ACEN=select,
  expect bbox-of-selection centroid.
- `acen_select_top.json` — same selection, sub-mode=top, expect
  bbox.maxY mid-plane.
- `acen_screen_camera_default.json` — verify Screen mode resolves
  consistently with vibe3d's pickMostFacingPlane fallback.
- `axis_workplane_aligned.json` — alignToSelection (existing case
  setup), AXIS=workplane, expect basis from MODO's workplane attrs.
- One end-to-end (level 2): `rotate_around_acen_select.json` — rotate
  cube around ACEN=Select pivot, compare vertices.

**Test harness changes (`tools/modo_diff/run.d`):**
- Recognise `query_acen` / `query_axis` ops in case JSON.
- Read both engines' scalar dumps.
- Compare via existing tolerance-based diff (already used for vertex
  positions).

**Risk:** modo_cl's `query toolservice attrvalue ?` syntax may differ
across MODO versions. If `tool.attr` query fails, fall back to
running a transform tool with that ACEN active and reading the
mesh — slower but more robust.

## Resolved decisions

The 6 open questions raised during plan review have been answered.
Captured here as the design contract for 7.2 implementation; revisit
only if a subphase hits a concrete blocker.

1. **selectSubMode bbox-sides frame** → **world XYZ.** Options
   `top/bottom/back/front/left/right` are inherently world-oriented
   (top = "scene top"). active-axis would surprise users with
   tilted workplanes / per-element axes.

2. **`actr.auto` click-outside semantics** → **Auto mode keeps a
   nullable `userPlacedCenter`.**
   - null → center = selection-centroid, recompute on selection
     change (= `centerManual = false` today).
   - non-null → center = `userPlacedCenter`, sticky (= `centerManual
     = true` today, but staying in Auto mode).
   - Click-outside-gizmo writes `userPlacedCenter = hit`. Mode stays
     Auto.
   - Re-selecting "Auto" in popup resets `userPlacedCenter = null`.
   - Manual mode stays as a separate explicit "pin forever"
     selection — switching to it copies `userPlacedCenter` over.

3. **AxIndex hint** → **stub at -1 in 7.2; populate when a consumer
   appears.** No axis-constrained drag in 7.2 scope. Field stays in
   the packet for SDK-parity and forward-compat.

4. **Element Move scope** → **alias-factory in `app.d` registry.**
   ```d
   reg.toolFactories["move.element"] = () {
       auto t = new MoveTool(...);
       t.setUndoBindings(history, vertexEditFactory);
       // Side-effect: switch ACEN+AXIS to element on activation.
       if (reg.commandFactories["actr.element"] !is null)
           runCommand(reg.commandFactories["actr.element"]());
       return cast(Tool)t;
   };
   ```
   No new tool class — MoveTool reads `state.actionCenter` per
   frame; element mode auto-produces per-element pivots. Side panel
   button comes for free. ACEN stays sticky on tool deactivate
   (matches MODO's behaviour).

5. **`tool.eltCenter` / `tool.eltAxis`** → **D delegate, not
   interface.**
   ```d
   alias ElementCenterFn = Vec3 delegate(uint elementIdx);
   struct ElementCenterPacket { ElementCenterFn fn; }
   ```
   SDK uses interface objects because of C++/COM constraints we
   don't share. Delegate captures `mesh*` + selection arrays via
   closure, faster (no vtable), trivial to mock in tests.

6. **`up` mapping for AXIS=Workplane** → **right=axis1, up=normal,
   fwd=axis2.** Already established in migrated
   `TransformTool.currentBasis()` (handler.axisX = workplane.axis1,
   axisY = normal, axisZ = axis2). Y-up convention ⇒ workplane
   normal naturally maps to `up`. **Verify in 7.2h** via modo_cl —
   set `tool.set axis.workplane on`, dump `axis/up/right` and
   compare. If MODO disagrees, swap is one-line in AxisStage.

## Sizes

| Subphase | LOC | Test |
|---|---|---|
| 7.2a ACEN auto+select+sub-mode | ~150 | unit |
| 7.2b ACEN origin/screen/manual | ~120 | unit |
| 7.2c AXIS world+workplane | ~120 | integration |
| 7.2d Element variants + Element Move | ~180 | integration |
| 7.2e Local + Border | ~150 | unit + integration |
| 7.2f `actr.*` combined-preset commands | ~80 | unit |
| 7.2g Status-bar UI + popup | ~100 | manual |
| 7.2h modo_diff harness for ACEN / AXIS query | ~80 | modo_diff |
| **Total 7.2** | **~980 LOC** | |

## Migration safety

Each subphase MUST keep `run_test.d --no-build` and `rdmd
tools/modo_diff/run.d --no-build` green at their pre-7.2 baselines
(44 unit / 75 modo_diff PASS / 3 XFAIL).

New tests added per subphase exercise the new stage's behaviour
without changing existing tool semantics. Defaults (ACEN=Auto, AXIS=
Auto) reproduce current Move/Rotate/Scale behaviour exactly.

## Where this lands relative to phase7_plan.md

`doc/phase7_plan.md` lists 7.2 as "Action Center + Axis + Element
variants" at ~500 LOC. This expanded plan adds:
- bbox sub-mode (top/bottom/...) for select
- Selection Border as a full mode
- combined-preset `actr.*` commands
- AxIndex hint mechanic
- per-element rules for vertex / edge / face
- explicit packets for ElementCenter / ElementAxis (callback shape)

Total grew from ~500 LOC → ~980 LOC (covered by ~8 commits instead
of 1). The original plan stays the source-of-truth for the overall
phase 7 roadmap; this doc is the detailed breakdown for 7.2.
