# OSD GPU evaluator — Phase 3 integration plan

## Status

* Phase 1 — `libosdGPU.a` built, `osd_static_gpu` linked. D-OpenSubdiv
  commit `c779393`. No new API.
* Phase 2 — `osdc_gl_create` / `osdc_gl_evaluate` / `osdc_gl_destroy`
  C entries + D bindings live. D-OpenSubdiv commit `ee49839`. Built
  on top of `Osd::GLXFBEvaluator` + `Osd::GLStencilTableTBO`. Runs
  the stencil eval as a GLSL transform-feedback shader; cage VBO →
  limit VBO, no CPU round-trip on the GPU side.
* Phase 2 wiring — vibe3d commit `eecee89`. Boot-time smoke test
  validates GPU eval byte-for-byte vs CPU; `g_osdGpuEnabled` flag
  flips true on success.
* Phase 3a — vibe3d commit `c7c3d7c`. OsdAccel.refresh routes through
  `osdc_gl_evaluate` then `glGetBufferSubData`-readbacks the limit
  positions into `preview.vertices` so the existing gpu.upload /
  picking / lasso paths see fresh data. Correct, production-wired.
* Phase 3b — done across four commits (`de2843f` step 1, `14f582e`
  step 2, `c1b7fd7` step 3, this commit step 4):
  * Step 1 — fan-out shader + cornerToLimit / cornerToFaceId /
    faceFirstVerts TBOs + `OsdAccel.refreshIntoFaceVbo`.
  * Step 2 — `GpuMesh.refreshNonFacePositions` (edge + vert VBOs only).
  * Step 3 — `SubpatchPreview.rebuildIfStale` accepts
    `targetFaceVbo` + sets `lastRefreshFannedOut`; main loop calls
    `refreshNonFacePositions` when set, `refreshPositions` otherwise.
  * Step 4 — readback dedupe: when fan-out runs the GPU eval, the
    redundant second eval inside `osdAccel.refresh` is skipped via
    new `osdAccel.readLimitIntoPreview` which just copies the
    already-populated `limitGlVbo` out via `glGetBufferSubData`.

### What Phase 3b achieves

* One GPU eval per drag frame (was two in the naive Step 3 wire-up
  because refresh re-evaluated).
* Face VBO write is GPU-driven via transform feedback — drops the
  bulk of the 6 MB / drag-frame CPU→GPU position upload that
  `refreshPositions` used to do for the face stream.
* Architecture lays the groundwork for Phase 3c — GPU fan-out paths
  for edge + vert VBOs would let us drop the readback entirely.

### What Phase 3b doesn't do (yet)

* The CPU-side `preview.vertices` is still kept fresh on every drag
  frame because `GpuMesh.refreshNonFacePositions` reads it for edge
  + vert VBO updates, and the lasso visibility path (below the 4 K
  threshold guard) iterates it too. The readback to maintain
  `preview.vertices` is a `glGetBufferSubData` from `limitGlVbo` —
  bandwidth-bound, ~0.1 ms per MB, sync-stalling. For the user's 8 K
  cage / 133 K preview-vert workload it's ~1.5 MB → roughly 1 ms.

### Phase 3c (future)

To drop the readback altogether: GPU fan-out shaders for edges + verts.
Sketch:

* edgeVbo: per-kept-edge × 2 positions. Shader pulls (a, b) limit
  verts → emits 6 floats. Same TBO setup pattern as the face fan-out.
* vertVbo: per-kept-vert position. Where `vertOrigin` filter doesn't
  remove anything, a `glCopyBufferSubData` from `limitGlVbo` works
  directly. Otherwise a tiny fan-out shader.

Lasso path: the 4 K-vert threshold already short-circuits visibility
to "all visible" on large previews (commit `4d4b6fa`), so it
doesn't need `preview.vertices` at the sizes where it'd matter for
perf. Below the threshold, an opt-in readback once per lasso mouse-
up suffices — drag-frame readback isn't needed.

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

## Phase 3b — concrete plan

After spending real time on this, the right approach is a **transform-
feedback fan-out shader** that pulls per-limit-vert positions from
OSD's output VBO and emits the (xyz, xyz)-interleaved face-corner
stream vibe3d's `gpu.faceVbo` expects. Compute the flat face normal
on GPU from the corner's parent face's first three limit verts. One
TF dispatch per drag frame; no CPU readback, no architecture-wide
VBO refactor.

### Shader

