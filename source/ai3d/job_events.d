module ai3d.job_events;

// ---------------------------------------------------------------------------
// Ai3dEvent — the immutable value posted by the AI3D worker thread and
// consumed by the main thread (task 0381, doc/ai3d_ui_plan.md Phase 1).
//
// Every field is a value type (string is an immutable(char)[] reference to
// immutable data) — an Ai3dEvent is safe to copy across the worker->main
// boundary with no synchronization beyond the queue's own mutex
// (ai3d.event_queue). The worker thread is the SOLE producer; the main
// thread is the SOLE consumer. Neither side holds a Document/Mesh/ImGui
// reference through this type.
// ---------------------------------------------------------------------------

/// What kind of update this event carries. One event carries exactly one
/// kind's worth of meaningful fields (see field comments below).
enum Ai3dEventKind {
    health,         // standalone probeHealth() result (no job involved)
    submitted,      // the create-POST succeeded; jobId/generation now known
    status,         // a poll-tick status update (state/stage/progress)
    terminal,       // job reached a final state: succeeded/failed/cancelled
    downloaded,     // artifact staged locally (objPath/bytes) — precedes
                    // the "succeeded" terminal event for the same job
    transportError, // a network/transport failure outside the job state
                    // machine (e.g. the create-POST itself failed)
}

struct Ai3dEvent {
    Ai3dEventKind kind;

    // submitted / status / terminal / downloaded
    string jobId;
    long generation;
    string state;      // worker job state: "submitted"|"queued"|"running"|
                        // "succeeded"|"failed"|"cancelled" (status/terminal)
    string stage;       // worker-reported stage string (status/terminal)
    double progress = 0; // 0..1, worker-reported (status/terminal)

    // terminal / transportError / health (error reporting)
    string code;         // machine-readable error code (empty on success)
    string message;      // human-readable message

    // downloaded
    string objPath;      // staged local artifact path
    ulong bytes;          // downloaded artifact byte length

    // health
    bool healthOk;
    int healthProtocol;
    string healthBackend;
    bool healthObjCapable;
}
