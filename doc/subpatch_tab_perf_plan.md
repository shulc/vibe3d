# Subpatch Tab — performance plan

## Goal

Reduce `Tab` (subpatch_toggle) latency on a 24576-cage-polygon mesh from the
current ~640 ms median down to **≤ 200 ms** (≈ 3× speed-up) so the user
stops perceiving a stall when toggling subpatch on heavy meshes.

## Status (commits 1628e83 → 8d3b2c4)

| Stage | Median Tab ms | Δ vs prev | Δ vs baseline | Notes |
|---|---|---|---|---|
| Baseline (45d7128) | 638 | —    | —      | starting point |
| P0 (1628e83)       | 532 | −17% | −17 %  | scratch buffers in OsdAccel.buildPreview |
| P1 (de8ccc1)       | 544 |   0% | −15 %  | OSD-side AA → sorted-array (timing flat — cleanup, the dominant AA was Mesh.edgeIndexMap) |
| P2 (e952aec)       | 470 | −13% | −26 %  | CSR adjacency in buildLoops for preview path |
| P3 (bf81feb)       | 336 | −29% | −47 %  | pre-sized + index-write GpuMesh.upload buffers |
| P4 (f2b79f2)       | 305 |  −9% | −52 %  | skip Mesh.buildLoops on the preview mesh — no consumer reads loops/edgeIndexMap on it |
| P5 (8d3b2c4)       | 256 | −16% | **−60 %** | grow-only setLength on GpuMesh.upload's float scratch (was 7.88 % of CPU on shrink-then-regrow) |

Median 638 → **256 ms** ; max 1029 → 454 ms. Plan target of ≤ 200 ms median
not fully closed but within striking range; the remaining 56 ms / ~22 %
sits mostly in OSD-internal work (StencilBuilder + CpuEvalStencils +
StencilTableFactory + QuadRefinement ≈ 28 % of post-P5 CPU) and intrinsic
memmove (14.8 % — split between OSD's own stencil-table memcpy and the
driver-side `glBufferData` upload). Closing that requires either:

- OSD-refiner reuse across topology-only Tab toggles (would need
  D-OpenSubdiv API surgery to expose split create-refiner /
  create-stencil-table calls), or
- moving the preview-build CPU helpers off the Tab critical path (build
  asynchronously while showing a "subpatch loading…" hint on the cage).

P4/P5 as shipped diverge from the candidates originally named in this
doc — what landed is more surgical:

- **Plan P4** was "cache OSD TopologyRefiner across topology-only
  toggles". *Not done.* The shipped "P4" (skip buildLoops on the preview)
  is a different cut that we found while auditing consumers.
- **Plan P5** was "flatten Mesh.faces from uint[][] to uint[] + offsets".
  *Not done.* The shipped "P5" (grow-only setLength) is a narrower
  optimisation. The structural flat-faces refactor remains future work
  but on the Tab path its benefit would now be modest — most of the
  outer-slice-header churn has already been removed.

## Baseline (captured with `tools/perf_subpatch/run.d`)

