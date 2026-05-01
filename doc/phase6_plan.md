# Phase 6 Plan — Interactive primitives + modo_diff parity

## Goal

Implement interactive Create-tools, with each primitive's wire format aligned to MODO 9's `prim.*` tool attribute schema. modo_diff cases assert tolerance-bounded parity for every primitive whose `prim.*` tool is loadable in modo_cl headless.

After phase 6:

- Eight primitives in the Create panel: Box, Sphere (Globe / QuadBall / Tesselation modes), Cone, Cylinder, Capsule, Torus, Pen, plus internal Vertex utility.
- Headless `prim.*` command path for all except Pen.
- modo_diff parity for six (Box, Sphere×3, Cylinder, Cone, Capsule).
- Wire format follows MODO `cmdhelptools.cfg` exactly — same attribute keys, same enum option keys.
- modo_dump.py and vibe3d_dump.d gain a `setup` block in case JSON.

## Source of truth: MODO `cmdhelptools.cfg`

Every MODO tool's complete attribute list is in `Modo902/resrc/cmdhelptools.cfg` indexed by `<hash type="Tool" key="prim.NAME@en_US">`. Wire keys are the inner `<hash type="Attribute" key="...">` values; enum option keys are nested `<hash type="Option" key="...">` inside `<hash type="ArgumentType" key="prim-...">`.

Used to extract canonical attribute lists below — eliminates guesswork.

## Findings (from MODO 9 docs, cmdhelptools.cfg, modo_cl probing)

### Loadable in modo_cl (full modo_diff parity possible)

- `prim.cube`, `prim.sphere`, `prim.cylinder`, `prim.cone`, `prim.capsule` — checked.
- `prim.ellipsoid`, `prim.teapot`, `prim.text` — checked, but out of phase-6 scope (exotic / low-value).

### NOT loadable in modo_cl (plugin tools)

- `prim.torus` — no entry in `cmdhelptools.cfg`, plugin-loaded. modo_diff impossible without full GUI MODO.
- `pen`, `bezier`, `curve`, `sketch`, `drawing`, `arc`, `make_polygon` — same.

### Reframed primitives

**Tube is path-based, not hollow cylinder.** `prim.tube` attributes (`mode`, `ptX/Y/Z`, `scale`, `repeat`, `current`, `number`, `length`, `twist`) describe a tube extruded along a polyline path — like a Sweep tool. **Drop from phase 6.** Hollow cylinder, if needed, comes later under a vibe3d-specific id.

**Ellipsoid is an exotic primitive, not a sphere variant.** `prim.ellipsoid` has `bulgeTop`, `bulgeSide`, `hole` — distinct semantics. **Drop from phase 6** — implement later if user-driven need surfaces.

**Sphere QuadBall is a MODO mode**, not a vibe3d extension. `prim.sphere method:qball`. Folded into Sphere subphases.

## Canonical attribute schemas

### `prim.cube` (Box)

| Wire key | UserName | Type | Notes |
|---|---|---|---|
| `cenX/Y/Z` | Position X/Y/Z | float | center |
| `sizeX/Y/Z` | Size X/Y/Z | float | dimensions, default 1m |
| `segmentsX/Y/Z` | Segments X/Y/Z | int | subdivisions, default 1 |
| `radius` | Radius | float | rounded edge amount; 0=sharp |
| `segmentsR` | Radius Segments | int | corner subdivision count |
| `sharp` | Sharp | bool | preserve flat faces under smoothing |
| `axis` | Axis | enum X/Y/Z | for Cube: orients radius |
| `uvs` | Make UVs | bool | **out of scope** — vibe3d has no UV system |
| `patch` | Patch | bool | toggle subpatch creation directly |
| `minX/Y/Z`/`maxX/Y/Z` | Min/Max X/Y/Z | float | bbox alternative to center+size |
| `flip` | Flip Plane | bool | invert normal in plane mode (sizeY=0) |

### `prim.sphere`

