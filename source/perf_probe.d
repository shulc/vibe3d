module perf_probe;

// ---------------------------------------------------------------------------
// PerfProbe — coarse-grained per-category timing + counters for the
// interactive-tool perf harness (doc/perf_harness_plan.md, Phase 1).
//
// The whole point is regression detection + bottleneck localization for the
// per-drag-step loop: pipeline stage evaluation, kernel apply, symmetry
// mirror, cache invalidation, GPU upload. Call sites scatter RAII scope
// timers (`auto z = g_perf.scope_(Cat.kernelApply);`) around COARSE chunks
// only — never inside a per-vertex loop (a MonoTime per vertex would
// de-vectorize the hot loop; see the plan's instrumentation rules).
//
// ZERO-COST IN THE DEFAULT BUILD. The public surface (`scope_`, `count`,
// `reset`, `toJson`) ALWAYS compiles and is callable with no `version` block
// at the call site. The implementation body is gated by `version(PerfProbe)`
// (set by the `perf` buildType). When PerfProbe is not defined, `scope_`
// returns an empty no-op struct, `count` is a no-op, `reset` a no-op, and
// `toJson` returns "{}" — so the optimizer elides every call.
//
// This is MODELING code: it imports nothing from source/render/* or
// source/material/* (render boundary).
// ---------------------------------------------------------------------------

import core.time : MonoTime, Duration;

