module ui.discard_guard;

// ---------------------------------------------------------------------------
// Task 1521 — THE unsaved-work guard, as ONE decision and ONE record.
//
// Before this, exactly one path asked `docDirty()` as a guard: the quit
// confirm (task 0434). File → New, File → Open and Import ▸ * replaced the
// document without asking — the owner hit it in ordinary work and believed the
// session was gone (it is Ctrl+Z-recoverable, but nothing on screen said so).
//
// The two halves live here for opposite reasons:
//
//   * `guardVerdict` is PURE, so the decision is assertable by a unittest with
//     no app, no window and no HTTP. The ImGui modal that carries it is not
//     observable headlessly, so an assertion written against the draw could
//     only ever say "the function ran" — the same split `ui/command_notice.d`
//     makes, for the same reason.
//
//   * the RECORD is `__gshared` + `synchronized`, in the shape of
//     `ui/availability.d`'s draw-time record, because the reader is the HTTP
//     thread and the writer is the main thread. It is written on EVERY guarded
//     dispatch, INCLUDING the `--test` one where the modal is suppressed —
//     that is the only reason a headless test can see the verdict at all.
// ---------------------------------------------------------------------------

/// What the guard decided for one dispatch.
enum GuardVerdict {
    proceed,  /// run it now
    prompt,   /// ask first; the action is DEFERRED, not run
}

/// THE RULE. Two terms, both load-bearing:
///   * `discards` — the command declared `Command.discardsUnsavedWork()`;
///   * `dirty`    — `io.doc_state.docDirty()` at dispatch time.
///
/// The `dirty` term is what keeps a clean document from being interrogated,
/// and it is pinned by its own case (a CLEAN quit must answer `proceed`) —
/// a dirty-document case cannot see it, because an unconditional prompt keeps
/// that assertion true.
GuardVerdict guardVerdict(bool discards, bool dirty) pure @safe nothrow @nogc {
    return (discards && dirty) ? GuardVerdict.prompt : GuardVerdict.proceed;
}

/// What a UI-origin dispatch ended up doing. Three answers, not two: the
/// dispatcher must tell a REFUSAL (which raises a notice) from a DEFERRAL
/// (which must stay silent — the user has not answered yet).
enum UiRunOutcome {
    applied,
    refused,
    deferred,
}

/// What the post-flush settle owes the deferred action. The answer is taken in
/// the DRAW; the action runs here, one settle later, so no document mutation
/// ever happens inside an ImGui frame.
enum GuardSettle {
    none,
    perform,    /// Discard was pressed — run it
    afterSave,  /// Save was pressed — run it ONLY if the save actually landed
}

/// Does the settle PERFORM the deferred action?
///
/// The `afterSave` term is the one that matters and the one a naive settle
/// gets wrong: a Save whose dialog was CANCELLED leaves the document dirty,
/// and completing the discard then would destroy exactly the work the prompt
/// was raised to protect. Pure, so the rule is assertable without an app —
/// making this return `true` unconditionally is the mutation that reddens
/// `tests/unit/ui/discard_guard_test.d`.
bool settlePerforms(GuardSettle s, bool dirtyAfterSave) pure @safe nothrow @nogc {
    final switch (s) {
        case GuardSettle.none:      return false;
        case GuardSettle.perform:   return true;
        case GuardSettle.afterSave: return !dirtyAfterSave;
    }
}

/// How a deferred action was answered.
enum GuardAnswer {
    none,
    save,      /// save first, then perform IF the save actually landed
    discard,   /// perform now
    cancel,    /// drop the deferred action
}

/// One guarded dispatch, as the main thread saw it.
struct GuardRecord {
    string id;          /// the DISPATCHED id ("file.new", "file.import.obj", …)
    string name;        /// `cmd.name()` ("scene.reset" for BOTH file.new and /api/reset)
    bool   discards;    /// `Command.discardsUnsavedWork()`
    bool   dirty;       /// `docDirty()` at dispatch time
    string verdict;     /// "proceed" | "prompt"
    bool   suppressed;  /// prompt was NOT raised (--test)
    string dropped;     /// "" or why the dispatch was dropped outright
    string outcome;     /// "applied" | "refused" | "deferred"
    bool   refused;     /// outcome == "refused"
    string notice;      /// the notice text raised for it, "" when none
    string answer;      /// "none" | "save" | "discard" | "cancel"
    bool   performed;   /// the deferred action ran after the answer
}

