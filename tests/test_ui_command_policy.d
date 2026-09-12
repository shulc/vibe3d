// Task 1520 — the two refusal policies, and the seam between them.
//
// WHAT THESE CASES CANNOT OBSERVE, said out loud rather than left implied.
// The real failure mode is an exception escaping an ImGui draw and unwinding
// through `_Dmain`. Every assertion below travels through the HTTP command
// bridge, whose lambda CATCHES (source/http_server.d), so what is observed is
// the PROXY "the UI adapter did not throw". Task 4711 makes that proxy
// structural: the test route and panel delegates invoke the same application
// binding with different explicit contexts; only the HTTP adapter turns a
// script-origin refusal into an exception.
//
// UNWITNESSED, AND ACCEPTED AS DEBT: the shipped panel call site
// (`ui/panels.d`'s "Load…" button). `tests/events/` holds 22 logs and not one
// clicks a panel button — they are camera, lasso, selection and numpad — so
// there is no cheap precedent for driving a panel press from an event log.
// The crash itself was reproduced by hand instead, twice, on an unmodified
// build (see the task card's Лог).

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;
import std.algorithm : canFind;

void main() {}

alias baseUrl = testBaseUrl;


JSONValue postCmd(string query, string argstring) {
    return parseJSON(cast(string)post(baseUrl ~ "/api/command" ~ query, argstring));
}

void resetScene() { post(baseUrl ~ "/api/command", commandBody("scene.reset")); }

long undoLength() {
    return cast(long)getJson("/api/history")["undo"].array.length;
}

long traceLength() {
    return cast(long)getJson("/api/trace").array.length;
}

unittest { // UI notice and HTTP exception remain two adapter policies
    // Keep the UI half first: mutating http_providers.refused into a quiet
    // return reaches the script red below only after this policy stayed green.
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

    resetScene();
    postCmd("", "history.clear");
    const historyBeforeRefusal = undoLength();
    // The same refusal under script origin is the HTTP adapter's exception.
    r = postCmd("", "image.load");
    const historyAfterRefusal = undoLength();
    // Keep this above the status assertion: the prescribed silent-refusal
    // mutation reaches and passes the no-history half before status reddens.
    assert(historyAfterRefusal == historyBeforeRefusal,
        "a script-origin refusal must add NO history entry: "
        ~ historyBeforeRefusal.to!string ~ " -> "
        ~ historyAfterRefusal.to!string);
    assert(r["status"].str == "error",
        "a script-origin refusal must be reported as an error, got: " ~ r.toString);
    assert(r["message"].str.canFind("image.load"),
        "the error must name the command: " ~ r.toString);
    assert(r["message"].str.canFind("no path given"),
        "the error must carry the command's own reason: " ~ r.toString);
}

unittest { // a command query returns its own JSON through the adapter
    resetScene();
    auto armed = postCmd("", "tool.set move");
    assert(armed["status"].str == "ok", "could not arm query fixture: " ~ armed.toString);
    auto query = postCmd("", "tool.attr move TX ?");
    assert(query["status"].str == "ok", "query failed: " ~ query.toString);
    assert("value" in query.object,
        "the command adapter lost the query command's own JSON: " ~ query.toString);
    assert(query["value"].floating == 0.0,
        "fresh move.TX query must return its own zero value: " ~ query.toString);
    postCmd("", "tool.set move off");
}

unittest { // automation reset before remains reachable through both doors
    resetScene();
    auto dirty = postCmd("", "mesh.subdivide");
    assert(dirty["status"].str == "ok", "could not dirty reset fixture");
    auto held = postCmd("?origin=ui", "file.new");
    assert(held["status"].str == "ok", held.toString);
    assert(getJson("/api/ui/policy")["pending"].boolean,
        "setup: file.new must leave a non-empty guarded action pending");

    // UI scene.reset must first drop that pending action. It then creates its
    // own deferral because the document is still dirty. Without before(), the
    // busy guard reports `guard already pending` instead.
    auto uiReset = postCmd("?origin=ui", "scene.reset");
    assert(uiReset["status"].str == "ok", uiReset.toString);
    auto uiPolicy = getJson("/api/ui/policy");
    assert(uiPolicy["pending"].boolean,
        "UI scene.reset must leave its own deferred action pending");
    assert(uiPolicy["last"]["id"].str == "scene.reset"
        && uiPolicy["last"]["outcome"].str == "deferred"
        && uiPolicy["last"]["dropped"].str.length == 0,
        "UI scene.reset did not run automation-before before guard dispatch: "
        ~ uiPolicy.toString);

    // Script scene.reset does not consult the UI guard. The only mechanism
    // that can clear the pending UI reset is automation-before on this door.
    auto scriptReset = postCmd("", "scene.reset");
    assert(scriptReset["status"].str == "ok", scriptReset.toString);
    auto scriptPolicy = getJson("/api/ui/policy");
    assert(!scriptPolicy["pending"].boolean,
        "script scene.reset did not run automation-before: "
        ~ scriptPolicy.toString);
    assert("last" !in scriptPolicy.object,
        "script scene.reset must clear, not replace, the UI policy record: "
        ~ scriptPolicy.toString);
}

unittest { // successful script reset runs automation-after
    resetScene();
    auto armed = parseJSON(cast(string)post(baseUrl ~ "/api/trace/reset", ""));
    assert(armed["status"].str == "ok", "could not arm step trace");
    auto populated = postCmd("", "mesh.subdivide");
    assert(populated["status"].str == "ok", "could not populate step trace");
    assert(traceLength() == 1,
        "automation reset witness population floor: expected one live trace row, got "
        ~ traceLength().to!string);

    auto reset = postCmd("", "scene.reset");
    assert(reset["status"].str == "ok", reset.toString);
    assert(traceLength() == 0,
        "successful script scene.reset did not run automation-after: step trace survived");
    parseJSON(cast(string)post(baseUrl ~ "/api/trace/disarm", ""));
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
