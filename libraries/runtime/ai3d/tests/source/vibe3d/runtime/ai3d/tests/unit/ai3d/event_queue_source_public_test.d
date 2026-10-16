module vibe3d.runtime.ai3d.tests.unit.ai3d.event_queue_source_public_test;

import core.sync.mutex : Mutex;
import vibe3d.runtime.ai3d.ai3d.job_events : Ai3dEvent, Ai3dEventKind;
import vibe3d.runtime.ai3d.ai3d.event_queue;


// ---------------------------------------------------------------------------
// Unit tests — single-threaded, exercise coalescing/overflow/retention and
// (critically) the lock-free-drain contract without needing real threads.
// ---------------------------------------------------------------------------

version (unittest) {
    private Ai3dEvent statusEv(string jobId, long gen, double progress) {
        Ai3dEvent e;
        e.kind = Ai3dEventKind.status;
        e.jobId = jobId;
        e.generation = gen;
        e.progress = progress;
        return e;
    }
}

unittest {
    // Coalescing: two status events for the same {jobId,generation} collapse
    // to the latest one.
    auto q = new Ai3dEventQueue();
    q.push(statusEv("job1", 1, 0.1));
    q.push(statusEv("job1", 1, 0.5));
    q.push(statusEv("job1", 1, 0.9));

    Ai3dEvent[] seen;
    q.drain((ref const Ai3dEvent e) { seen ~= e; });
    assert(seen.length == 1, "same-job status should coalesce to one event");
    assert(seen[0].progress == 0.9);
}

unittest {
    // Distinct jobs/generations do not coalesce with each other.
    auto q = new Ai3dEventQueue();
    q.push(statusEv("jobA", 1, 0.1));
    q.push(statusEv("jobB", 1, 0.2));
    q.push(statusEv("jobA", 2, 0.3)); // different generation than jobA/1

    Ai3dEvent[] seen;
    q.drain((ref const Ai3dEvent e) { seen ~= e; });
    assert(seen.length == 3);
}

unittest {
    // Retention: a terminal/error event is never coalesced away by a status
    // event that shares its jobId but NOT its generation (a late update from
    // a stale generation, e.g. after a cancel-and-restart) — it survives
    // alongside the terminal event rather than being dropped or merged.
    auto q = new Ai3dEventQueue();
    q.push(statusEv("job1", 1, 0.1));
    Ai3dEvent term;
    term.kind = Ai3dEventKind.terminal;
    term.jobId = "job1";
    term.generation = 1;
    term.state = "succeeded";
    q.push(term);
    q.push(statusEv("job1", 2, 0.99)); // different generation — must NOT coalesce with either above

    Ai3dEvent[] seen;
    q.drain((ref const Ai3dEvent e) { seen ~= e; });
    assert(seen.length == 3);
    assert(seen[1].kind == Ai3dEventKind.terminal);
}


unittest {
    // LOAD-BEARING, genuine two-thread proof: drain() must invoke the
    // delegate LOCK-FREE (copy the pending events under the mutex, release
    // it, THEN invoke the delegate over the copy).
    //
    // A same-thread re-entrant push() from inside the delegate can NOT
    // distinguish "lock held" from "lock released": this repo's
    // core.sync.mutex.Mutex is RECURSIVE (PTHREAD_MUTEX_RECURSIVE on
    // POSIX, CRITICAL_SECTION on Windows), so a same-thread re-lock always
    // succeeds regardless of whether drain() actually released the mutex
    // first — an earlier version of this test asserted exactly that and
    // passed even with a (hypothetically) buggy lock-holding drain(),
    // proving nothing (review fix, task 0381).
    //
    // The only way to genuinely observe the lock being held is a SECOND
    // thread trying to push() while the drain delegate is still running:
    // if drain() held the mutex across the delegate call, that push()
    // would block for the whole delegate duration; since the mutex is
    // actually released beforehand, the push() returns almost immediately
    // instead.
    import core.atomic : atomicLoad, atomicStore;
    import core.thread  : Thread;
    import core.time    : msecs, seconds, MonoTime;
    import std.conv     : to;

    auto q = new Ai3dEventQueue();
    q.push(statusEv("job1", 1, 0.1));

    shared bool delegateRunning;
    shared bool delegateDone;
    enum delegateSleepMs = 300;

    auto drainer = new Thread({
        q.drain((ref const Ai3dEvent e) {
            atomicStore(delegateRunning, true);
            Thread.sleep(delegateSleepMs.msecs);
            atomicStore(delegateDone, true);
        });
    });
    drainer.start();

    // Wait for the delegate to actually start running before we try to
    // race it.
    auto waitDeadline = MonoTime.currTime + 2.seconds;
    while (!atomicLoad(delegateRunning) && MonoTime.currTime < waitDeadline)
        Thread.sleep(1.msecs);
    assert(atomicLoad(delegateRunning), "drain()'s delegate never started");

    // While the delegate is still sleeping (mid-run), push() from THIS
    // (different) thread must return promptly.
    const pushStart = MonoTime.currTime;
    q.push(statusEv("job2", 1, 0.2));
    const pushElapsedMs = (MonoTime.currTime - pushStart).total!"msecs";

    assert(!atomicLoad(delegateDone),
           "test invariant violated: the delegate finished before push() was attempted "
           ~ "(the sleep window was too short on this host — not a lock-freedom failure)");
    assert(pushElapsedMs < delegateSleepMs / 2,
           "push() from another thread must return promptly while drain()'s delegate "
           ~ "is still running — it took " ~ pushElapsedMs.to!string
           ~ "ms, suggesting drain() holds the queue's mutex across the delegate call");

    drainer.join();
    assert(!q.empty()); // job2's event is pending for the next drain
}