private __gshared GuardRecord g_last;      // guarded by g_mx
private __gshared bool        g_haveLast;  // guarded by g_mx
private __gshared bool        g_pending;   // guarded by g_mx
private __gshared Object      g_mx;

shared static this() { g_mx = new Object(); }

// WHY the id AND the name (task 1520 plan, B7). `file.new`'s factory builds a
// `SceneReset`, whose `name()` is `"scene.reset"` — the SAME string
// `/api/reset` dispatches. `file.open` and `file.import.obj` likewise share
// `FileLoad`/`"file.load"`. A record carrying only `name()` cannot tell the
// user path from the programmatic one, which is exactly the distinction both
// tasks turn on.

/// Record one guarded dispatch. Main thread only.
void recordGuardRequest(GuardRecord r) {
    synchronized (g_mx) {
        g_last     = r;
        g_haveLast = true;
    }
}

/// Note the answer the user gave to the pending prompt, and whether the
/// deferred action then ran. Main thread only.
void recordGuardAnswer(GuardAnswer a, bool performed) {
    synchronized (g_mx) {
        if (!g_haveLast) return;
        final switch (a) {
            case GuardAnswer.none:    g_last.answer = "none";    break;
            case GuardAnswer.save:    g_last.answer = "save";    break;
            case GuardAnswer.discard: g_last.answer = "discard"; break;
            case GuardAnswer.cancel:  g_last.answer = "cancel";  break;
        }
        g_last.performed = performed;
    }
}

/// Record the notice text a UI-origin refusal produced. Main thread only.
/// Written even under `--test`, where the modal itself is suppressed — that
/// record is the ONLY way a headless test can see what the user would read.
void recordUiNotice(string text) {
    synchronized (g_mx) {
        if (!g_haveLast) return;
        g_last.notice = text;
    }
}

/// Publish whether a deferred action is currently held. Main thread only.
void setGuardPending(bool pending) {
    synchronized (g_mx) { g_pending = pending; }
}

/// `GET /api/ui/policy` payload.
string uiPolicyJson() {
    import std.array : appender;
    GuardRecord r;
    bool have, pending;
    synchronized (g_mx) { r = g_last; have = g_haveLast; pending = g_pending; }

    auto buf = appender!string;
    buf.put(`{"pending":`);
    buf.put(pending ? "true" : "false");
    if (have) {
        buf.put(`,"last":{`);
        buf.put(`"id":"`         ~ esc(r.id)      ~ `",`);
        buf.put(`"name":"`       ~ esc(r.name)    ~ `",`);
        buf.put(`"discards":`    ~ (r.discards ? "true" : "false")   ~ `,`);
        buf.put(`"dirty":`       ~ (r.dirty ? "true" : "false")      ~ `,`);
        buf.put(`"verdict":"`    ~ esc(r.verdict) ~ `",`);
        buf.put(`"suppressed":`  ~ (r.suppressed ? "true" : "false") ~ `,`);
        buf.put(`"dropped":"`    ~ esc(r.dropped) ~ `",`);
        buf.put(`"outcome":"`    ~ esc(r.outcome) ~ `",`);
        buf.put(`"refused":`     ~ (r.refused ? "true" : "false")    ~ `,`);
        buf.put(`"notice":"`     ~ esc(r.notice)  ~ `",`);
        buf.put(`"answer":"`     ~ esc(r.answer)  ~ `",`);
        buf.put(`"performed":`   ~ (r.performed ? "true" : "false"));
        buf.put(`}`);
    }
    buf.put(`}`);
    return buf.data;
}

/// Clear the record. Called by `/api/reset` so a test reads its OWN dispatch
/// and not the previous case's leftovers on the shared `--test` instance.
void resetUiPolicyRecord() {
    synchronized (g_mx) {
        g_last     = GuardRecord.init;
        g_haveLast = false;
        g_pending  = false;
    }
}

private string esc(string s) {
    import std.array : appender;
    auto buf = appender!string;
    foreach (char c; s) {
        switch (c) {
            case '"':  buf.put(`\"`);  break;
            case '\\': buf.put(`\\`);  break;
            case '\n': buf.put(`\n`);  break;
            case '\r': buf.put(`\r`);  break;
            case '\t': buf.put(`\t`);  break;
            default:
                if (c < 0x20) {
                    import std.format : format;
                    buf.put(format(`\u%04x`, cast(int)c));
                } else buf.put(c);
        }
    }
    return buf.data;
}
