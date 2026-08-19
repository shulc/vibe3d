// Task 1520 — the two refusal policies, and the seam between them.
//
// WHAT THESE CASES CANNOT OBSERVE, said out loud rather than left implied.
// The real failure mode is an exception escaping an ImGui draw and unwinding
// through `_Dmain`. Every assertion below travels through the HTTP command
// bridge, whose lambda CATCHES (source/http_server.d), so what is observed is
// the PROXY "the UI adapter did not throw". That proxy is sound under exactly
// one condition — the `?origin=ui` route must dispatch through the app's
// `uiCommandDelegate` FIELD, the same binding the 28 panel call sites use, and
// not through a second closure over the same body. `uiRefusalDoesNotThrow`'s
// mutation (null the field after wiring) is what holds that condition.
//
// UNWITNESSED, AND ACCEPTED AS DEBT: the shipped panel call site
// (`ui/panels.d`'s "Load…" button). `tests/events/` holds 22 logs and not one
// clicks a panel button — they are camera, lasso, selection and numpad — so
// there is no cheap precedent for driving a panel press from an event log.
// The crash itself was reproduced by hand instead, twice, on an unmodified
// build (see the task card's Лог).

import std.net.curl;
import std.json;
import std.conv : to;
import std.algorithm : canFind;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue postCmd(string query, string argstring) {
    return parseJSON(cast(string)post(baseUrl ~ "/api/command" ~ query, argstring));
}

void resetScene() { post(baseUrl ~ "/api/reset", ""); }

unittest { // httpRefusalIsReported — the script contract is UNCHANGED
    resetScene();
    // `image.load` with no path: the dialog is suppressed under --test, so the
    // command legitimately declines. A script MUST be told.
    auto r = postCmd("", "image.load");
    assert(r["status"].str == "error",
        "a script-origin refusal must be reported as an error, got: " ~ r.toString);
    assert(r["message"].str.canFind("image.load"),
        "the error must name the command: " ~ r.toString);
    assert(r["message"].str.canFind("no path given"),
        "the error must carry the command's own reason: " ~ r.toString);
}

unittest { // uiRefusalDoesNotThrow — the panel path REFUSES WITHOUT DYING
    resetScene();
    auto r = postCmd("?origin=ui", "image.load");
    assert(r["status"].str == "ok",
        "a UI-origin refusal must NOT surface as a thrown error: " ~ r.toString);

    // The process is still there. This is the whole point of the task: before
    // it, this exact refusal unwound out of the panel draw and exited(1).
    auto ping = parseJSON(cast(string)get(baseUrl ~ "/api/ping"));
    assert(ping["status"].str == "ok", "the editor must survive a UI refusal");

    // …and the user was TOLD, rather than the refusal being swallowed.
    auto pol = getJson("/api/ui/policy");
    assert("last" in pol.object, "the UI dispatch must be recorded: " ~ pol.toString);
    assert(pol["last"]["id"].str == "image.load", pol.toString);
    assert(pol["last"]["refused"].boolean,
        "the record must say the command refused: " ~ pol.toString);
    assert(pol["last"]["notice"].str.length > 0,
        "a refusal WITH a reason must produce a notice: " ~ pol.toString);
    assert(pol["last"]["notice"].str.canFind("no path given"), pol.toString);
}

unittest { // origin=ui is TEST-ONLY plumbing and must not silently no-op
    // A bogus origin value falls back to the script policy (it is not "ui"),
    // so the refusal is still reported. This pins that the switch is on the
    // exact token, not on "the query string exists".
    resetScene();
    auto r = postCmd("?origin=script", "image.load");
    assert(r["status"].str == "error",
        "only origin=ui selects the UI policy: " ~ r.toString);
}

unittest { // cancelIsSilent — a cancelled chooser says NOTHING
    // `PickOutcome.cancelled` carries no reason, so `commandNoticeText` yields
    // "" and nothing is shown. The three outcomes used to collapse into one
    // `refuse("no path given")`, which would have popped a false error at a
    // user who had just pressed Cancel — a defect that would have SURVIVED the
    // policy fix on its own.
    //
    // Headlessly the chooser answers `unavailable`, not `cancelled`, so the
    // cancel leg is pinned by the pure table in `io/file_dialog.d`'s unittest.
    // What this case pins is the OTHER half: `unavailable` is NOT silent, i.e.
    // the distinction exists at all.
    resetScene();
    postCmd("?origin=ui", "image.load");
    auto pol = getJson("/api/ui/policy");
    assert(pol["last"]["notice"].str.canFind("suppressed in --test"),
        "the suppressed-dialog outcome must name itself, not hide behind "
        ~ "a bare 'no path given': " ~ pol.toString);
}

unittest { // refusalTextsArePinned — Phase 2 CHANGED these strings (B8)
    // Nothing pinned them before, and the file-dialog rework moves all four
    // families from a bare "command 'X' did not apply" to a sentence that
    // names the outcome. Pin the exact shape for each family.
    resetScene();

    // The four DIALOG-OPENING families. `image.replace` is deliberately not
    // here: it refuses on its missing `index` before it ever reaches a
    // chooser, so it would pin the wrong sentence — its dialog leg is covered
    // by the shared `io/file_dialog.d` it now calls.
    //
    // `ai3d.generate.open` is in the list for a second reason (M4): it returns
    // false even when the pick SUCCEEDS, on purpose — it records no undo
    // entry. Pinning its refusal text also pins that Phase 2 did not "fix"
    // that `false` into a `true` and hand it an undo entry it must not have.
    immutable string[] ids =
        ["file.load", "file.save", "image.load", "ai3d.generate.open"];
    immutable string reason = "no path given: the file dialog is suppressed in --test";
    foreach (id; ids) {
        auto r = postCmd("", id);
        assert(r["status"].str == "error", id ~ ": " ~ r.toString);
        assert(r["message"].str == "command '" ~ id ~ "' did not apply: " ~ reason,
            id ~ " refusal text drifted: " ~ r["message"].str);
    }
}
