module subpatch_preview;

// ---------------------------------------------------------------------------
// SubpatchPreview — the cached OpenSubdiv preview of a cage mesh, and the
// async/GPU state machine around it.
//
// Split out of mesh.d (task 4066): 898 lines of build dispatch, reception,
// staleness keys and a two-slot cage snapshot pool, none of which touches a
// private of `Mesh` and none of whose own privates anything outside it reads.
// mesh.d re-exports this module (`public import subpatch_preview;`), the same
// way it re-exports mesh_topo / mesh_gpu / mesh_edge_slice, so `import mesh`,
// `import mesh : SubpatchPreview` and `mesh.SubpatchPreview` all resolve
// unchanged and no call site moved.
//
// EVERY import here is PLAIN, deliberately. mesh.d `public import`s this
// module, and a SELECTIVE import makes a module-scope alias that the public
// import re-exports — which is how one folded function in this same task gave
// `import mesh : edgeKey` two candidates for one symbol. A plain import
// creates no such alias.
// ---------------------------------------------------------------------------

import mesh;
import math;
import subpatch_osd;
import subpatch_worker;

/// Cached subdivision preview of a source (cage) mesh. When `active`
/// is true, `mesh`/`trace` hold the OpenSubdiv-emitted limit geometry;
/// otherwise the cage should be rendered directly and this struct is
/// inert. The cache rebuilds lazily when the cage's change-bus GEOMETRY epoch,
/// its `mutationVersion` or `depth` changes; drag-frame position updates go
/// through the cached `osdAccel` stencil table without touching topology.
struct SubpatchPreview {
    Mesh          mesh;
    SubpatchTrace trace;
    bool          active;
    /// Source mesh ADDRESS this preview was last built against (layers Stage
    /// 2). Two layers' cages can share an equal (mutationVersion,
    /// topologyVersion) — e.g. a layer.select swaps the preview source with no
    /// intervening mutation — so the address is part of the staleness key.
    /// With one layer this is constant ⇒ invisible. `size_t.max` forces a
    /// rebuild on first call.
    size_t        sourceMeshAddr        = size_t.max;
    /// TASK 1906 STAGE 2d (plan §3.4 row 10) — the freshness half of the
    /// staleness key is TWO terms, `sourceEpoch` here and `sourceVersion`
    /// below, and the early-out needs BOTH to match. Together with
    /// `sourceMeshAddr` the epoch half is a `mesh_dirty.MeshDirtyKey` in two
    /// fields; the address stays a field of its own because the position-only
    /// fast path below reads it separately.
    ///
    /// THE EPOCH IS `mesh_dirty.g_geomEpochs` — `Position | Points |
    /// Polygons`, the same watcher the surface BVH and the cage VBO read, and
    /// NOT an any-class one. What it buys is the case `mutationVersion` cannot
    /// see: an interactive gizmo Move/Rotate/Scale updates `source.vertices`
    /// WITHOUT bumping `source.mutationVersion` — both on drag AND on commit
    /// (see the warning above `deactivate()`) — so the pre-0401 (address,
    /// mutationVersion, depth) key was unchanged even though the cage had
    /// moved. Task 0401 patched that with a `positionsDirty` flag passed in by
    /// `app.d`, which put the consumer's invalidation decision at the CALL
    /// SITE and left the IPR caller to remember it separately; the epoch
    /// carries the same information at the lazy recompute, where the artifact
    /// is read, and that parameter is gone with it.
    ///
    /// WHY THE COUNTER STAYED RATHER THAN BEING REPLACED — this is the review
    /// finding the stage was landed on, and the reasoning it replaces
    /// ("`commitChange` bumps `mutationVersion` for every class, so an
    /// any-class epoch is not a widening") is FALSE. Not every class bump goes
    /// through `commitChange`: `Mesh.noteSelectionChange` — the funnel under
    /// every marks setter — publishes `Marks` and deliberately bumps NO
    /// version, and `noteChange(Visibility)` and `app.d`'s
    /// `noteChange(MeshChangeAll)` are version-silent the same way. All three
    /// reach a per-mesh epoch through `app.d`'s per-layer feed. An any-class
    /// epoch therefore invalidates this cache on a plain SELECTION CLICK,
    /// which the counter never did: MEASURED at six `selectVertex` calls with
    /// a live preview — cage `mutationVersion` 13 -> 13, preview work 1 -> 7,
    /// i.e. the OSD stencil evaluate plus the VBO fan-out on every frame in
    /// which the user picks something. With the split key that delta is 0
    /// (`tests/unit/subpatch_osd_test.d`, the "version-silent selection
    /// clicks" block).
    ///
    /// `ulong.max` is never a real epoch, so a fresh preview always rebuilds.
    ulong         sourceEpoch           = ulong.max;
    /// The SECOND freshness term, and the one that carries every class
    /// `g_geomEpochs` deliberately drops. `Tab`/`setSubpatch` write `Marks`,
    /// `setCreaseWeight` writes `Material`; neither is in the geometry mask,
    /// and both MUST rebuild the preview (a missed crease rebuild presents as
    /// "the written weight does nothing" — task 1062 §3). Both go through
    /// `commitChange`, so both move `mutationVersion`, and that is exactly the
    /// half of the old key worth keeping. The two terms are complementary, not
    /// redundant: neither alone is the invalidation set this cache needs.
    ///
    /// A term can only ever ADD rebuilds, never remove one, so the 0401
    /// guarantee is unaffected by its presence.
    ulong         sourceVersion         = ulong.max;
    /// Last source.topologyVersion we built against. While
    /// `source.topologyVersion` is unchanged but mutationVersion
    /// bumped (move/rotate/scale drag), we skip the full rebuild and
    /// re-evaluate stencil positions via `osdAccel.refresh`.
    ulong         sourceTopologyVersion = ulong.max;
    int           depth                 = -1;