```glsl
#version 330 core
uniform  isamplerBuffer u_cornerToLimit;      // per-corner: limit-vert idx
uniform usamplerBuffer  u_cornerToFaceId;     // per-corner: face id
uniform  isamplerBuffer u_faceFirstVerts;     // per-face × 3: limit-vert idx
uniform  samplerBuffer  u_limitPositions;     // limitGlVbo, GL_RGB32F
out vec3 vPos;
out vec3 vNorm;
void main() {
    int corner = gl_VertexID;
    int li = texelFetch(u_cornerToLimit, corner).r;
    vPos = texelFetch(u_limitPositions, li).rgb;

    int fid = int(texelFetch(u_cornerToFaceId, corner).r);
    int a   = texelFetch(u_faceFirstVerts, fid * 3 + 0).r;
    int b   = texelFetch(u_faceFirstVerts, fid * 3 + 1).r;
    int c   = texelFetch(u_faceFirstVerts, fid * 3 + 2).r;
    vec3 p0 = texelFetch(u_limitPositions, a).rgb;
    vec3 p1 = texelFetch(u_limitPositions, b).rgb;
    vec3 p2 = texelFetch(u_limitPositions, c).rgb;
    vec3 n  = cross(p1 - p0, p2 - p0);
    float l = length(n);
    vNorm   = l > 1e-6 ? n / l : vec3(0, 1, 0);
}
```

Output captured via `GL_INTERLEAVED_ATTRIBS` writes (vPos, vNorm)
sequentially into the bound TF buffer — exact match for vibe3d's
existing face-VBO stride-6 layout.

### What OsdAccel needs to add

```d
struct OsdAccel {
    // ... existing ...
    private GLuint cornerToLimitVbo, cornerToLimitTex;
    private GLuint cornerToFaceIdVbo, cornerToFaceIdTex;
    private GLuint faceFirstVertsVbo, faceFirstVertsTex;
    private GLuint limitTex;            // TBO view over limitGlVbo
    private GLuint fanOutProgram;
    private int    faceVertCount;
}
```

* `cornerToLimit[corner]` — built at `buildPreview` by walking
  `outMesh.faces` the same way `GpuMesh.upload` triangulates them.
* `cornerToFaceId[corner]` — duplicates the existing `gpu.faceIdVbo`
  data; redundant copy is acceptable.
* `faceFirstVerts[3*fid]` — first three verts of each face from
  `outMesh.faces[fid][0..3]`.
* `limitTex` — single `glTexBuffer(GL_TEXTURE_BUFFER, GL_RGB32F,
  limitGlVbo)`.
* `fanOutProgram` — vertex shader above + empty fragment + linked
  with `glTransformFeedbackVaryings(prog, 2, ["vPos","vNorm"],
  GL_INTERLEAVED_ATTRIBS)`.

### refreshIntoFaceVbo signature

```d
void refreshIntoFaceVbo(ref const Mesh cage, GLuint targetFaceVbo) {
    // 1. Pack cage positions, glBufferSubData into cageGlVbo.
    // 2. osdc_gl_evaluate(cageGlVbo → limitGlVbo).
    // 3. glUseProgram(fanOutProgram).
    // 4. Bind the four TBOs to texture units 0..3 + set the uniform
    //    sampler-buffer locations.
    // 5. glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, targetFaceVbo).
    // 6. glEnable(GL_RASTERIZER_DISCARD).
    // 7. glBeginTransformFeedback(GL_POINTS).
    //    glDrawArrays(GL_POINTS, 0, faceVertCount).
    //    glEndTransformFeedback().
    // 8. glDisable(GL_RASTERIZER_DISCARD).
    // 9. Restore prev program, vao, buffer bindings.
}
```

### Main-loop coordination — the actual hard part

`SubpatchPreview.rebuildIfStale` currently bumps
`preview.mesh.mutationVersion`, which makes the main loop trigger
`gpu.upload(preview.mesh, ...)` — and that re-uploads positions from
the (now stale) `preview.vertices`. Phase 3b needs:

1. A way to tell the main loop "skip the position-write part of
   `gpu.upload` because the fan-out already updated faceVbo."
   Cleanest: split `gpu.upload` into `uploadTopology` (faces, edges,
   ids — once per topology change) and `uploadPositions` (per-frame).
   Phase 3b skips the latter when GPU fan-out ran.

2. `SubpatchPreview.rebuildIfStale` needs to know whether we're on
   the Phase-3b path so it doesn't bother CPU-side. Either expose
   the choice through a delegate, or move the entire orchestration
   into app.d's main loop.

3. CPU consumers of `preview.vertices`: lasso visibility test
   (skipped above 4 K-vert threshold anyway, so OK), picking
   (gpu_select reads VBO not preview.vertices, so OK), bounding-box
   updates (re-check call sites — likely also fine since they
   typically operate on cage). Verify each in a sweep before
   shipping.

### Suggested rollout

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