/// Measurement categories. The first block are timers (recorded via
/// `scope_`); the trailing block are counters (recorded via `count`).
///
/// ORDINALS ARE NOT A CONTRACT — names are (task 1370). The only ordinal
/// law is the PARTITION: every timer must sit below `firstCounter` and
/// every counter at or above it, because that is what `recordNs`/`count`
/// branch on and what sizes `timers_`/`counters_`. A new TIMER therefore
/// goes at the end of the timer block — i.e. immediately BEFORE
/// `falloffEvalCount` — which shifts every counter's ordinal by one, and
/// that is fine: `counters_` is indexed relative (`c - firstCounter`),
/// both array lengths are computed from the enum at compile time,
/// `toJson` keys by member NAME, and neither `tools/perf/baseline.json`
/// nor `tools/perf/history/*.jsonl` stores an ordinal. The one place that
/// casts — `toolpipe/pipeline.d:perfCatFor` — round-trips
/// `cast(int)Cat.pipeX` back through `cast(Cat)`, so it moves with the
/// enum. Verified by grep for `cast(Cat)` / `cast(int)Cat` / `Cat.max` /
/// `Cat.min` / `to!Cat` before the 1370 insertion.
///
/// An earlier version of this comment said ordering "is stable so `toJson`
/// emits a predictable key order". It read as a contract and it was not
/// one: `toJson` emits a JSON OBJECT, whose key order no consumer may rely
/// on, and every consumer in-tree looks keys up by name. Key order does
/// change when a category is inserted mid-enum; nothing depends on it.
enum Cat {
    // --- timers ---
    pipeSymmetry,
    pipeSnap,
    pipeAcen,
    pipeAxis,
    pipeFalloff,
    pipeTotal,
    kernelApply,
    symmetryMirror,
    cacheInvalidate,
    gpuUpload,
    // snapQuery is the REAL per-drag-frame snap work: the geometric
    // candidate walk in snap.d:snapCursor (vertex/edge/grid/workplane
    // candidates projected + ranged). pipeSnap above only times the
    // SnapStage that publishes a config packet (~0); the heavy query
    // runs from the tools every motion event and is timed here.
    snapQuery,
    // commandApply times a full command apply() at the dispatch site —
    // used to bench one-shot discrete commands like mesh.delete /
    // mesh.remove (interactive transform drags use kernelApply / pipeTotal
    // instead). Must stay a TIMER (ordinal < firstCounter).
    commandApply,
    // --- draw / picking / preview timers (task 0196) ---
    drawMesh,          // foreground faces (solid/lit) draw
    drawEdges,         // foreground wireframe edge draw (+ occasional sel-edge cache)
    drawOverlays,      // selection checker + vertex dots + tool/falloff gizmo & handles
    hoverPick,         // per-frame hover pick (GPU ID-FBO + BVH face raycast)
    subpatchPreview,   // OSD subpatch preview rebuild
    // --- interactive-tool preview rebuild (task 1370) ---
    //
    // THREE timers, and the third minus the other two is the point. Sixteen
    // tools rebuild their standing preview on every drag frame / every
    // interactive attribute scrub, and every one of them has the same shape:
    //
    //     before.restore(*mesh);   // <- previewRestore
    //     <the tool's own kernel>  // <- what we actually want to watch
    //     refreshCaches();         // <- previewRefresh (the GPU upload; the
    //                              //    cache-resize half went at task 1930)
    //
    // `toolPreview` wraps the whole method; `previewRestore` and
    // `previewRefresh` are opened ONCE EACH in the two shared callees
    // (`snapshot.d:MeshSnapshot.restore`, `display_sync.d:refreshDisplay`)
    // rather than sixteen times at the tool sites. Inside a `perfReset`-
    // bounded single-attribute window there is no OTHER restore or refresh
    // running, so those two decompose the wrapper for every one of the
    // sixteen tools at the cost of two edits.
    //
    // The kernel is `toolPreview - previewRestore - previewRefresh`.
    // It is deliberately NOT `toolPreview - cacheInvalidate - gpuUpload`:
    // those two are opened in app.d's MAIN FRAME LOOP (`app.d:gpuUpload`,
    // `app.d:cacheInvalidate`), not inside the preview call, so subtracting
    // them mixes frame-loop samples into a command-path window and the sign
    // of the result depends on how many frames happened to render.
    //
    // Nesting is deliberate and the JSON keys are distinct, so there is no
    // within-category double count — only a naive cross-category SUM would
    // count the restore/refresh twice. (Until task 1930 the same caveat
    // applied to `viewcacheRebuild` nesting inside `cacheInvalidate`; that
    // inner category is gone with `viewcache.d`.)
    toolPreview,       // one whole rebuildPreview()/rebuildCut() call
    previewRestore,    // MeshSnapshot.restore — the ~16 array dups + buildLoops
    previewRefresh,    // display_sync.refreshDisplay — the gpu.upload
    // ONE `Mesh.visibilityProbe` construction — passes 0 and 1 of the snap
    // visibility mask (task 1351). A TIMER, at REQUEST granularity: one
    // open/close per built probe, never one per candidate, so the
    // instrumentation rule above ("counters, not timers" for per-element work)
    // is respected.
    //
    // WHAT IT DOES NOT COVER, said here because the obvious reading is wrong
    // and cost a gate: pass 2 — the occluder walk — is LAZY. It runs inside
    // `VisibilityProbe.visible`, which snap's gates call, i.e. OUTSIDE
    // this scope. Measured (task 1351): disabling the occluder buckets
    // multiplies pairs tested by 806x and `snapQuery` by 19x while this
    // timer's median does not move. So it bounds the O(V)+O(F) FLOOR and
    // nothing else — that is invariant I7e's job; the walk is watched by I7d,
    // which is a ratio of counters and not a time at all.
    //
    // PLACEMENT: immediately before `falloffEvalCount`, because that member IS
    // `firstCounter`. A timer appended after it is silently routed into
    // `counters_`, `recordNs` returns early, and `scope_` becomes a no-op that
    // still compiles and still reports `{"count":0,"sum":0}`. See the trap note
    // on `firstCounter` below.
    snapVisMask,
    // --- BVH pick-structure rebuild (task 1540 measurement) ------------
    //
    // `hoverPick` above times the WHOLE face pick, which is two different
    // things wearing one number: an O(log n) raycast, and — on the frame
    // after the source mesh changed — a full O(n) BVH construction over
    // the geometry the GPU rasterised (the LIMIT surface while a subpatch
    // preview is active, ~400 K faces at n=316). 1500 measured the frame
    // phase `cache` at 87-94 % of the first Tab's worst frame and named
    // this rebuild as its bulk, but the phase timer also spanned the
    // pick-cache invalidate block (deleted with `viewcache.d` in task
    // 1930), so the attribution was an inference. This timer is
    // what turns it into an observation: opened inside `BvhPick.rebuild`,
    // it is the construction and nothing else, so
    // `hoverPick - bvhRebuild` is the raycast half and
    // `cacheNs - cacheInvalidate - hoverPick` is what neither covers.
    //
    // A TIMER at CONSTRUCTION granularity — one open per rebuild, never one
    // per triangle, so the per-element instrumentation rule holds.
    //
    // PLACEMENT: still below `falloffEvalCount`, which IS `firstCounter` —
    // see the trap note on `snapVisMask` directly above.
    bvhRebuild,
    // --- counters ---
    falloffEvalCount,
    // Triangles fed to `dbvh_build` per rebuild (task 1540). A COUNTER, and
    // it is the term that decides WHICH MESH a rebuild was over: while the
    // async preview is in flight `subpatchPreview.active` is false, so the
    // hover pick answers from the CAGE and builds a cage-sized BVH that the
    // preview's arrival then throws away. Cage and limit differ by the
    // refinement factor, so `sum / count` names the mesh without a second
    // instrument -- and without it, "two rebuilds" is a number with no
    // subject.
    bvhRebuildTris,
    // The abort path's subject (task 1540): faces walked / vertices seen by a
    // rebuild that returned without calling `dbvh_build`. These read ZERO on
    // every run so far, and that is their result, not their failure: they are
    // what ruled the empty-mesh branch OUT as the explanation for the extra
    // ~385 ms sample. See `bvhRebuildEnter` for what it actually was.
    bvhAbortFaces,
    bvhAbortVerts,
    // Task 1720 — one bump on ENTRY to `BvhPick.rebuild`, before the scope
    // timer is armed. It exists because entry and exit disagreed, and it is
    // what SETTLED that disagreement, so the answer is recorded here rather
    // than left as folklore.
    //
    // THE DISAGREEMENT: `bvhRebuild.count` read 2 while the exit counters read
    // 0 aborts + 1 build. Neither instrument was broken. `ScopeTimer` cannot
    // double-count (`@disable this(this)`), and replacing it with manual
    // `recordNs` reproduced the 2 exactly.
    //
    // THE CAUSE, and it is a general hazard rather than a fact about the BVH:
    // `/api/perf/reset` is served on the HTTP THREAD and can land in the
    // MIDDLE of a long main-thread operation. A cage-sized BVH construction
    // takes ~385 ms at n=316 — an enormous window — so its entry bump was
    // wiped by the reset while its timer sample, recorded at exit, landed
    // AFTER it. One operation, its two halves on opposite sides of a window
    // boundary.
    //
    // THE CONSEQUENCE FOR ANY READER OF THIS PROBE: a perf window can be
    // inflated by the tail of an operation that began before it. `entries`
    // against `timerOpens` is how you SEE that, and the tab-cold lane prints
    // both for exactly that reason. Under task 1540's option C the same lane
    // prints `entries=0 timerOpens=1` — the straddle with the in-window build
    // now removed — which is the same artifact seen from the other side.
    bvhRebuildEnter,
    // Task 1800 — the three `Mesh.selectedVertexIndices*` builders, which
    // grow an `int[]` by APPEND over the whole mesh. Per-phase alloc
    // attribution put 99.9 % of a drag frame's 8 MB inside `events` with the
    // tool apply itself at ZERO, and these are the appenders in that phase.
    // A counter, not a timer: the question is how often they run, since one
    // call per drag is a cost and one per frame is a defect.
    selVertexIndicesBuild,
    // Task 1760 probe — how many times a DERIVED accessor is re-derived during
    // one drag. `Document.primary` is a function, not a field
    // (`nthEditTargetCandidate(0)`), and `TransformTool.computeSelectionHash`
    // rehashes the selection; a flame of `move/baseline` put them at 6.38 %
    // and 6.75 % of the profile on a ONE-LAYER document, where the walk is a
    // single loop iteration. A share that large from a body that small is a
    // CALL-COUNT statement, and these are what turn it into one.
    editTargetDerive,
    selectionHashCompute,
    vertsTouched,
    // undoApply — bumped once per successful `undo()` (Case A/B success
    // return, command_history.d:1090). A true counter (ordinal >
    // firstCounter): used by the `undo-spam` frame scenario (task 0200) to
    // assert an exact undo-apply count immune to main-loop frame batching.
    undoApply,
    // --- snap visibility mask (task 1350, extended by 1355) ---
    //
    // The five counters that make the snap mask's LAZINESS — and its
    // RELEVANCE — observable from outside the process, which is the only
    // reason they exist:
    //
    //   snapVisBuild   — one per `Mesh.visibleVertices` computation inside a
    //                    snap query. That call is O(V+F) plus ~1.4 MB of
    //                    fresh arrays on a 100K mesh, so "how many times did
    //                    a drag pay for it" IS the regression this task was
    //                    opened for.
    //   snapVisConsult — one per CONSULTATION of the mask by a candidate
    //                    (`vertVisible`/`edgeVisible`/`faceVisible`).
    //                    Zero consultations is the whole-mesh drag: every
    //                    candidate is excluded before the mask is reached, so
    //                    a build there is pure waste. "Whole-mesh case ⇒
    //                    consultations == 0" is the invariant that catches a
    //                    reader hoisting the accessor back to the top of the
    //                    walk — `build > 0 ⇒ consult > 0` cannot, because
    //                    the build happens INSIDE the consultation.
    //   snapVisReject  — one per consultation whose MASK ARRAY said no.
    //                    Separates "the mask admitted everything" from "the
    //                    mask was never consulted", which are the same
    //                    measurement without it. Excludes the front-facing
    //                    cull and the hidden-face early-out — see
    //                    `visAdmit`'s comment in snap.d for why.
    //   snapHit        — one per `snapCursor` call that actually SNAPPED,
    //                    by ANY tier.
    //   snapHitGeom    — one per `snapCursor` call where the DISCRETE tier
    //                    won with a mask-gated type (`snap.isMaskGatedType`).
    //                    `snapHit` alone cannot stand in for it: grid,
    //                    workplane and the LINE/PLANE constraints all set
    //                    `snapped` without consulting the mask, so an
    //                    all-false mask leaves `snapHit` non-zero while the
    //                    query gets CHEAPER — a regression that reads as an
    //                    improvement. This is the counter that says a
    //                    mask-gated candidate won.
    //
    // Counters, not timers: `snapQuery` already times the whole walk, and a
    // MonoTime per candidate would be exactly the per-element instrumentation
    // the plan's rules forbid.
    snapVisBuild,
    snapVisConsult,
    snapVisReject,
    snapHit,
    snapHitGeom,
    // --- subpatch preview topology cache (task 1374) ---
    //
    // `subpatchPreview` above is a TIMER opened as the FIRST statement of
    // `OsdAccel.buildPreview` — BEFORE the LRU(2) topology-cache lookup a few
    // hundred lines further down. So its `count` is "how many times
    // buildPreview was entered", and a cache HIT is indistinguishable from a
    // cold stencil build in it. That is not an oversight to work around at the
    // reader's end: from OUTSIDE the process there was no way to tell whether a
    // Tab measurement paid ~1.9 s of StencilBuilder/QuadRefinement work or 77 ms
    // of cache reuse, which makes every "cold Tab" number an assumption rather
    // than an observation. These two split it:
    //
    //   subpatchTopoMiss — one per buildPreview that BUILT a fresh OSD topology
    //                      (`lookupCachedTopology` said no). This is the
    //                      expensive path and the one a cold-path measurement
    //                      must be able to assert it took.
    //   subpatchTopoHit  — one per buildPreview that REUSED a cached topology.
    //
    // Note the third state they make visible by their absence: the LAYER-2
    // cache (`SubpatchPreview.reusablePreviewKey/Ready`, mesh.d) short-circuits
    // BEFORE buildPreview is entered at all, so a layer-2 reuse shows
    // subpatchPreview.count == 0 with both of these at 0. Hit==0 alone
    // therefore does NOT mean "a build happened"; miss==1 does.
    //
    // subpatchLevelChosen — one per buildPreview, with the EFFECTIVE
    // refinement level as its value. The depth cap
    // (`chooseSubpatchLevel`, subpatch_osd.d) can silently spend 4x the work of
    // its neighbour cage size, and until this counter the chosen level was
    // visible only in a `logWarn` line that fires ONLY when the level was
    // capped — i.e. never for the case where the cap did not bite, which is
    // exactly the expensive side of the cliff. With the gated `count == 1` of
    // the `tab-cold` scenario, `sum` IS the level.
    subpatchTopoMiss,
    subpatchTopoHit,
    subpatchLevelChosen,
    // --- snap visibility mask, part 2 (task 1351) ---
    //
    //   snapVisVertexProbe — one per DISTINCT vertex the mask actually
    //                        evaluated, i.e. per memo MISS inside
    //                        `VisibilityProbe.visible`. This is the `k`
    //                        of the cost model: the mask's occlusion pass is
    //                        O(k x |front faces|), and before laziness `k` was
    //                        V whether anyone asked or not. It is NOT the same
    //                        quantity as `snapVisConsult` — see that counter.
    //   snapVisPairsTested — one per (candidate, occluder) bbox test. The
    //                        quantity the broad phase exists to reduce, and
    //                        the only one that can tell "the buckets ran" from
    //                        "the buckets ran and returned everything": the
    //                        MASK is identical either way, by the superset
    //                        contract.
    //   snapVisGridBail    — one per probe build whose bucket grid was over
    //                        `MAX_OCCL_BUCKET_INTS` and was not built.
    //   snapVisPixelOutside— one per vertex probe whose pixel fell outside the
    //                        bucketed domain and took the linear walk. The
    //                        linear arm is LIVE, not a backstop: `edgeVisible`
    //                        asks about BOTH endpoints of an edge the cursor's
    //                        neighbourhood gathered, and Edge is an EXTENT
    //                        kind, so a LONG edge's far endpoint can be
    //                        hundreds of pixels away. It is not, however,
    //                        "non-zero on any Edge case" — measured 0 on the
    //                        perf grid plane at n=316, whose edges project to
    //                        ~2 px so both ends are always inside the domain.
    //                        It takes long edges, which that fixture has none
    //                        of; `tests/unit/snap_visibility_corpus_test.d`'s
    //                        `longedge` fixture is where the arm is exercised.
    snapVisVertexProbe,
    snapVisPairsTested,
    snapVisGridBail,
    snapVisPixelOutside,
    // --- epoch-keyed derived-cache REBUILD RATES (task 2000) -------------
    //
    // Two rebuilds that are O(V) each and whose only failure mode is a RATE.
    // Both caches stay CORRECT however often they are rebuilt, so no value
    // assertion anywhere can see the regression they exist to catch: between
    // 2026-08-25 18:45 and 19:54 the candidate grid went from one build per
    // drag to one per drag STEP, and the five `#snapQuery` perf cases went
    // +715..+1204 % with per-case allocation at exactly x20 = the step count.
    //
    //   snapGridBuild     — one per `snap.buildCandidateGrid`, i.e. per
    //                       (slot, kind) grid actually rebuilt. `snapQuery`
    //                       above times the whole walk and cannot separate
    //                       "the query was slow" from "the query rebuilt the
    //                       buckets"; this is the term that does.
    //   symPairingRebuild — one per `SymmetryStage.evaluate` that re-ran
    //                       `rebuildPairing` / `rebuildPairingTopological`.
    //                       `pipeSymmetry` times the stage, which is ~0 on a
    //                       cache hit and ~51 ms on a miss, so the timer's
    //                       MEDIAN hides the miss entirely — only a count
    //                       says how many misses there were.
    //
    // Counters, not timers, and for the same reason `bvhRebuildTris` is one:
    // the question is HOW OFTEN, and both sites already sit inside a timer.
    // The always-on `__gshared` twins of these two
    // (`snap.g_snapGridBuilds`, `toolpipe.stages.symmetry.g_symPairingRebuilds`,
    // read over `/api/cache/rebuilds`) are what the SUITE lane asserts on —
    // this probe is compiled out of every build but `perf`.
    snapGridBuild,
    symPairingRebuild,
}

/// First counter category. Categories with ordinal < this are timers.
///
/// PLACEMENT TRAP for anyone extending `Cat`: this split is what routes a
/// category into `timers_` (ordinal < firstCounter) or `counters_` (ordinal
/// >= firstCounter), and NOTHING checks that a new member landed in the half
/// its call sites use. A TIMER appended after `firstCounter` is silently
/// routed into `counters_`, `recordNs` returns early, and its `scope_` becomes
/// a no-op that still compiles and still reports `{"count":0,"sum":0}`. Append
/// COUNTERS at the very end (as task 1374's three above); insert TIMERS before
/// `falloffEvalCount`.
private enum Cat firstCounter = Cat.falloffEvalCount;

