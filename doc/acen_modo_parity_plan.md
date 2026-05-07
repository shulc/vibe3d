# ACEN: pixel-perfect parity with MODO actr.* modes

## Goal

Bring vibe3d's `Mode.Auto` / `Mode.Select` / `Mode.Local` action-center
implementations into bit-for-bit agreement with MODO 9 `actr.auto` /
`actr.select` / `actr.local` so that `tools/modo_diff/run_acen_drag.sh`
passes on the `asymmetric` selection pattern in addition to the existing
`single_top` baseline.

Background: the drag-based cross-check (separate one-off harness, see
`tools/modo_diff/run_acen_drag.sh` and the memory note
`memory/vibe3d_acen_divergences.md`) found three concrete behavioural
differences. They are accepted simplifications today; this plan is the
roadmap if/when full parity is wanted (e.g. for Modo file
import/export round-trip, or to remove a long-standing footgun where
artists' muscle memory from MODO produces unexpected pivots in vibe3d).

## Status snapshot (2026-05-07)

| Phase | Status | Result |
|---|---|---|
| 1 — Auto: drag-projected pivot          | ✅ done | Click-away path already wired (notifyAcenUserPlaced existed); switched projection plane from most-facing-axis-through-gizmo to world Y=0 Work Plane to match MODO docs. New `screenToWorkPlane` helper in math.d. All tests pass. |
| 2 — Select: bbox center, not vert avg   | ✅ done | `asymmetric/select` + `selectauto` PASS in `run_acen_drag.sh`; all 47 unit tests still pass (symmetric inputs). Commit b7c96ca. |
| 3 — Local: per-cluster pivots in Tool   | ✅ done | `ActionCenterPacket` now ships `clusterCenters[]`+`clusterOf[]`. Scale tool consumes them via `pivotFor(vi)`. `asymmetric/local` PASS — MODO's per-cluster bbox-center invariant is preserved. All 12/12 cross-check modes pass. Move/Rotate per-cluster — follow-up. |
| 4 — Local: per-cluster axes (axis.local)| 🟡 partial | Move per-cluster basis done (commit 046d38f). Scale/Rotate per-cluster basis still TODO. Test extensions: sphere_top pattern + rotate tool now in defaults — 52/54 cells pass. Two known fails: `rotate/sphere_top/border` and `rotate/sphere_top/origin` — drag at (1000, 580) hits the gizmo's centre disk (which moves the gizmo) instead of a rotation ring when the pivot is at world origin (origin) or at sphere bbox center (border). Tracking as a drag-position calibration issue, not a vibe3d bug. |

## Recommended order

**2 → 1 → 3**. Phase 2 is the smallest change and gives the largest
ratio of (parity progress) / (code touched). Phase 1 is self-contained
(touches only Auto + the drag-begin path). Phase 3 is the only one
that perturbs the Tool Pipe state ABI and merits its own separate
planning + review round.

---

## Phase 1: ACEN.Auto — Work-Plane projection at drag start

**Effort: ~2-3 days. Risk: medium (camera ↔ world ray correctness).**

### What MODO does

> "The Automatic action center is not fixed, like other action centers
> are. You can define a new center by clicking away from the tool
> handle, setting the position at the intersection of where the
> pointer clicked in the viewport and the Work Plane."
> — `Modo902/help/content/help/pages/modeling/action_centers.html`

Empirically, MODO does this on EVERY drag, even for clicks "near" the
gizmo handle — there is no "snap to centroid" zone. Pivot is whatever
the click ray intersects on the Work Plane (default Y=0 world).

### What vibe3d does today

`source/toolpipe/stages/actcenter.d:172-174`:
```d
case Mode.Auto:
    if (userPlaced) return userPlacedCenter;
    return centroidWithGeometryFallback();
```

Static. `userPlaced` is only set by an explicit
`setManualCenter(worldPos)` call from outside.

### Plan

1. **`source/view.d` — add ray-plane projection helper**
   ```d
   // Project screen pixel `screenPos` onto the plane at world height
   // `planeY` (default 0 = X-Z work plane). Returns true iff the ray
   // intersects in front of the camera; out param `worldHit` carries
   // the intersection world coordinates.
   bool screenToWorkPlane(Vec2 screenPos, out Vec3 worldHit,
                          float planeY = 0.0f) const;
   ```
   Uses the same view+projection matrices the cache uses for picking.

2. **`source/handler.d` — add `onToolDragBegin(screenPos)` hook on `Handler`**
   - Default impl: no-op.
   - Tool-specific gizmo handlers can override; `MoveTool` /
     `RotateTool` / `ScaleTool` call it as part of their existing
     mousedown handler.

3. **`source/toolpipe/stages/actcenter.d` — extend Mode.Auto**
   - Add transient field `Vec3 dragPivot` + `bool dragPivotActive`.
   - New API `void onAutoDragBegin(Vec3 worldHit)` called by the tool:
     sets `dragPivot = worldHit; dragPivotActive = true`.
   - New API `void onDragEnd()` called on mouseup: clears
     `dragPivotActive`. Persistent `userPlaced` is independent
     (still drives the popup-menu "click in viewport sets center"
     path).
   - `computeCenter()` for `Mode.Auto`:
     ```d
     case Mode.Auto:
         if (dragPivotActive) return dragPivot;
         if (userPlaced)      return userPlacedCenter;
         return centroidWithGeometryFallback();
     ```

4. **Tool integration**
   - `source/tools/move.d`, `rotate.d`, `scale.d`: at start of
     drag-handling, if `actCenter.mode == Mode.Auto`, compute
     `view.screenToWorkPlane(screenPos, hit)` and call
     `actCenter.onAutoDragBegin(hit)`. On drag end, call
     `actCenter.onDragEnd()`.

5. **Tests**
   - Unit: feed a synthetic click coordinate through
     `screenToWorkPlane`; assert the projected pivot drives a known
     post-transform vertex set.
   - Cross-check: `run_acen_drag.sh asymmetric` — current `auto/asymm`
     PASSes the *skip*-style check; tighten the verifier to assert
     pivot is within tolerance of the click projection (need to
     decide click position deterministically — in the test we drag
     from `(CUBE_DRAG_X, CUBE_DRAG_Y)` so the projection is computable
     given the camera).

### Risks / open questions

- Work Plane is not always Y=0 in MODO. The tilt-workplane feature
  rotates the plane. Keep planeY+normal as parameters and pull from
  scene state (later — for now hard-code `Y=0, normal=(0,1,0)`).
- Camera matrix accessibility from inside `actcenter.d` needs a
  reference, not a copy — view orbits/zooms during a long drag in
  theory shouldn't change the pivot mid-drag, but verify.

---

## Phase 2: ACEN.Select — bbox center, not vertex average

**Effort: ~0.5 day. Risk: low. Impact: highest visible parity gain.**

### What MODO does (empirically)

For the `asymmetric` test pattern (10 unique selected vertices whose
mean is `(-0.05, 0.10, 0.10)`), MODO's drag-derived pivot is
`(0, 0, 0)` — exactly the **bounding box center** of the selected
vertex set. `actr.border` produces the same value. Modes therefore
*coincide* on Select vs Border in MODO 9 for this kind of asymmetric
pattern.

The MODO docs claim "average vertex position", but the empirical
behaviour is bbox center. Either docs are loose / wrong, or the docs
described an older MODO version. Going by the artifact rather than
the documentation.

### What vibe3d does today

`source/mesh.d:selectionCentroidFaces` (and `*Vertices`, `*Edges`):
```d
foreach (face) {
    foreach (vert) {
        if (!seen[vi]) { sum += vert; count++; seen[vi] = true; }
    }
}
return sum / count;
```

True per-vertex average. Diverges from MODO whenever the selection is
asymmetric.

### Plan

1. **`source/mesh.d` — add bbox-center alternatives**

   Keep the current `selectionCentroid*` for callers that genuinely
   want the per-vertex mean (if any exist). Add:
   ```d
   Vec3 selectionBBoxCenterFaces() const;
   Vec3 selectionBBoxCenterEdges() const;
   Vec3 selectionBBoxCenterVertices() const;
   ```
   Each walks the same vertex set as the centroid version but tracks
   `min`/`max` per axis and returns `(min+max)/2`.

2. **`source/toolpipe/stages/actcenter.d` — switch Select to bbox**

   In `centroidWithGeometryFallback`:
   ```d
   final switch (*editMode_) {
       case EditMode.Vertices: return mesh_.selectionBBoxCenterVertices();
       case EditMode.Edges:    return mesh_.selectionBBoxCenterEdges();
       case EditMode.Polygons: return mesh_.selectionBBoxCenterFaces();
   }
   ```
   This affects `Mode.Auto`, `Mode.Select`, `Mode.SelectAuto`,
   `Mode.Border`. All four already converge to bbox center in MODO
   for the asymmetric pattern, so this is the right unification.

3. **Audit other callers of `selectionCentroid*`**

   Anything still wanting "true average" (e.g. weld-to-centroid
   vertex op?) gets the renamed-to-`selectionVertexAverage*` path.
   Most likely all current callers want bbox semantics anyway.

4. **Tests**
   - Update `tests/test_toolpipe_acen.d`: any expected pivot for an
     asymmetric selection has to switch from vertex-average to bbox.
     Symmetric cases (single top face) are unchanged.
   - Cross-check: after this change, `run_acen_drag.sh asymmetric`
     should report PASS for `select`, `selectauto`, `border`.

### Risks / open questions

- A handful of unit tests might be calibrated against vertex-average
  values; sweeping the test files first will reveal the blast radius.
- Border is currently a separate `Mode.Border` codepath that already
  returns bbox-style. After Phase 2 it overlaps Select semantically;
  keep them as distinct enum values (UI cosmetic — different status
  bar label) but the published center is the same.

---

## Phase 3: ACEN.Local — per-cluster pivots during transform

**Effort: ~5-7 days. Risk: high (Tool Pipe state ABI change).**

### What MODO does

> "Uses the center of individual element clusters for the operation
> center, like having a separate axis and center for each selection
> group. This lets you select multiple elements and have them each
> rotate around their own local axis."
> — MODO docs

Empirically: in our asymmetric test, MODO's recovered scale factor
was `k ≈ 1.48` (NOT the uniform `k = 1.96` of single-pivot modes).
That's only consistent with each cluster scaling around its own
centroid — top cluster around `(-0.25, 0.5, 0)`, bottom around
`(0.25, -0.5, 0.25)`.

In MODO, this is delivered via the `LXpToolElementCenter` packet,
which ships per-element centers and an axis system per element.

### What vibe3d does today

`source/toolpipe/stages/actcenter.d:188-193`:
```d
case Mode.Local: {
    Vec3 first;
    int  count;
    computeLocalClusters(first, count);
    return count > 0 ? first : centroidWithGeometryFallback();
}
```

Publishes the **first cluster's centroid** as a single Vec3. The
Move/Rotate/Scale tools see only this single pivot and apply the
same transform around it for every selected vertex.

### Plan

#### Subphase 3.1 — Data structures (~1 day)

Extend the published action-center packet so a tool can ask "for
this vertex, which pivot do I use".

```d
// source/toolpipe/state.d (or wherever ActionCenterState lives)
struct ElementCenters {
    Vec3[]   clusterCenters;   // [cluster id] -> world pivot
    int[]    clusterOf;        // length = mesh.vertices.length, -1 if not selected
}

struct ActionCenterState {
    Vec3                center;
    Mat3                axis;
    ...
    ElementCenters*     perElement;   // null = single-pivot fallback
}
```

Tools default to using `state.center` when `perElement is null`. Old
behaviour preserved.

#### Subphase 3.2 — ACEN.Local publishes per-cluster centers (~1 day)

`computeLocalClusters` already finds clusters (face graph for face
selection, vertex graph for vert/edge selection). Extend it to also
fill an `ElementCenters` and assign it to the published state. Keep
`state.center` set to the first cluster's centroid for legacy callers
that don't read `perElement` yet.

#### Subphase 3.3 — Tools consume per-element pivots (~2-3 days)

Order: Scale → Rotate → Move (Move barely cares — translate is
pivot-invariant for delta vectors).

For each tool, in the apply path:
```d
if (state.perElement !is null) {
    foreach (vi, ref v; mesh.vertices) {
        if (!selected(vi)) continue;
        int cid = state.perElement.clusterOf[vi];
        Vec3 pivot = state.perElement.clusterCenters[cid];
        v = applyTransform(v, pivot, axis, factor);
    }
} else {
    // existing single-pivot path
}
```

Test on asymmetric pattern: the cross-check verifier (Phase 0 of this
file already has the math) will recover per-cluster `k` and `P`.

#### Subphase 3.4 — Multi-gizmo rendering (optional, ~1-2 days)

When `Mode.Local` is active and there are >1 clusters, the gizmo
handler should draw one gizmo per cluster center, all hot-tracked
together (drag any handle ⇒ all clusters transform with same factor
but each around its own pivot). Vibe3d's current gizmo renders only
once at `state.center`. Skipping this subphase still gives correct
math but worse UX.

#### Subphase 3.5 — Tests (~1 day)

- Unit: select 2 disjoint face groups, ACEN.Local should produce 2
  cluster centers; scale and assert each group transformed around
  its own.
- Cross-check: `run_acen_drag.sh asymmetric` for `local` should PASS
  with non-uniform per-cluster k.

### Risks / open questions

- ABI change in the published state — every reader of
  `state.actionCenter.center` continues to work, but anything that
  *should* be aware of per-element pivots needs updating. Audit
  before shipping.
- For modes other than Local, `perElement` stays null; no semantic
  change for Select/Border/Auto/Origin.
- Gizmo rendering for multiple clusters can interact awkwardly with
  the screen-space picker — collisions when clusters are visually
  close. Resolve by tagging each handle with its cluster id and
  picking the front-most.

---

---

## Phase 4: Per-cluster axes for `axis.local` (Move/Rotate/Scale)

**Effort: ~3-4 days. Risk: medium (AxisPacket ABI change, mirrors Phase 3).**

### What MODO does

`actr.local` + `xfrm.move` with multiple disjoint clusters does NOT
move every cluster by the same world-space delta. Instead each cluster
moves along its own local basis: the same screen drag projects onto
each cluster's right/up/fwd vectors, producing different per-cluster
world deltas.

Cross-check empirical (`tools/modo_diff/run_acen_drag.sh`,
`asymmetric/local/move`):
- top -X cluster delta ≈ `(0, 0.11, 3.8)` — primarily +Z
- bottom +X+Z cluster delta ≈ `(3.8, -0.11, 0)` — primarily +X
- same screen drag, two completely different world directions

This is `axis.local`'s per-cluster basis at work. MODO derives each
cluster's basis from its own geometry (face normal for face clusters;
edge direction for edge clusters; etc.). Without this, vibe3d's
single-basis Move tool will move all clusters in the same direction —
visibly wrong vs MODO.

