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
/// `scope_`); the last two are counters (recorded via `count`). Ordering
/// is stable so `toJson` emits a predictable key order.
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
    viewcacheRebuild,  // screen-space pick-cache invalidate (camera/mesh change)
    hoverPick,         // per-frame hover pick (GPU ID-FBO + BVH face raycast)
    subpatchPreview,   // OSD subpatch preview rebuild
    // --- counters ---
    falloffEvalCount,
    vertsTouched,
}

/// First counter category. Categories with ordinal < this are timers.
private enum Cat firstCounter = Cat.falloffEvalCount;

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
}

version (PerfProbe) {

    // -----------------------------------------------------------------------
    // Active implementation (perf buildType).
    // -----------------------------------------------------------------------

    /// RAII scope timer. Records elapsed MonoTime into its category on
    /// destruction. Construct via `g_perf.scope_(Cat.x)`; let it die at
    /// end of scope. Non-copyable so the stop time is taken exactly once.
    struct ScopeTimer {
        private MonoTime start_;
        private Cat cat_;
        private bool armed_;

        @disable this(this);

        ~this() {
            if (!armed_) return;
            const elapsed = MonoTime.currTime - start_;
            g_perf.recordNs(cat_, elapsed.total!"nsecs");
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
        void add(long n) { count++; sum += n; }
        void clear() { this = CounterStat.init; }
    }

    struct PerfProbe {
        private TimerStat[firstCounter]              timers_;
        private CounterStat[Cat.max + 1 - firstCounter] counters_;

        /// Open a scope timer for `c`. Records on destruction.
        ScopeTimer scope_(Cat c) {
            ScopeTimer z;
            z.cat_ = c;
            z.armed_ = true;
            z.start_ = MonoTime.currTime;
            return z;
        }

        /// Add `n` to a counter category (vertsTouched / falloffEvalCount).
        /// No-op (with a debug consistency check) if `c` is a timer.
        void count(Cat c, long n) {
            if (c < firstCounter) {
                debug assert(false, "perf_probe.count called on a timer category");
                return;
            }
            counters_[c - firstCounter].add(n);
        }

        /// Internal: record an elapsed-ns sample into a timer category.
        /// Called by ScopeTimer.~this. No-op if `c` is a counter.
        void recordNs(Cat c, long ns) {
            if (c >= firstCounter) return;
            timers_[c].add(ns);
        }

        /// Zero every category. Call before a measured run
        /// (POST /api/perf/reset).
        void reset() {
            foreach (ref t; timers_)   t.clear();
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
                        `"median_ns":%d,"p95_ns":%d}`,
                        member, t.count, t.sum,
                        t.count > 0 ? t.min : 0,
                        t.count > 0 ? t.max : 0,
                        median, p95);
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
        private Phase p_;
        private bool armed_;

        @disable this(this);

        ~this() {
            if (!armed_) return;
            const elapsed = MonoTime.currTime - start_;
            g_frames.addPhase(p_, elapsed.total!"nsecs");
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
        private long meshCacheRebuilds;

        // In-flight frame state.
        private FrameRec  cur_;
        private MonoTime  frameStart_;
        private ulong     allocBase_;
        private size_t    collBase_;

        /// Start a new frame. Call as the FIRST statement inside
        /// `while (running)` in app.d.
        void beginFrame() {
            cur_ = FrameRec.init;
            frameStart_ = MonoTime.currTime;
            allocBase_  = GC.allocatedInCurrentThread;
            collBase_   = GC.profileStats().numCollections;
        }

        /// Open a scope timer for phase `p`. Records into `cur_` on
        /// destruction; multiple opens of the same phase within one frame
        /// (e.g. `draw` across an N-cell render loop) accumulate.
        PhaseTimer phase(Phase p) {
            PhaseTimer z;
            z.p_ = p;
            z.armed_ = true;
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
                sumAllocBytes, sumCollections, meshCacheRebuilds);
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
            cur_.gcCollections = cast(long)(GC.profileStats().numCollections - collBase_);

            ring[ringPos] = cur_;                 // write FIRST
            ringPos = (ringPos + 1) % Ring;        // then advance
            if (ringLen < Ring) ringLen++;         // then publish

            frameCount++;
            if (cur_.totalNs > 16_600_000) hitch16++;
            if (cur_.totalNs > 33_000_000) hitch33++;
            sumAllocBytes  += cur_.gcAllocBytes;
            sumCollections += cur_.gcCollections;
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
            meshCacheRebuilds = 0;
        }

        private static string recJson(const ref FrameRec r) {
            import std.format : format;
            return format(
                `{"totalNs":%d,"eventNs":%d,"toolNs":%d,"cacheNs":%d,` ~
                `"drawNs":%d,"uploadNs":%d,"uiNs":%d,"gcAllocBytes":%d,` ~
                `"gcCollections":%d}`,
                r.totalNs, r.eventNs, r.toolNs, r.cacheNs, r.drawNs,
                r.uploadNs, r.uiNs, r.gcAllocBytes, r.gcCollections);
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
                `"gcAllocBytes":%d,"gcCollections":%d`,
                hitch16, hitch33, meshCacheRebuilds,
                sumAllocBytes, sumCollections);

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
        pragma(inline, true) void count(Cat, long) {}
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
