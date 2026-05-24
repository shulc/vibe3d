module perf_helpers;

// Tiny shared harness for the Stage-D performance regression tests.
//
// Scope: this is a REGRESSION CATCHER, not a precision benchmark.
// Each measurement is wall-clock through the HTTP API, so it includes
// ~1-3 ms of TCP / parse / dispatch overhead per call. Budgets in the
// individual tests are sized generously (×3-×5 the typical observed
// median) so that:
//   • normal CI / dev-host variance doesn't trip them
//   • but a genuine order-of-magnitude regression — e.g. an O(n²) loop
//     creeping into a hot path — definitely does
//
// Why this lives alongside the regular tests rather than under tests/perf/
// with its own runner: keeps the tooling surface small. The price is
// that test_perf_*.d is opt-in (excluded by default in run_all.d so
// pre-commit runs stay fast and noise-free) and the harness is bare-
// bones — just timeMedian().

import std.algorithm : sort;
import core.time     : MonoTime, Duration;

/// Run `body_()` `n` times, return the median elapsed time in
/// milliseconds. Discards the first run (acts as a warm-up — JIT-style
/// effects, cache priming, HTTP connection pooling can make iteration 1
/// disproportionately slow even though steady state is fine).
double timeMedianMs(int n, void delegate() body_) {
    assert(n >= 3, "need ≥3 runs for a useful median (warmup + at least 2)");
    body_();   // warmup, discarded
    double[] samples;
    samples.length = n;
    foreach (i; 0 .. n) {
        auto t0 = MonoTime.currTime;
        body_();
        Duration d = MonoTime.currTime - t0;
        samples[i] = d.total!"hnsecs" / 10_000.0;   // hnsecs → ms
    }
    sort(samples);
    return samples[$ / 2];
}

/// String-format helper used by the asserts so failure messages stay
/// short. Returns "Xms" with one decimal.
string fmtMs(double ms) {
    import std.format : format;
    return format("%.1fms", ms);
}