// The trap above, made a compile error for the categories added since it was
// written. `count`/`recordNs` branch on this partition at RUNTIME and each
// silently returns on the wrong side, so a misplaced member reports
// `{"count":0,...}` forever and no test can tell it from a call site that
// never fired. These two lines cost nothing and fail the build instead.
static assert(Cat.snapVisMask < firstCounter,
    "Cat.snapVisMask is a TIMER and must sit before firstCounter");
static assert(Cat.snapVisVertexProbe  >= firstCounter
           && Cat.snapVisPairsTested  >= firstCounter
           && Cat.snapVisGridBail     >= firstCounter
           && Cat.snapVisPixelOutside >= firstCounter,
    "the task-1351 snap-visibility counters must sit at or after firstCounter");

// ---------------------------------------------------------------------------
// FrameProbe — per-frame ring buffer for whole-main-loop timing (task 0195,
// milestone F1, doc/frame_probe_scenarios_plan.md). Sibling to PerfProbe
// above: PerfProbe times coarse chunks WITHIN a drag/command; FrameProbe
// times the WHOLE `while (running)` iteration in app.d, split into six
// disjoint-ish phases, plus GC deltas. Same zero-cost gate/stub shape.
//
// Phase-map note (see the beginFrame/endFrame call sites in app.d for the
// authoritative line-by-line mapping): phase fields are INDEPENDENT per-frame
// accumulators, not a strict partition of totalNs. `toolNs` is the one
// deliberate nest (⊆ eventNs — it times the live geometry apply inside the
// event/replay-dispatch region). `drawNs` is a disjoint TOP-LEVEL phase that
// runs sequentially BEFORE `uiNs` (a blit block sits between them) — it is
// NOT a sub-slice of uiNs. `totalNs` is measured from `beginFrame` (top of
// the loop) to `endFrame`, which is placed BEFORE the present/flush
// conditional so `totalNs` is pure CPU submission cost in both `--test` and
// `--perf` run modes (present/vsync/SDL_Delay excluded either way). Do NOT
// "fix" per-phase fields into summing to totalNs, or re-nest drawNs under
// uiNs — the remainder is reported as `other = totalNs - (eventNs + cacheNs
// + uploadNs + drawNs + uiNs)` by the caller (toolNs excluded from that sum,
// since it double-counts inside eventNs).
// ---------------------------------------------------------------------------

/// One frame's coarse phase-timing + GC-delta record. POD — used both as the
/// ring-buffer element and as the "worst frame" / "worstN" breakdown emitted
/// by `/api/frames`.
struct FrameRec {
    long totalNs;
    long eventNs;
    long toolNs;
    long cacheNs;
    long drawNs;
    long uploadNs;
    long uiNs;
    long gcAllocBytes;
    long gcCollections;
    // ---- Task 2070: WHAT THE COLLECTIONS COST ------------------------
    //
    // `gcCollections` above counts collections; it has never said what one
    // COST. For an interactive editor that is the wrong half of the fact:
    // the 60 fps budget is 16.7 ms per frame, so what decides the question
    // is not how many collections ran but whether ONE of them stopped the
    // world for longer than the frame had left. Four collections of 200 us
    // are invisible to a user; one of 40 ms is a visible stutter, and both
    // shapes read the same on `gcCollections`.
    //
    // All three come from the SAME `GC.profileStats()` call the collection
    // count already makes (one call per beginFrame/endFrame, not one per
    // field), so they are free.
    //
    // PROCESS-GLOBAL, NOT PER-THREAD — and unlike `gcAllocBytes` beside
    // them there is no per-thread variant to choose instead. druntime keeps
    // ONE set of pause figures for the whole process, so an allocation on a
    // render worker (`--config=with-render`'s IPR thread) or on the HTTP
    // thread that triggers a collection lands in THIS frame's pause figure.
    // That is the right answer for the question being asked — a
    // stop-the-world pause stops the main loop no matter who triggered it,
    // exactly the asymmetry `gcCollections` was already documented to want
    // below — but it is the WRONG number to attribute to main-loop code:
    // a frame whose own work allocated nothing can still show a pause here.
    // Where it matters: reading these off a `with-render` build during a
    // live IPR render attributes the renderer's collections to the frame
    // that happened to be in flight.
    long gcMaxPauseNs;      // worst SINGLE pause in this frame (see gcWindowMaxPauseNs)
    long gcPauseNs;         // this frame's stop-the-world total
    long gcCollectNs;       // this frame's total collection time (>= gcPauseNs)
    // ---- Task 1800: WHICH PHASE ALLOCATED ----------------------------
    //
    // `gcAllocBytes` above says a frame allocated; it has never said WHERE.
    // A `perf` capture cannot close that either — the allocator entry points
    // resolve no callers through this build's inlining, tried and failed —
    // and the GC mark phase is 5.4 % of a drag profile, which is a cost
    // driven entirely by allocation RATE. So the attribution has to come
    // from the same place the timing attribution already comes from: the
    // phase scopes.
    //
    // These are alloc deltas around each `phase()` scope, in the same six
    // buckets the ns fields use, so a reader compares like with like. NOT a
    // partition of `gcAllocBytes`: the phases do not tile the frame (there
    // is un-phased work between them) and `toolNs` deliberately NESTS inside
    // `eventNs`, so tool bytes are counted in events too. Same caveat the
    // ns side carries, and for the same reason.
    long eventAlloc;
    long toolAlloc;
    long cacheAlloc;
    long drawAlloc;
    long uploadAlloc;
    long uiAlloc;
}

/// Per-frame phase categories timed by `FrameProbe.phase()`. Distinct from
/// `Cat` above (PerfProbe's per-drag-step categories): `Cat` measures coarse
/// chunks inside a single drag/command; `Phase` measures the whole main-loop
/// frame the drag/command runs inside of.
enum Phase { events, tool, cache, draw, upload, ui }

/// By-value snapshot of `FrameProbe`'s running (ring-eviction-proof) counters
/// — task 0198 (perf HUD). Declared at module scope (outside `version
/// (PerfProbe)`) so both builds share one type; the default build's
/// `FrameProbe.stats()` stub returns `FrameStatsSnapshot.init`.
struct FrameStatsSnapshot {
    long frameCount;
    long hitch16;
    long hitch33;
    long sumAllocBytes;
    long sumCollections;
    long meshCacheRebuilds;
    // Task 2070. `sumPauseNs` is summable across frames (it is a delta of a
    // counter); `maxPauseNs` is NOT — it is the running worst over the
    // window, which is the figure a 16.7 ms budget question actually wants.
    long sumPauseNs;
    long maxPauseNs;
}

// ===========================================================================
// Task 2070 — GC PAUSE / ALLOCATION SAMPLING, always compiled.
//
// `GC.profileStats()` hands back FIVE fields and this module used to keep
// exactly one of them (`numCollections`). The four it dropped are the ones
// that answer the only GC question an interactive editor has: not "did the
// collector run" but "did it stop the world for longer than a frame".
//
// Everything in this section is OUTSIDE `version (PerfProbe)` on purpose.
// `FrameProbe` and `PerfProbe` are compiled out of every build but `perf`,
// so a witness written against them can only run in a build the two default
// gates never make. The pure derivation below and `CommandGcProbe` are
// therefore always present, and are testable in the DEFAULT build.
// ===========================================================================

/// One reading of the process's GC counters. `allocBytes` is the only
/// PER-THREAD field; the other four are process-global (see FrameRec).
struct GcSample {
    long allocBytes;      // GC.allocatedInCurrentThread — THIS thread only
    long collections;     // process-global, monotone counter
    long totalPauseNs;    // process-global, monotone counter
    long maxPauseNs;      // process-global RUNNING MAX — see gcWindowMaxPauseNs
    long totalCollectNs;  // process-global, monotone counter
}

/// Read all five counters in ONE `GC.profileStats()` call. Not `@nogc`:
/// `GC.allocatedInCurrentThread` is documented `nothrow` only.
GcSample gcSampleNow() nothrow {
    import core.memory : GC;
    auto p = GC.profileStats();
    GcSample s;
    s.allocBytes     = cast(long) GC.allocatedInCurrentThread;
    s.collections    = cast(long) p.numCollections;
    s.totalPauseNs   = p.totalPauseTime.total!"nsecs";
    s.maxPauseNs     = p.maxPauseTime.total!"nsecs";
    s.totalCollectNs = p.totalCollectionTime.total!"nsecs";
    return s;
}

/// The worst SINGLE stop-the-world pause inside a bracketed window, in ns,
/// derived from the two `GcSample`s that bracket it.
///
/// THE TRAP THIS FUNCTION EXISTS FOR: `maxPauseTime` is a process-wide
/// RUNNING MAX, not a counter, so subtracting two samples of it is
/// meaningless. A window containing a 5 ms pause reads a delta of ZERO
/// whenever some earlier window already saw 6 ms — i.e. the naive
/// `after - before` under-reports exactly the frames a 16.7 ms budget cares
/// about most, and does it silently. The three honest cases:
///
///   * `collDelta <= 0` — no collection ran, so no pause happened: 0.
///   * the running max GREW — the pause that grew it is by definition the
///     largest the process has seen AND it happened inside this window, so
///     the window's worst pause is EXACTLY the new max.
///   * the running max stood still — every pause here was <= the standing
///     max, and the only exact figure this window owns is its pause TOTAL.
///     With k collections the worst lies in [total/k, total]; we report the
///     TOTAL, which is EXACT for k == 1 (overwhelmingly the common case)
///     and an OVER-estimate for k > 1. Over, never under: this number
///     answers "did anything here blow the frame budget", where a false
///     alarm costs a second look and a miss costs the whole instrument.
///
/// HOW LOOSE THAT THIRD CASE GETS, measured rather than guessed (task 2070):
/// `mesh.duplicate` over half a 316x316 grid ran 59 collections in ONE
/// command and this function reported 391 ms, while the same command in a
/// window where the running max DID grow reported its true single worst
/// pause as 7.2 ms over 234 collections — a 54x over-estimate in the k >> 1
/// case. That is the safe direction, but it is not a small correction, so:
///
///   * For a FRAME this is effectively exact. k is 0 or 1 for virtually
///     every frame, which is the case this field was added to answer.
///   * For a whole COMMAND, read `gcMaxPauseNs` WITH the collection count
///     beside it. Both are published (`gcCollections` / `lastCollections`)
///     and the ops lane prints them on the same line for this reason. At
///     k > 1 treat it as a bound, not a measurement.
///
/// druntime publishes no per-collection histogram, so a tighter answer for
/// k > 1 is not available from `ProfileStats` at all — this is the limit of
/// the data, not a shortcut.
long gcWindowMaxPauseNs(long maxBeforeNs, long maxAfterNs,
                        long pauseDeltaNs, long collDelta)
        pure nothrow @nogc @safe {
    if (collDelta <= 0) return 0;
    if (maxAfterNs > maxBeforeNs) return maxAfterNs;
    return pauseDeltaNs;
}