    /// How many times this preview has BUILT a subdivided surface for the cage
    /// (task 1620) — the synchronous `rebuild` path that reaches OpenSubdiv,
    /// plus every asynchronous `dispatchBuild`. Those are the events that
    /// discard the preview's INDEX SPACE, and in the async case the one that
    /// drops `active` outright, i.e. what a viewer sees as the surface
    /// snapping back to the cage.
    ///
    /// Three things deliberately do NOT count, because none of them derives
    /// anything: the position-only fast path in `rebuildIfStale` (it keeps the
    /// index space and only re-evaluates limit positions), a `rebuild` on a
    /// cage with no subpatch faces, and a `rebuild` at depth <= 0. The last
    /// two mean the preview is OFF — a cage that can never dispatch, which is
    /// exactly the rig on which a churn assertion would be vacuous.
    ///
    /// It exists so a test can assert on the flicker's proximate cause
    /// instead of on a screenshot: a drag that changes no topology must leave
    /// this number where it was. Monotone, never reset.
    ulong         topologyBuilds;

    /// Reverse-lookup: for each CAGE vertex index, the preview-mesh
    /// vertex that carries its smoothed position (`uint.max` if no
    /// preview vert traces back to this cage vert). Built alongside
    /// `trace.vertOrigin[]` so the picking pipeline can iterate the
    /// 8 K cage verts instead of the 500 K+ preview verts at
    /// `subpatchDepth=3` (saves a ~60× factor in the per-frame
    /// hover-pick inner loop on subpatch meshes).
    uint[] cageVertPreview;

    /// OpenSubdiv back-end. Owns the cached topology + stencil table
    /// and drives both full rebuilds (buildPreview) and per-drag-frame
    /// position refreshes (refresh).
    import subpatch_osd : OsdAccel;
    OsdAccel      osdAccel;

    /// Phase 3b — set by the most recent rebuildIfStale fast-path
    /// when the OSD GPU fan-out wrote vibe3d's face VBO directly.
    /// Main loop reads this to skip the duplicate face-VBO write
    /// inside its standard `gpu.refreshPositions` call (uses
    /// refreshNonFacePositions instead).
    bool lastRefreshFannedOut;

    /// Phase 3c — set when face AND edge AND vert VBOs were all
    /// written via the GPU fan-out. Main loop skips
    /// refreshNonFacePositions entirely when this is true; no CPU
    /// position upload happens at all on the drag-frame fast path.
    bool lastRefreshSkipNonFace;

    // Tab-toggle fast reactivation: when the user toggles subpatch OFF, keep the
    // last preview mesh/trace around. If the next ON sees the exact same cage
    // geometry + face topology + subpatch mask + depth, reuse it and pay only the
    // preview GPU upload. This is deliberately stricter than topologyVersion:
    // setSubpatch bumps topologyVersion on every toggle, so version equality
    // cannot identify a true back-and-forth Tab reuse.
    ulong reusablePreviewKey;
    bool  reusablePreviewReady;

    // =====================================================================
    // ASYNCHRONOUS BUILD (task 1500)
    // =====================================================================
    //
    // WHAT IS PROMISED: no multi-second freeze. NOT "no hitches" — D stops
    // the world to collect, and a virgin build allocates ~248 MB (task 1374),
    // so residual per-frame jitter during a background build is a MEASUREMENT
    // in the task's acceptance, not an assumption in this comment.
    //
    // THE HAZARD THIS CODE EXISTS AROUND. The preview is not just a picture:
    // it carries element provenance (`SubpatchTrace`) and it PARTICIPATES IN
    // SELECTION. Task 1500's phase-0 discriminator measured it — deferring
    // the rebuild made `tests/test_hide_geometry_pick.d`'s edge-lasso row
    // answer with the CAGE's 16 edges where it asserts the PREVIEW's 12. So
    // "make the build async" without a discipline on when recorded input is
    // delivered is not a perf improvement, it is a broken suite.
    //
    // The discipline has three parts, and each has its own witness:
    //   1. `active` drops to false AT DISPATCH, not at arrival, whenever the
    //      index space changes. While a build is in flight the cage is what
    //      is drawn AND what is selected, and a cage answer is a complete,
    //      permanent answer — every pick path already returns CAGE indices
    //      (gpu_select.d's *OriginGpu translation, bvh_pick's _triToFace,
    //      the lasso's trace.*Origin walk), so an arriving preview never has
    //      to re-map or discard a selection the user already made. M-SEL.
    //   2. RECORDED INPUT is held while a build is in flight — and only
    //      recorded input, not the HTTP bridge tick, so `/api/reset` and the
    //      observation routes keep answering. `scriptedInputHeld` below is
    //      the whole of that gate. M-DET.
    //   3. The receiver runs at ONE point in the frame, immediately before
    //      the single GPU-upload block, so no pick can ever observe a live
    //      preview `trace` against cage VBOs. M-INV asserts the one-sided
    //      invariant at the two CONSUMERS.
    //
    // OFF BY DEFAULT. `asyncEnabled` is set by the editor's main loop only.
    // The module unittests and the IPR preview (source/render/render_mvp.d)
    // keep the synchronous path — they call `rebuildIfStale` and read
    // `preview.mesh` on the next line, and there is no frame loop under them
    // to run a receiver. This is not the "in test mode, wait synchronously"
    // trap the task warns about: the editor, INCLUDING under --test, is
    // always async, which is what makes M-ASYNC and the perf lane's
    // `subpatchWorkerBuildNs > 0` able to see the window at all.

