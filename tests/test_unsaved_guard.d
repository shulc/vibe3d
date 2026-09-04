// Task 1521 — the unsaved-work guard, one case per path.
//
// The driver is `POST /api/command?origin=ui` (the --test-only UI-policy
// route, task 1520 Phase 1); the observable is `GET /api/ui/policy`.
//
// WHY THE RECORD CARRIES BOTH `id` AND `name`. `file.new`'s factory builds a
// `SceneReset`, whose `name()` is `"scene.reset"` — the same string
// `/api/reset` dispatches — and `file.open`/`file.import.obj` likewise share
// `FileLoad`/`"file.load"`. A record keyed on `name()` alone could not tell the
// guarded user path from the unguarded programmatic one, which is the
// distinction this whole task turns on.
//
// WHAT `--test` SUPPRESSES IS THE MODAL, NOT THE DEFERRAL: the action is held
// either way (`suppressed:true` says the prompt was not raised), which is what
// makes the busy rule observable here at all. `/api/reset` drops any held
// action so one case cannot leak into the next on the shared instance.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

alias baseUrl = testBaseUrl;


JSONValue postCmd(string query, string argstring) {
    return parseJSON(cast(string)post(baseUrl ~ "/api/command" ~ query, argstring));
}

void resetScene() { post(baseUrl ~ "/api/command", commandBody("scene.reset")); }

long vertCount() {
    return getJson("/api/model")["vertices"].array.length;
}

/// A cube, then a real geometry edit — the document is now DIRTY, which is the
/// precondition every `guards*` case needs.
void dirtyScene() {
    resetScene();
    auto r = postCmd("", "mesh.subdivide");
    assert(r["status"].str == "ok", "setup: mesh.subdivide failed: " ~ r.toString);
}

/// Number of entries the armed step trace holds. `/api/trace` is a JSON array.
long traceLength() {
    return getJson("/api/trace").array.length;
}

/// Let the main loop turn over so a just-dispatched command's step-trace
/// append has landed before it is read back.
void settleFrames() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(200.msecs);
}

JSONValue policyLast() {
    auto p = getJson("/api/ui/policy");
    assert("last" in p.object, "no UI dispatch was recorded: " ~ p.toString);
    return p["last"];
}

unittest { // guardsFileNew — File → New over unsaved work ASKS
    dirtyScene();
    const before = vertCount();
    auto r = postCmd("?origin=ui", "file.new");
    assert(r["status"].str == "ok", r.toString);

    auto l = policyLast();
    assert(l["id"].str       == "file.new",    l.toString);
    assert(l["name"].str     == "scene.reset", l.toString);
    assert(l["discards"].boolean,              l.toString);
    assert(l["dirty"].boolean,                 l.toString);
    assert(l["verdict"].str  == "prompt",      l.toString);
    assert(l["suppressed"].boolean,            l.toString);
    // …and the document was NOT thrown away while the question stands.
    assert(vertCount() == before,
        "a deferred file.new must not have run: " ~ vertCount().to!string);
}

unittest { // guardsFileLoad — File → Open over unsaved work ASKS
    dirtyScene();
    auto r = postCmd("?origin=ui", "file.load");
    assert(r["status"].str == "ok", r.toString);
    auto l = policyLast();
    assert(l["id"].str      == "file.load", l.toString);
    assert(l["verdict"].str == "prompt",    l.toString);
}

unittest { // importDeclaration — Import ▸ OBJ is the FOURTH discard path
    // It shares `FileLoad` with File → Open, so the class declaration covers
    // it for free — and the record proves the DISPATCHED id survives, which is
    // the only way Import and Open can be told apart at all.
    dirtyScene();
    auto r = postCmd("?origin=ui", "file.import.obj");
    assert(r["status"].str == "ok", r.toString);
    auto l = policyLast();
    assert(l["id"].str      == "file.import.obj", l.toString);
    assert(l["name"].str    == "file.load",       l.toString);
    assert(l["verdict"].str == "prompt",          l.toString);
}

unittest { // guardsQuit — quitting over unsaved work ASKS, through the SAME point
    dirtyScene();
    auto r = postCmd("?origin=ui", "file.quit");
    assert(r["status"].str == "ok", r.toString);
    auto l = policyLast();
    assert(l["id"].str      == "file.quit", l.toString);
    assert(l["verdict"].str == "prompt",    l.toString);

    // The process is still here: the quit was DEFERRED, not performed.
    auto ping = parseJSON(cast(string)get(baseUrl ~ "/api/ping"));
    assert(ping["status"].str == "ok", "a deferred quit must not exit");
}

unittest { // cleanNewIsNotGuarded — a clean document is not interrogated
    resetScene();                     // reset rebaselines the dirty tracking
    auto r = postCmd("?origin=ui", "file.new");
    assert(r["status"].str == "ok", r.toString);
    auto l = policyLast();
    assert(l["dirty"].boolean == false,   l.toString);
    assert(l["verdict"].str   == "proceed", l.toString);
    assert(l["outcome"].str   == "applied", l.toString);
    assert(vertCount() == 0,
        "an unguarded file.new must actually empty the scene; got "
        ~ vertCount().to!string);
}