/// The main loop's thread, recorded once at startup by `app.d`. Read by
/// `CommandGcProbe` to answer "was this bracket taken on the thread that
/// actually ran the work" — see `offMainThreadBrackets`.
__gshared size_t g_mainLoopThreadId;

/// Record the calling thread as the main loop's. Called once from app.d.
void markMainLoopThread() nothrow {
    g_mainLoopThreadId = currentThreadId();
}

/// A stable per-thread identity. The `Thread` object's address is unique
/// and constant for the life of the thread on every platform we ship, and
/// reading it is a TLS load — no allocation, no syscall.
size_t currentThreadId() nothrow {
    import core.thread.osthread : Thread;
    try {
        return cast(size_t) cast(void*) Thread.getThis();
    } catch (Throwable) {
        return 0;
    }
}

// ---------------------------------------------------------------------------
// CommandGcProbe — what ONE command cost the collector.
//
// WHY THE BRACKET IS WHERE IT IS, and this is the whole correctness story
// for the allocation column: `GC.allocatedInCurrentThread` is PER-THREAD.
// `/api/command` ARRIVES on the HTTP background thread, but it does NOT RUN
// there — the route is `Answered.mainThread`, so the HTTP thread only fills
// a request slot, bumps a submit epoch and spins, and the command body is
// executed by `MainThreadBridge.tick()` from the main loop. Sampling on the
// HTTP thread would therefore read that thread's own allocation (the request
// parse, the response buffer) and NOTHING of the command — a small, stable,
// entirely plausible-looking number unrelated to the work. The bracket
// consequently lives inside the bridge's SERVICE body, which runs on the
// main loop, and `lastThreadId` / `offMainThreadBrackets` below keep that
// claim checkable at runtime instead of resting on this comment.
//
// The counters are monotone and never reset, like `/api/cache/rebuilds`'s.
// The `last*` fields are the most recent command's OWN figures, which is
// what a per-case harness column wants: the ops lane fires exactly one
// command per repeat and reads them straight, with `commands` as the
// anti-vacuity check that a bracket fired at all.
// ---------------------------------------------------------------------------
struct CommandGcProbe {
    // Running totals over every command since process start.
    ulong commands;
    long  sumAllocBytes;
    long  sumCollections;
    long  sumPauseNs;
    long  runMaxPauseNs;      // running max — NOT summable, NOT delta-able

    // The most recent command's own figures.
    long  lastAllocBytes;
    long  lastCollections;
    long  lastPauseNs;
    long  lastMaxPauseNs;
    long  lastCollectNs;

    // Bracketing provenance — the runtime half of the thread argument above.
    size_t lastThreadId;
    ulong  offMainThreadBrackets;

    private GcSample base_;
    private int      depth_;

    /// Open the bracket. Nested dispatches (a command that fires another)
    /// do NOT re-arm: the OUTERMOST bracket owns the window, or an inner
    /// command would reset the base and the outer one would report only its
    /// own tail.
    void begin() nothrow {
        if (depth_++ != 0) return;
        base_ = gcSampleNow();
    }

    /// Close the bracket and publish. Safe to call unbalanced-ly (a throw
    /// inside the dispatch is caught by the bridge, but `end()` is called
    /// from a `scope(exit)` so the depth cannot leak).
    void end() nothrow {
        if (--depth_ != 0) {
            if (depth_ < 0) depth_ = 0;   // never let an unbalanced end wedge it
            return;
        }
        auto now = gcSampleNow();
        immutable long dAlloc = now.allocBytes    - base_.allocBytes;
        immutable long dColl  = now.collections   - base_.collections;
        immutable long dPause = now.totalPauseNs  - base_.totalPauseNs;
        immutable long dCollNs= now.totalCollectNs - base_.totalCollectNs;
        immutable long mx     = gcWindowMaxPauseNs(base_.maxPauseNs,
                                                   now.maxPauseNs, dPause, dColl);
        lastAllocBytes  = dAlloc;
        lastCollections = dColl;
        lastPauseNs     = dPause;
        lastMaxPauseNs  = mx;
        lastCollectNs   = dCollNs;

        commands++;
        sumAllocBytes  += dAlloc;
        sumCollections += dColl;
        sumPauseNs     += dPause;
        if (mx > runMaxPauseNs) runMaxPauseNs = mx;

        lastThreadId = currentThreadId();
        if (g_mainLoopThreadId != 0 && lastThreadId != g_mainLoopThreadId)
            offMainThreadBrackets++;
    }

    /// JSON for `GET /api/gc/commands`.
    string toJson() const {
        import std.format : format;
        return format(
            `{"commands":%d,"sumAllocBytes":%d,"sumCollections":%d,` ~
            `"sumPauseNs":%d,"runMaxPauseNs":%d,"lastAllocBytes":%d,` ~
            `"lastCollections":%d,"lastPauseNs":%d,"lastMaxPauseNs":%d,` ~
            `"lastCollectNs":%d,"lastThreadId":%d,"mainLoopThreadId":%d,` ~
            `"offMainThreadBrackets":%d}`,
            commands, sumAllocBytes, sumCollections, sumPauseNs,
            runMaxPauseNs, lastAllocBytes, lastCollections, lastPauseNs,
            lastMaxPauseNs, lastCollectNs, lastThreadId,
            g_mainLoopThreadId, offMainThreadBrackets);
    }
}

/// Process-wide per-command GC probe. Written on the main loop from the
/// HTTP command bridge's service body, read from the HTTP thread
/// (GET /api/gc/commands) — same no-lock diagnostic contract as `g_perf`.
__gshared CommandGcProbe g_commandGc;