    import subpatch_worker : SubpatchWorker;
    import subpatch_osd    : CageSnapshot, PreviewBuildResult, takeCageSnapshot;

    /// Ceiling on how long recorded input may be held. Taken from
    /// measurement, not feel: task 1374 puts the worst cold build at ~4 s
    /// with the 800 000-face budget, so this is ~4x it. Its job is that a
    /// build wedged inside the third-party stencil builder costs one warning
    /// and a degraded (cage) answer instead of a hung lane.
    enum long kScriptedHoldCeilingMs = 15_000;

    /// Ceiling on the bounded join `OsdAccel.clear()` runs through. Longer
    /// than the input ceiling on purpose: this one is protecting memory a
    /// running thread is reading, so it must outlast any build that is
    /// merely slow.
    enum long kJoinWaitMs = 20_000;

    SubpatchWorker worker;
    bool  asyncEnabled;

    /// A build is dispatched and has not been received. This is the ONE bit
    /// the barrier, the indicator and the observation route all read.
    bool  buildPending;
    /// The bounded join gave up on a build. Its topology is deliberately NOT
    /// freed (see `joinInFlight`), so this also means "one topology has been
    /// leaked on purpose".
    bool  buildAbandoned;
    ulong buildGeneration;
    /// Stencil-space key the in-flight build was dispatched for. NOT the
    /// tuple `rebuildIfStale` early-outs on: that one is
    /// (address, mutationVersion, depth), and an interactive gizmo drag
    /// changes `vertices` WITHOUT bumping `mutationVersion`, so it is both
    /// too strong (mutationVersion moves on edits that leave the stencil
    /// table identical) and too weak (a version-silent move does not move
    /// it at all) to decide whether an arriving build is still wanted.
    ulong pendingKey;
    ulong buildsCompleted;
    ulong buildsDiscarded;
    /// Frames on which a build was in flight. The perf lane subtracts this
    /// from `frameCount` so F-I9's frame band keeps measuring exactly what it
    /// measured before the work moved off-thread.
    ulong pendingFrames;
    long  workerBuildNs;            // last completed build
    long  workerAllocBytes;         // last completed build
    /// Refinement level the depth policy actually picked for the last build
    /// (`depth` is what was REQUESTED; `chooseSubpatchLevel` caps it).
    int   chosenLevel = -1;
    long  workerBuildNsTotal;       // since process start / perf reset
    long  workerAllocBytesTotal;

    import core.time : MonoTime;
    MonoTime buildStarted;
    bool     ceilingFired;

    /// Test-only knob (POST /api/subpatch/hold). Delays RECEPTION, never the
    /// worker: the build completes normally, so `joinInFlight` under a hold
    /// never waits and `/api/reset` stays instant even mid-hold.
    ///   0  — off
    ///  >0  — hold reception for this many ms after dispatch
    ///  <0  — hold until released (the ceiling witness, M-CEIL)
    long holdMs;
    long ceilingMs = kScriptedHoldCeilingMs;

    /// PERMANENT front/back snapshot pool. The second one is allocated at the
    /// first Tab and keeps its capacity for the process's life — so the GC
    /// spinlock contention P0 removed (subpatch_osd.d, 10.5 % of samples at
    /// 24K cage polys) comes back for the FIRST build only, not for each one.
    /// The cost is real and is the task's risk 2: peak memory grows by one
    /// cage-proportional snapshot.
    private CageSnapshot[2] snapPool;
    private size_t          snapBack;

    /// Turn the async path on and give this preview its builder. Called once,
    /// by the editor's main loop.
    void enableAsync(SubpatchWorker w) {
        worker       = w;
        asyncEnabled = w !is null;
        osdAccel.joinInFlightHook = &this.joinInFlight;
    }

    /// Is recorded input held this frame? Consulted at exactly two sites —
    /// the `--playback` tick and the `/api/play-events` tick — and nowhere
    /// else. In particular `httpServer.tickAll()` is NOT gated: it drains
    /// every registered main-thread bridge, so gating it would take
    /// `/api/reset` (the harness's only recovery lever) and
    /// `/api/subpatch/preview` (the route that has to answer `pending:true`)
    /// down with it, and would run the 5 s `submitAndWait` ceiling on ~30
    /// routes.
    ///
    /// BOUNDED. Past `ceilingMs` the input is delivered anyway, with one
    /// warning: the cage answer is correct (just not the limit-surface one),
    /// and an unbounded gate would turn a wedged third-party build into a
    /// wedged test lane.
    /// The in-flight build has outrun its ceiling.
    ///
    /// ONE definition, because there are now TWO mechanisms bounded by it and
    /// they must lift together (task 1730). `scriptedInputHeld` below holds
    /// recorded input while a build runs; `App.previewIndexSpaceStale` holds
    /// the VBOs on the stale limit surface and freezes the pickers that read
    /// its index map. Both exist so a build in flight is invisible to the
    /// user, and both would wedge FOREVER on a build that never finishes —
    /// which is not hypothetical, the point of no return is inside the
    /// third-party stencil builder and there is nothing to interrupt it with.
    ///
    /// Past the ceiling both give up in the same direction: input is delivered
    /// against the cage, and the cage is what is drawn and picked. A wedged
    /// build degrades to the pre-1730 behaviour — a visible flicker — rather
    /// than to a viewport that no longer answers. `test_subpatch_async_preview`
    /// M-CEIL is what refuses the other choice.
    ///
    /// Reads the CLOCK rather than `ceilingFired`: that flag latches inside
    /// `scriptedInputHeld`, so it is only ever set if something asked on the
    /// scripted path, and a second consumer keying on it would sit frozen
    /// through the whole build in any session where nothing did.
    bool buildPastCeiling() {
        if (!buildPending) return false;
        import core.time : dur;
        return MonoTime.currTime - buildStarted >= dur!"msecs"(ceilingMs);
    }

