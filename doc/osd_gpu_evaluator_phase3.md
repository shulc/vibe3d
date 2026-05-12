# OSD GPU evaluator — Phase 3 integration plan

## Status

* Phase 1 — `libosdGPU.a` built, `osd_static_gpu` linked. D-OpenSubdiv
  commit `c779393`. No new API.
* Phase 2 — `osdc_gl_create` / `osdc_gl_evaluate` / `osdc_gl_destroy`
  C entries + D bindings live. D-OpenSubdiv commit `ee49839`. Built
  on top of `Osd::GLXFBEvaluator` + `Osd::GLStencilTableTBO`. Runs
  the stencil eval as a GLSL transform-feedback shader; cage VBO →
  limit VBO, no CPU round-trip on the GPU side.
* **Phase 3 — vibe3d integration. NOT YET WIRED.** This doc plans
  it. The Phase-2 API is callable but no production code path
  consumes it; the CPU evaluator (`osdc_evaluate`) still drives every
  subpatch refresh.

## What blocks the simple drop-in

`OsdAccel.refresh` today does:

```d
foreach (vi, v; cage.vertices) {
    cageScratchXyz[3*vi + 0] = v.x; ... ;
}
osdc_evaluate(osd, cageScratchXyz.ptr,
              cast(float*)preview.vertices.ptr);
```

CPU sees the limit positions in `preview.vertices`; main loop then
calls `gpu.refreshPositions` / `gpu.upload`, which **reads
`preview.vertices` and writes into the existing interleaved
`gpu.faceVbo` (xyz + normal, 6 floats per vertex)**.

For GPU eval to be a net win, we must avoid the readback. Naive
drop-in:

```d
// Upload cage positions
glBindBuffer(GL_ARRAY_BUFFER, cageGlVbo);
glBufferSubData(...cage_xyz...);
// Eval on GPU
osdc_gl_evaluate(glEval, cageGlVbo, limitGlVbo);
// Read back (KILLS THE BENEFIT)
glBindBuffer(GL_ARRAY_BUFFER, limitGlVbo);
glGetBufferSubData(...preview.vertices...);
```

That's CPU → GPU → CPU per frame. The readback on a 9 MB / 24 K-vert
preview costs ~5–10 ms — within an order of magnitude of the cost
the CPU eval already had. Not worth the integration churn.

## Real fix — drop the round-trip

vibe3d's VBO model needs the limit positions to **live on the GPU**.
Two equivalent strategies:

### Option A — separate positions VBO

Split `gpu.faceVbo`'s interleaved (xyz + normal) into two parallel
buffers:

* `gpu.facePosVbo` — xyz only. OSD GL evaluator writes straight
  into this.
* `gpu.faceNormalVbo` — normal_xyz. Either computed once on full
  rebuild and stale during drag, or recomputed each frame on GPU.

`drawFaces` shader switches from `layout(location=0) vec3 aPos;
layout(location=1) vec3 aNormal;` reading interleaved → reading
two attribute streams. Trivial shader change.

Normal recompute options:

* **Stale flat normals.** Computed once at rebuild from the cage
  topology + initial positions; not updated during drag. Surface
  shading lags one frame behind position, only noticeable on slow
  drags of high-frequency geometry. Cheapest.

* **Compute shader normal recompute.** GLSL 4.3 (or GL 3.3 with
  ARB_compute_shader extension on most drivers). Tiny kernel —
  for each face, cross-product of two edges, scatter into the
  normal VBO. ~negligible on GPU.

* **Vertex-shader recompute** via per-face triangle barycentrics
  and per-vert face-id (`faceIdVbo` already exists). Computes
  flat normal in the vertex shader from neighbouring face verts.
  Slightly more shader complexity, no extra pass.

### Option B — interleaved write via shader

Keep the interleaved VBO. After OSD writes raw xyz to a scratch
VBO, run a second compute pass that takes (scratch xyz, faceIdVbo,
topology) and writes interleaved (xyz, normal) into `gpu.faceVbo`.
One extra GL kernel.

Simpler topology refactor, more shader code.

## Suggested rollout

1. **Lift `gpu.faceVbo`'s layout split (Option A).** One commit,
   shader change + GpuMesh.upload split. Verify rendering still
   works with the existing CPU eval path (now writes only positions
   instead of positions+normals into faceVbo, normals go into a
   parallel VBO).

2. **Add GL eval to `OsdAccel`.**
   * `osdAccel.glEval` field — non-null when GL context exists.
   * Owns two extra GL VBOs: cage positions, limit positions.
   * `buildPreview` creates them + builds the GL evaluator.
   * `refresh` uploads cage xyz to `cageGlVbo`, calls
     `osdc_gl_evaluate(cageGlVbo, limitGlVbo)`. The limit VBO IS
     the preview's facePosVbo — no copy.
   * CPU `preview.vertices` array is left stale during drag. Code
     that reads it (picking, lasso) either gets refreshed via a
     one-shot readback when the drag ends, or migrates to reading
     positions from the GL VBO on demand.

3. **Verify the round-trip is gone.** Bench against the CPU path:
   for the 8 K-vert cage / 133 K-vert preview from the LWO scenario,
   target sub-frame (< 16 ms) end-to-end refresh.

4. **Normal recompute.** Pick one of the three options above and
   wire it up. Compute-shader is cleanest but needs a GL 4.3
   capability check; vertex-shader recompute keeps us on GL 3.3.

## Smoke test for Phase 2 (today)

`osdc_gl_create` requires an active GL 3.3 context — it compiles
the transform-feedback shader at create time. The shim API is
otherwise untested at runtime. Suggested smoke verification before
starting Phase 3:

1. Wire a one-shot `osdc_gl_smoke` call in `app.d` after SDL+GL init.
2. Build a tiny cage (cube), build OSD topology, create GL
   evaluator.
3. Allocate two GL VBOs; upload cage positions to src; run
   `osdc_gl_evaluate`.
4. Read back dst via `glGetBufferSubData`.
5. Compare to `osdc_evaluate` (CPU) output. Print max delta to
   stderr.
6. Remove the smoke call once we have Phase 3 confidence.

A few ms of test overhead on every startup is acceptable for the
debug build; release builds can short-circuit.

## Related

* D-OpenSubdiv `ee49839` — Phase 2 API + GLStencilTableTBO +
  GLXFBEvaluator integration
* D-OpenSubdiv `c779393` — Phase 1 build infrastructure
* `gpu_select.d` — the existing offscreen FBO render that already
  uses GL state; that file's coexistence pattern is a model for
  Phase 3 GL state isolation.