version (PerfProbe) {

    // -----------------------------------------------------------------------
    // Active implementation (perf buildType).
    // -----------------------------------------------------------------------

    /// RAII scope timer. Records elapsed MonoTime into its category on
    /// destruction. Construct via `g_perf.scope_(Cat.x)`; let it die at
    /// end of scope. Non-copyable so the stop time is taken exactly once.
    struct ScopeTimer {
        private MonoTime start_;
        private ulong    allocStart_;   // task 1800
        private Cat cat_;
        private bool armed_;

        @disable this(this);

        ~this() {
            if (!armed_) return;
            const elapsed = MonoTime.currTime - start_;
            g_perf.recordNs(cat_, elapsed.total!"nsecs");
            // Task 1800 — the alloc delta over the same scope, so every
            // existing timer answers "and how much did it allocate" for free.
            // The frame-phase probe put 99.9 % of a drag frame's 8 MB inside
            // `events` with the tool apply at ZERO, which named a phase but
            // not a call; these scopes are the finer grain inside it.
            import core.memory : GC;
            g_perf.recordAlloc(cat_,
                cast(long)(GC.allocatedInCurrentThread - allocStart_));
        }
    }

    /// Ring-buffer + running stats for one timer category. Samples feed
    /// median / p95 (computed lazily in toJson); the running min/max/sum
    /// stay exact across the whole run regardless of ring eviction.
    private struct TimerStat {
        enum size_t Ring = 4096;
        long count;
        long sum;
        long min = long.max;
        long max = long.min;
        long[Ring] ring;
        size_t ringLen;   // number of valid entries (<= Ring)
        size_t ringPos;   // next write index

        void add(long ns) {
            count++;
            sum += ns;
            if (ns < min) min = ns;
            if (ns > max) max = ns;
            ring[ringPos] = ns;
            ringPos = (ringPos + 1) % Ring;
            if (ringLen < Ring) ringLen++;
        }

        void clear() { this = TimerStat.init; }
    }

    /// Running totals for one counter category.
    private struct CounterStat {
        long count;   // number of count() calls
        long sum;     // accumulated value
        void add(long n) nothrow @nogc { count++; sum += n; }
        void clear() { this = CounterStat.init; }
    }

    struct PerfProbe {
        private TimerStat[firstCounter]              timers_;
        private long[firstCounter]                   allocs_;   // task 1800
        private CounterStat[Cat.max + 1 - firstCounter] counters_;

        /// Open a scope timer for `c`. Records on destruction.
        ScopeTimer scope_(Cat c) {
            import core.memory : GC;
            ScopeTimer z;
            z.cat_ = c;
            z.armed_ = true;
            z.allocStart_ = GC.allocatedInCurrentThread;   // task 1800
            z.start_ = MonoTime.currTime;
            return z;
        }

        /// Add `n` to a counter category (vertsTouched / falloffEvalCount).
        /// No-op (with a debug consistency check) if `c` is a timer.
        void count(Cat c, long n) nothrow @nogc {
            if (c < firstCounter) {
                debug assert(false, "perf_probe.count called on a timer category");
                return;
            }
            counters_[c - firstCounter].add(n);
        }

        /// Internal: record an elapsed-ns sample into a timer category.
        /// Called by ScopeTimer.~this. No-op if `c` is a counter.
        /// Task 1800 — accumulated GC bytes for a TIMER category. Lives
        /// beside the ns total rather than in a counter, because the question
        /// it answers is about the same scope.
        void recordAlloc(Cat c, long b) {
            if (c >= firstCounter) return;
            allocs_[c] += b;
        }

        void recordNs(Cat c, long ns) {
            if (c >= firstCounter) return;
            timers_[c].add(ns);
        }

        /// Zero every category. Call before a measured run
        /// (POST /api/perf/reset).
        void reset() {
            foreach (ref t; timers_)   t.clear();
            allocs_[] = 0;                                    // task 1800
            foreach (ref cc; counters_) cc.clear();
        }

        /// JSON breakdown: each timer → {count, sum_ns, min_ns, max_ns,
        /// median_ns, p95_ns}; each counter → {count, sum}. Computed on
        /// demand so the hot path never sorts.
        string toJson() {
            import std.array  : appender;
            import std.format : formattedWrite;
            import std.algorithm : sort;

            auto app = appender!string();
            app.put("{");
            bool first = true;

            void comma() {
                if (!first) app.put(",");
                first = false;
            }

            // Timers.
            static foreach (i, member; __traits(allMembers, Cat)) {{
                enum Cat c = __traits(getMember, Cat, member);
                static if (c < firstCounter) {
                    auto t = timers_[c];   // copy so we can sort the ring
                    long median = 0, p95 = 0;
                    if (t.ringLen > 0) {
                        long[] samples = t.ring[0 .. t.ringLen].dup;
                        samples.sort();
                        median = samples[samples.length / 2];
                        size_t p95idx = cast(size_t)((samples.length - 1) * 95 / 100);
                        p95 = samples[p95idx];
                    }
                    comma();
                    app.formattedWrite(
                        `"%s":{"count":%d,"sum_ns":%d,"min_ns":%d,"max_ns":%d,` ~
                        `"median_ns":%d,"p95_ns":%d,"alloc_bytes":%d}`,
                        member, t.count, t.sum,
                        t.count > 0 ? t.min : 0,
                        t.count > 0 ? t.max : 0,
                        median, p95,
                        allocs_[__traits(getMember, Cat, member)]);
                }
            }}

            // Counters.
            static foreach (member; __traits(allMembers, Cat)) {{
                enum Cat c = __traits(getMember, Cat, member);
                static if (c >= firstCounter) {
                    auto cc = counters_[c - firstCounter];
                    comma();
                    app.formattedWrite(
                        `"%s":{"count":%d,"sum":%d}`,
                        member, cc.count, cc.sum);
                }
            }}

            app.put("}");
            return app.data;
        }
    }

    // -------------------------------------------------------------------
    // FrameProbe — active implementation.
    // -------------------------------------------------------------------

    import core.memory : GC;

    /// RAII scope timer for one `Phase` within the current frame. Mirrors
    /// `ScopeTimer` above but ADDS into `g_frames`'s current-frame
    /// accumulator (`addPhase`) rather than a ring sample directly — a phase
    /// can be entered more than once per frame (e.g. `drawNs` across an
    /// N-cell viewport loop) and the accumulator sums them.
    struct PhaseTimer {
        private MonoTime start_;
        private ulong    allocStart_;   // task 1800
        private Phase p_;
        private bool armed_;

        @disable this(this);

        ~this() {
            if (!armed_) return;
            const elapsed = MonoTime.currTime - start_;
            g_frames.addPhase(p_, elapsed.total!"nsecs");
            // Task 1800 — the alloc delta over the same scope. A TLS read
            // either side, which is why this can sit on a per-phase scope
            // and could not sit on a per-element one.
            import core.memory : GC;
            g_frames.addPhaseAlloc(p_,
                cast(long)(GC.allocatedInCurrentThread - allocStart_));
        }
    }

    struct FrameProbe {
        enum size_t Ring = 8192;

        private FrameRec[Ring] ring;
        private size_t ringLen;    // number of valid entries (<= Ring)
        private size_t ringPos;    // next write index

        // Running counters, exact across the whole run regardless of ring
        // eviction (mirrors TimerStat's count/sum split above).
        private long frameCount;
        private long hitch16;      // frames with totalNs > 16.6ms
        private long hitch33;      // frames with totalNs > 33ms
        private long sumAllocBytes;
        private long sumCollections;
        // Task 2070 — the pause twins. `sumPauseNs` accumulates (a delta of
        // a counter); `maxPauseNs` is the running WORST over the window, and
        // is deliberately NOT a sum: "one frame paused for 40 ms" is the
        // fact, and summing it away into a window total hides it.
        private long sumPauseNs;
        private long maxPauseNs;
        private long hitchGc16;    // frames whose OWN GC pause blew 16.6 ms
        private long meshCacheRebuilds;
        // Task 1540 — the `cache` PHASE summed over the window, so the
        // window-wide `Cat.*` sums off /api/perf (which is the only
        // granularity those have) can be compared against the phase they are
        // supposed to decompose. Without it the comparison is a window sum
        // against a single worst frame, which is not a decomposition of
        // anything.
        private long sumCacheNs;

        // In-flight frame state.
        private FrameRec  cur_;
        private MonoTime  frameStart_;
        private ulong     allocBase_;
        private size_t    collBase_;
        // Task 2070 — the other three counters from the SAME profileStats()
        // call `collBase_` already comes from. No extra GC call.
        private long      pauseBase_;
        private long      maxPauseBase_;
        private long      collectNsBase_;

        /// Start a new frame. Call as the FIRST statement inside
        /// `while (running)` in app.d.
        void beginFrame() {
            cur_ = FrameRec.init;
            frameStart_ = MonoTime.currTime;
            allocBase_  = GC.allocatedInCurrentThread;
            // ONE profileStats() call for all four process-global bases —
            // it used to be called here for `numCollections` alone and the
            // other four fields were discarded (task 2070).
            auto pb = GC.profileStats();
            collBase_      = pb.numCollections;
            pauseBase_     = pb.totalPauseTime.total!"nsecs";
            maxPauseBase_  = pb.maxPauseTime.total!"nsecs";
            collectNsBase_ = pb.totalCollectionTime.total!"nsecs";
        }

        /// Open a scope timer for phase `p`. Records into `cur_` on
        /// destruction; multiple opens of the same phase within one frame
        /// (e.g. `draw` across an N-cell render loop) accumulate.
        PhaseTimer phase(Phase p) {
            import core.memory : GC;
            PhaseTimer z;
            z.p_ = p;
            z.armed_ = true;
            z.allocStart_ = GC.allocatedInCurrentThread;   // task 1800
            z.start_ = MonoTime.currTime;
            return z;
        }

        /// Internal: add `ns` into the current frame's field for `p`.
        /// Called by PhaseTimer.~this.
        void addPhase(Phase p, long ns) {
            final switch (p) {
                case Phase.events: cur_.eventNs  += ns; break;
                case Phase.tool:   cur_.toolNs   += ns; break;
                case Phase.cache:  cur_.cacheNs  += ns; break;
                case Phase.draw:   cur_.drawNs   += ns; break;
                case Phase.upload: cur_.uploadNs += ns; break;
                case Phase.ui:     cur_.uiNs     += ns; break;
            }
        }

        /// Task 1800 — the alloc twin of `addPhase`, same buckets, same
        /// accumulate-on-reopen behaviour.
        void addPhaseAlloc(Phase p, long b) {
            final switch (p) {
                case Phase.events: cur_.eventAlloc  += b; break;
                case Phase.tool:   cur_.toolAlloc   += b; break;
                case Phase.cache:  cur_.cacheAlloc  += b; break;
                case Phase.draw:   cur_.drawAlloc   += b; break;
                case Phase.upload: cur_.uploadAlloc += b; break;
                case Phase.ui:     cur_.uiAlloc     += b; break;
            }
        }

        /// F-I1 counter: bump when a mesh-driven cache rebuild / GPU upload
        /// fires this frame (see the two call sites in app.d's cache block
        /// + the gpu.upload sites in the upload block — NOT the
        /// camera-reprojection branch, which is gated `!doingCameraDrag`
        /// and skipped entirely during an orbit).
        void bumpMeshCacheRebuild() { meshCacheRebuilds++; }

        /// Copy the most-recent COMMITTED frames into `dst` (oldest→newest),
        /// up to `min(dst.length, ringLen)`. Returns the number copied. No
        /// allocation — `dst` is a caller-preallocated buffer (task 0198's
        /// HUD owns one). Read-only; does not touch `ringPos`/`ringLen`.
        //
        // Same benign-tear, no-lock diagnostic-read contract as `toJson`
        // above (and as documented on `endFrame`'s write-then-advance
        // comment): this reader runs on the MAIN thread, before the current
        // frame's own `endFrame()` commits, so the newest fully-written slot
        // it can see is frame N-1 — no intra-thread race. It follows the same
        // "read ringLen, then copy" discipline as the HTTP thread's `toJson`
        // even though the HUD's own reads never race the writer (main thread
        // reads its own prior writes) — kept for symmetry/defensiveness, not
        // because it is required here. No new lock is added; ringLen/ringPos
        // stay lock-free like every other FrameProbe field.
        size_t copyRecent(FrameRec[] dst) {
            size_t len = ringLen;   // snapshot once
            size_t n = dst.length < len ? dst.length : len;
            // newest committed slot is (ringPos - 1); walk back n, emit
            // oldest-to-newest into dst[0 .. n).
            foreach (i; 0 .. n) {
                size_t src = (ringPos + Ring - (n - i)) % Ring;
                dst[i] = ring[src];
            }
            return n;
        }

        /// By-value snapshot of the running (ring-eviction-proof) counters.
        /// No allocation.
        FrameStatsSnapshot stats() const {
            return FrameStatsSnapshot(frameCount, hitch16, hitch33,
                sumAllocBytes, sumCollections, meshCacheRebuilds,
                sumPauseNs, maxPauseNs);
        }

        /// Close the frame: stamp totalNs + GC deltas, then commit `cur_`
        /// into the ring. Call BEFORE the present/flush conditional in
        /// app.d's main loop (see the phase-map note above) so `totalNs`
        /// excludes SwapWindow/glFlush/SDL_Delay in both `--test` and
        /// `--perf`.
        //
        // Single-writer discipline for the lockless HTTP read: write the
        // FULL record into `ring[ringPos]` FIRST, THEN advance `ringPos`,
        // THEN bump `ringLen`. A racy reader that snapshots `ringLen` before
        // reading `ring[0 .. len]` therefore only ever sees fully-written
        // slots — worst case it misses the single newest frame. No lock.
        void endFrame() {
            cur_.totalNs = (MonoTime.currTime - frameStart_).total!"nsecs";
            // GC-metric asymmetry is DELIBERATE (see the plan's Risks
            // section): gcCollections uses the GLOBAL collection count (a
            // stop-the-world hitch stalls the main loop regardless of which
            // thread triggered it); gcAllocBytes uses the MAIN-THREAD-ONLY
            // allocatedInCurrentThread (per-frame allocation is a main-loop
            // property). GC.allocatedInCurrentThread is `nothrow` only (NOT
            // @nogc/@safe) but reads a running per-thread counter without
            // allocating, so it is safe on this hot path.
            cur_.gcAllocBytes  = cast(long)(GC.allocatedInCurrentThread - allocBase_);
            // Task 2070 — one call, four fields, matching beginFrame's base.
            auto pe = GC.profileStats();
            cur_.gcCollections = cast(long)(pe.numCollections - collBase_);
            cur_.gcPauseNs     = pe.totalPauseTime.total!"nsecs" - pauseBase_;
            cur_.gcCollectNs   = pe.totalCollectionTime.total!"nsecs" - collectNsBase_;
            // NOT `maxAfter - maxBefore`: maxPauseTime is a running max, and
            // that subtraction reads 0 for any frame whose pause failed to
            // beat the process record. See gcWindowMaxPauseNs.
            cur_.gcMaxPauseNs  = gcWindowMaxPauseNs(
                maxPauseBase_, pe.maxPauseTime.total!"nsecs",
                cur_.gcPauseNs, cur_.gcCollections);

            ring[ringPos] = cur_;                 // write FIRST
            ringPos = (ringPos + 1) % Ring;        // then advance
            if (ringLen < Ring) ringLen++;         // then publish

            frameCount++;
            if (cur_.totalNs > 16_600_000) hitch16++;
            if (cur_.totalNs > 33_000_000) hitch33++;
            sumAllocBytes  += cur_.gcAllocBytes;
            sumCollections += cur_.gcCollections;
            sumPauseNs     += cur_.gcPauseNs;
            if (cur_.gcMaxPauseNs > maxPauseNs) maxPauseNs = cur_.gcMaxPauseNs;
            if (cur_.gcMaxPauseNs > 16_600_000) hitchGc16++;
            sumCacheNs     += cur_.cacheNs;
        }

        /// Zero the ring + every published counter. Call before a measured
        /// run (POST /api/frames/reset).
        //
        // Deliberately does NOT touch `cur_` / `frameStart_` / `allocBase_`
        // / `collBase_` — those are the main thread's IN-FLIGHT frame state
        // between a `beginFrame()`/`endFrame()` pair. `reset()` is called
        // from the HTTP thread (mirrors `/api/perf/reset`'s g_perf.reset()),
        // so it can land mid-frame; a wholesale `this = FrameProbe.init`
        // would zero `frameStart_` out from under the main thread's
        // in-progress frame, and the next `endFrame()` would then compute
        // `MonoTime.currTime - MonoTime.init` — a many-hour "elapsed"
        // garbage sample. Only the published ring/counters are reset; the
        // ring is not physically cleared (reads are gated by `ringLen`, so
        // stale slots beyond it are never read).
        void reset() {
            ringLen = 0;
            ringPos = 0;
            frameCount = 0;
            hitch16 = 0;
            hitch33 = 0;
            sumAllocBytes = 0;
            sumCollections = 0;
            sumPauseNs = 0;
            maxPauseNs = 0;
            hitchGc16 = 0;
            meshCacheRebuilds = 0;
            sumCacheNs = 0;
        }

        private static string recJson(const ref FrameRec r) {
            import std.format : format;
            return format(
                `{"totalNs":%d,"eventNs":%d,"toolNs":%d,"cacheNs":%d,` ~
                `"drawNs":%d,"uploadNs":%d,"uiNs":%d,"gcAllocBytes":%d,` ~
                `"gcCollections":%d,"gcMaxPauseNs":%d,"gcPauseNs":%d,` ~
                `"gcCollectNs":%d,"eventAlloc":%d,"toolAlloc":%d,` ~
                `"cacheAlloc":%d,"drawAlloc":%d,"uploadAlloc":%d,"uiAlloc":%d}`,
                r.totalNs, r.eventNs, r.toolNs, r.cacheNs, r.drawNs,
                r.uploadNs, r.uiNs, r.gcAllocBytes, r.gcCollections,
                r.gcMaxPauseNs, r.gcPauseNs, r.gcCollectNs,
                r.eventAlloc, r.toolAlloc, r.cacheAlloc, r.drawAlloc,
                r.uploadAlloc, r.uiAlloc);
        }

        /// JSON snapshot: frame count, total-time percentiles, per-phase
        /// p95s, hitch counts, mesh-cache-rebuild + GC aggregates, a
        /// steady-state alloc/frame figure (F-I2, warmup-skipped), the
        /// single worst frame (max totalNs), and a bounded worst-N list.
        /// Computed on demand so the hot path never sorts.
        string toJson() {
            import std.array     : appender;
            import std.format    : formattedWrite;
            import std.algorithm : sort;

            // Tear-free snapshot (write-then-advance discipline above): for
            // any single measured window (frameCount <= Ring, true for every
            // realistic scenario — the ring is reset between scenarios) the
            // slots [0 .. len) are exactly the chronological frame order.
            size_t len = ringLen;
            FrameRec[] s = ring[0 .. len].dup;

            auto app = appender!string();
            app.put("{");
            app.formattedWrite(`"frameCount":%d`, frameCount);

            long p50 = 0, p95 = 0, p99 = 0, mx = 0;
            if (len > 0) {
                long[] totals = new long[len];
                foreach (i, ref r; s) totals[i] = r.totalNs;
                totals.sort();
                p50 = totals[(len - 1) * 50 / 100];
                p95 = totals[(len - 1) * 95 / 100];
                p99 = totals[(len - 1) * 99 / 100];
                mx  = totals[len - 1];
            }
            app.formattedWrite(
                `,"total":{"p50_ns":%d,"p95_ns":%d,"p99_ns":%d,"max_ns":%d}`,
                p50, p95, p99, mx);

            // Per-phase p95 — sort each field's column independently (the
            // columns are NOT required to correlate frame-to-frame).
            app.put(`,"phases":{`);
            static immutable string[6] phaseNames =
                ["eventNs", "toolNs", "cacheNs", "drawNs", "uploadNs", "uiNs"];
            foreach (pi, name; phaseNames) {
                long[] col = new long[len];
                foreach (i, ref r; s) {
                    final switch (pi) {
                        case 0: col[i] = r.eventNs;  break;
                        case 1: col[i] = r.toolNs;   break;
                        case 2: col[i] = r.cacheNs;  break;
                        case 3: col[i] = r.drawNs;   break;
                        case 4: col[i] = r.uploadNs; break;
                        case 5: col[i] = r.uiNs;     break;
                    }
                }
                long pv = 0;
                if (len > 0) { col.sort(); pv = col[(len - 1) * 95 / 100]; }
                if (pi > 0) app.put(",");
                app.formattedWrite(`"%s":{"p95_ns":%d}`, name, pv);
            }
            app.put("}");

            app.formattedWrite(
                `,"hitch_16ms":%d,"hitch_33ms":%d,"meshCacheRebuilds":%d,` ~
                `"gcAllocBytes":%d,"gcCollections":%d,"gcPauseNs":%d,` ~
                `"gcMaxPauseNs":%d,"gcHitch_16ms":%d`,
                hitch16, hitch33, meshCacheRebuilds,
                sumAllocBytes, sumCollections, sumPauseNs,
                maxPauseNs, hitchGc16);

            // F-I2 (RECORDED, NON-GATING): steady-state alloc/frame after a
            // K-frame warmup skip (lazy inits, first-frame ImGui layout).
            // `gcAllocBytes` here is WHOLE-FRAME main-thread allocation, not
            // drag-only — see the plan's Risks section on why a nonzero
            // floor is expected (ImGui chrome rebuilds every frame) and why
            // this is a measurement, not a gate.
            enum size_t WarmupFrames = 3;
            long steadyMaxAllocBytes = 0;
            if (len > WarmupFrames) {
                foreach (i; WarmupFrames .. len)
                    if (s[i].gcAllocBytes > steadyMaxAllocBytes)
                        steadyMaxAllocBytes = s[i].gcAllocBytes;
            }
            app.formattedWrite(`,"steadyMaxAllocBytes":%d`, steadyMaxAllocBytes);
            app.formattedWrite(`,"sumCacheNs":%d`, sumCacheNs);

            // Worst frame (max totalNs) — full record.
            if (len > 0) {
                size_t worstIdx = 0;
                foreach (i, ref r; s)
                    if (r.totalNs > s[worstIdx].totalNs) worstIdx = i;
                app.put(`,"worst":`);
                app.put(recJson(s[worstIdx]));
            } else {
                app.put(`,"worst":null`);
            }

            // Bounded worst-N (by totalNs, descending).
            enum size_t WorstN = 8;
            app.put(`,"worstN":[`);
            if (len > 0) {
                FrameRec[] byWorst = s.dup;
                byWorst.sort!((a, b) => a.totalNs > b.totalNs);
                size_t take = len < WorstN ? len : WorstN;
                foreach (i; 0 .. take) {
                    if (i > 0) app.put(",");
                    app.put(recJson(byWorst[i]));
                }
            }
            app.put("]");

            app.put("}");
            return app.data;
        }
    }

} else {

    // -----------------------------------------------------------------------
    // No-op implementation (default modeling build). Every method is an
    // empty inline-able stub; `scope_` hands back a zero-field struct whose
    // destructor does nothing, so the optimizer drops the call entirely.
    // The signatures match the active impl exactly so call sites compile
    // identically in both builds.
    // -----------------------------------------------------------------------

    struct ScopeTimer {
        @disable this(this);
    }

    struct PerfProbe {
        pragma(inline, true) ScopeTimer scope_(Cat) { return ScopeTimer.init; }
        pragma(inline, true) void count(Cat, long) nothrow @nogc {}
        // Task 1500: the subpatch build's timer is no longer opened by a
        // ScopeTimer at the top of one function — the build runs on a worker
        // thread and the MAIN thread records the elapsed span on reception.
        // So `recordNs` is part of the public surface now and needs its
        // no-op twin here, or the default build stops compiling.
        pragma(inline, true) void recordNs(Cat, long) {}
        pragma(inline, true) void reset() {}
        pragma(inline, true) string toJson() { return "{}"; }
    }

    // -----------------------------------------------------------------------
    // FrameProbe — no-op implementation. Same shape/signatures as the active
    // impl so call sites (app.d main loop) compile identically in both
    // builds; every method elides in the default (non-PerfProbe) build.
    // -----------------------------------------------------------------------

    struct PhaseTimer {
        @disable this(this);
    }

    struct FrameProbe {
        pragma(inline, true) void beginFrame() {}
        pragma(inline, true) PhaseTimer phase(Phase) { return PhaseTimer.init; }
        pragma(inline, true) void addPhase(Phase, long) {}
        pragma(inline, true) void bumpMeshCacheRebuild() {}
        pragma(inline, true) size_t copyRecent(FrameRec[]) { return 0; }
        pragma(inline, true) FrameStatsSnapshot stats() const { return FrameStatsSnapshot.init; }
        pragma(inline, true) void endFrame() {}
        pragma(inline, true) void reset() {}
        pragma(inline, true) string toJson() { return "{}"; }
    }
}

