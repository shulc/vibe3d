# Fix: lasso visibility test should use the GPU pick buffer

## Status

Symptom mitigated in commit `4d4b6fa` by skipping the occlusion test
above a 4 K-vert/face threshold (`VIS_OCCLUSION_LIMIT` in
`source/app.d` inside `handleMouseButtonUp`). Lasso on heavy meshes
returns in milliseconds at the cost of also selecting some verts that
are occluded by closer geometry. This document captures the proper
fix.

## Symptom

* Loaded an LWO mesh (cage ≈ 8 K verts / 8 K faces). Subpatch ON →
  preview ≈ 133 K verts / 132 K faces.
* RMB-lasso-select on vertices in the viewport → drop the mouse.
* vibe3d pegged at 100 % CPU for several minutes, no UI updates.

## Root cause

`Mesh.visibleVertices(eye, vp)` in `source/mesh.d:1142` runs an
O(V × F\_front) occlusion test for every candidate vert against every
front-facing face:

```
Pass 1 — collect front faces with screen-space bbox      : O(F)
Pass 2 — per-vert × per-front-face bbox + PIP + ray-plane : O(V × F)
```

`perf record -F 99 --call-graph fp` showed 99.79 % of CPU in
`Mesh.visibleVertices`, called from `VisibilityCache.get`, called
from `pvVisCache.get(*pv, eye, vp)` in `handleMouseButtonUp`. On the
preview that's roughly 17 G ops — many minutes wall-clock.

The `VisibilityCache` memoises by `(mutationVersion, eye, view)`, so
the cost only hits the first lasso after a camera move; subsequent
lassoes from the same angle return instantly. But the FIRST hit is
the showstopper.

## Proposed fix: GPU-pick-buffer lasso pass

`source/gpu_select.d` already renders verts to an offscreen R32UI
texture with `gl_VertexID + 1` as the per-point colour, depth-tested
against the face surface (via the `SelectMode.Vertex` depth pre-pass).
A pixel in that buffer is non-zero iff the corresponding vert is both
inside the viewport and not occluded by any front face. The lasso
pass can re-use the exact same buffer:

1. `gpuSelect.pick(SelectMode.Vertex, …)` already populates the per-
   mode FBO. Cache slot key on `(mode, uploadVersion, view, proj, w,
   h)` — already in place.
2. Add a new entry point `gpu_select.lassoVerts(mode, pxs, pys,
   outMask)` that reads back the entire FBO once, then for each
   non-zero pixel does the screen-space `pointInPolygon2D` against
   `(pxs, pys)` and sets `outMask[vertOriginGpu[bufferValue - 1]] =
   true`.
3. `handleMouseButtonUp` calls `gpuSelect.lassoVerts(...)` instead of
   `meshVisCache.get` + the per-vert loop. The cage-/preview-mode
   split goes away: a single render + readback handles both because
   the GPU only ever rasterises verts that are visible at the
   currently-uploaded mesh (cage or subpatch).

### Cost

* Render is already done for hover picking; the lasso path is just an
  extra readback + scan.
* Readback: O(viewport pixels) — for a 1920×1080 viewport that's
  ~2 M `uint32` (8 MB) one-time over PCIe. ~1 ms on modern hardware.
* Scan: O(pixels-in-lasso-bbox) for the PIP test. Few ms even for
  the largest lassoes.
* Net: < 10 ms regardless of mesh size, vs. multi-minute hang.

## Same hazard for edges & faces

`source/app.d` `handleMouseButtonUp` has parallel branches for
`EditMode.Edges` and `EditMode.Polygons`. Both consult `pvVisible[a]
/ pvVisible[b]` (edges) and a per-face front-facing check + per-vert
PIP (faces). Same threshold guard applies (`VIS_OCCLUSION_LIMIT` in
the interim commit). Same GPU-pick-buffer treatment in the proper
fix:

* Edges — `gpu_select.d` already has `SelectMode.Edge` with `gl_VertexID
  / 2 + 1` as the edge-segment ID. Lasso pass reads back, PIP per
  non-zero pixel, OR into a per-cage-edge mask via `edgeOriginGpu`.
* Faces — `SelectMode.Face` rasterises faces with `aFaceId + 1` as
  the per-vertex flat varying. Same lasso treatment with
  `faceOriginGpu`.

Strict-inside-vs-any-pixel semantics differ between elements (`Vertices`:
vert pixel inside; `Edges`: both endpoints' pixels inside; `Polygons`:
every preview-child fully inside). The GPU buffer answers "is element
X visible at pixel Y?" — the semantic combinators stay CPU-side.

## Threshold-guard interim

```d
enum size_t VIS_OCCLUSION_LIMIT = 4_000;
bool[] visible =
    (mesh.vertices.length > VIS_OCCLUSION_LIMIT
        || mesh.faces.length > VIS_OCCLUSION_LIMIT)
    ? allTrue(mesh.vertices.length)
    : meshVisCache.get(mesh, cameraView.eye, vp2);
```

— in `source/app.d:1993` (cage) and `:2002` (preview). Lasso on small
meshes still does the occlusion test; above the threshold it skips,
trading "select occluded verts" for "no multi-minute hang." Remove
when the GPU-pick-buffer pass lands.

## When to do this

Next high-priority polish pass — the threshold guard makes vibe3d
usable on real imports, but the UX cost (lasso selects through walls
on heavy meshes) is visible in any tightly-clustered selection. The
GPU pick buffer plumbing is already in place; the lasso side is one
new function + a couple of caller swaps.

## Bench bar

* Lasso vert-select on a 132 K-poly preview must finish in < 50 ms
  (well within one frame at 60 Hz so the next render shows the new
  selection immediately).
* Result must match "rendered verts visible at the pixel-grid"
  semantics — same as the existing `gpuSelect.pick` returns for
  hover.

## Related

* `commit 4d4b6fa` — the interim threshold guard
* `source/gpu_select.d` — the existing pick FBO infrastructure
* `source/visibility_cache.d` — kept as-is; it's still useful for
  cages below the threshold (the under-4 K-vert case is fast enough
  that the CPU path's correctness wins over the GPU pass complexity)
