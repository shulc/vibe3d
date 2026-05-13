# Subpatch Tab — next directions

After `doc/subpatch_tab_perf_plan.md` (P0-P5, 638 → 256 ms median) and
`doc/mesh_faces_flat_refactor_plan.md` (Stages A-B', perf-flat
scaffolding for a Mesh.faces flat refactor), the bulk of vibe3d-side
wins on the Tab path are realised. The residual 256 ms breaks down
roughly as:

| Category | Share of CPU |
|---|---|
| OSD core (StencilBuilder + CpuEvalStencils + StencilTableFactory + QuadRefinement + topology_create_sharp) | **~28 %** |
| Intrinsic `memmove` (OSD's stencil-table memcpy + driver-side `glBufferData`) | ~15 % |
| `GpuMesh.upload` (already index-write into reusable scratch) | ~10 % |
| `OsdAccel.buildPreview` D-side glue | ~7 % |
| `Mesh.buildLoops` (only on subdivide / bevel paths, NOT on Tab — Tab skips it after P4) | n/a for Tab |

Further D-side micro-optimisation (Mesh.faces flat, more scratch
reuse, etc.) targets less than 5 % of the profile — practical wins
are capped at ~10-20 ms on the Tab median. To cross the next big
threshold three concrete directions are open. This doc captures each
with goal / mechanism / expected win / risk / stages, and recommends
an order to implement them in.

## Direction A — OSD refiner cache *(concrete perf win on Tab)*

**Goal.** Reuse OpenSubdiv's `Far::TopologyRefiner` across `Tab`
toggles that only flip `isSubpatch` flags on a cage whose face-
vertex topology is unchanged. Re-toggle of the same state, or
incremental selection changes, both hit the cache.

**Mechanism.** `osdc_topology_create_sharp` currently builds the
refiner AND the stencil table together. Split it in D-OpenSubdiv:

```
osdc_refiner_create(nv, nf, faceCounts, faceIndices, maxLevel)
   → osdc_refiner_t*
osdc_stencil_create(refiner, creases…, corners…)
   → osdc_stencil_t*
osdc_topology_from(refiner, stencil)
   → osdc_topology_t*  (caller still owns refiner + stencil)
```

Refiner construction is the heavy bit (the `QuadRefinement` and
`StencilTableFactory::Create` work in the post-P5 profile). The
stencil table itself is a function of (refiner, creases/corners),
much cheaper to rebuild when only sharpness markers change.

In vibe3d:

- Add `Mesh.faceTopologyVersion` — bumped on `addFace`, `removeFace`,
  `addFaceFast`, `vert.merge`, and any other mutator that changes
  the face-vertex map. **Not bumped** on `setSubpatch` (which is the
  primary Tab signal).
- `OsdAccel` keeps `osdc_refiner_t* cachedRefiner` plus the
  `faceTopologyVersion` it was built against. On `buildPreview`:
  - If `cage.faceTopologyVersion == cachedFaceTopologyVersion`,
    reuse `cachedRefiner` and build only a fresh stencil table from
    the new crease markers.
  - Else, free both, rebuild.

**Expected win.** ~30-60 ms on Tab toggles that hit the cache.
Toggle pattern in real use: user enables subpatch (cache miss,
build everything), then explores. Subsequent isSubpatch flips
(adding faces, removing faces from the subpatch set) hit the
cache and pay only the cheaper stencil-rebuild.

**Risk.**
- OSD API surface: must verify `Far::TopologyRefiner` can have its
  stencil-table recomputed against new sharpness without re-
  refining. From the OSD docs the refiner stays valid; the stencil-
  table factory takes (refiner, options) and builds afresh.
- Lifetime: refiner outlives stencil. Need clear ownership in
  `osdc_topology_t`.
- Cache invalidation: face-vertex topology changes during a session
  (bevel, subdivide command, vert.merge, load LWO) — every such
  mutator must bump `faceTopologyVersion`. Audit list:
  `mesh.d:addFace`, `addFaceFast`, `rebuildEdgesFromFaces`,
  `vert.merge`, `vert.join`, `mesh.subdivide` (which replaces the
  whole mesh — fine, mutation version bumps), `lwo.importLWO`
  (replaces whole mesh).

**Stages.**

A.1 — D-OpenSubdiv: add `osdc_refiner_create`, `osdc_stencil_create`,
      `osdc_topology_from_refiner_stencil`. Keep
      `osdc_topology_create_sharp` as a back-compat wrapper. Push
      to the github fork.
A.2 — D-OpenSubdiv unittests: build a refiner once, swap its
      stencil-table, verify limit positions update.
A.3 — vibe3d: bump dub.json submodule. Add
      `Mesh.faceTopologyVersion` + bump it everywhere face-vert
      topology mutates. **Don't** touch `topologyVersion` — that
      still drives subpatch preview invalidation as before.
A.4 — `OsdAccel.buildPreview` checks `faceTopologyVersion` and
      caches the refiner. Free the refiner only in `clear()` and
      on actual topology change.
A.5 — `tools/perf_subpatch/run.d` measure: toggle 30 times, both
      back-and-forth (cache-hits) and add-face-then-toggle (cache
      misses). Median Tab should drop on the back-and-forth case.

## Direction B — Async preview build *(UX win, no real speed-up)*

**Goal.** Make Tab feel instant on heavy meshes by running
`OsdAccel.buildPreview` on a worker thread. The actual work still
takes 200-300 ms; the main thread keeps rendering the cage (or a
stale preview) while it's in progress.

**Mechanism.**
- On Tab, snapshot cage vertices + face-vertex topology.
- Spawn a worker that calls `OsdAccel.buildPreview` against the
  snapshot. CPU-only — stencil eval on CPU, no GL context on the
  worker.
- Worker fills a fresh `Mesh preview` + `SubpatchTrace trace` on
  the heap.
- Main thread polls a `shared bool ready`; once set, takes
  ownership of the preview/trace, runs the GPU eval (which DOES
  need the main thread's GL context) to populate `limitGlVbo`, and
  rebuilds the fan-out TBOs.
- Until ready, draw the cage in subpatch-flag-shaded mode (or the
  stale preview from before Tab).

**Expected win.** UX: Tab feels instant. Real CPU cost unchanged.

**Risk.**
- Concurrency hazards: cage mutation during build. Snapshot is the
  guard — once captured, cage can move freely; the build is on
  the snapshot.
- GL-context split: workers can't touch GL. Need to move the GPU
  eval + TBO setup to a "finalise" step on the main thread after
  the worker hands off. Net main-thread cost: ~50-80 ms (GPU eval
  + TBO uploads) instead of the full 250 ms.
- Multiple Tabs in flight: queue or cancel the in-progress build
  when a new Tab fires. Simplest is "latest wins" — cancel the
  pending job and start a new one.
- Worker thread implementation: D's `std.concurrency` or
  `core.thread.Thread`. Mesh is on the main thread; worker takes
  a `shared` snapshot.

**Stages.**

B.1 — Refactor `OsdAccel.buildPreview` to split CPU work from GL
      work. CPU phase produces `Mesh preview + SubpatchTrace
      trace + scratch fan-out arrays` purely on CPU. GL phase
      takes those plus the main thread's GL context and uploads
      TBOs / runs GPU eval.
B.2 — Add a `SubpatchPreviewJob` struct: snapshot cage state,
      run CPU phase. Main thread launches via `std.parallelism.
      task!`.
B.3 — Main loop tick: if job pending, check `ready`. If ready,
      run GL finalize, swap into `SubpatchPreview`. Continue
      rendering the cage during the busy phase.
B.4 — Cancel logic: new Tab while job pending → abort old job
      (set `cancel` flag, worker checks at key points and bails),
      start new one.
B.5 — Visual indicator on cage while preview is "loading" (small
      ImGui spinner in the corner of the viewport).

## Direction C — Lift depth cap *(correctness/quality, not perf)*

**Goal.** Allow subpatch depth 3 on 24K-poly cages without OOM /
SIGBUS. Today `fed3b5a` caps depth based on a 1.5 M projected limit-
face threshold.

**Mechanism.** OSD's `Far::StencilTableFactory::Create` materialises
the entire stencil table in memory — quadratic in cage face count
× refinement level. Two routes around it:

- C.1 — **Streaming stencil eval.** Process limit-faces in chunks
        of ~64 K at a time. Build a per-chunk stencil sub-table,
        evaluate the chunk's verts, free the sub-table. Significantly
        complicates OSD's `EvalStencils` API.
- C.2 — **GPU-resident stencil table.** Build the stencil table
        directly into a GL buffer via `GLStencilTableTBO` and
        evaluate on GPU. Already half-done — Phase 3a-c wired GL
        eval. The remaining issue is the BUILD-TIME memory peak
        in OSD's `StencilTableFactory`. Migration to GPU build (if
        the OSD upstream supports it) avoids the host-memory peak.

**Expected win.** Higher quality subpatch on heavy cages. Tab cost
might go UP (more work) — this isn't a perf win, it's a feature
completeness fix.

**Risk.** Largest of the three. Touches OSD upstream or requires a
custom stencil-table builder. Defer until after A and B land.

**Stages.** Detailed in a follow-up doc once we're ready to start.

## Recommended order

**A first** (OSD refiner cache) — the highest concrete perf return
per unit of work. Splits cleanly between D-OpenSubdiv (1-2 commits)
and vibe3d (2-3 commits). Measurable Tab improvement on
back-and-forth toggle benchmarks.

**B second** (async preview build) — UX win after the actual cost
is already minimised by A. Doesn't compete with A; layers on top.

**C last** (depth cap) — biggest scope, depends on OSD upstream
choices. Not a perf direction, more a quality direction; pick
when subpatch quality on heavy cages becomes a felt issue.

## Verification methodology

Each direction has its own metric:

- **A**: extend `tools/perf_subpatch/run.d` with a `--repeat-state`
  mode that toggles to the SAME isSubpatch state N times (cache-hit
  scenario) vs the existing alternating-state mode (which is half
  cache-miss). Compare medians pre-/post-A.
- **B**: instrument the main loop's per-frame time during a Tab
  storm. Pre-B: 1 frame at ~250 ms (visible hitch). Post-B: each
  frame stays under ~16 ms (smooth) with the "loading" indicator
  visible until the build finishes.
- **C**: measure max sustainable cage face-count at depth 3 before
  OOM / SIGBUS. Today: ~6 K. Post-C: target 24 K+ at depth 3.

All three preserve all 47 HTTP + 10 inline unittest modules green at
every commit. Direction A also keeps `doc/mesh_faces_flat_refactor_plan.md`'s
pmf scenarios neutral (refiner cache doesn't touch `Mesh.faces`).