/// Process-wide probe. Read/written from the main loop (timers + counters)
/// and read from the HTTP thread (GET /api/perf). Reads of plain counters
/// across threads are benign for this diagnostic use — no lock.
__gshared PerfProbe g_perf;

/// Process-wide per-frame probe. Read/written from the main loop
/// (beginFrame/phase/endFrame) and read from the HTTP thread
/// (GET /api/frames). Same no-lock diagnostic-read contract as `g_perf`
/// (see the plan's "direct read" decision).
__gshared FrameProbe g_frames;

// ===========================================================================
// FrameWorkProbe — ALWAYS-COMPILED per-frame WORK COUNTERS.
//
// Third probe in this module, and the only one that is live in the DEFAULT
// `modeling` build — the configuration `run_test.d` builds and every test
// actually runs against. PerfProbe/FrameProbe above stay `version(PerfProbe)`
// and stay TIMERS; this one is present everywhere and carries NO wall clock
// at all. That split is the whole design, and it is deliberate:
//
//   * A nanosecond figure taken on this host is not a fact about vibe3d. The
//     machine runs several agent lanes, a compile, and sometimes a second
//     editor at once; frame `totalNs` moves by 3-5x between two runs of the
//     same scenario with the same binary. A number like that gets quoted in a
//     task result and then defended. So: no timing here. If you want times,
//     build `--build=perf` and drive `tools/perf/run.d`, which brackets its
//     numbers with a baseline and a p95 and is honest about the spread.
//
//   * Every performance defect this project has actually shipped and fixed
//     was CPU-side, not draw-call bound. `drawCalls`, `drawVerts`,
//     `allocBytes` and `stageEvals` are exact integers that reproduce
//     bit-for-bit across runs on a loaded host, so a test can assert on them
//     and a regression is a diff, not a judgement call.
//
//     Checked honestly against the three real ones rather than asserted, and
//     the score is two and a half out of three:
//       - `selectedFaces` allocating a fresh `bool[]` on every read from the
//         draw path: CAUGHT, cleanly. `allocBytes` rises and, being per-frame
//         and per-mesh, rises WITH the mesh — which is the signature.
//       - a pipeline stage publishing a packet nobody read: SURFACED, not
//         diagnosed. `stageEvals` shows the operator running every frame;
//         that it has no consumer is still a question you have to go and ask.
//       - an O(F^2) `isSubpatch` @property called inside a face loop: NOT
//         caught. It allocates nothing and changes no counted quantity — it
//         is purely slower. That one needs the `perf` build, and pretending
//         otherwise is how a measurement gets trusted past its range.
//     The gap has a shape if anyone wants to close it: a work-unit counter
//     that scan-type code bumps by its iteration count would make O(n^2)
//     visible as "this count grew quadratically with the mesh". It is not
//     here because choosing which scans to instrument is a judgement call
//     that deserves its own task, not a rider on this one.
//
// WHAT THIS CANNOT TELL YOU, stated up front so nobody reads more into the
// numbers than is there:
//   * Nothing about GPU time. `drawVerts` is submitted-vertex count, i.e. how
//     much work we HAND to the driver, not how long the driver takes. Two
//     passes with equal `drawVerts` can differ by 10x in shader cost.
//   * Nothing about per-call CPU cost. 4 draw calls are not "4x worse" than
//     1; they are 4, which is a fact you can then go and price.
//   * Nothing about time spent inside a phase. A pass that got slower without
//     changing its call/vertex/alloc counts is invisible here BY CONSTRUCTION.
//     That case is what the `perf` build exists for.
//   * `allocBytes` is main-thread GC allocation for the whole frame, ImGui
//     chrome included. It has a nonzero floor. It is a DELTA instrument: the
//     claim it supports is "this change added N bytes/frame", never "a frame
//     should allocate less than N".
//
// Cost in the default build: a `++` and a `+=` per GL draw submission (tens
// per frame), one struct clear per frame, and two thread-local reads for the
// GC delta. Nothing here allocates and nothing here locks.
//
// The frame-rate figures taken while this was built — 233 fps idle, 215 under
// 24 competing spinners, 205 under 64 — are NOT a measurement of that cost and
// must not be quoted as one. All three rows are the same binary with these
// counters live; there is no probe-off column anywhere in that experiment, so
// it cannot price the probe at all. The quantity that varies across the rows
// is external host load, and the conclusion runs opposite to a tax: the
// counters were bit-identical (2144 bytes / 6 calls / 472 verts) in all three
// while the frame rate moved 12%, which is the argument FOR counting instead
// of timing in the default build. Quoting "233 -> 205 under 64 spinners" on
// its own drops the idle and 24-spinner rows and inverts the finding into a
// 12% probe overhead that was never measured and is not claimed.
//
// COVERAGE IS NOT UNIFORMLY ENFORCED, and the difference matters the moment
// you add a draw call. In `mesh_gpu.d` every submission goes through
// `dcArrays()`, which holds the only `glDrawArrays` in that struct: bypassing
// the counter there means writing a SECOND raw `glDrawArrays` into the file,
// and a grep finds it. No other draw path is protected that way. In
// `handles/shapes.d`, `handles/gl_util.d`, `ui/panels.d`, `gpu_select.d` and
// `subpatch_osd.d` a raw `glDrawArrays` simply has a `g_fc.draw` on the next
// line, paired by habit and nothing else. The pairing is complete today — 18
// raw calls, 18 bumps — so the current numbers are whole. But a NEW call added
// to one of those files without its bump is SILENT: a raw `glDrawArrays` is
// the norm there, so there is no anomaly to grep for, and the probe would
// under-report while the response still looked complete. If you touch one of
// them, the check is cheap and is the whole guarantee those files get:
//
//     grep -c 'glDrawArrays(' <file>  ==  grep -c 'g_fc\.draw(' <file>
// ===========================================================================