unittest { // cleanQuitIsNotGuarded — THE case that pins the `dirty` term
    // A dirty-document case CANNOT see this term: making the verdict prompt
    // unconditionally keeps "dirty ⇒ prompt" true. Only a CLEAN document can
    // catch the term being dropped, which is why this case exists separately.
    resetScene();
    auto r = postCmd("?origin=ui", "file.quit");
    assert(r["status"].str == "ok", r.toString);
    auto l = policyLast();
    assert(l["discards"].boolean,           l.toString);
    assert(l["dirty"].boolean == false,     l.toString);
    assert(l["verdict"].str   == "proceed", l.toString);

    // It ran — and `--test` suppresses the EXIT for a command-dispatched quit
    // (only a window close still exits), so the harness survives it.
    auto ping = parseJSON(cast(string)get(baseUrl ~ "/api/ping"));
    assert(ping["status"].str == "ok",
        "a command-dispatched quit must not take the --test instance down");
}

unittest { // scriptResetIsUnguarded — the PROGRAMMATIC path never prompts
    // WHAT THIS CASE NOW DISCRIMINATES, because its old rationale is dead.
    // It used to read: "`/api/reset` builds the `scene.reset` factory and
    // calls `cmd.apply()` DIRECTLY: it touches neither `applyOrRefire` nor the
    // UI dispatch point" — and concluded that only a mutation inside
    // `SceneReset.apply()` could redden it. That was true of a dedicated route
    // with its own hand-rolled body. Task 4063 retired that route: a scene
    // reset is now the SAME generic `/api/command` dispatch as every other
    // command, so it does go through `applyOrRefire`, and "this one path is
    // special" is no longer the thing being said.
    //
    // What is left is still worth a case, and it is the ORIGIN split. The
    // unsaved-work guard lives at exactly one point, `runUiCommand`, which
    // only a `CommandOrigin.ui` line reaches; a script line applies directly.
    // So this case pins that a scene reset dispatched WITHOUT `?origin=ui`
    // raises no prompt and leaves no deferred action — the contract every
    // other test in the tree leans on when it calls `resetScene()` on a dirty
    // document. Its sibling `guardsFileNew` above drives the
    // SAME command class down the ui path and gets the prompt; between them
    // the origin term is pinned in both directions, which is a stronger
    // reading than the old "it bypasses the dispatcher" one ever was.
    //
    // The mutation that reddens it is therefore a policy mutation, not a
    // command one: make `refused`/`runUiCommand` reachable from the script
    // origin, or make the guard unconditional, and the `pending` assert below
    // goes red.
    dirtyScene();
    assert(vertCount() > 8, "setup: the scene should be subdivided");

    resetScene();
    auto p = getJson("/api/ui/policy");
    if ("last" in p.object)
        assert(p["last"]["verdict"].str != "prompt",
            "a script-origin scene.reset must not raise the unsaved-work "
          ~ "prompt: " ~ p.toString);
    assert(p["pending"].boolean == false,
        "a script-origin scene.reset must leave no deferred action: "
      ~ p.toString);
    assert(vertCount() == 8,
        "a script-origin scene.reset must have actually reset the scene; got "
        ~ vertCount().to!string);
}

unittest { // deferredFileNewRunsNoResetSideEffects — task 4063 blocker 3
    // THE DEFECT THIS PINS. `/api/command`'s dispatcher carries a test-mode
    // re-baseline for the AUTOMATION reset: before dispatch it wipes the UI
    // policy record and drops any held action, and after dispatch it cancels
    // the pipe drag, clears the AI debug traces, turns the AI switch off,
    // parks the override pointer, closes the pie menu, discards a pending
    // exploration and RESETS THE STEP TRACE. It was gated on
    // `cast(SceneReset)cmd !is null` — and `file.new`'s factory builds a
    // `SceneReset` too (its `name()` is literally "scene.reset", which is what
    // the header of this file is about). So in `--test` every `file.new` ran
    // the whole re-baseline, INCLUDING on the ui path where the unsaved-work
    // prompt had held the action and it never applied at all: seven pieces of
    // global state destroyed for a command that did nothing.
    //
    // WHY THE STEP TRACE IS THE OBSERVABLE. Of the seven it is the only one
    // that is cheap, queryable over HTTP and unambiguous: `/api/trace/reset`
    // arms it, one command appends one entry, and the re-baseline's
    // `stepTrace.reset()` empties it. The pointer park needs a pixel probe and
    // the AI switch needs the AI subsystem; this needs two GETs.
    //
    // ORDER. The POPULATION FLOOR comes first — "the trace survived" is
    // vacuously true of an empty trace, and an unarmed trace is always empty.
    // Then the deferral itself is asserted, because a `file.new` that APPLIED
    // would make the surviving trace mean nothing (a re-baseline after a real
    // apply is the intended behaviour). The survival assert is last, so it is
    // the line that reddens.
    dirtyScene();
    parseJSON(cast(string)post(baseUrl ~ "/api/trace/reset", ""));
    auto sub = postCmd("", "mesh.subdivide");
    assert(sub["status"].str == "ok", "setup: subdivide failed: " ~ sub.toString);
    settleFrames();

    // POPULATION FLOOR: the trace is armed and holds exactly the one entry
    // the subdivide above appended.
    assert(traceLength() == 1,
        "setup: an armed trace must hold the one subdivide entry; got "
        ~ traceLength().to!string ~ " — with 0 the survival assert below is "
        ~ "satisfied by a trace that was never populated");
    immutable long vertsBefore = vertCount();

    // The gesture: File → New over unsaved work. It is HELD by the prompt.
    auto r = postCmd("?origin=ui", "file.new");
    assert(r["status"].str == "ok", r.toString);
    auto l = policyLast();
    assert(l["id"].str        == "file.new",  l.toString);
    assert(l["outcome"].str   == "deferred",  l.toString);
    assert(l["performed"].boolean == false,   l.toString);
    assert(getJson("/api/ui/policy")["pending"].boolean,
        "the guarded file.new must be HELD — without the deferral this cell "
        ~ "measures nothing");
    assert(vertCount() == vertsBefore,
        "a deferred file.new must not have emptied the scene; got "
        ~ vertCount().to!string ~ " verts");

    // THE RED HALF. Nothing applied, so nothing may have been re-baselined.
    assert(traceLength() == 1,
        "a DEFERRED file.new ran the automation reset's post-dispatch "
        ~ "re-baseline and wiped the step trace: " ~ traceLength().to!string
        ~ " entries left. That block belongs to `scene.reset` on the script "
        ~ "origin, not to every command that happens to be a SceneReset "
        ~ "instance");

    resetScene();   // drop the held action for the next case
}