| Wire key | UserName | Type / Options | Notes |
|---|---|---|---|
| `method` | Sphere Mode | enum: `globe`/`qball`/`tess` | UV-sphere / QuadBall / icosphere |
| `polType` | Polygon Type | enum: `face`/`subdiv`/`psubdiv` | regular / SDS / Catmull-Clark |
| `cenX/Y/Z` | Position X/Y/Z | float | |
| `sizeX/Y/Z` | Radius X/Y/Z | float | per-axis radius (handles ellipsoidal spheres) |
| `sides` | Sides | int | longitude segments (Globe), default 24 |
| `segments` | Segments | int | latitude rings (Globe), default 24 |
| `axis` | Axis | enum X/Y/Z | pole axis |
| `order` | Subdivision Level | int | for QuadBall and Tesselation modes |
| `uvs` | Make UVs | bool | out of scope |
| `minX/Y/Z`/`maxX/Y/Z` | Min/Max X/Y/Z | float | bbox alternative |
| `flip` | Flip Plane | bool | |

### `prim.cylinder`

| Wire key | UserName | Type | Notes |
|---|---|---|---|
| `cenX/Y/Z` | Position X/Y/Z | float | |
| `sizeX/Y/Z` | Radius X/Y/Z | float | bbox-style size; combined with axis defines radius+height |
| `sides` | Sides | int | circumference |
| `segments` | Segments | int | height subdivision |
| `axis` | Axis | enum X/Y/Z | cylinder's main axis |
| `uvs` | Make UVs | bool | OOS |
| `minX/Y/Z`/`maxX/Y/Z` | Min/Max X/Y/Z | float | |
| `flip` | Flip Plane | bool | |

**Important:** MODO Cylinder has no separate `radiusTop`/`radiusBottom` — both ends inherit from `sizeX/sizeZ` (radius in axes perpendicular to `axis`). **Frustum (truncated cone) is NOT a cylinder mode in MODO.** Vibe3d follows MODO — drop Frustum from plan.

**Disk** (height ≈ 0): set `sizeY = 0` (with `axis=Y`) → degenerate cylinder. Vibe3d-side detection in CylinderTool, no special MODO mode.

### `prim.cone`

Same shape as Cylinder. `sizeX/Y/Z` define base bbox, apex is geometric (at top of axis). **No `radiusTop`** parameter — apex always single vertex.

| Wire key | UserName | Notes |
|---|---|---|
| `cenX/Y/Z` | Position X/Y/Z | |
| `sizeX/Y/Z` | Size X/Y/Z | |
| `sides` | Sides | |
| `segments` | Segments | |
| `axis` | Axis | |
| `uvs`, `minX/Y/Z`, `maxX/Y/Z`, `flip` | (same family as Cylinder) | |

### `prim.capsule`

Cylinder + spherical end-caps.

| Wire key | UserName | Notes |
|---|---|---|
| `cenX/Y/Z`, `sizeX/Y/Z`, `sides`, `segments`, `axis` | (same as Cylinder) | |
| `endsegments` | End segments | spherical cap subdiv count |
| `endsize` | End Size | end cap radius (proportional?) |
| `polType` | Polygon Type | face/subdiv/psubdiv |
| `uvs`, `minX/Y/Z`, `maxX/Y/Z`, `flip` | | |

### `prim.torus` — NOT in modo_cl

Plugin tool. modo_diff impossible without full MODO GUI. Implement vibe3d's TorusTool with conventional parameters (`majorRadius`, `minorRadius`, `majorSegments`, `minorSegments`, `axis`); wire format kept reasonable for future compat.

### Common enum option keys

- **Axis** (in many tools): `x`, `y`, `z` (lowercase).
- **Polygon Type** (`prim-polygon-type` enum): `face` / `subdiv` / `psubdiv`.
- **Sphere Mode** (`prim-sphere-method` enum): `globe` / `qball` / `tess`.

These option keys are MODO's wire format and what we pass over `tool.attr`. Use them verbatim.

## Architectural decisions

### A. Tool ID naming aligns with MODO

```d
reg.toolFactories["prim.cube"]     = () => new BoxTool(...);
reg.toolFactories["prim.sphere"]   = () => new SphereTool(...);
reg.toolFactories["prim.cylinder"] = () => new CylinderTool(...);
reg.toolFactories["prim.cone"]     = () => new ConeTool(...);
reg.toolFactories["prim.capsule"]  = () => new CapsuleTool(...);
reg.toolFactories["prim.torus"]    = () => new TorusTool(...);
reg.toolFactories["pen"]           = () => new PenTool(...);
```

