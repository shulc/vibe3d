// Module unittests for the GC instrument (task 2070).
//
// WHAT IS AND IS NOT TESTABLE HERE. `FrameProbe` — the per-frame consumer of
// these fields — lives behind `version (PerfProbe)` and is compiled out of
// every build but `perf`, which is NOT a build either default gate makes. So
// a witness written against `FrameProbe` could never run here. What runs here
// is the machinery `FrameProbe` USES and shares verbatim with the per-command
// probe: `gcSampleNow`, `gcWindowMaxPauseNs`, `CommandGcProbe`. Both consumers
// derive their pause figure from the SAME pure function, so a defect in the
// derivation reddens these blocks.
//
// EVERY BLOCK IS SEPARATE ON PURPOSE. druntime aborts a module at its FIRST
// failing assert, so blocks merged for brevity would hide each other under a
// mutation; split, each one names its own reason.
module tests.unit.gc_instrument_test;

import core.memory : GC;
import perf_probe : GcSample, gcSampleNow, gcWindowMaxPauseNs,
                    CommandGcProbe, currentThreadId, g_mainLoopThreadId;

// Allocate roughly `mb` megabytes in blocks the GC cannot fold away, and drop
// them, so a collection has real work to do. Returns the live tail so the
// optimizer cannot delete the whole thing.
private void[] churn(size_t mb) {
    void[][] keep;
    foreach (i; 0 .. mb * 4) keep ~= new void[](256 * 1024);
    return keep[$ - 1];
}

unittest { // gcWindowMaxPauseNs: no collection ⇒ no pause, whatever the maxima say
    // The standing max is huge and the window still owns none of it.
    assert(gcWindowMaxPauseNs(50_000_000, 50_000_000, 0, 0) == 0);
    assert(gcWindowMaxPauseNs(0, 0, 0, 0) == 0);
    // A negative collection delta (counter reset under us) is not a pause.
    assert(gcWindowMaxPauseNs(10, 10, 999, -1) == 0);
}

unittest { // gcWindowMaxPauseNs: the running max GREW ⇒ the window owns exactly it
    // 12 ms standing, 40 ms after: the 40 ms pause happened HERE, and the
    // window's worst pause is the new max, not the 28 ms difference.
    assert(gcWindowMaxPauseNs(12_000_000, 40_000_000, 41_000_000, 1)
           == 40_000_000,
           "a grown running max IS the window's worst pause");
}

unittest { // gcWindowMaxPauseNs: THE TRAP — a real pause under a standing record
    // This is the cell a naive `maxAfter - maxBefore` gets wrong, and gets
    // wrong SILENTLY: some earlier window already saw 30 ms, this window
    // paused for 5 ms, and the subtraction reports ZERO — i.e. it under-
    // reports exactly the frames a 16.7 ms budget cares about.
    immutable long got = gcWindowMaxPauseNs(30_000_000, 30_000_000,
                                            5_000_000, 1);
    assert(got != 0,
           "a window that paused must never report 0 just because an " ~
           "earlier window paused for longer");
    assert(got == 5_000_000,
           "with one collection the window's pause TOTAL is its worst pause");
}

unittest { // gcWindowMaxPauseNs: k > 1 over-estimates, and never under-estimates
    // Two collections summing to 6 ms under a 30 ms standing record: the true
    // worst is somewhere in [3 ms, 6 ms] and we report the upper end.
    immutable long got = gcWindowMaxPauseNs(30_000_000, 30_000_000,
                                            6_000_000, 2);
    assert(got == 6_000_000);
    assert(got >= 6_000_000 / 2, "must never fall below the arithmetic mean");
}

unittest { // the pause fields are LIVE, not zero-by-construction (direction 1)
    // A field that is read but never written reads 0 forever, and 0 is ALSO
    // the correct answer for a window in which nothing collected — so a green
    // 0 proves nothing on its own. This block forces real collections and
    // demands a nonzero reading; its twin below demands 0 from a quiet
    // window. Neither direction alone can tell a live field from a dead one.
    CommandGcProbe p;
    p.begin();
    auto tail = churn(96);
    GC.collect();
    p.end();
    if (tail.length) { /* keep the churn alive to here */ }

    assert(p.commands == 1, "the bracket must have closed exactly once");
    assert(p.lastCollections > 0,
           "a forced collect after ~96 MB of churn must register a collection");
    assert(p.lastMaxPauseNs > 0,
           "GC.profileStats().maxPauseTime is reaching the record: a " ~
           "collection ran and its pause must be nonzero");
    assert(p.lastPauseNs > 0, "totalPauseTime must have advanced too");
    assert(p.lastCollectNs >= p.lastPauseNs,
           "collection time includes the stop-the-world pause");
}

unittest { // the pause fields are LIVE, not stuck-nonzero (direction 2)
    // The complement of the block above: a window that collects nothing must
    // read 0 on all three, even though the PROCESS-WIDE maxPauseTime is by
    // now large (the churn block above raised it). A field wired to the raw
    // running max instead of the derivation would report that standing max
    // here and this assert names it.
    CommandGcProbe p;
    p.begin();
    // No allocation, no collection. A trivial integer loop the optimizer may
    // fold; folding it is fine, the point is that nothing hits the heap.
    long acc;
    foreach (i; 0 .. 1000) acc += i;
    p.end();
    assert(acc == 499_500);

    assert(p.commands == 1);
    // UNCONDITIONAL on purpose. Wrapping these in `if (lastCollections == 0)`
    // would be a second, unnamed guard that can refuse before the assert
    // under test is ever reached, making the block quietly vacuous. It is
    // sound to demand it: D's GC only starts a collection on an allocation,
    // and this window makes none.
    assert(p.lastCollections == 0,
           "a window that touches no heap cannot collect");
    assert(p.lastMaxPauseNs == 0,
           "a window with no collection must report NO pause, not the " ~
           "process's standing maximum");
    assert(p.lastPauseNs == 0);
}

