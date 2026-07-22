module step_trace;

// ---------------------------------------------------------------------------
// StepTrace — per-command capture ring backing GET /api/trace.
//
// Every command CommandHistory successfully records fires `onRecord` (see
// command_history.d); app.d's onRecord chain hands each DISCRETE entry (see
// the coalescing guard in app.d's captureStepTrace) to StepTrace.append() as
// one pre-serialized JSON object string — command + args + the resulting
// selection in WORLD POSITIONS + a full mesh snapshot at that step.
// GET /api/trace returns the whole ring so an external observer can
// reconstruct every intermediate editing step (mesh + selection) WITHOUT the
// destructive /api/history/jump path (jump actually rewinds/replays the live
// undo stack — this is a read-only side log that never touches it).
//
// Thread-safety: append()/nextSeq() run on the MAIN thread (inside
// CommandHistory's onRecord, itself only ever called from record()/
// recordCoalescing() on the main thread); snapshotJson()/reset() run on the
// HTTP thread (GET /api/trace, POST /api/trace/reset) — reset() is also
// called directly from the main-thread /api/reset handler. Unlike the
// snapshot-at-request-time providers elsewhere (a plain read of a few
// scalars/short structs, where a torn read is an accepted rare race),
// StepTrace mutates a dynamic array — appending can reallocate the backing
// store — so a concurrent snapshotJson() could observe a torn/moved array
// without a real lock. Hence an actual Mutex here, not just careful
// ordering.
// ---------------------------------------------------------------------------

import core.sync.mutex : Mutex;
import std.array : join;

final class StepTrace {
    private string[] entries_;
    private long      seq_;
    private Mutex     mutex_;

    /// Ring capacity — oldest entry is dropped once exceeded. 500 discrete
    /// (non-InSession/non-Refire) commands is generous for a single editing
    /// session; caps memory on a long-lived --test instance instead of
    /// growing unbounded.
    enum size_t maxEntries = 500;

    this() {
        mutex_ = new Mutex();
    }

    /// Return the next sequence number and post-increment the counter. Call
    /// BEFORE building the entry JSON so the "seq" field embedded in the
    /// entry matches the number returned here.
    long nextSeq() {
        mutex_.lock();
        scope(exit) mutex_.unlock();
        return seq_++;
    }

    /// Append one pre-serialized JSON object (no wrapping brackets or
    /// trailing/leading comma — snapshotJson() joins entries with ",").
    /// Drops the oldest entry once the ring exceeds maxEntries.
    void append(string entryJson) {
        mutex_.lock();
        scope(exit) mutex_.unlock();
        entries_ ~= entryJson;
        if (entries_.length > maxEntries)
            entries_ = entries_[$ - maxEntries .. $];
    }

    /// Clear the trace. Called on /api/reset and POST /api/trace/reset.
    void reset() {
        mutex_.lock();
        scope(exit) mutex_.unlock();
        entries_.length = 0;
        seq_ = 0;
    }

    /// Snapshot the whole trace as a JSON array string. Safe to call
    /// concurrently with append()/reset() (HTTP thread vs main thread).
    string snapshotJson() {
        mutex_.lock();
        scope(exit) mutex_.unlock();
        return "[" ~ entries_.join(",") ~ "]";
    }
}

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
