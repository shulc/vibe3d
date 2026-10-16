module vibe3d.runtime.ai3d.ai3d.event_queue;

import core.sync.mutex : Mutex;

import vibe3d.runtime.ai3d.ai3d.job_events : Ai3dEvent, Ai3dEventKind;

// ---------------------------------------------------------------------------
// Ai3dEventQueue — bounded mutex-protected FIFO, worker-thread producer /
// main-thread consumer (task 0381, doc/ai3d_ui_plan.md Phase 1).
//
// LOAD-BEARING CONTRACT (`drain`): pending events are copied out UNDER the
// mutex, the lock is released, and ONLY THEN is the caller's delegate
// invoked, lock-free, over the copy. The delegate must never run while the
// queue mutex is held: `onAi3dEvent` (app.d) dispatches `ai3d.importResult`
// on `downloaded`, which runs an assimp parse — if that ran under this
// mutex, a worker-thread `push()` (e.g. the very next status tick) would
// block on the parse, defeating the whole point of the worker thread.
//
// Bounded (`Ai3dMaxControllerEvents`): a worker that outpaces a stalled main
// thread must never grow this queue without limit. `status` events for the
// same {jobId, generation} are coalesced in place (only the latest progress
// matters); if the queue still fills up, the ENTIRE pending queue is
// replaced by one synthetic terminal failure event so the consumer always
// sees a definitive end state rather than a silently truncated stream.
// ---------------------------------------------------------------------------

enum Ai3dMaxControllerEvents = 64;

final class Ai3dEventQueue {
    private Mutex mutex_;
    private Ai3dEvent[] buf_;
    private bool overflowed_;

    this() {
        mutex_ = new Mutex();
    }

    /// Producer-side push (worker thread). See class doc for the coalesce +
    /// overflow rules.
    void push(Ai3dEvent ev) {
        synchronized (mutex_) {
            if (overflowed_) return; // already latched the one overflow event; drop further pushes until drained
            if (ev.kind == Ai3dEventKind.status) {
                foreach (ref e; buf_) {
                    if (e.kind == Ai3dEventKind.status &&
                        e.jobId == ev.jobId && e.generation == ev.generation) {
                        e = ev;
                        return;
                    }
                }
            }
            if (buf_.length >= Ai3dMaxControllerEvents) {
                buf_ = null;
                Ai3dEvent overflow;
                overflow.kind = Ai3dEventKind.terminal;
                overflow.jobId = ev.jobId;
                overflow.generation = ev.generation;
                overflow.state = "failed";
                overflow.code = "queue_overflow";
                overflow.message = "AI3D event queue overflowed";
                buf_ ~= overflow;
                overflowed_ = true;
                return;
            }
            buf_ ~= ev;
        }
    }

    /// Consumer-side drain (main thread only, once per frame). Copies the
    /// pending events out under the mutex, then invokes `onEvent` per event
    /// with the lock released (see class doc — LOAD-BEARING).
    void drain(scope void delegate(ref const Ai3dEvent) onEvent) {
        Ai3dEvent[] copy;
        synchronized (mutex_) {
            if (buf_.length == 0) return;
            copy = buf_.dup;
            buf_ = null;
            // A fresh window can accept events again once drained, even
            // after a prior overflow — the overflow event itself was
            // already handed to the consumer above.
            overflowed_ = false;
        }
        foreach (ref e; copy) onEvent(e);
    }

    /// True once at least one event is pending (test/diagnostic helper;
    /// racy by nature against a live producer — not used for control flow).
    bool empty() {
        synchronized (mutex_) return buf_.length == 0;
    }
}
