module lib.stats;
// Pure math / shaping helpers shared by the `ops` and `frames` subcommands:
// median/p95, ns→ms conversion, JSON-safe number formatting, and the
// FrameProbe per-frame record/stats shapes (JSON-parsed but otherwise HTTP-
// agnostic — the actual GET lives in lib.http.fetchFrames).
//
// Extracted from tools/perf/run.d as part of task 0197 (perf tooling
// consolidation) — pure code-motion, no behavior change.

import std.algorithm : sort;
import std.array     : appender;
import std.format    : format;
import std.json      : JSONValue, JSONType;

double medianOf(double[] xs) {
    if (xs.length == 0) return 0;
    auto s = xs.dup; s.sort();
    return s[s.length / 2];
}
double p95Of(double[] xs) {
    if (xs.length == 0) return 0;
    auto s = xs.dup; s.sort();
    size_t idx = cast(size_t)((s.length - 1) * 95 / 100);
    return s[idx];
}

double msFromNs(long ns) { return cast(double)ns / 1_000_000.0; }

// Task 2070 — the run-to-run SPREAD of a per-repeat column: max - min.
//
// Deliberately the full range and not a standard deviation: with the 3-7
// repeats this harness runs, a sigma is a fiction, while "the worst two
// readings differed by this much" is exactly the fact that decides whether a
// column can ever carry a gate. 0 for fewer than two samples.
double spreadOf(double[] xs) {
    if (xs.length < 2) return 0;
    double lo = xs[0], hi = xs[0];
    foreach (v; xs[1 .. $]) { if (v < lo) lo = v; if (v > hi) hi = v; }
    return hi - lo;
}

// Pair up two equal-length before/after columns into per-repeat deltas, so a
// spread can be taken over the DELTAS rather than over either endpoint. A
// spread of `after` alone would mostly measure the process's overall growth
// across the run, not the per-repeat variation of what the command costs.
double[] perRepeatDeltas(double[] before, double[] after) {
    size_t n = before.length < after.length ? before.length : after.length;
    double[] d;
    d.reserve(n);
    foreach (i; 0 .. n) d ~= after[i] - before[i];
    return d;
}

// JSON-safe number: a bare `%.3f` renders NaN as `nan`, which is INVALID
// JSON and breaks loadBaseline (std.json throws). Command cases have no
// pipe stages, so their pipe median is legitimately NaN — emit `null`.
string jsonNum(double v) {
    import std.math : isNaN;
    return v.isNaN ? "null" : format("%.3f", v);
}

string replicate(string s, size_t n) {
    auto a = appender!string();
    foreach (_; 0 .. n) a.put(s);
    return a.data;
}

// ---------------------------------------------------------------------------
// /api/frames — FrameProbe (task 0195) shapes. The fetch itself
// (lib.http.fetchFrames) does the HTTP GET + hands back a FrameStats built
// from these.
// ---------------------------------------------------------------------------

// One record from FrameProbe's "worst" / "worstN" (source/perf_probe.d
// FrameRec — total + per-phase ns + GC deltas for a single frame).
struct FrameRecJ {
    long totalNs, eventNs, toolNs, cacheNs, drawNs, uploadNs, uiNs;
    long gcAllocBytes, gcCollections;
    // Task 2070 — what those collections COST this frame. `gcMaxPauseNs` is
    // the worst SINGLE stop-the-world pause and is the field that answers a
    // 60 fps question (16.7 ms/frame): four 200 us collections and one 40 ms
    // one are the same `gcCollections` and a completely different editor.
    // PROCESS-GLOBAL, unlike `gcAllocBytes` above, which is main-thread-only
    // — a render worker's collections land here too.
    long gcMaxPauseNs, gcPauseNs, gcCollectNs;
    // Task 1800 — per-phase alloc deltas. NOT a partition of gcAllocBytes:
    // the phases do not tile the frame and `tool` nests inside `events`, so
    // they overlap exactly as the ns fields do.
    long eventAlloc, toolAlloc, cacheAlloc, drawAlloc, uploadAlloc, uiAlloc;
}

FrameRecJ parseFrameRec(JSONValue j) {
    FrameRecJ r;
    r.totalNs       = j["totalNs"].integer;
    r.eventNs       = j["eventNs"].integer;
    r.toolNs        = j["toolNs"].integer;
    r.cacheNs       = j["cacheNs"].integer;
    r.drawNs        = j["drawNs"].integer;
    r.uploadNs      = j["uploadNs"].integer;
    r.uiNs          = j["uiNs"].integer;
    r.gcAllocBytes  = j["gcAllocBytes"].integer;
    r.gcCollections = j["gcCollections"].integer;
    // Guarded like the task-1800 alloc block below: an older binary on the
    // other end of the socket simply has no such key.
    if ("gcMaxPauseNs" in j) {
        r.gcMaxPauseNs = j["gcMaxPauseNs"].integer;
        r.gcPauseNs    = j["gcPauseNs"].integer;
        r.gcCollectNs  = j["gcCollectNs"].integer;
    }
    if ("eventAlloc" in j) {
        r.eventAlloc  = j["eventAlloc"].integer;
        r.toolAlloc   = j["toolAlloc"].integer;
        r.cacheAlloc  = j["cacheAlloc"].integer;
        r.drawAlloc   = j["drawAlloc"].integer;
        r.uploadAlloc = j["uploadAlloc"].integer;
        r.uiAlloc     = j["uiAlloc"].integer;
    }
    return r;
}

// Parsed /api/frames snapshot. `empty` is true when the binary has no
// PerfProbe instrumentation (default build ⇒ "{}") or the window recorded
// zero frames — callers must check it before trusting any other field.
struct FrameStats {
    bool empty = true;
    long frameCount;
    long p50Ns, p95Ns, p99Ns, maxNs;
    long hitch16, hitch33;
    long meshCacheRebuilds;
    long gcAllocBytes;     // sum across the window
    long gcCollections;    // sum across the window
    long gcPauseNs;        // task 2070 — stop-the-world total across the window
    long gcMaxPauseNs;     // the window's WORST single pause — NOT a sum
    long gcHitch16;        // frames whose own GC pause alone blew 16.6 ms
    long steadyMaxAllocBytes;
    long sumCacheNs;        // task 1540 — the `cache` phase over the window
    FrameRecJ worst;
}