    bool scriptedInputHeld() {
        if (!buildPending) return false;
        if (buildPastCeiling()) {
            if (!ceilingFired) {
                ceilingFired = true;
                try {
                    import log        : logWarn;
                    import std.format : format;
                    logWarn("subpatch", format(
                        "preview build still running after %d ms — delivering "
                        ~ "recorded input against the cage", ceilingMs));
                } catch (Exception) {}
            }
            return false;
        }
        return true;
    }

    private bool receptionHeld() {
        if (holdMs == 0) return false;
        if (holdMs < 0)  return true;
        import core.time : dur;
        return (MonoTime.currTime - buildStarted) < dur!"msecs"(holdMs);
    }

    /// The bounded join every destructive `OsdAccel` primitive runs through
    /// (`clear()` / `destroyCache()` call it as their FIRST statement).
    ///
    /// ON TIMEOUT WE LEAK, DELIBERATELY. There is nothing to interrupt a
    /// build with — the point of no return is inside the stencil builder —
    /// and freeing the topology or the GL objects underneath a running
    /// thread is the use-after-free this join exists to prevent. A leak that
    /// is logged beats a crash that is not. This branch has NO test witness
    /// and that is recorded in doc/behavior_gap_registry.md rather than
    /// dressed up.
    void joinInFlight() {
        if (worker is null || !buildPending) return;
        if (!worker.waitIdle(kJoinWaitMs)) {
            buildAbandoned = true;
            buildPending   = false;
            try {
                import log : logError;
                logError("subpatch", "preview build did not finish within the "
                    ~ "join ceiling — abandoning it and leaking its topology "
                    ~ "rather than freeing memory it may still be reading");
            } catch (Exception) {}
            return;
        }
        PreviewBuildResult res;
        if (worker.tryTake(res)) {
            ++buildsCompleted;
            ++buildsDiscarded;
            workerBuildNs         = res.workerNs;
            workerAllocBytes      = res.workerAllocBytes;
            workerBuildNsTotal    += res.workerNs;
            workerAllocBytesTotal += res.workerAllocBytes;
            osdAccel.retireResult(res);
        }
        buildPending = false;
    }

    /// Stencil-space key: everything the EXPENSIVE half of the build depends
    /// on, and nothing else.
    ///
    /// `mutationVersion` is deliberately absent — see `pendingKey`. Positions
    /// are absent too, because they are re-evaluated from the LIVE cage at
    /// reception (`evaluateFromCage`), so a version-silent drag during a
    /// build cannot produce a stale surface and must not be allowed to
    /// invalidate the build either — a `Position` publish (task 1906 stage 2d;
    /// formerly the `positionsDirty` flag) lands on every drag frame, so a
    /// positions-sensitive key would mean a build that never completes while
    /// the user is dragging.
    ///
    /// The HIDE mask is in the key: it changes which limit faces are kept, so
    /// it changes the preview's index space. The change bus already treats it
    /// as a preview trigger (`MeshEditScope.Marks` in app.d's
    /// `kSubpatchTriggers`).
    private ulong computeStencilKey(ref const Mesh source, int d) const {
        import core.internal.hash : hashOf;
        ulong h = hashOf(cast(size_t)&source);
        h = hashOf(source.topologyVersion, h);
        h = hashOf(d, h);
        h = hashOf(source.vertices.length, h);
        h = hashOf(source.faces.length, h);
        h = hashOf(source.edges.length, h);
        // Subpatch and Hide only. Reading whole `faceMarks` would fold
        // Marks.Select in and make every click look like a topology change.
        foreach (m; source.faceMarks)
            h = hashOf(cast(uint)(m & (Mesh.Marks.Subpatch | Mesh.Marks.Hide)), h);
        auto cw = source.creaseWeightMap();
        if (cw !is null) h = hashOf(cw.data, h);
        else             h = hashOf(0xC1EA5E00u, h);
        return h == 0 ? 1 : h;
    }

    /// Dispatch one build. Precondition: no build in flight.
    private void dispatchBuild(ref const Mesh source, int d) {
        assert(!buildPending, "dispatchBuild with a build already in flight");
        auto snap = &snapPool[snapBack];
        takeCageSnapshot(source, d, *snap);
        // The three answers the build would return `false` for, decided here
        // so a pointless dispatch never happens and the cage is left drawn.
        if (snap.nv == 0 || snap.nf == 0 || d < 1 || !snap.anyMarked) {
            rebuild(source, d);
            return;
        }
        // INDEX SPACE CHANGES NOW. The stale trace does not outlive its cage
        // by a single frame, so `faceOrigin` can never run past
        // `mesh.faces.length` — by construction, not by a bounds check.
        cageVertPreview.length = 0;
        active                = false;
        reusablePreviewReady  = false;
        reusablePreviewKey    = 0;
        // Claim the staleness keys at DISPATCH so `rebuildIfStale` short-
        // circuits for the frames the build is running, instead of trying to
        // dispatch again on every one of them.
        depth                 = d;
        sourceMeshAddr        = cast(size_t)&source;
        sourceEpoch           = stampSourceEpoch(source);
        sourceVersion         = source.mutationVersion;
        sourceTopologyVersion = source.topologyVersion;

        osdAccel.joinInFlightHook = &this.joinInFlight;
        ++topologyBuilds;      // task 1620 — see the field's doc comment
        ++buildGeneration;
        pendingKey   = computeStencilKey(source, d);
        buildPending = true;
        ceilingFired = false;
        buildStarted = MonoTime.currTime;
        worker.submit(&osdAccel, snap, buildGeneration, pendingKey);
        snapBack = 1 - snapBack;
    }

