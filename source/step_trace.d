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
    // Capture is ARMED, not always-on (task 0680). Every entry embeds a full
    // mesh dump, so appending one costs time proportional to the MESH, not to
    // the command: on the perf lane's 99 856-face grid a single capture measured
    // 75 ms for mesh.remove, 130 ms for scene.reset and 162 ms for mesh.select —
    // ten times the work of the command being traced, paid by every `--test`
    // run whether or not anyone reads /api/trace. It is what made the delete
    // family read +612% against a baseline captured before this file existed.
    //
    // The one documented consumer (the fuzz/parity driver) always POSTs
    // /api/trace/reset immediately before the gesture it wants and GETs the
    // trace after, so arming there costs it nothing and leaves every other run
    // free. A SCENE reset (/api/reset) still CLEARS but must not disarm: it
    // fires mid-session, inside a capture window that armed deliberately.
    private bool      armed_;

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

    /// Clear the trace WITHOUT changing whether capture is armed. Called on
    /// the scene reset (/api/reset), which can fire inside a capture window.
    void reset() {
        mutex_.lock();
        scope(exit) mutex_.unlock();
        entries_.length = 0;
        seq_ = 0;
    }

    /// Clear AND arm: start capturing. Backs POST /api/trace/reset — the call
    /// the capture workflow already makes right before the gesture it wants.
    void arm() {
        mutex_.lock();
        scope(exit) mutex_.unlock();
        entries_.length = 0;
        seq_ = 0;
        armed_ = true;
    }

    /// Whether captures are being recorded. The capture closure checks this
    /// BEFORE building an entry, so an unarmed trace costs one bool read.
    bool armed() const {
        return armed_;
    }

    /// Snapshot the whole trace as a JSON array string. Safe to call
    /// concurrently with append()/reset() (HTTP thread vs main thread).
    string snapshotJson() {
        mutex_.lock();
        scope(exit) mutex_.unlock();
        return "[" ~ entries_.join(",") ~ "]";
    }
}
