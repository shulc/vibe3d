// Module unittests for `ui.discard_guard` — the PURE half of the unsaved-work
// guard (tasks 1520 + 1521).
//
// What is asserted here is the DECISION, not the drawing: the ImGui modal that
// carries it is not observable headlessly, so an assertion written against the
// draw could only ever say "the function ran". The same split
// `tests/unit/ui/command_notice_test.d` makes, for the same reason.
module tests.unit.ui.discard_guard_test;

import ui.discard_guard;
import guarded_action_controller : GuardedActionController,
    GuardedActionPorts, GuardObservationPorts;
import command : Command, g_testMode;
import command_history : RecordMode;
import editmode : EditMode;
import mesh : Mesh;
import view : View;

private Mesh guardProbeMesh;
private View guardProbeView;

private final class GuardProbeCommand : Command {
    private string name_;
    private string label_;

    this(string name, string label) {
        super(&guardProbeMesh, guardProbeView, EditMode.Vertices);
        name_ = name;
        label_ = label;
    }

    override string name() const { return name_; }
    override string label() const { return label_; }
    override bool discardsUnsavedWork() const { return true; }
}

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

unittest { // the real application owner, with no window and no HTTP
    import std.json : parseJSON;

    const oldTestMode = g_testMode;
    g_testMode = true;
    scope(exit) {
        g_testMode = oldTestMode;
        resetUiPolicyRecord();
    }

    bool dirty = true;
    bool saveShouldLand;
    bool lastSaveResult;
    size_t saveCount;
    size_t deferredCount;
    Command[] applied;
    RecordMode[] appliedModes;

    auto controller = new GuardedActionController(GuardedActionPorts(
        (Command command, RecordMode mode) {
            applied ~= command;
            appliedModes ~= mode;
            return true;
        },
        () => dirty,
        () {
            ++saveCount;
            lastSaveResult = saveShouldLand;
            if (lastSaveResult) dirty = false;
            return lastSaveResult;
        },
        (Command) {},
        GuardObservationPorts(
            (record) => recordGuardRequest(record),
            (answer, performed) => recordGuardAnswer(answer, performed),
            (pending) {
                setGuardPending(pending);
                if (pending) ++deferredCount;
            })));

    // Busy holds A by identity even when B has the same command name.
    auto busyA = new GuardProbeCommand("scene.reset", "Original new");
    auto busyB = new GuardProbeCommand("scene.reset", "Replacement reset");
    assert(controller.invoke(busyA, RecordMode.Record, "file.new")
        == UiRunOutcome.deferred);
    auto firstRecord = parseJSON(uiPolicyJson())["last"];
    assert(firstRecord["id"].str == "file.new"
        && firstRecord["name"].str == "scene.reset",
        "guard record replaced the dispatched id with the command name");
    assert(applied.length == 0, "guarded action applied before settle");
    assert(controller.invoke(busyB, RecordMode.Coalescing, "scene.reset")
        == UiRunOutcome.deferred);
    assert(controller.pendingCommand is busyA,
        "busy dispatch replaced the original pending command");
    controller.answerCancel();
    assert(!controller.pending, "cancel left a guarded action pending");
    assert(applied.length == 0, "cancel performed the guarded action");

    // A cancelled ordinary Save fires at answer time but cannot arm an early
    // guarded apply, and the dirty read prevents it at settle.
    auto saveCancelled = new GuardProbeCommand("scene.reset", "Cancelled save");
    dirty = true;
    saveShouldLand = false;
    assert(controller.invoke(saveCancelled, RecordMode.Record, "file.new")
        == UiRunOutcome.deferred);
    assert(!controller.answerSave());
    assert(saveCount == 1 && !lastSaveResult,
        "cancelled ordinary save did not report its own result");
    assert(applied.length == 0,
        "guarded action applied at the cancelled-save answer");
    assert(!controller.settle());
    assert(applied.length == 0,
        "cancelled save performed the guarded action at settle");

    // A landed ordinary Save still performs only the original held instance,
    // and only after the explicit settle.
    auto saveLanded = new GuardProbeCommand("scene.reset", "Landed save");
    dirty = true;
    saveShouldLand = true;
    assert(controller.invoke(saveLanded, RecordMode.Coalescing, "file.new")
        == UiRunOutcome.deferred);
    assert(controller.answerSave());
    assert(saveCount == 2 && lastSaveResult,
        "landed ordinary save did not report its own result");
    assert(applied.length == 0,
        "guarded action applied at the landed-save answer");
    assert(controller.settle());
    assert(applied.length == 1 && applied[$ - 1] is saveLanded,
        "save settle did not apply the original guarded command");

    // Discard has the same answer/settle split, and settle is one-shot.
    auto discarded = new GuardProbeCommand("scene.reset", "Discarded original");
    dirty = true;
    assert(controller.invoke(discarded, RecordMode.Record, "file.new")
        == UiRunOutcome.deferred);
    controller.answerDiscard();
    assert(applied.length == 1,
        "guarded action applied at the discard answer");
    assert(controller.settle());
    assert(applied.length == 2 && applied[$ - 1] is discarded,
        "discard settle did not apply the original guarded command");
    assert(!controller.settle());
    assert(applied.length == 2,
        "repeated settle applied the guarded command twice");

    assert(deferredCount == 4,
        "deferred-action population floor: expected four held commands");
    assert(applied.length == 2,
        "guarded-apply population floor: expected two guarded applies");
    assert(appliedModes == [RecordMode.Coalescing, RecordMode.Record],
        "guarded applies lost their requested record modes");
}