Each (except Pen) gets a parallel `commandFactories["prim.*"] = ToolHeadlessCommand("prim.*", ...)`.

### B. Headless apply via `applyHeadless()` (phase 4.2 contract)

Each PrimitiveTool overrides `bool applyHeadless()` to build geometry into a fresh Mesh using current `params_` and replace the scene mesh via `applyNewMesh` (extracted in 6.0). ToolHeadlessCommand wraps with snapshot pair.

Pen has no `applyHeadless` (interactive only).

### C. Schema using MODO wire keys

Each PrimitiveTool's `params()` returns Param entries using the canonical wire keys above. Enum-typed attributes use `Param.enum_` (string-backed) since MODO's option keys are strings.

Internal D enums (e.g. `enum SphereMethod { Globe, QuadBall, Tesselation }`) map to/from MODO option strings via the schema's wireTag.

### D. Tolerance vs bit-for-bit parity

- Vertex/edge/face counts: must match exactly.
- Vertex positions: tolerance `0.001`.
- Face winding: must match (else normals differ).
- Vertex ordering: closest-position pairing in `diff.py`.

### E. modo_diff schema extension — `setup` block

```json
{
  "setup": {
    "kind": "primitive",
    "tool": "prim.cube",
    "params": {"sizeX": 1.0, "sizeY": 1.0, "sizeZ": 1.0,
               "cenX": 0.0, "cenY": 0.0, "cenZ": 0.0}
  },
  "ops": [],
  "tolerance": 0.001
}
```

Both dumpers gain `setup` handlers. `vibe3d_dump.d` uses `POST /api/reset?empty=true` then argstring `prim.cube sizeX:1.0 ...`.

### F. `/api/reset?empty=true`

Adds query param to start with empty scene (current default keeps starter cube unchanged).

## Subphase breakdown

Each subphase: tool + ToolHeadlessCommand registration + modo_diff cases (where parity possible). Each lands as one commit; gates on build/tests/modo_diff.

### 6.0 — Common helpers + harness extension

- Extract `pickMostFacingPlane`, `screenToPlane`, `applyNewMesh` into `source/tools/create_common.d`.
- BoxTool refactored to use helpers (no behavior change).
- modo_diff: `setup` block in case schema; both dumpers handle it.
- `/api/reset?empty=true`.
- Smoke case `prim_cube_default.json` validates harness using existing BoxTool.

### 6.1 — Box (`prim.cube`) — modo_diff ✓

Full MODO attribute set:
- Phase 6.1a: core (Center/Size/Segments + Plane/Cube/Cuboid modes, 13 attrs).
- Phase 6.1b: rounded edges (`radius`, `segmentsR`, `sharp`, `axis` for radius orient) — **significant new feature**, basically built-in rounded-cube generator.
- Phase 6.1c: Min/Max bbox alternative spec.
- Phase 6.1d: `patch` (subpatch on creation).
- Phase 6.1e: `flip` for plane mode.

modo_diff cases:
- `prim_cube_default.json` — 1×1×1.
- `prim_cube_segmented.json` — segments=2/2/2.
- `prim_cube_cuboid.json` — non-uniform sizes.
- `prim_cube_plane.json` — sizeY=0.
- `prim_cube_rounded.json` — radius=0.05, segmentsR=4.
- `prim_cube_rounded_sharp.json` — same with sharp=true.
- `prim_cube_minmax.json` — `minX/Y/Z`+`maxX/Y/Z` spec.

Unit test `tests/test_primitive_box.d`.

### 6.2 — Sphere (`prim.sphere method:globe`) — modo_diff ✓

- `SphereTool`, drag = radius.
- `method:globe`. MODO defaults: `sides=24`, `segments=24`, radius from drag.
- modo_diff cases for default + small-segment count.
- Unit test.

### 6.3 — Sphere (`prim.sphere method:qball`) — modo_diff ✓

- QuadBall mode added to SphereTool.
- `method:qball`, `order` for subdivision level.
- modo_diff cases for various `order` values.
- Unit test.

### 6.4 — Sphere (`prim.sphere method:tess`) — modo_diff ✓