    /// MAIN LOOP, ONCE PER FRAME, immediately before the GPU-upload block.
    ///
    /// WHY HERE AND NOT AT THE TOP OF THE EVENTS PHASE. The only place a
    /// preview is uploaded to the GPU is that block. `ensureDisplayCurrent`,
    /// the mid-frame pull-guard the pick paths call, refreshes the CAGE and
    /// does not upload the preview at all. Receiving before the events phase
    /// would therefore leave a whole frame's worth of delivered events
    /// picking against a live preview `trace` while every VBO — and
    /// `gpuVisible`, which app.d keys by PREVIEW face index — still held the
    /// cage. Preview faces past the cage's count would skip the visibility
    /// gate on the array-length guard and the ones below it would take
    /// someone else's visibility: a wrong selection covered by a bounds
    /// check, i.e. not even a crash. M-INV.
    ///
    /// Returns true iff a build was INSTALLED this frame; the caller must
    /// then force a FULL preview upload (a version-silent rebuild changes
    /// neither `mutationVersion` nor the preview-on/off state, so neither of
    /// the upload block's existing triggers would fire).
    bool pumpAsyncBuild(ref const Mesh source, int d) {
        if (!asyncEnabled || worker is null) return false;
        if (!buildPending) return false;
        ++pendingFrames;
        if (receptionHeld()) return false;

        PreviewBuildResult res;
        if (!worker.tryTake(res)) return false;

        buildPending = false;
        ++buildsCompleted;
        workerBuildNs          = res.workerNs;
        workerAllocBytes       = res.workerAllocBytes;
        workerBuildNsTotal    += res.workerNs;
        workerAllocBytesTotal += res.workerAllocBytes;
        chosenLevel            = res.chosenLevel;

        import core.time : MonoTime;
        immutable MonoTime tInstall = MonoTime.currTime;

        if (!res.ok) {
            // A refusal is an ARRIVAL: it clears the gate and leaves the cage
            // on screen, exactly as the synchronous path's `return false` did.
            osdAccel.retireResult(res);
            osdAccel.clear();
            mesh   = Mesh.init;
            trace  = SubpatchTrace.init;
            active = false;
            reusablePreviewReady = false;
            reusablePreviewKey   = 0;
            osdAccel.publishBuildCounters(res,
                (MonoTime.currTime - tInstall).total!"nsecs");
            return false;
        }

        if (res.key != computeStencilKey(source, d)) {
            // The cage moved on while this was building. Throw the result
            // away — INCLUDING its topology, which is the single most
            // expensive object in the system and which nothing else will
            // free. M-LEAK.
            ++buildsDiscarded;
            osdAccel.retireResult(res);
            osdAccel.publishBuildCounters(res,
                (MonoTime.currTime - tInstall).total!"nsecs");
            if (d > 0 && source.hasAnySubpatch()) dispatchBuild(source, d);
            return false;
        }

        // ---- Install ----------------------------------------------------
        // `clear()` runs HERE rather than at the start of the build, which is
        // the observable ordering change of this task: the old preview has to
        // stay drawable for the whole flight.
        osdAccel.clear();
        // Positions from the LIVE cage, never from the snapshot. This is what
        // makes a version-silent drag during the build harmless, and it is
        // the same stencil evaluate the position-only fast path already runs
        // every drag frame. M-GEN-POS.
        osdAccel.evaluateFromCage(source, res.topo, res.mesh);
        osdAccel.installGl(res, res.mesh, res.trace);
        osdAccel.swapLimitPool();

        mesh  = res.mesh;
        trace = res.trace;
        ++mesh.mutationVersion;
        active                = true;
        depth                 = d;
        sourceMeshAddr        = cast(size_t)&source;
        sourceEpoch           = stampSourceEpoch(source);
        sourceVersion         = source.mutationVersion;
        sourceTopologyVersion = source.topologyVersion;
        reusablePreviewKey    = computeReusablePreviewKey(source, d);
        reusablePreviewReady  = true;
        buildCageVertPreview(source);
        osdAccel.publishBuildCounters(res,
            (MonoTime.currTime - tInstall).total!"nsecs");
        return true;
    }

    /// The "building preview" indicator's TEXT, and the single place its law
    /// lives (task 1500, phase 4). Empty string = no indicator.
    ///
    /// It exists in the scope, not in a follow-up, and the reason is not
    /// polish: the chosen answer to "what is shown while the build runs" is
    /// THE CAGE — which for the FIRST Tab (the case this whole task was
    /// opened for) means the picture does not change at all for several
    /// seconds. Without an indicator that reads as "the key did nothing",
    /// which is WORSE than the frozen window it replaces, and the task would
    /// have made the product worse while making the number better.
    ///
    /// The renderer's use of this string has no headless probe (nothing in
    /// this codebase reads ImGui label text), so what a test can witness is
    /// this function and the `pending` bit it reads — that is stated in the
    /// task rather than dressed up as coverage of the draw.
    string buildIndicatorText() const {
        if (!buildPending) return "";
        immutable long ms = estimatedBuildMsRemaining();
        if (ms <= 0) return "building subpatch preview...";
        import std.format : format;
        try {
            return format("building subpatch preview... ~%.1f s",
                          cast(double)ms / 1000.0);
        } catch (Exception) {
            return "building subpatch preview...";
        }
    }

