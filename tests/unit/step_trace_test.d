// Module unittests for `step_trace`, moved verbatim out of source/step_trace.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.step_trace_test;

import core.sync.mutex : Mutex;
import std.array : join;
import step_trace;

unittest {
    auto t = new StepTrace();
    assert(t.snapshotJson() == "[]");
    assert(t.nextSeq() == 0);
    t.append(`{"seq":0}`);
    assert(t.nextSeq() == 1);
    t.append(`{"seq":1}`);
    assert(t.snapshotJson() == `[{"seq":0},{"seq":1}]`);
    t.reset();
    assert(t.snapshotJson() == "[]");
    assert(t.nextSeq() == 0);
}

unittest {
    // Ring eviction: appending past maxEntries drops the oldest entries so
    // the array only ever holds the newest maxEntries.
    import std.format : format;
    import std.string : startsWith, endsWith;
    auto t = new StepTrace();
    foreach (i; 0 .. StepTrace.maxEntries + 10)
        t.append(format("%d", i));
    string snap = t.snapshotJson();
    assert(snap.startsWith("[10,"), snap);
    assert(snap.endsWith(format("%d]", StepTrace.maxEntries + 9)), snap);
}