Setup: cube → `mesh.subdivide × 6` → 24576 quads → `mesh.subpatch_toggle`.
Subpatch depth is capped to 2 by `fed3b5a` (would-be depth 3 → 1.5M limit
faces blows up OSD's stencil-table builder), yielding **393 216 preview
faces / ≈ 786 K preview edges / ≈ 400 K preview verts**.

```
rdmd tools/perf_subpatch/run.d --tabs 30 --freq 4999 --capture 1
→ Tab ms min/avg/med/max : 2 / 433 / 638 / 1029
```

Odd-numbered tabs tear the preview down (~2-15 ms each — cheap); even ones
re-build it (~600-1000 ms). The plan targets only the re-build path.

## Hot-path map

`perf report --no-children` over 30 tab toggles at -F4999, top slices:

| % CPU | Symbol | File / context |
|---|---|---|
| 10.47% | `core.internal.spinlock.SpinLock.lock` | D GC global lock |
| 9.89%  | kernel (unknown) | mostly GC mark + syscalls |
| 6.83%  | `atomicCompareExchangeStrongNoResult` | GC CAS in mark / alloc |
| **6.28%**  | `findSlotLookup!(ulong)` on `uint[ulong]` | AA lookups (see below) |
| 3.30%  | `OpenSubdiv::Far::StencilBuilder::Index::AddWithWeight` | OSD core |
| 3.29%  | `memmove` | array grow + dup |
| **2.78%**  | `GpuMesh.upload` | `source/mesh.d:2368` |
| 2.76%  | `expandArrayUsed` (GC) | array length growth |
| 2.49%  | GC mark | |
| **2.12%**  | `OsdAccel.buildPreview` | `source/subpatch_osd.d:763` |
| 1.94%  | `getBlkInfo` (GC) | every alloc consults blkcache |
| **1.67% + 0.86% + 0.83% + 0.79%** | `Mesh.buildLoops.fillOneFace / fillLoopEdge / fillTwin / total` | `source/mesh.d:1438`, parallel pass over 393K preview faces |
| 0.61%  | `OSD::Osd::CpuEvalStencils` | preview.vertices CPU eval |

Aggregated:

| Category | % |
|---|---|
| D GC (lock + CAS + mark + expandArrayUsed + blkcache + setLocked + ...) | **≥ 25 %** |
| `uint[ulong]` AA lookups | 6.3 % |
| `Mesh.buildLoops` on preview | 4.2 % |
| `GpuMesh.upload` | 2.8 % |
| Vibe-side wrapper code (`buildPreview` self-time) | 2.1 % |
| OSD core (stencil-builder + CpuEvalStencils) | < 4 % |

OSD itself is *not* the bottleneck. The cost lives in D-side glue:
allocations during preview construction, `uint[ulong]` lookups, the
loop-structure rebuild for the preview, and the GPU buffer upload.

## Optimization candidates (priority order)

Numbered roughly by expected `Tab`-latency win. Each item lists a concrete
code site, the change, the expected return, and how to verify.

### P0 — Cut GC churn in `buildPreview` (`source/subpatch_osd.d:763-1010`)

`OsdAccel.buildPreview` allocates fresh arrays for every rebuild:

- `outMesh.vertices = new Vec3[](limitVerts)` (393K Vec3)
- `outMesh.edges.length = limitEdges` (786K edges, each a `uint[2]`)
- `outMesh.faces.length = limitFaces`; each `outMesh.faces[fi].length = cnt`
  is a fresh `uint[]` allocation per preview face (393K small allocs!)
- `outMesh.isSubpatch = new bool[](limitFaces)`
- `outMesh.selectedVertices.length = limitVerts`, edges, faces
- `outTrace.{vert,edge,face}Origin = new uint[](...)`, `outTrace.subpatch = new bool[](limitFaces)`
- `cornerToLimit ~= ...` four times per preview face → 4 × 393K `~=` ops
- `cornerToFaceId ~= ...` same
- `edgeSegToLimit ~= ...`, `vertToLimit ~= ...`
- `faceCounts`, `faceIndices`, `edgeVertsRaw`, `vertOriginsRaw`, `faceOriginsRaw`, `edgeOriginsRaw` scratch arrays — all fresh per call

Each per-face `outMesh.faces[fi] = new uint[](cnt)` is a tiny GC allocation
touching the global GC lock; with 393K faces this is most of the `SpinLock`
hit.

**Actions:**

1. Move all scratch arrays (`faceCounts`, `faceIndices`, `edgeVertsRaw`,
   `*OriginsRaw`, `cornerToLimit`, `cornerToFaceId`, `edgeSegToLimit`,
   `vertToLimit`, `faceFirstVerts`) into `OsdAccel` fields. `setLength(N)`
   to grow in-place; D won't shrink a slice's underlying capacity, so a
   second call at the same or smaller N is allocation-free.
2. Pre-compute capacities for `cornerToLimit` etc.
   (`Σ_f (face.length - 2) * 3`) and `reserve`/`setLength` instead of `~=`.
3. Flatten `outMesh.faces` into a single contiguous `uint[]` storage with
   per-face offsets (`Mesh.faces` is currently `uint[][]`; consider a
   secondary `outMesh.facesFlat` + offsets just for the preview path, fed
   by `setLength` on existing buffers). Even without changing `Mesh.faces`
   itself, we can reuse the per-face slices if `setLength` keeps prior
   capacity.
4. Don't reallocate `outMesh.isSubpatch` / `selected*` when the previous
   length matches; just `[] = false` in place.

**Expected win:** ~150-250 ms off the rebuild. GC `SpinLock.lock` (10.5%)
and `expandArrayUsed` (2.8%) drop sharply when the per-face `uint[]`
allocations and the `~=` cascades are gone.

**Risk:** Lifetime — `outMesh` and `outTrace` are kept by `SubpatchPreview`,
so the scratch arrays must remain valid until the next rebuild. Trivial
when they live in `OsdAccel`. Verify nothing else writes to them outside
`buildPreview`.

**Verify:** `rdmd tools/perf_subpatch/run.d --tabs 30 --freq 4999 --capture 1`,
SpinLock + expandArrayUsed share should fall below 5% combined; per-tab
median should drop accordingly.

---

### P1 — Replace `uint[ulong]` AAs with sorted arrays / open-addressed maps

Two AA hot sites, both at 6%+:

1. `source/subpatch_osd.d` (added by `671fa3b`): `vibe3dEdgeByVerts`
   maps `(min,max) → vibe3d cage edge idx`. 50K entries on the 24K-poly
   cage, populated and queried once per rebuild.
2. `source/mesh.d:addEdge` / `addFaceFast`'s `edgeIndexMap` —
   `uint[ulong]` per call. Not invoked by `buildPreview` directly, but
   called from `Mesh.buildLoops` setup elsewhere; worth a follow-up.

For (1) the right shape is: build a `KV` array of `(key, value)`,
`sort!"a.key < b.key"`, binary-search on lookup. With 50K entries the
build is `O(n log n)` ≈ 800K comparisons (~ms), and each lookup is
`O(log n)` ≈ 16 comparisons vs the AA's hash + probe + indirect alloc
chain. Bonus: no GC entries.

Alternative: a robin-hood / linear-probing open-addressed hash with a
flat array. ~3× cheaper than D's AA in microbench.

**Expected win:** ~30-60 ms off the rebuild. AA share (6.3%) drops to
< 1.5%.

**Verify:** `findSlotLookup` disappears from top-30; per-tab median
drops by tens of ms.

---

### P2 — Speed up `Mesh.buildLoops` on the preview

`source/mesh.d:1438`. Currently runs in 4 passes:

- `fillOneFace` (parallel ≥ PARALLEL_BUILD_MIN=4096)
- `fillLoopEdge`
- `fillTwin`
- (vertLoop seed serial)

At 393K preview faces, this is `4.15%` of the profile. Concrete hits:

1. `loops.length = total`, `vertLoop.length = vertices.length`,
   `loopEdge.length = total` — allocate fresh each rebuild. Cache them on
   `Mesh` as growable buffers (like P0).
2. `fillTwin` walks all loops searching for opposite-direction twins. On a
   manifold mesh this is fast; on the preview it can degenerate near
   non-manifold seams. Verify the closed-mesh anchor-walk skip from
   `c8f2a85` actually fires for preview meshes.
3. Check that `PARALLEL_BUILD_MIN=4096` triggers the parallel branch on a
   393K-face preview — if not, lower the threshold or force parallel for
   preview.

**Expected win:** ~20-40 ms.

**Verify:** `Mesh.buildLoops.*` share falls to < 2%.

---

### P3 — `GpuMesh.upload` (`source/mesh.d:2368`)

`upload` builds `faceData` and `faceIdData` via `~=` inside a face loop and
similarly for `edgeData` / `vertData`. 393K * 6 floats ≈ 2.4M float
appends, plus 393K uint appends — half of P0's GC pain lives here.

**Actions:**

1. Pre-compute total sizes from `mesh.faces` and `mesh.edges` / `vertices`
   (loops are cheap; appends in inner loops are not). `setLength` once,
   index into the flat buffer.
2. Keep `faceData` / `edgeData` / `vertData` / `faceIdData` as `GpuMesh`
   fields so successive uploads reuse storage (just like P0 for the OSD
   trace arrays).
3. `glBufferData(..., GL_DYNAMIC_DRAW)` on every upload re-allocates the
   driver-side buffer. For same-size uploads `glBufferSubData` (or
   `glMapBufferRange` with `GL_MAP_INVALIDATE_BUFFER_BIT`, mirroring
   `refreshPositions`) avoids the realloc.

**Expected win:** ~50-80 ms; combined with P0 the GC group drops
substantially.

**Verify:** `GpuMesh.upload` falls below 1%, `memmove` share drops.

---

### P4 — Hoist `buildPreview`'s per-call OSD work

`osdc_topology_create` builds the `TopologyRefiner` from the face-vertex
arrays. On a topology-only toggle (same cage, just flipping `isSubpatch`
flags) we throw away the entire TopologyRefiner + stencil tables and
rebuild from scratch.

**Action:** Cache the TopologyRefiner keyed by `cage.topologyVersion`.
`isSubpatch` flips bump `topologyVersion`, but the underlying CAGE
topology (faces, edges) is unchanged — only the sharpness markers differ.
If OSD supports re-running stencil-table construction with new sharpness
inputs against an existing refiner, we skip the most expensive setup
step.

If that's not feasible without forking D-OpenSubdiv, **skip P4** —
the P0-P3 wins are easier and additive.

**Expected win:** uncertain — may take big chunks (OSD stencil builder ≈
3.3% + part of buildPreview self-time) or zero, depending on OSD API.

---

### P5 — `Mesh.faces` as `uint[]` + offsets instead of `uint[][]`

Long-term: `Mesh.faces = uint[][]` causes a per-face allocation. Switching
to flat storage + per-face offset would remove every per-face `uint[]`
allocation site project-wide (not just in `buildPreview`).

This is a structural refactor with wide reach; defer until P0-P4 land
and we measure whether it's still worth the disruption.

## Verification methodology

Run before and after each P-item:

```
rdmd tools/perf_subpatch/run.d --tabs 30 --freq 4999 --capture 1
```

Read off:

- `Tab ms min/avg/med/max` from the harness output
- Top-30 hot symbols (`tools/perf_subpatch/out/perf.txt`)
- Folded stacks for FlameGraph (`tools/perf_subpatch/out/folded.txt`)

A pass is **net-positive** only if both:

1. Median Tab time drops by ≥ 5 ms.
2. The corresponding `perf` line item drops by ≥ 50 % of its baseline share.

Regressions: re-run `./run_all.d --no-build` to confirm correctness tests
still pass (subpatch fan-out test in `tests/test_subpatch_move.d` is the
primary guard; the inline edge-origin topology test in
`source/subpatch_osd.d` guards the trace-edge mapping).

## Out of scope (intentionally)

- ImGui wire/line/text overhead: at 24K polys with a quiescent UI it sits
  at 0-1% per symbol; only dominates with `--capture 8` where rebuild
  amortises across hundreds of idle frames. Not the user's Tab pain.
- Mesa / Wayland driver share (~5%): driver floor, no D-side handle.
- Lifting the depth cap (`fed3b5a`): orthogonal — would require a
  staged stencil-table build inside OSD or going GPU-only.
