// Module unittests for `ui.discard_guard` — the PURE half of the unsaved-work
// guard (tasks 1520 + 1521).
//
// What is asserted here is the DECISION, not the drawing: the ImGui modal that
// carries it is not observable headlessly, so an assertion written against the
// draw could only ever say "the function ran". The same split
// `tests/unit/ui/command_notice_test.d` makes, for the same reason.
module tests.unit.ui.discard_guard_test;

import ui.discard_guard;

unittest {
    // THE TABLE. Two inputs, and both terms matter:
    //   * without `discards`, nothing is ever asked — a subdivide must not
    //     interrogate the user;
    //   * without `dirty`, a document-discarding command runs straight through
    //     — File → New on an untouched scene asks nothing.
    assert(guardVerdict(false, false) == GuardVerdict.proceed);
    assert(guardVerdict(false, true ) == GuardVerdict.proceed);
    assert(guardVerdict(true,  false) == GuardVerdict.proceed);
    assert(guardVerdict(true,  true ) == GuardVerdict.prompt);
}

unittest {
    // The `dirty` term, isolated. This is the case a dirty-document assertion
    // cannot see: an unconditional `prompt` keeps "dirty ⇒ prompt" true, so
    // only a CLEAN case can catch the term being dropped.
    assert(guardVerdict(true, false) == GuardVerdict.proceed,
        "a clean document must never be interrogated");
}

unittest {
    // THE SETTLE RULE. Discard performs; Cancel (which leaves `none`) does
    // not; and Save performs ONLY if the save actually landed.
    assert(!settlePerforms(GuardSettle.none,    false));
    assert(!settlePerforms(GuardSettle.none,    true));
    assert( settlePerforms(GuardSettle.perform, false));
    assert( settlePerforms(GuardSettle.perform, true),
        "Discard performs regardless of dirtiness — that IS the answer");

    // The one that matters: a cancelled Save dialog leaves the document dirty,
    // and completing the discard then would destroy the very work the prompt
    // was raised to protect.
    assert( settlePerforms(GuardSettle.afterSave, false),
        "a Save that landed ⇒ the deferred action runs");
    assert(!settlePerforms(GuardSettle.afterSave, true),
        "a Save that left the document dirty ⇒ the deferred action is DROPPED");
}

unittest {
    // The published record round-trips through the JSON the HTTP thread reads.
    // Not a formatting test: `id` and `name` are BOTH carried on purpose, and a
    // reader that only got `name` could not tell `file.new` (a user path,
    // guarded) from `/api/reset` (programmatic, unguarded) — both answer
    // "scene.reset".
    import std.json : parseJSON;
    resetUiPolicyRecord();
    GuardRecord r;
    r.id       = "file.new";
    r.name     = "scene.reset";
    r.discards = true;
    r.dirty    = true;
    r.verdict  = "prompt";
    r.suppressed = true;
    r.outcome  = "deferred";
    recordGuardRequest(r);
    setGuardPending(true);

    auto j = parseJSON(uiPolicyJson());
    assert(j["pending"].boolean);
    assert(j["last"]["id"].str        == "file.new");
    assert(j["last"]["name"].str      == "scene.reset");
    assert(j["last"]["discards"].boolean);
    assert(j["last"]["dirty"].boolean);
    assert(j["last"]["verdict"].str   == "prompt");
    assert(j["last"]["suppressed"].boolean);
    assert(j["last"]["outcome"].str   == "deferred");

    // A notice attaches to the record that is already there — that is how a
    // headless run reads text whose modal is suppressed.
    recordUiNotice("Load Image did not run:\n\nno path given");
    auto j2 = parseJSON(uiPolicyJson());
    import std.algorithm : canFind;
    assert(j2["last"]["notice"].str.canFind("no path given"));

    resetUiPolicyRecord();
    auto j3 = parseJSON(uiPolicyJson());
    assert(!j3["pending"].boolean);
    assert("last" !in j3.object, "reset must leave no record behind");
}