/// Draw-pass identity. One slot per thing a scene render can submit, split so
/// that a pass appearing or vanishing (a display style dropping the face
/// pass) is legible in the numbers rather than buried in a total.
///
/// `bgFaces`/`bgEdges` are the SAME GpuMesh entry points as `faces`/`edges`,
/// routed by the backdrop redirect (see `FrameWorkProbe.backdrop`) — a
/// background layer's draws must not be indistinguishable from the primary's,
/// because "the backdrop got expensive" and "the model got expensive" call
/// for different fixes.
enum DrawPass {
    faces,        // primary mesh surface (solid/lit), incl. the highlighted variant
    faceOverlay,  // selected-face checker overlay
    edges,        // primary mesh wireframe (base + selection + hover line passes)
    verts,        // vertex dots
    bgFaces,      // background-layer surface
    bgEdges,      // background-layer wireframe
    imagePlane,   // reference-image plane (task 0612) — its own slot rather
                  // than `bgFaces`, because it is not a mesh pass: it draws
                  // BEFORE the grid, textured, with the depth test off, and
                  // folding it into a mesh counter would make "the background
                  // layers stopped drawing" unreadable
    grid,         // ground grid + axis lines
    symmetry,     // symmetry-plane overlay
    handles,      // tool gizmo / handle shapes
    subpatch,     // subpatch-preview transform-feedback evaluation (a
                  // rasteriser-discarded dispatch, NOT a visible pass —
                  // it appears in drawCalls because it is a GL
                  // submission, and its own slot is what keeps it from
                  // being mistaken for surface drawing)
    idPick,       // GPU ID-buffer pass (picking, not display)
}

/// Per-pass work for one frame: GL submissions, and the vertices those
/// submissions cover.
struct PassCount {
    long calls;
    long verts;
}

/// One frame's deterministic work record. Every field is a COUNT. There is
/// deliberately no time field — see the header.
struct FrameWork {
    long seq;                 /// frame ordinal since the last reset (1-based)
    long cellsConsidered;     /// viewport cells the N-cell render loop looked at
    long cellsRendered;       /// cells whose dirty key actually fired a scene render
    long uploadCalls;         /// GpuMesh buffer (re)uploads issued this frame
    long uploadVerts;         /// mesh vertices those uploads covered
    long hoverPicks;          /// pick operations run (GPU ID-buffer pass
                              /// AND BVH ray-casts — an interaction can be
                              /// several, so this is operations, not frames)
    long pipeEvals;           /// Pipeline.evaluate() passes
    long stageEvals;          /// individual operator evaluate() calls inside them
    long statRebuilds;        /// Statistics-panel row-model rebuilds
                              /// (`statSectionsInto` passes). Zero while the
                              /// panel is closed, which is what makes "the
                              /// panel costs nothing when it is not open" a
                              /// measurement rather than a claim (task 1100).
    long allocBytes;          /// main-thread GC bytes allocated during the frame
    long drawCalls;           /// sum over pass[].calls
    long drawVerts;           /// sum over pass[].verts
    PassCount[DrawPass.max + 1] pass;
}

/// RAII redirect: while alive, `DrawPass.faces`/`edges` submissions are
/// attributed to `bgFaces`/`bgEdges` instead. Nests (depth-counted) so an
/// inner helper that opens one too cannot un-redirect its caller.
///
/// Holds the OWNING probe, not `g_fc`. Production only ever has one probe, so
/// popping the global would look correct forever — and then the unit tests,
/// which use local instances, would push one probe and pop another and see a
/// redirect that never ends. It did exactly that before this pointer existed.
struct BackdropScope {
    private FrameWorkProbe* owner_;
    @disable this(this);
    ~this() { if (owner_ !is null) owner_.popBackdrop(); }
}