    /// Estimated wall time the in-flight build still has to run, in ms, for
    /// the "building preview" indicator. Printed from MEASURED constants
    /// (task 1374: 4.45-4.96 us per limit face on the reference host), not
    /// from a guess: at the 800 000-face budget the top of the range is ~4 s.
    long estimatedBuildMsRemaining() const {
        if (!buildPending) return 0;
        import subpatch_osd : projectedLimitFaces, chooseSubpatchLevel;
        immutable long corners = snapPool[1 - snapBack].cornerCount;
        immutable int  lvl     = chooseSubpatchLevel(corners, depth);
        immutable long faces   = projectedLimitFaces(corners, lvl);
        immutable long totalMs = (faces * 5) / 1000;      // ~5 us per limit face
        immutable long spent   = (MonoTime.currTime - buildStarted).total!"msecs";
        return totalMs > spent ? totalMs - spent : 0;
    }

    import subpatch_osd : GpuFanOutTargets;

    /// Force the preview OFF and invalidate the staleness keys.
    ///
    /// A scene reset replaces the source mesh IN PLACE (same heap address,
    /// fresh contents), so a still-`active` preview whose cached
    /// (sourceMeshAddr, sourceEpoch, sourceVersion, depth) key happens to match the
    /// replacement would be left live by `rebuildIfStale`'s early-out — a
    /// cross-reset state leak. While the preview is live,
    /// `GpuMesh.suppressCageUpload` turns a tool-side cage upload into a bare
    /// `++mesh.mutationVersion` (the main loop owns the real upload). Those
    /// spurious version bumps then trip the transform tool's mutation-boundary
    /// poll, which resets the run and silently cancels an in-session falloff
    /// re-grade in the NEXT edit. Clearing the keys here forces the next
    /// `rebuildIfStale` to re-derive from scratch (and stay OFF for a
    /// non-subpatch mesh), so no reset can carry the preview into a fresh scene.
    void deactivate() {
        active                = false;
        sourceMeshAddr        = size_t.max;
        sourceEpoch           = ulong.max;
        sourceVersion         = ulong.max;
        sourceTopologyVersion = ulong.max;
        depth                 = -1;
        reusablePreviewReady  = false;
        reusablePreviewKey    = 0;
    }

    /// Drop the OSD-side LRU(2) TOPOLOGY cache — the cache layer BELOW the
    /// `reusablePreviewKey` one `deactivate()` clears (task 1374).
    ///
    /// ONE function rather than two copies of two lines, and the reason is
    /// evidence, not tidiness. Both scene-reset hooks call it
    /// (`scene.reset` and `file.new`, source/registration.d) but only the
    /// `scene.reset` one is reachable from a test: `/api/reset` routes to that
    /// factory, and nothing in the test suite or the perf lane drives
    /// `file.new`. With the body here, the perf lane's F-I8 witnesses the BODY
    /// for both hooks — mutate it and `frames --n 316 tab-cold` goes red. What
    /// remains unwitnessed is the single CALL LINE in the `file.new` hook, and
    /// that is said out loud at the call site rather than left looking covered.
    void dropTopologyCache() {
        // `clear()` first is no longer required for SAFETY — `destroyCache()`
        // drops its own borrowed aliases and clears `valid` (see its comment).
        // It is still wanted here because it ALSO frees the per-build fan-out
        // GL infrastructure (TBOs, programs, TF VAO) that a reset scene has no
        // further use for.
        osdAccel.clear();
        osdAccel.destroyCache();
    }

    private ulong computeReusablePreviewKey(ref const Mesh source, int d) const {
        import core.internal.hash : hashOf;
        ulong h = hashOf(d);
        h = hashOf(source.vertices.length, h);
        h = hashOf(source.edges.length, h);
        h = hashOf(source.faces.length, h);
        h = hashOf(source.vertices, h);
        h = hashOf(source.edges, h);
        foreach (face; source.faces) {
            h = hashOf(face.length, h);
            h = hashOf(face, h);
        }
        foreach (fi; 0 .. source.faces.length)
            h = hashOf(source.isFaceSubpatch(fi), h);
        // Hide (task 0613, R4). This is the Tab-toggle REUSE key: preview off,
        // preview on again, and if the key matches we resurrect the cached
        // preview mesh WITHOUT re-running buildPreview. That cached mesh
        // carries the Hide marks stamped from the cage at build time
        // (subpatch_osd.d), so a hide performed while the preview was off must
        // land in this key or the resurrected preview draws the pre-hide set.
        // Folded as its own per-face term rather than OR-ed into the Subpatch
        // one, so "face i subpatch" and "face i hidden" cannot cancel.
        foreach (fi; 0 .. source.faces.length)
            h = hashOf(source.isFaceHidden(fi), h);
        // Crease-weight fold (task 1062, same reasoning as the Hide fold
        // just above): this IS the Tab-toggle REUSE key. A weight changed
        // while the preview was off must land in this key, or the
        // resurrected preview (rebuildIfStale's reusablePreviewKey branch)
        // draws the pre-change surface — the crease-map analogue of the bug
        // the Hide fold was added to fix. Hashes the map's raw data when the
        // reserved map exists, a fixed sentinel when it does not, so
        // "no crease map" can never alias a real (all-zero-weight) map by
        // both folding down to the same value.
        {
            auto cw = source.creaseWeightMap();
            if (cw !is null) h = hashOf(cw.data, h);
            else              h = hashOf(0xC1EA5E00u, h);
        }
        return h == 0 ? 1 : h;
    }

