# Subpatch drag performance optimization log

Series of profile-driven optimizations of the depth-3 subpatch preview
during an interactive move drag on a sphere. Captured via `perf record
-F 999 --call-graph fp` on `vibe3d` built with the `profile-fp` dub
config (`debugMode + debugInfo + optimize + -gs`). Reproduction: open
a sphere primitive, Tab into subpatch preview at depth 3, drag a vert.

## Profile timeline

| # | Total samples / 20 s | Top symbols (% self) | Change vs prior |
|---|---|---|---|
| 1 (baseline) | n/a | full C-C rebuild every frame + full GPU upload | — |
| 2 | n/a | buildLoops anchor walk + dirMap AA dominated | added CSR adjacency, parallel passes |
| 3 | 24461 | `gpu.upload` 16.3%, memmove 12.1%, GC 10.5% | added position-only `refreshSubdivPositions` fast path (kept C-C output topology, swapped vert positions in-place) |
| 4 | 47051 | `refreshPositions` 24.1%, Vec3 ops cluster ~30%, computeOneVert/EdgePoint 23% | added `GpuMesh.refreshPositions` (scatter-write VBOs via `glMapBuffer` — bypasses `~=` reallocation, memmove, GC) |
| 5 | 52189 | `refreshPositions` 27.8%, Vec3 cluster ~24%, computeOneVert/EdgePoint 26% | unrolled face-fan triangulation in `refreshPositions`; removed `foreach (idx; [face[0],face[i],face[i+1]])` literal-array alloc and Vec3 normal-compute ops |
| 6 | 42662 | `refreshPositions` 38.1%, computeOneVert 20.2%, computeOneEdgePoint 12.6%, Vec3 0% | inlined Vec3 ops in `refreshSubdivPositions` (computeOneVert, computeOneEdgePoint, faceCentroid) — plain float aggregators |

Sample count drop from 52 K → 42 K with the same 20 s wall budget
indicates the app is now waiting on vsync more — i.e. the per-frame
work shrank enough that the GL swap dominates the budget at high FPS.

## What stuck (kept in the codebase)

### 1. Topology cache + position-only refresh

`mesh.topologyVersion` is bumped only by ops that change vertex /
edge / face counts (subdiv, split, weld, etc.); pure position
mutations (move/rotate/scale drag) bump `mutationVersion` only. The
preview pipeline (`SubpatchPreview`) caches per-C-C-level CSR
adjacency in `Level.cache`. On a drag frame, when source
`topologyVersion` is unchanged, the preview calls
`refreshSubdivPositions(prev, cache, out_)` per level instead of
rerunning the full C-C subdivision. Saves the ~190 ms L3 rebuild on
every drag frame.

### 2. GPU buffer scatter-write (`GpuMesh.refreshPositions`)

When the preview's `sourceTopologyVersion` matches the last full
upload, the main loop in `source/app.d` calls
`gpu.refreshPositions(...)` instead of `gpu.upload(...)`. The fast
path uses `glMapBuffer` to scatter-write into the existing
`faceVbo` / `edgeVbo` / `vertVbo` without reallocating the
`faceData[]` / `edgeData[]` / `vertData[]` D arrays. Eliminates all
`memmove` and GC `expandArrayUsed` cost from the drag path.

Subpatch-mode filter mirrors `upload`: edges/verts with
`edgeOrigin[ei] == uint.max` / `vertOrigin[vi] == uint.max` are
skipped to keep VBO segment order identical to the last full upload.

### 3. Float-only inner loops

All hot inner loops in `refreshSubdivPositions` and
`GpuMesh.refreshPositions` use plain float arithmetic instead of
`Vec3` operator overloads. Reason: each `Vec3 + Vec3`, `Vec3 *
float`, `Vec3 / float` returns a fresh `Vec3` (one
`emplaceInitializer` per op) and dmd does not consistently eliminate
the temporary. On a depth-3 sphere drag they were ~25–30 % of total
CPU; after inlining to scalar Fx/Fy/Fz / sx/sy/sz aggregators, they
fell to 0 in the top symbols.

### 4. Closed-mesh anchor-walk skip

`buildLoops` (and `buildLoopsAfterEmit`) check `hasBoundary` before
running the per-vertex anchor walk. On closed meshes the walk does
nothing useful but was ~30 % of `buildLoops` self-time.

### 5. Parallel passes in `buildLoops` / position recompute

