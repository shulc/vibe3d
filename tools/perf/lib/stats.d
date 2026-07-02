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
    long steadyMaxAllocBytes;
    FrameRecJ worst;
}