### What vibe3d does today

`AxisStage.Mode.Local` returns a single basis (currently aligned to
the FIRST cluster's geometry, mirroring how `actr.local` returned only
the first cluster's centroid pre-Phase-3). Move/Rotate/Scale tools all
read `state.axis.right/up/fwd` once and apply that basis to every
selected vertex regardless of cluster.

### Plan

#### Subphase 4.1 — AxisPacket cluster fields (~0.5 day)

```d
struct AxisPacket {
    Vec3 right, up, fwd;
    int  axIndex = -1;
    int  type;
    // Per-cluster basis (Phase 4). When `clusterRight.length >= 2`
    // the packet is in multi-cluster mode and tools must use
    // clusterRight[clusterId] / clusterUp / clusterFwd. Length and
    // cluster ids match ActionCenterPacket.clusterCenters.length.
    Vec3[] clusterRight;
    Vec3[] clusterUp;
    Vec3[] clusterFwd;
}
```

#### Subphase 4.2 — AxisStage.Local fills cluster basis (~1 day)

For each cluster (face / edge / vertex), compute a local right/up/fwd:

- **Face clusters**: `up` = average face normal across the cluster's
  selected faces. `right` = primary tangent — pick the world axis
  aligned with the cluster's longest bbox extent in the face plane
  (ties broken by lowest world-axis index). `fwd` = `cross(up, right)`.
- **Edge clusters**: `right` = average edge direction. `up` =
  perpendicular to `right` and most-camera-aligned. `fwd` =
  `cross(up, right)`.
- **Vertex clusters**: fall back to world basis (PCA over so few
  verts is unstable).

The "longest bbox extent" rule is empirically close to MODO 9 but not
exact — see "Risks" below. Single-cluster Local stays in the global
basis (matches Phase 3's "skip per-element when only one cluster").

#### Subphase 4.3 — Move tool consumes per-cluster basis (~1 day)

Currently `MoveTool.onMouseMotion` calls `axisDragDelta` /
`screenAxisDelta` which compute the world delta from screen mouse
delta along a single axis. Extend the apply loop to:

```d
auto cp = queryClusterPivots();   // per-cluster pivot (Phase 3)
auto ap = queryClusterAxes();     // per-cluster basis (Phase 4)
foreach (vi; vertexIndicesToProcess) {
    Vec3 axis = (ap.active && cp.clusterOf[vi] >= 0)
              ? ap.cluster[ax_id][cp.clusterOf[vi]]
              : globalAxis;
    Vec3 delta = projectScreenDelta(mouseDelta, axis, cachedVp);
    mesh.vertices[vi] = mesh.vertices[vi] + delta;
}
```

`globalAxis` is the existing single-basis path; `axis` is per-cluster
when both Local stages are active. Single-pivot fallback keeps
non-Local modes unaffected.

#### Subphase 4.4 — Rotate / Scale per-cluster basis (~1 day)

Scale already has per-cluster pivots from Phase 3; it gets
per-cluster axes too, plumbed through `scaleAlongBasis(v, pivot, ax,
ay, az, fx, fy, fz)` — just look up `(ax, ay, az)` per cluster.

Rotate today computes `rotateVec(v, pivot, axis, angle)`. Extend to
look up `pivot` per-cluster (Phase 3 wasn't yet ported to Rotate) and
`axis` per-cluster (Phase 4). Rotate angle stays the same — single
drag → single angle, applied around per-cluster pivot+axis.

### Subphase 4.5 — Test extensions

1. **Sphere geometry**: new pattern in `modo_drag_setup.py` —
   `sphere_top_half`. Activates `prim.sphere`, selects all faces
   above Y=0 (the top half of the sphere). Tests Local with a
   non-axis-aligned cluster geometry, more representative than
   the cube faces.

2. **Rotate tool**: `tool` arg gains a third value `rotate`. Setup
   activates `xfrm.transform` with `T=0 R=1 S=0` (TransformRotate
   tool preset) instead of `xfrm.scale`. Verifier gets a
   `verify_rotate` path: for rotate, vertices stay equidistant from
   pivot and the chord between pre/post per cluster is consistent.

3. Full matrix becomes `tool × pattern × mode` =
   `3 × 3 × 6 = 54` cells. Runtime ~10 minutes.

### Risks

- AxisPacket ABI change: any external reader of
  `state.axis.right/up/fwd` continues to work, but existing AxisStage
  unit tests will need updates if they query the cluster fields.
- MODO's exact per-cluster basis algorithm isn't documented. Our
  "longest bbox extent" heuristic matches the asymmetric test case
  but may diverge for other geometries (e.g. a face whose normal
  isn't axis-aligned, where the tangent picking is ambiguous).
- Sphere clusters interact with the current sphere primitive's
  topology — need to validate `prim.sphere` segment count gives a
  clean Y=0 split (segmentsY=2 should put a vertex ring at Y=0).

---

## Cross-check verification matrix (target state)

After Phase 2 + Phase 3 (Phase 1 too if click-to-relocate cared about):

| pattern × mode  | single_top | asymmetric |
|-----------------|:----------:|:----------:|
| select          | PASS (today) | **PASS (after P2)** |
| selectauto      | PASS (today) | **PASS (after P2)** |
| auto            | PASS (today) | PASS (today, exact pivot from P1) |
| border          | PASS (today) | PASS (today) |
| origin          | PASS (today) | PASS (today) |
| local           | PASS (today) | **PASS (after P3)** |

Phases 2 and 3 each unblock specific cells; Phase 1 tightens the
"skip" branch to a positive assertion.