/// Always-compiled per-frame work counters. Single-writer (main thread);
/// read from the HTTP thread with the same benign, lock-free diagnostic
/// contract as `g_perf`/`g_frames`.
///
/// The contract is not uniform across the three published records, and the
/// difference is worth stating because it used to be stated wrongly. `last_`
/// and `lastScene_` ARE stamped whole (`last_ = cur_` from a fully populated
/// local), so a racy read of either gets a slightly stale frame, never a torn
/// one. `total_` is NOT: it is accumulated field-by-field in place, so a
/// reader's copy of it can mix fields from two adjacent frames. That is
/// tolerable in a diagnostic total — no consumer compares two of its fields —
/// but reading the SAME field of it twice is not, which is why `toJson` takes
/// one copy up front and serialises the copy. See its comment.
struct FrameWorkProbe {

    // In-flight frame.
    private FrameWork cur_;
    private ulong     allocBase_;
    private int       backdropDepth_;

    // Published snapshots.
    private FrameWork last_;       // last committed frame, whatever it did
    private FrameWork lastScene_;  // last committed frame that rendered >=1 cell
    private FrameWork total_;      // cumulative since reset (seq = frame count)

    // ---- frame lifecycle -------------------------------------------------

    /// Start a frame. Called from the top of app.d's main loop, beside
    /// `g_frames.beginFrame()`.
    void beginFrame() {
        cur_ = FrameWork.init;
        backdropDepth_ = 0;
        allocBase_ = allocatedNow();
    }

    /// Close the frame: fold per-pass totals, stamp the GC delta, publish.
    /// Called beside `g_frames.endFrame()`.
    ///
    /// Publication order is write-record-then-publish, matching FrameProbe's
    /// ring discipline: `last_`/`lastScene_` are assigned from a fully
    /// populated local, so the HTTP reader either sees the previous frame or
    /// this one, never half of each.
    void endFrame() {
        long dc = 0, dv = 0;
        foreach (ref p; cur_.pass) { dc += p.calls; dv += p.verts; }
        cur_.drawCalls = dc;
        cur_.drawVerts = dv;
        cur_.allocBytes = cast(long)(allocatedNow() - allocBase_);

        total_.seq++;
        cur_.seq = total_.seq;

        total_.cellsConsidered   += cur_.cellsConsidered;
        total_.cellsRendered     += cur_.cellsRendered;
        total_.uploadCalls       += cur_.uploadCalls;
        total_.uploadVerts       += cur_.uploadVerts;
        total_.hoverPicks        += cur_.hoverPicks;
        total_.pipeEvals         += cur_.pipeEvals;
        total_.stageEvals        += cur_.stageEvals;
        total_.statRebuilds      += cur_.statRebuilds;
        total_.allocBytes        += cur_.allocBytes;
        total_.drawCalls         += cur_.drawCalls;
        total_.drawVerts         += cur_.drawVerts;
        foreach (i, ref p; cur_.pass) {
            total_.pass[i].calls += p.calls;
            total_.pass[i].verts += p.verts;
        }

        last_ = cur_;
        if (cur_.cellsRendered > 0) lastScene_ = cur_;
    }

    // ---- instrumentation -------------------------------------------------

    /// Record one GL draw submission covering `verts` vertices.
    /// `verts` is the count argument handed to glDrawArrays/glDrawElements —
    /// vertices SUBMITTED, not triangles and not pixels.
    void draw(DrawPass p, long verts) {
        if (backdropDepth_ > 0) {
            if (p == DrawPass.faces) p = DrawPass.bgFaces;
            else if (p == DrawPass.edges) p = DrawPass.bgEdges;
        }
        cur_.pass[p].calls++;
        cur_.pass[p].verts += verts;
    }

    /// Open a backdrop redirect for the enclosing scope.
    BackdropScope backdrop() return {
        backdropDepth_++;
        BackdropScope s;
        s.owner_ = &this;
        return s;
    }

    /// Internal: close one backdrop redirect. Called by ~BackdropScope.
    void popBackdrop() { if (backdropDepth_ > 0) backdropDepth_--; }

    /// One GPU buffer (re)upload covering `verts` mesh vertices.
    void upload(long verts) nothrow @nogc {
        cur_.uploadCalls++;
        cur_.uploadVerts += verts;
    }
    version(unittest) long uploadCallsForTest() const nothrow @nogc {
        return cur_.uploadCalls;
    }

    void bumpCellConsidered()  { cur_.cellsConsidered++; }
    void bumpCellRendered()    { cur_.cellsRendered++; }
    void bumpHoverPick()       { cur_.hoverPicks++; }
    void bumpPipeEval()        { cur_.pipeEvals++; }
    void bumpStatRebuild()     { cur_.statRebuilds++; }
    void bumpStageEval()       { cur_.stageEvals++; }

    /// Zero every published counter and the in-flight frame's accumulators.
    ///
    /// Called from the HTTP thread, so it can land mid-frame. Unlike
    /// `FrameProbe.reset` this DOES clear `cur_` — there is no elapsed-time
    /// base to corrupt here (the one base, `allocBase_`, is re-stamped in
    /// `beginFrame`; a reset landing mid-frame at worst mis-attributes that
    /// single frame's `allocBytes`, and tests reset while quiescent).
    void reset() {
        cur_ = FrameWork.init;
        last_ = FrameWork.init;
        lastScene_ = FrameWork.init;
        total_ = FrameWork.init;
        backdropDepth_ = 0;
        allocBase_ = allocatedNow();
    }

    // ---- read-out --------------------------------------------------------

    /// By-value copy of the last committed frame that rendered at least one
    /// viewport cell. This — not `last` — is what an assertion should read:
    /// the render loop skips cells whose dirty key is unchanged, so an
    /// arbitrary frame legitimately has zero draws.
    FrameWork lastScene() const { return lastScene_; }

    /// By-value copy of the last committed frame, rendered or not.
    FrameWork last() const { return last_; }

    /// By-value cumulative totals since reset (`seq` = frames committed).
    FrameWork totals() const { return total_; }

    /// JSON: `{"frames":N,"lastScene":{...},"last":{...},"totals":{...}}`.
    /// Live in EVERY build — this endpoint is not a "{}" stub.
    ///
    /// Every record is COPIED before anything is serialised, and the reason is
    /// specifically `frames`: it and `totals.seq` are the same counter, and
    /// reading it live at both sites left ~70 `to!string` allocations' worth of
    /// window between them for the main thread to commit a frame in. One
    /// response then said `frames: N` and `totals: {seq: N+1}` — a document
    /// contradicting itself, which is what tests/test_frame_counts.d's
    /// "totals.seq is the committed-frame count" is entitled to reject.
    /// Measured on an idle host: 89 of 40 000 responses, every one of them
    /// off by exactly +1. Serialising from the copies makes the two fields the
    /// same read, so the disagreement is not narrowed, it is unrepresentable.
    ///
    /// The copies do not make the read atomic and are not meant to: `total_`
    /// is accumulated in place (see the struct header), so one copy can still
    /// mix fields from two adjacent frames. Nothing compares two of its fields;
    /// a response disagreeing with ITSELF about one field is the defect.
    string toJson() {
        import std.array : appender;
        const scene = lastScene_;
        const lastF = last_;
        const tot   = total_;
        auto app = appender!string();
        app.put(`{"frames":`);
        putLong(app, tot.seq);
        app.put(`,"lastScene":`); putWork(app, scene);
        app.put(`,"last":`);      putWork(app, lastF);
        app.put(`,"totals":`);    putWork(app, tot);
        app.put("}");
        return app.data;
    }

    private static void putLong(A)(ref A app, long v) {
        import std.conv : to;
        app.put(v.to!string);
    }

    private static void putWork(A)(ref A app, const ref FrameWork w) {
        app.put(`{"seq":`);              putLong(app, w.seq);
        app.put(`,"cellsConsidered":`);  putLong(app, w.cellsConsidered);
        app.put(`,"cellsRendered":`);    putLong(app, w.cellsRendered);
        app.put(`,"drawCalls":`);        putLong(app, w.drawCalls);
        app.put(`,"drawVerts":`);        putLong(app, w.drawVerts);
        app.put(`,"uploadCalls":`);      putLong(app, w.uploadCalls);
        app.put(`,"uploadVerts":`);      putLong(app, w.uploadVerts);
        app.put(`,"hoverPicks":`);       putLong(app, w.hoverPicks);
        app.put(`,"pipeEvals":`);        putLong(app, w.pipeEvals);
        app.put(`,"stageEvals":`);       putLong(app, w.stageEvals);
        app.put(`,"statRebuilds":`);     putLong(app, w.statRebuilds);
        app.put(`,"allocBytes":`);       putLong(app, w.allocBytes);
        app.put(`,"pass":{`);
        static foreach (i, member; __traits(allMembers, DrawPass)) {{
            static if (i > 0) app.put(",");
            app.put(`"` ~ member ~ `":{"calls":`);
            putLong(app, w.pass[__traits(getMember, DrawPass, member)].calls);
            app.put(`,"verts":`);
            putLong(app, w.pass[__traits(getMember, DrawPass, member)].verts);
            app.put("}");
        }}
        app.put("}}");
    }
}

/// Main-thread GC allocation counter. Isolated so the one druntime call this
/// probe makes per frame boundary has a single named site.
///
/// `GC.allocatedInCurrentThread` reads a THREAD-LOCAL running total — no
/// lock, no allocation, no stop-the-world. `GC.profileStats().numCollections`
/// is deliberately NOT read here: it is a global that the conservative GC
/// serialises, and a per-frame lock acquisition in the default build is a
/// cost this probe is not allowed to introduce. Collection counts stay in the
/// `perf` build's FrameProbe, which is where a stop-the-world hitch is a
/// timing question anyway.
/// (`nothrow` only, not `@nogc`: druntime does not mark the accessor `@nogc`
/// even though it allocates nothing — see the FrameProbe comment on the same
/// call in `endFrame`.)
private ulong allocatedNow() nothrow {
    import core.memory : GC;
    return GC.allocatedInCurrentThread;
}

/// Process-wide frame-work counters. Written by the main loop, read by the
/// HTTP thread (GET /api/frames/counts). Live in every build configuration,
/// unlike `g_perf`/`g_frames`.
__gshared FrameWorkProbe g_fc;

// ---------------------------------------------------------------------------
// FrameWorkProbe unit tests. These run under `dub test --config=tests` —
// i.e. in the SAME configuration the probe is live in, which is the whole
// point of it being ungated. A local instance is used throughout; `g_fc` is
// the main loop's and must not be disturbed.
// ---------------------------------------------------------------------------
