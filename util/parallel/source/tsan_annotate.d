// Thin ThreadSanitizer annotations for parallel loops whose library join is
// implemented with synchronization the instrument cannot see. Native builds
// keep that runner; browser builds use the serial runner and import no thread
// pool. Task 6950's closure/parity witness is
// tests/unit/version_gate_census_ai3d_remesh_test.d plus mesh_test.d; task
// 6340's sanitizer witness is tools/sanitizer/parallel_loop_completion_probe.d.
module tsan_annotate;

import std.range : iota;

version (unittest) {
    private size_t g_serialRunnerCalls;
    private size_t g_parallelRunnerCalls;
    private bool g_forceSerialRunner;

    void resetLoopRunnerProbe() {
        g_serialRunnerCalls = 0;
        g_parallelRunnerCalls = 0;
    }
    size_t serialRunnerCalls() { return g_serialRunnerCalls; }
    size_t parallelRunnerCalls() { return g_parallelRunnerCalls; }
    void forceSerialLoopRunnerForTest(bool enabled) {
        g_forceSerialRunner = enabled;
    }
}

pragma(inline, true)
void serialForWithCompletion(alias work)(size_t count) {
    version (unittest) ++g_serialRunnerCalls;
    foreach (idx; iota(count)) work(idx);
}

version (web) {
    alias parallelForWithCompletion = serialForWithCompletion;
} else {
    import std.parallelism : parallel;

    version (SanitizerThreadPreinit) {
        // SanitizerThreadPreinit is intentionally the gate: dub.json declares it
        // only for the `tsan` build type. SanitizerSelfTest also exists in the
        // ASan/check builds, where these runtime entry points are not linked.
        extern(C) void AnnotateHappensBefore(const(char)* file, int line,
                                             void* address);
        extern(C) void AnnotateHappensAfter(const(char)* file, int line,
                                            void* address);
    }

    /// Run one parallel range and make its completion visible to ThreadSanitizer.
    /// Every worker publishes after its last write; the caller acquires only after
    /// `parallel` has returned, preserving the library's real join semantics.
    pragma(inline, true)
    void parallelForWithCompletion(alias work)(size_t count) {
        version (unittest) {
            if (g_forceSerialRunner) {
                serialForWithCompletion!work(count);
                return;
            }
        }
        version (unittest) ++g_parallelRunnerCalls;
        version (SanitizerThreadPreinit) {
            ubyte completionToken;
            foreach (idx; parallel(iota(count))) {
                work(idx);
                AnnotateHappensBefore(__FILE__.ptr, __LINE__, &completionToken);
            }
            AnnotateHappensAfter(__FILE__.ptr, __LINE__, &completionToken);
        } else {
            foreach (idx; parallel(iota(count))) work(idx);
        }
    }
}
