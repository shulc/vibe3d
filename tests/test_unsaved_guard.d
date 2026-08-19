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

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue postCmd(string query, string argstring) {
    return parseJSON(cast(string)post(baseUrl ~ "/api/command" ~ query, argstring));
}

void resetScene() { post(baseUrl ~ "/api/reset", ""); }

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

unittest { // apiResetIsUnguarded — the PROGRAMMATIC path never prompts
    // `/api/reset` builds the `scene.reset` factory and calls `cmd.apply()`
    // DIRECTLY: it touches neither `applyOrRefire` nor the UI dispatch point.
    // That is why the mutation which reddens this case has to be inserted into
    // `SceneReset.apply()` itself — moving the guard into `applyOrRefire`
    // would be INERT here.
    dirtyScene();
    assert(vertCount() > 8, "setup: the scene should be subdivided");

    resetScene();
    auto p = getJson("/api/ui/policy");
    if ("last" in p.object)
        assert(p["last"]["verdict"].str != "prompt",
            "/api/reset must not raise the unsaved-work prompt: " ~ p.toString);
    assert(p["pending"].boolean == false,
        "/api/reset must leave no deferred action: " ~ p.toString);
    assert(vertCount() == 8,
        "/api/reset must have actually reset the scene; got "
        ~ vertCount().to!string);
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