    /// `targets` (when non-null) wires the GPU fan-out path: the
    /// position-only fast path attempts face, edge, vert dispatches
    /// in order, only doing the CPU readback fallback for the
    /// pieces that didn't make it onto GPU. Caller (app.d main loop)
    /// supplies gpu.{face,edge,vert}Vbo + matching counts.
    ///
    /// The epoch to stamp for `source`, read from the change bus's per-mesh
    /// GEOMETRY table (task 1906 stage 2d). One place, because the three
    /// rebuild entry points (`rebuild`, `dispatchBuild`, `pumpAsyncBuild`)
    /// each stamp at their own moment and one of them silently reading a
    /// different table than the early-out does is the whole failure mode of a
    /// split key. The `mutationVersion` half is stamped alongside it at every
    /// one of those sites — see `sourceVersion`.
    private static ulong stampSourceEpoch(ref const Mesh source) nothrow @nogc {
        import mesh_dirty : g_geomEpochs;
        return g_geomEpochs.epochFor(cast(size_t)&source);
    }

    /// TASK 1906 STAGE 2d — there is no `positionsDirty` parameter any more.
    /// The staleness key's freshness half is two terms read here at the lazy
    /// recompute: `mesh_dirty.g_geomEpochs` for this mesh's address, and
    /// `source.mutationVersion`. See `sourceEpoch` / `sourceVersion` for why
    /// it takes both and why an any-class epoch alone is a widening rather
    /// than parity. A caller with no bus in scope (a unit test over a scratch
    /// cage no `Document` owns, and therefore no delivery at all) drives the
    /// listener body by hand:
    /// `mesh_dirty.noteMeshChange(cast(size_t)&cage, flags)`.
    ///
    /// The epoch is sampled ONCE, here, and that same sample is what the
    /// rebuild stamps. A publisher that fires DURING the rebuild therefore
    /// leaves the stamp behind the live epoch and the next call rebuilds
    /// again — over-invalidation, which is the safe direction.
    void rebuildIfStale(ref const Mesh source, int d,
                         const(GpuFanOutTargets)* targets = null) {
        lastRefreshFannedOut    = false;
        lastRefreshSkipNonFace  = false;
        const srcAddr = cast(size_t)&source;
        import mesh_dirty : g_geomEpochs;
        const ulong srcEpoch = g_geomEpochs.epochFor(srcAddr);
        // recorded remainder (1906 §3.6): `mutationVersion` owns the THIRD term
        // of this early-out and is REQUIRED beside the epoch, not belt-and-
        // braces. `GeomEpochMask` deliberately drops `Marks` (a Tab toggle) and
        // `Material` (a crease weight); the counter carries both. The epoch
        // carries what the counter cannot — the version-silent gizmo `Position`
        // of task 0401. Dropping either term is a live bug, and each has its
        // own witness (see `sourceEpoch` / `sourceVersion`).
        if (sourceMeshAddr == srcAddr
            && sourceEpoch == srcEpoch
            && sourceVersion == source.mutationVersion && depth == d)
            return;
        // Position-only fast path: SAME source mesh, cage topology + depth
        // unchanged → ask OSD's stencil table for new limit positions. A
        // different source address (layer switch) must NOT take this path — the
        // cached stencil table belongs to the prior layer's cage.
        //
        // recorded remainder (1906 §3.6): `topologyVersion` owns the
        // `sourceTopologyVersion` term below, and it is NOT a freshness signal.
        // It is the INDEX-SPACE IDENTITY of the stencil table already built —
        // "is the limit surface still laid out for this source topology, so new
        // positions can be scattered into it". A change class answers "something
        // moved"; only an identity answers "the layout is the same one".
        if (active
            && sourceMeshAddr == srcAddr
            && depth == d
            && sourceTopologyVersion == source.topologyVersion
            && osdAccel.valid)
        {
            bool didFace  = false;
            bool didEdges = false;
            bool didVerts = false;
            if (targets !is null && osdAccel.canFanOut
                && targets.faceVbo != 0
                && osdAccel.refreshIntoFaceVbo(source,
                        targets.faceVbo, targets.faceVertCount))
            {
                didFace = true;
                // GPU eval already ran inside refreshIntoFaceVbo.
                // limitGlVbo is hot — try the edge / vert dispatches
                // off the same data.
                if (targets.edgeVbo != 0 && osdAccel.canFanOutEdges
                    && osdAccel.refreshEdgeVbo(targets.edgeVbo,
                                                targets.edgeSegCount))
                    didEdges = true;
                if (targets.vertVbo != 0 && osdAccel.canFanOutVerts
                    && osdAccel.refreshVertVbo(targets.vertVbo,
                                                targets.vertCount))
                    didVerts = true;
            }

            if (didFace) {
                lastRefreshFannedOut = true;
                if (didEdges && didVerts) {
                    // Phase 3c — all three VBOs written on GPU.
                    // preview.vertices stays stale (no CPU readback)
                    // since no consumer needs it on the drag-frame
                    // path. Lasso mouse-up reads it via a one-shot
                    // sync (handled at the lasso site).
                    lastRefreshSkipNonFace = true;
                } else {
                    // Face on GPU, but edge or vert needed the CPU
                    // path → readback so refreshNonFacePositions
                    // sees fresh data.
                    osdAccel.readLimitIntoPreview(mesh);
                }
            } else {
                // Fan-out unavailable / layout mismatch — full CPU
                // (or GPU-with-readback) eval path.
                osdAccel.refresh(source, mesh);
            }
            ++mesh.mutationVersion;
            sourceMeshAddr = srcAddr;
            sourceEpoch    = srcEpoch;
            sourceVersion  = source.mutationVersion;
            return;
        }
        if (!active && d > 0 && source.hasAnySubpatch()
            && reusablePreviewReady
            && reusablePreviewKey == computeReusablePreviewKey(source, d)
            && mesh.vertices.length != 0)
        {
            depth                 = d;
            sourceMeshAddr        = srcAddr;
            sourceEpoch           = srcEpoch;
            sourceVersion         = source.mutationVersion;
            sourceTopologyVersion = source.topologyVersion;
            active                = true;
            ++mesh.mutationVersion;
            return;
        }
        // Task 1500. The synchronous build is still what the module
        // unittests and the IPR preview take; the editor dispatches instead.
        if (asyncEnabled && worker !is null) {
            requestAsyncBuild(source, d);
            return;
        }
        rebuild(source, d);
    }