Four `buildLoops` passes and both `computeOneVert` /
`computeOneEdgePoint` parallelize via `taskPool` / `parallel(iota)`
above a small N threshold (4096 edges/verts) — below it the
single-threaded path stays as the parallel framework overhead
otherwise dominates.

### 6. Tool-pipe early exits

`MoveTool.applySnapToDelta` early-exits when `SnapStage.enabled ==
false`; `TransformTool.cluster*` calls bail out when `ACEN.mode !=
Local` and `AXIS.mode != Local`. Both cleared sequential
`pipeline.evaluate` overhead from the per-mouse-move path.

## What did NOT stick (failed experiments)

### `core.math.sqrt` for SSE `sqrtss`

`std.math.sqrt(float)` on DMD lowers to x87 (`fsqrt` + `fstps` —
~12 % of `refreshPositions` self-time on the face normal compute).
Tried switching to `core.math.sqrt`; DMD still emits `fsqrt`. Would
need LDC or hand-rolled inline asm (`sqrtss`) to fix.

## Remaining bottlenecks (for future passes)

In rough order of payoff:

1. **Face normals in shader, not VBO.** ~64 K cross + sqrt per frame
   live in `GpuMesh.refreshPositions`. Drop the normal channel from
   `faceVbo`, halve the buffer size, and either compute the face
   normal in the vertex/geometry shader from `gl_Position` derivatives
   or via `flat`-qualified attribute filled by a dedicated normal
   pass. Eliminates the entire x87 `fsqrt` cluster and roughly halves
   `refreshPositions` self-time.

2. **Parallel face VBO write.** `glMapBuffer` returns a pointer
   usable from the GL thread only, but we can parallel-fill a CPU
   staging buffer and then issue one `memcpy` (or `glBufferSubData`)
   into the GPU buffer. With ~9 MB written per frame the memcpy is
   ~1.5 ms but the parallel compute saves 5–10 ms — net win on a
   multi-core machine.

3. **Switch to LDC for `sqrtss` + better autovec.** ~12 % from x87
   on the face normal path and likely additional wins on the dense
   float loops inside `computeOneVert` / `computeOneEdgePoint`.

4. **Persistent mapped buffer (GL 4.4) or buffer orphaning.**
   `glMapBuffer` may force a driver sync on each frame; `glMapBuffer
   Range(GL_MAP_INVALIDATE_BUFFER_BIT)` or `glBufferSubData` with a
   freshly-orphaned buffer may have better driver paths.

## File map

- `source/mesh.d`
  - `Mesh.topologyVersion` — bumped at every topology-changing op
    (~14 call sites: edge split, vert merge, snapshot restore,
    subpatch toggle, etc.).
  - `SubdivCache` — per-level CSR adjacency + slot map; populated by
    `catmullClarkTracked`, consumed by `refreshSubdivPositions`.
  - `refreshSubdivPositions(prev, cache, out_)` — position-only
    C-C refresh.
  - `SubpatchPreview.rebuildIfStale` — branches to position-only
    fast path when `sourceTopologyVersion` matches.
  - `GpuMesh.refreshPositions(mesh, edgeOrigin?, vertOrigin?)` —
    scatter-write VBOs via `glMapBuffer`.
- `source/app.d` — main render-loop upload decision; tracks
  `gpuUploadedPreviewTopVersion` to choose between
  `refreshPositions` and full `upload`.
- `source/snapshot.d`, `source/commands/mesh/subpatch_toggle.d` —
  bump `topologyVersion` after restore / subpatch flag flip.
- `source/tools/move.d`, `source/tools/transform.d` — early-exits
  for disabled pipeline stages on the per-mouse-move path.

## Repro recipe for future regressions

```bash
dub build --build=profile-fp
./vibe3d --test &
# In the GUI: select sphere primitive, Tab into subpatch, depth 3.
# Pick one vert and start dragging.
PID=$(pgrep -af vibe3d | grep -v run_test | awk '{print $1}')
perf record -F 999 --call-graph fp -p $PID -o /tmp/vibe3d_prof.data -- sleep 20
perf report -i /tmp/vibe3d_prof.data --stdio --no-children -g none | head -30
```

A clean profile after the changes in this log should show
`refreshPositions` ≈ 38 %, `computeOneVert` ≈ 20 %,
`computeOneEdgePoint` ≈ 12 %, **no** `memmove` / GC /
`Vec3.opBinary` symbols in the top 10. If they reappear it
indicates a regression in either the topology-version invariant or
the position-only fast path.
