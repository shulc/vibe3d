// Thin ThreadSanitizer annotations for parallel loops whose library join is
// implemented with synchronization the instrument cannot see. Task 6340's
// committed witness is tools/sanitizer/parallel_loop_completion_probe.d.
module tsan_annotate;

import std.parallelism : parallel;
import std.range : iota;

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