    /// Async twin of `rebuild`'s "do the build" tail.
    ///
    /// Tab-OFF and "the cage has no subpatch faces" are answered
    /// SYNCHRONOUSLY, because those are the two paths whose whole job is to
    /// stop the preview from participating: deferring them would leave a live
    /// preview `trace` selecting for however long the deferral lasted. The
    /// expensive direction — build a preview — is the one that goes to the
    /// worker.
    private void requestAsyncBuild(ref const Mesh source, int d) {
        if (d <= 0 || !source.hasAnySubpatch()) {
            // TAB-OFF DOES NOT JOIN, and that is the case that matters:
            // un-Tabbing flips the subpatch MASK, so it lands on the
            // `!hasAnySubpatch` branch of `rebuild`, which sets `active =
            // false` and returns without touching `osdAccel` at all. Blocking
            // there would re-freeze the window on exactly the build this task
            // moved off the main thread. The in-flight result is thrown away
            // on arrival by the ordinary key check (the mask is in the key),
            // and no re-dispatch follows because `hasAnySubpatch` is false.
            //
            // `d <= 0` — the depth control taken to zero, NOT Tab — does go
            // through `rebuild`'s clearing branch and therefore through
            // `osdAccel.clear()`'s bounded join. It is a rarer action, and
            // the wait is bounded by the build it is waiting on.
            rebuild(source, d);
            return;
        }
        if (buildPending) {
            // LAST DISPATCH WINS, and the loser is not cancelled: the point
            // of no return is inside the third-party stencil builder. The
            // in-flight build runs to completion and the receiver throws its
            // result away on the key check, then dispatches again. Named
            // cost: up to one full build of background core burnt.
            return;
        }
        dispatchBuild(source, d);
    }

    void rebuild(ref const Mesh source, int d) {
        depth                 = d;
        sourceMeshAddr        = cast(size_t)&source;
        sourceEpoch           = stampSourceEpoch(source);
        sourceVersion         = source.mutationVersion;
        sourceTopologyVersion = source.topologyVersion;
        if (d <= 0) {
            cageVertPreview.length = 0;
            osdAccel.clear();
            mesh   = Mesh.init;
            trace  = SubpatchTrace.init;
            active = false;
            reusablePreviewReady = false;
            reusablePreviewKey   = 0;
            return;
        }
        if (!source.hasAnySubpatch()) {
            active = false;
            return;
        }

        // Task 1620 — THE INDEX SPACE IS DISCARDED HERE, which is the event
        // the counter is about. Counted after the two branches above, which
        // derive nothing: `d <= 0` (Tab / depth zero) and a cage with no
        // subpatch faces both leave the preview off, and neither can happen
        // mid-drag. See the field's doc comment.
        ++topologyBuilds;
        cageVertPreview.length = 0;
        osdAccel.clear();

        // OsdAccel.buildPreview feeds the WHOLE cage to OpenSubdiv (stale
        // note fixed, task 1062: unlike catmullClarkOsd, which DOES extract
        // the subpatch-marked subset into a sub-cage, buildPreview never
        // subsets — cage edge index == mesh edge index, with no remap).
        // Selective subpatch is simulated by crease/corner sharpness
        // (SHARP_INF) on the un-marked region's boundary instead of face
        // removal, so non-subpatch faces DO appear in the preview — held
        // flat by the sharpness markers rather than smoothed — see
        // OsdAccel.buildPreview for the trade-off rationale.
        if (!osdAccel.buildPreview(source, d, mesh, trace)) {
            // OSD topology creation failed on a degenerate input —
            // leave the preview inert rather than rendering stale
            // geometry. Callers fall through to rendering the cage.
            mesh   = Mesh.init;
            trace  = SubpatchTrace.init;
            active = false;
            reusablePreviewReady = false;
            reusablePreviewKey   = 0;
            return;
        }

        active = true;
        reusablePreviewKey   = computeReusablePreviewKey(source, d);
        reusablePreviewReady = true;
        buildCageVertPreview(source);
    }

    /// Reverse `trace.vertOrigin` into `cageVertPreview`. Its own function
    /// since task 1500: the asynchronous receiver publishes the same preview
    /// through a different path and must build the same reverse map.
    private void buildCageVertPreview(ref const Mesh source) {
        cageVertPreview = new uint[](source.vertices.length);
        cageVertPreview[] = uint.max;
        foreach (pi, origin; trace.vertOrigin) {
            if (origin == uint.max) continue;
            if (origin >= cageVertPreview.length) continue;
            // First preview vert that maps back wins; for the
            // smoothed-original verts there's only one such vert per
            // cage vert anyway.
            if (cageVertPreview[origin] == uint.max)
                cageVertPreview[origin] = cast(uint)pi;
        }
    }
}