unittest { // secondGuardedIsRefused — the BUSY rule (B9)
    // ImGui modals do not raise `WantTextInput`, and `WantCaptureKeyboard` is
    // explicitly unusable as a gate in this app, so a second guarded gesture
    // DOES reach the dispatch point while the prompt is up. Overwriting the
    // held action silently would throw away a decision the user is in the
    // middle of making.
    dirtyScene();
    auto first = postCmd("?origin=ui", "file.new");
    assert(first["status"].str == "ok", first.toString);
    auto l1 = policyLast();
    assert(l1["id"].str      == "file.new", l1.toString);
    assert(l1["dropped"].str == "",         l1.toString);
    assert(getJson("/api/ui/policy")["pending"].boolean,
        "the first guarded action must be held");

    auto second = postCmd("?origin=ui", "file.load");
    assert(second["status"].str == "ok", second.toString);
    auto l2 = policyLast();
    assert(l2["id"].str      == "file.load",            l2.toString);
    assert(l2["dropped"].str == "guard already pending", l2.toString);

    resetScene();   // drop the held action for the next case
}

// ---------------------------------------------------------------------------
// THE GESTURE WITNESS (task 1521).
//
// `tests/test_commands_file_misc.d` already runs `file.new` four times — but
// all four go through `POST /api/command`, the PROGRAMMATIC path, which is
// unguarded by design. Until this log existed, nothing drove `file.new` the
// way the owner did: as a user gesture. (The card claimed "no test runs
// file.new at all"; that claim is FALSE and was corrected during planning. What
// is true, and what left the hole open, is that no test ran it through a USER
// path.)
// ---------------------------------------------------------------------------

void waitPlayback() {
    import core.thread : Thread;
    import core.time   : msecs;
    foreach (_; 0 .. 80) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].boolean) return;
        Thread.sleep(50.msecs);
    }
    assert(false, "play-events did not finish within 4 s");
}

void playLog(string path) {
    import std.file : read;
    auto events = cast(string)read(path);
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/play-events", events));
    assert(r["status"].str == "success", "/api/play-events failed: " ~ r.toString);
    waitPlayback();
}

unittest { // ctrlNIsWitnessedByGesture — clean document, real keystroke
    waitPlayback();
    resetScene();
    assert(vertCount() == 8, "setup: the default scene is a cube");

    playLog("tests/events/file_new_ctrl_n.log");

    assert(vertCount() == 0,
        "Ctrl+N must empty the scene through the real keyboard path; got "
        ~ vertCount().to!string ~ " verts");
    auto l = policyLast();
    // `runCommand` (the keyboard/menu entry) has no dispatched id to give, and
    // the record says so honestly rather than inventing one.
    assert(l["id"].str      == "",            l.toString);
    assert(l["name"].str    == "scene.reset", l.toString);
    assert(l["verdict"].str == "proceed",     l.toString);
    assert(l["outcome"].str == "applied",     l.toString);
}

unittest { // the guard is reached FROM THE KEYBOARD, not only from HTTP
    waitPlayback();
    dirtyScene();
    const before = vertCount();

    playLog("tests/events/file_new_ctrl_n.log");

    auto l = policyLast();
    assert(l["name"].str    == "scene.reset", l.toString);
    assert(l["dirty"].boolean,                l.toString);
    assert(l["verdict"].str == "prompt",      l.toString);
    assert(vertCount() == before,
        "Ctrl+N over unsaved work must not have run: " ~ vertCount().to!string);

    resetScene();   // drop the held action for the next case
}