- Tesselation (icosphere) mode.
- `method:tess`, `order` for subdiv level.
- modo_diff cases for `order=0` (icosahedron 12v/30e/20f) and `order=1`.

### 6.5 — Cylinder (`prim.cylinder`) — modo_diff ✓

- `CylinderTool`, two-drag interactive (base + height).
- MODO size-based bbox spec — `sizeX/Y/Z` + `axis`.
- modo_diff cases:
  - `prim_cylinder_default.json` — sides=24.
  - `prim_cylinder_segmented.json` — sides=8.
  - `prim_cylinder_disk.json` — `sizeY=0` (with axis=Y) → disk.

### 6.6 — Cone (`prim.cone`) — modo_diff ✓

- Separate ConeTool. May share radial helpers with Cylinder.
- modo_diff cases for default + various sides.

### 6.7 — Capsule (`prim.capsule`) — modo_diff ✓

- CapsuleTool — cylinder + sphere caps.
- Includes `endsegments`, `endsize`, `polType`.
- modo_diff cases.

### 6.8 — Torus (`prim.torus`) — no modo_diff (plugin tool)

- TorusTool, two-drag.
- Unit test verifies counts (`majorSeg × minorSeg` quads) and topology (manifold, no degenerate tris).
- Wire format kept reasonable for future modo_cl compat.

### 6.9 — Pen — interactive-only

- Polygons mode only (per `pen.html`): click-add-vertex, double-click / Enter close, Backspace / Esc cancel.
- Other Pen modes (Lines, Vertices, SDS, Polyline, Wall Mode, Make Quads, Close, Merge) deferred.
- No headless apply, no modo_diff.
- Unit test via recorded event log.

## Open questions / risks

1. **`patch` attribute semantics.** MODO `prim.cube patch:true` likely emits faces tagged as subpatch. Vibe3d's mesh has `isSubpatch` flag. Verify mapping — should be a direct toggle.
2. **`order` semantics for QuadBall/Tesselation.** `order=0` for tesselation is likely icosahedron itself (12v/30e/20f). For QuadBall `order=0` might be a single cube (8v/12e/6f) or undefined. Verify in modo_cl during 6.3/6.4.
3. **`endsize` for Capsule.** Is it absolute (in meters) or proportional (fraction of cylinder length)? Verify before subphase 6.7.
4. **Ellipsoidal sphere defaults.** MODO `prim.sphere` accepts `sizeX/Y/Z` per axis. Default is uniform — confirm.
5. **Axis-driven height vs radius.** With `axis:Y` and `sizeX=0.5, sizeY=1.0, sizeZ=0.5`, cylinder is radius 0.5, height 2.0 (`sizeY*2`?) or height 1.0 (`sizeY` direct)? Verify experimentally.
6. **Snapshot for primitive replace.** Whole-mesh snapshot is heavy but correct for replace-style ops.
7. **Pen — Make-Polygon overlap.** MODO `make_polygon` is a separate command (CC.4 in roadmap). Pen with auto-close is a superset. Decide if Pen subsumes Make-Polygon or they coexist.

## Success metrics

- 7 primitive tools (8 with Pen) in Create panel; each works interactively.
- 6 tools have headless paths and modo_diff parity (Box, Sphere×3, Cylinder, Cone, Capsule).
- modo_diff suite grows from 15 to ~28 cases.
- All 36 existing unit tests + new primitive tests pass.
- `tests/primitive_check.d` invariants helper applied across primitive tests.

## Size

Phase 6 ≈ 2000-2500 LOC across 11 commits (most subphases self-contained). 6.0-6.1 are unblock; rest can be paused or parallelized.

Subphase rough breakdown:
- 6.0 helpers + harness — ~250 LOC
- 6.1 Box (5 features) — ~500 LOC + tests (largest, includes rounded-cube)
- 6.2 Sphere Globe — ~150 LOC + tests
- 6.3 Sphere QuadBall — ~120 LOC + tests
- 6.4 Sphere Tesselation — ~120 LOC + tests
- 6.5 Cylinder — ~200 LOC + tests
- 6.6 Cone — ~150 LOC + tests
- 6.7 Capsule — ~200 LOC + tests
- 6.8 Torus — ~150 LOC + unit tests
- 6.9 Pen — ~250 LOC + interactive test
