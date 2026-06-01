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
    // --- counters ---
    falloffEvalCount,
    vertsTouched,
}

/// First counter category. Categories with ordinal < this are timers.
private enum Cat firstCounter = Cat.falloffEvalCount;

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
}

/// Process-wide probe. Read/written from the main loop (timers + counters)
/// and read from the HTTP thread (GET /api/perf). Reads of plain counters
/// across threads are benign for this diagnostic use — no lock.
__gshared PerfProbe g_perf;