unittest { // the bracket is real: work OUTSIDE it is not counted
    // The mutation this block exists to catch is moving a sample to the wrong
    // side of the work. Allocate a large, known amount BEFORE `begin()`; the
    // probe must not see it.
    auto before = churn(48);
    CommandGcProbe p;
    p.begin();
    p.end();
    if (before.length) {}
    assert(p.lastAllocBytes < 8 * 1024 * 1024,
           "48 MB allocated BEFORE begin() leaked into the bracket — the " ~
           "sample is on the wrong side of the work");
}

unittest { // the bracket is real: work INSIDE it IS counted, and tracks its size
    // Potency, at unit scale: a nearly-free window and a heavy one must not
    // read the same, or the instrument is dead.
    CommandGcProbe light;
    light.begin();
    light.end();

    CommandGcProbe heavy;
    heavy.begin();
    auto tail = churn(32);
    heavy.end();
    if (tail.length) {}

    assert(heavy.lastAllocBytes > 24 * 1024 * 1024,
           "~32 MB of churn inside the bracket must show up as bytes");
    assert(heavy.lastAllocBytes > light.lastAllocBytes * 100 + 1_000_000,
           "a heavy window and an empty one must not read the same");
}

unittest { // a nested dispatch does not reset the outer bracket's base
    // A command that fires another command must not leave the outer window
    // reporting only its own tail. The OUTERMOST bracket owns the window.
    CommandGcProbe p;
    p.begin();
    auto a = churn(16);
    p.begin();          // inner "command"
    auto b = churn(16);
    p.end();            // inner close — must publish NOTHING
    assert(p.commands == 0, "an inner close must not publish a command");
    auto c = churn(16);
    p.end();            // outer close
    if (a.length && b.length && c.length) {}

    assert(p.commands == 1);
    assert(p.lastAllocBytes > 40 * 1024 * 1024,
           "the outer window must span all three churns (~48 MB), not just " ~
           "the tail after the inner close");
}

unittest { // running totals accumulate; the running MAX does not sum
    CommandGcProbe p;
    foreach (i; 0 .. 3) {
        p.begin();
        auto t = churn(8);
        p.end();
        if (t.length) {}
    }
    assert(p.commands == 3);
    assert(p.sumAllocBytes > 20 * 1024 * 1024);
    // maxPauseTime is a MAX, not a sum: the running figure must equal the
    // largest single reading, never their total.
    assert(p.runMaxPauseNs >= p.lastMaxPauseNs);
    if (p.sumPauseNs > 0)
        assert(p.runMaxPauseNs <= p.sumPauseNs,
               "a running MAX can never exceed the sum it is drawn from");
}

unittest { // the thread the bracket ran on is recorded, and a wrong one is caught
    // `GC.allocatedInCurrentThread` is PER-THREAD, so a bracket taken on a
    // thread other than the one that ran the work measures the wrong thread's
    // allocation — a small, stable, plausible-looking number unrelated to the
    // command. `offMainThreadBrackets` is the runtime check on that, and it
    // can only discriminate because `g_mainLoopThreadId` is sourced
    // INDEPENDENTLY (app.d at startup) rather than from the dispatch site.
    immutable size_t saved = g_mainLoopThreadId;
    scope(exit) g_mainLoopThreadId = saved;

    // Right thread: this one.
    g_mainLoopThreadId = currentThreadId();
    CommandGcProbe ok;
    ok.begin();
    ok.end();
    assert(ok.lastThreadId == g_mainLoopThreadId);
    assert(ok.offMainThreadBrackets == 0,
           "a bracket on the recorded main-loop thread must not be flagged");

    // Wrong thread: pretend the main loop is someone else.
    g_mainLoopThreadId = saved + 0xBEEF;   // an identity this thread cannot have
    CommandGcProbe bad;
    bad.begin();
    bad.end();
    assert(bad.offMainThreadBrackets == 1,
           "a bracket taken off the main-loop thread must be counted — this " ~
           "is the only runtime signal that the per-thread allocation " ~
           "counter is being read on the thread that did not do the work");
}

unittest { // gcSampleNow reads all five counters, and the four global ones are monotone
    auto a = gcSampleNow();
    auto tail = churn(24);
    GC.collect();
    auto b = gcSampleNow();
    if (tail.length) {}
    assert(b.allocBytes    >= a.allocBytes);
    assert(b.collections   >= a.collections);
    assert(b.totalPauseNs  >= a.totalPauseNs);
    assert(b.maxPauseNs    >= a.maxPauseNs, "maxPauseTime is a RUNNING max");
    assert(b.totalCollectNs>= a.totalCollectNs);
    // The whole point of the task: these four were fetched and discarded
    // before. At least one of them must be nonzero after a forced collect,
    // or profileStats is not populating on this runtime and every pause
    // number downstream is a constant 0 dressed as a measurement.
    assert(b.collections > a.collections);
    assert(b.totalPauseNs > a.totalPauseNs,
           "GC.profileStats().totalPauseTime is not advancing — the pause " ~
           "columns downstream would be structurally zero");
}
