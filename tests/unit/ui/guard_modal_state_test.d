module tests.unit.ui.guard_modal_state_test;

import editor_app : makeGuardModalRole;
import command : Command, g_testMode;
import command_history : RecordMode;
import vibe3d.editing.contracts.editmode : EditMode;
import guarded_action_controller : GuardedActionController,
    GuardedActionPorts, GuardObservationPorts;
import mesh : Mesh;
import ui.discard_guard : GuardAnswer, UiRunOutcome;
import ui.guard_modal_state : GuardModalState;
import ui.panels : drawQuitGuardModal, guardModalDrawSnapshot,
    resetGuardModalDrawSnapshot;
import tests.unit.ui.headless_panel : openPanel;
import view : View;
import d_imgui.imgui_h : ImGuiKey, ImVec2;

private Mesh probeMesh;
private View probeView;

private final class GuardModalProbeCommand : Command {
    private string id_;

    this(string id) {
        super(&probeMesh, probeView, EditMode.Vertices);
        id_ = id;
    }

    override string name() const { return id_; }
    override string label() const { return "Guard modal " ~ id_; }
    override bool discardsUnsavedWork() const { return true; }
}

private final class GuardModalHarness {
    bool dirty = true;
    size_t saveCount;
    Command[] applied;
    RecordMode[] appliedModes;
    GuardAnswer[] answers;
    bool[] performed;
    GuardedActionController controller;

    this() {
        controller = new GuardedActionController(GuardedActionPorts(
            (Command command, RecordMode mode) {
                applied ~= command;
                appliedModes ~= mode;
                return true;
            },
            () => dirty,
            () {
                ++saveCount;
                dirty = false;
                return true;
            },
            (Command) {},
            GuardObservationPorts(
                (record) {},
                (answer, didPerform) {
                    answers ~= answer;
                    performed ~= didPerform;
                },
                (pending) {})));
    }

    GuardModalProbeCommand defer(string id, RecordMode mode) {
        auto command = new GuardModalProbeCommand(id);
        assert(controller.invoke(command, mode, id) == UiRunOutcome.deferred,
            "guard modal fixture did not defer " ~ id);
        return command;
    }
}

private ImVec2 center(ImVec2 lo, ImVec2 hi) {
    return ImVec2((lo.x + hi.x) * 0.5f, (lo.y + hi.y) * 0.5f);
}

private string repositoryRoot() {
    import std.path : dirName;

    return __FILE_FULL_PATH__.dirName.dirName.dirName.dirName;
}

private size_t occurrences(const string haystack, const string needle) {
    import std.string : indexOf;

    size_t count;
    size_t at;
    while (at < haystack.length) {
        const found = haystack.indexOf(needle, at);
        if (found < 0) break;
        ++count;
        at = cast(size_t)found + needle.length;
    }
    return count;
}

unittest { // each callback remains pure before any deliberately partial binding
    import ui.panel_host_roles : GuardModalRole;
    size_t[5] calls;
    bool awaiting() { ++calls[0]; return false; }
    string prompt() { ++calls[1]; return ""; }
    bool save() { ++calls[2]; return false; }
    void discard() { ++calls[3]; }
    void cancel() { ++calls[4]; }
    auto role = GuardModalRole(&awaiting, &prompt, &save, &discard, &cancel);
    const bound = role.isBound();
    assert(calls[0] == 0, "W18 guard query purity awaitingAnswer");
    assert(calls[1] == 0, "W18 guard query purity promptText");
    assert(calls[2] == 0, "W18 guard query purity answerSave");
    assert(calls[3] == 0, "W18 guard query purity answerDiscard");
    assert(calls[4] == 0, "W18 guard query purity answerCancel");
    assert(bound, "W18 guard valid false/empty callback results remain bound");
}

unittest { // each independent missing door makes the role unbound
    import ui.panel_host_roles : GuardModalRole;
    bool awaiting() { return false; }
    string prompt() { return ""; }
    bool save() { return false; }
    void discard() {}
    void cancel() {}
    assert(GuardModalRole(&awaiting, &prompt, &save, &discard, &cancel).isBound(),
        "W18 guard all-valid local positive");
    assert(!GuardModalRole(null, &prompt, &save, &discard, &cancel).isBound(), "W18 guard missing awaitingAnswer requirement");
    assert(!GuardModalRole(&awaiting, null, &save, &discard, &cancel).isBound(), "W18 guard missing promptText requirement");
    assert(!GuardModalRole(&awaiting, &prompt, null, &discard, &cancel).isBound(), "W18 guard missing answerSave requirement");
    assert(!GuardModalRole(&awaiting, &prompt, &save, null, &cancel).isBound(), "W18 guard missing answerDiscard requirement");
    assert(!GuardModalRole(&awaiting, &prompt, &save, &discard, null).isBound(), "W18 guard missing answerCancel requirement");
    assert(!makeGuardModalRole(null).isBound(), "W18 guard null controller remains unbound");
}

unittest { // actual factory awaitingAnswer door reads or acts on the same live controller
    auto a = new GuardModalHarness;
    auto b = new GuardModalHarness;
    auto role = makeGuardModalRole(a.controller);
    assert(role.isBound(), "W18 guard factory local positive");
    assert(!role.awaitingAnswer, "W18 guard factory awaitingAnswer idle positive");
    a.defer("borrow-A", RecordMode.Record);
    assert(role.awaitingAnswer && !b.controller.awaitingAnswer, "W18 guard factory awaitingAnswer live A/B");
    a.controller.answerCancel();
    assert(!role.awaitingAnswer, "W18 guard factory awaitingAnswer second live read");
}

unittest { // actual factory promptText door reads or acts on the same live controller
    auto a = new GuardModalHarness;
    auto b = new GuardModalHarness;
    auto role = makeGuardModalRole(a.controller);
    assert(role.isBound(), "W18 guard factory local positive");
    a.defer("borrow-A", RecordMode.Record);
    b.defer("borrow-B", RecordMode.Record);
    assert(role.promptText == "You have unsaved changes.\n\nSave them before Guard modal borrow-A?",
        "W18 guard factory promptText exact live A/B label");
    a.controller.answerCancel();
    assert(role.promptText.length == 0, "W18 guard factory promptText second live read");
}

unittest { // actual factory answerSave door reads or acts on the same live controller
    auto a = new GuardModalHarness;
    auto b = new GuardModalHarness;
    auto role = makeGuardModalRole(a.controller);
    assert(role.isBound(), "W18 guard factory local positive");
    a.defer("borrow-A", RecordMode.Record);
    b.defer("borrow-B", RecordMode.Record);
    assert(role.answerSave() && a.saveCount == 1 && b.saveCount == 0, "W18 guard factory answerSave identity");
    assert(a.answers == [GuardAnswer.save] && a.performed == [false] && a.applied.length == 0,
        "W18 guard factory save event remains before settle");
}

unittest { // actual factory answerDiscard door reads or acts on the same live controller
    auto a = new GuardModalHarness;
    auto b = new GuardModalHarness;
    auto role = makeGuardModalRole(a.controller);
    assert(role.isBound(), "W18 guard factory local positive");
    a.defer("borrow-A", RecordMode.Record);
    b.defer("borrow-B", RecordMode.Record);
    role.answerDiscard();
    assert(!a.controller.awaitingAnswer && b.controller.awaitingAnswer, "W18 guard factory answerDiscard live A/B");
    assert(a.answers == [GuardAnswer.discard] && a.performed == [false] && a.applied.length == 0,
        "W18 guard factory discard event remains before settle");
}

unittest { // actual factory answerCancel door reads or acts on the same live controller
    auto a = new GuardModalHarness;
    auto b = new GuardModalHarness;
    auto role = makeGuardModalRole(a.controller);
    assert(role.isBound(), "W18 guard factory local positive");
    a.defer("borrow-A", RecordMode.Record);
    b.defer("borrow-B", RecordMode.Record);
    role.answerCancel();
    assert(!a.controller.pending && b.controller.pending, "W18 guard factory answerCancel live A/B");
    assert(a.answers == [GuardAnswer.cancel] && a.performed == [false] && a.applied.length == 0,
        "W18 guard factory cancel answers without apply");
}

unittest { // a partial unused answer door safely isolates the original policy refusal
    import core.exception : AssertError;
    import ui.panel_host_roles : GuardModalRole;
    size_t calls;
    bool awaiting() { ++calls; return false; }
    string prompt() { ++calls; return ""; }
    bool save() { ++calls; return false; }
    void discard() { ++calls; }
    void cancel() { ++calls; }
    auto state = new GuardModalState;
    auto partial = GuardModalRole(&awaiting, &prompt, null, &discard, &cancel);
    auto valid = GuardModalRole(&awaiting, &prompt, &save, &discard, &cancel);
    bool refused;
    auto ui = openPanel(() {
        try { drawQuitGuardModal(state, false, partial); }
        catch (AssertError error) {
            refused = true;
            assert(error.msg == "quit guard modal requires guard policy",
                "W18 partial guard must refuse at the original policy assertion");
        }
        assert(refused, "W18 partial guard policy refusal missing");
        assert(calls == 0, "W18 partial guard refused after invoking a callback");
        drawQuitGuardModal(state, false, valid);
    }, "W18 guard partial and restored idle positive");
    scope (exit) ui.close();
    ui.frame();
    assert(!state.discardConfirmOpen, "W18 guard all-valid idle local positive");
}

unittest { // physical query and production factory carry each independent door
    import std.file : readText;
    import std.path : buildPath;
    import std.string : indexOf;
    import std.regex : matchAll, regex;
    import tests.unit.census_symbols : blankNonCode, countIdent, balancedSpan;
    const root = repositoryRoot();
    const role = blankNonCode(readText(buildPath(root, "packages/editor-ui/source/ui/panel_host_roles.d")));
    const factory = blankNonCode(readText(buildPath(root, "source/editor_app.d")));
    const app = blankNonCode(readText(buildPath(root, "source/app.d")));
    assert(countIdent(role, "isBound") == 1, "W18 guard query declaration floor");
    const queryAt = role.indexOf("isBound");
    const bodyAt = role.indexOf("{", cast(size_t)queryAt);
    const body = balancedSpan(role, cast(size_t)bodyAt, '{', '}');
    assert(body.length > 100, "W18 guard query body floor");
    assert(!matchAll(body, regex(r"\bawaitingAnswer_\b\s*!is\s+null")).empty, "W18 guard physical awaitingAnswer term");
    assert(!matchAll(body, regex(r"\bpromptText_\b\s*!is\s+null")).empty, "W18 guard physical promptText term");
    assert(!matchAll(body, regex(r"\banswerSave_\b\s*!is\s+null")).empty, "W18 guard physical answerSave term");
    assert(!matchAll(body, regex(r"\banswerDiscard_\b\s*!is\s+null")).empty, "W18 guard physical answerDiscard term");
    assert(!matchAll(body, regex(r"\banswerCancel_\b\s*!is\s+null")).empty, "W18 guard physical answerCancel term");
    const roleAt = role.indexOf("struct GuardModalRole");
    const roleOpen = role.indexOf("{", cast(size_t)roleAt);
    const roleBody = balancedSpan(role, cast(size_t)roleOpen, '{', '}');
    assert(roleAt >= 0 && roleBody.length > 800, "W18 guard private slot scope floor");
    const firstPublic = roleBody.indexOf("public:");
    const firstPrivate = roleBody.indexOf("private:");
    assert(firstPrivate >= 0 && firstPublic > firstPrivate
        && !matchAll(roleBody[firstPrivate .. firstPublic], regex(r"(?m)^\s*bool\s+delegate\(\)\s+awaitingAnswer_\s*;")).empty,
        "W18 guard private awaitingAnswer_ source door");
    assert(firstPrivate >= 0 && firstPublic > firstPrivate
        && !matchAll(roleBody[firstPrivate .. firstPublic], regex(r"(?m)^\s*string\s+delegate\(\)\s+promptText_\s*;")).empty,
        "W18 guard private promptText_ source door");
    assert(firstPrivate >= 0 && firstPublic > firstPrivate
        && !matchAll(roleBody[firstPrivate .. firstPublic], regex(r"(?m)^\s*bool\s+delegate\(\)\s+answerSave_\s*;")).empty,
        "W18 guard private answerSave_ source door");
    assert(firstPrivate >= 0 && firstPublic > firstPrivate
        && !matchAll(roleBody[firstPrivate .. firstPublic], regex(r"(?m)^\s*void\s+delegate\(\)\s+answerDiscard_\s*;")).empty,
        "W18 guard private answerDiscard_ source door");
    assert(firstPrivate >= 0 && firstPublic > firstPrivate
        && !matchAll(roleBody[firstPrivate .. firstPublic], regex(r"(?m)^\s*void\s+delegate\(\)\s+answerCancel_\s*;")).empty,
        "W18 guard private answerCancel_ source door");
    assert(role.indexOf(".tupleof") < 0 && role.indexOf("mixin") < 0
        && role.indexOf("getMember") < 0, "W18 guard role gained a raw reflection capability");
    assert(countIdent(factory, "makeGuardModalRole") == 1, "W18 guard factory declaration floor");
    assert(!matchAll(factory, regex(r"&\s*guardController\s*\.\s*awaitingAnswer\b")).empty, "W18 guard physical factory awaitingAnswer identity");
    assert(!matchAll(factory, regex(r"&\s*guardController\s*\.\s*promptText\b")).empty, "W18 guard physical factory promptText identity");
    assert(!matchAll(factory, regex(r"&\s*guardController\s*\.\s*answerSave\b")).empty, "W18 guard physical factory answerSave identity");
    assert(!matchAll(factory, regex(r"&\s*guardController\s*\.\s*answerDiscard\b")).empty, "W18 guard physical factory answerDiscard identity");
    assert(!matchAll(factory, regex(r"&\s*guardController\s*\.\s*answerCancel\b")).empty, "W18 guard physical factory answerCancel identity");
    assert(app.indexOf("editor_app.makeGuardModalRole(guardController)") >= 0, "W18 guard production draw uses original controller");
}

unittest { // exact derived role capability and five private slot types
    import ui.panel_host_roles : GuardModalRole;
    static assert([__traits(allMembers, GuardModalRole)] == ["awaitingAnswer_", "promptText_", "answerSave_", "answerDiscard_", "answerCancel_", "__ctor", "isBound", "awaitingAnswer", "promptText", "answerSave", "answerDiscard", "answerCancel"]);
    static assert(is(typeof(GuardModalRole.init.tupleof[0]) == bool delegate()));
    static assert(is(typeof(GuardModalRole.init.tupleof[1]) == string delegate()));
    static assert(is(typeof(GuardModalRole.init.tupleof[2]) == bool delegate()));
    static assert(is(typeof(GuardModalRole.init.tupleof[3]) == void delegate()));
    static assert(is(typeof(GuardModalRole.init.tupleof[4]) == void delegate()));
    static assert(is(typeof(GuardModalRole.init.isBound()) == bool));
    static assert(__traits(compiles, { const GuardModalRole role; return role.isBound(); }));
}

unittest { // five fields belong to each state instance, never shared storage
    auto visible = new GuardModalState();
    auto other = new GuardModalState();

    visible.requestDiscardOpen(false, true);
    assert(visible.discardConfirmOpen && visible.discardConfirmPending,
        "pending guard did not request its popup handshake");
    assert(visible.consumeDiscardOpen(),
        "the first pending->open handoff did not fire");
    assert(!visible.consumeDiscardOpen(),
        "one pending guard requested OpenPopup more than once");
    visible.requestDiscardOpen(false, true);
    assert(!visible.discardConfirmPending,
        "an already-open guard re-armed its pending->open handoff");

    visible.publishNotice("visible refusal");
    assert(visible.noticeText == "visible refusal"
        && visible.noticeOpen && visible.noticePending,
        "notice publisher did not write the visible state owner");
    assert(!other.discardConfirmOpen && !other.discardConfirmPending
        && other.noticeText.length == 0 && !other.noticeOpen
        && !other.noticePending,
        "two GuardModalState instances share popup storage");
    assert(visible.consumeNoticeOpen() && !visible.consumeNoticeOpen(),
        "one notice requested OpenPopup more than once");

    other.requestDiscardOpen(true, true);
    assert(!other.discardConfirmOpen && !other.discardConfirmPending,
        "test mode opened the guard window instead of suppressing only it");
}

unittest { // real ImGui handshake keeps every answer deferred until settle
    const oldTestMode = g_testMode;
    g_testMode = false;
    scope (exit) g_testMode = oldTestMode;

    auto state = new GuardModalState();
    auto harness = new GuardModalHarness();
    resetGuardModalDrawSnapshot();
    auto ui = openPanel(() {
        drawQuitGuardModal(state, false, makeGuardModalRole(harness.controller));
    }, "Guard modal host");
    scope (exit) ui.close();

    auto saveCommand = harness.defer("save", RecordMode.Coalescing);
    ui.frame();
    ui.frame();
    auto snap = guardModalDrawSnapshot();
    assert(snap.discardOpenCalls == 1 && state.discardConfirmOpen
        && !state.discardConfirmPending,
        "one deferred command must perform pending->OpenPopup exactly once");
    assert(snap.saveMax.x > snap.saveMin.x && snap.saveMax.y > snap.saveMin.y,
        "guard modal did not publish a clickable Save button");
    ui.hoverAt(center(snap.saveMin, snap.saveMax));
    snap = guardModalDrawSnapshot();
    ui.pressAt(center(snap.saveMin, snap.saveMax));
    ui.release();
    assert(harness.saveCount == 1,
        "Save answer did not run the ordinary Save separately");
    assert(harness.applied.length == 0,
        "guarded action applied at the Save answer before settle");
    assert(harness.controller.pending && !harness.controller.awaitingAnswer,
        "Save answer dropped the deferred command before settle");
    assert(harness.controller.settle()
        && harness.applied.length == 1
        && harness.applied[0] is saveCommand,
        "post-flush settle did not apply the Save-held command");

    harness.dirty = true;
    auto discardCommand = harness.defer("discard", RecordMode.Record);
    ui.frame();
    ui.frame();
    snap = guardModalDrawSnapshot();
    assert(snap.discardOpenCalls == 2,
        "the second guarded command did not get exactly one fresh open request");
    assert(snap.discardMax.x > snap.discardMin.x
        && snap.discardMax.y > snap.discardMin.y,
        "guard modal did not publish a clickable Discard button");
    ui.hoverAt(center(snap.discardMin, snap.discardMax));
    snap = guardModalDrawSnapshot();
    ui.pressAt(center(snap.discardMin, snap.discardMax));
    ui.release();
    assert(harness.applied.length == 1,
        "guarded action applied at the Discard answer before settle");
    assert(harness.controller.pending && !harness.controller.awaitingAnswer,
        "Discard answer dropped the deferred command before settle");
    assert(harness.controller.settle()
        && harness.applied.length == 2
        && harness.applied[1] is discardCommand,
        "post-flush settle did not apply the Discard-held command");
    assert(!harness.controller.settle() && harness.applied.length == 2,
        "guarded settle was not one-shot");
    assert(harness.saveCount == 1
        && harness.appliedModes == [RecordMode.Coalescing, RecordMode.Record],
        "ordinary Save and guarded applies were not counted independently");

    harness.dirty = true;
    harness.defer("cancel-between-frames", RecordMode.Record);
    ui.frame();
    assert(state.discardConfirmOpen,
        "between-frame cancellation setup did not open the popup");
    harness.controller.answerCancel();
    const answersBeforeCloseFrame = harness.answers.length;
    ui.frame();
    assert(!state.discardConfirmOpen && !state.discardConfirmPending,
        "a controller cancelled between frames left the popup open");
    assert(harness.answers.length == answersBeforeCloseFrame,
        "closing a popup for an already-cancelled controller answered twice");

    harness.dirty = true;
    harness.defer("escape", RecordMode.Record);
    ui.frame();
    ui.keyDown(cast(int)ImGuiKey.Escape);
    ui.frame();
    ui.keyUp(cast(int)ImGuiKey.Escape);
    ui.frame();
    assert(!harness.controller.pending && !state.discardConfirmOpen,
        "ESC did not route through the guard's Cancel answer");
    ui.close();

    harness.dirty = true;
    harness.defer("test-mode", RecordMode.Record);
    auto suppressedState = new GuardModalState();
    auto suppressedUi = openPanel(() {
        drawQuitGuardModal(suppressedState, true, makeGuardModalRole(harness.controller));
    }, "Suppressed guard modal host");
    scope (exit) suppressedUi.close();
    suppressedUi.frame();
    assert(harness.controller.awaitingAnswer
        && !suppressedState.discardConfirmOpen
        && harness.applied.length == 2,
        "test mode suppressed the deferral instead of only the guard window");
    harness.controller.answerCancel();
}

unittest { // production publisher, panel and diagnostic share one owner
    import std.algorithm.searching : canFind;
    import tests.unit.census_symbols : readText = wave15ReadText;
    import std.path : buildPath;
    import std.string : indexOf;

    const root = repositoryRoot();
    const app = readText(root.buildPath("source", "app.d"));
    const editor = readText(root.buildPath("source", "editor_app.d"));
    const panel = readText(root.buildPath("source", "ui", "panels.d"));
    const provider = readText(root.buildPath("source", "http_providers.d"));

    assert(occurrences(app, "auto guardModalState = new GuardModalState();") == 1,
        "application must construct exactly one GuardModalState owner");
    assert(occurrences(app,
            "app.guardModalState               = guardModalState;") == 1
        && occurrences(app,
            "guardModalState.publishNotice(text);") == 1
        && occurrences(app,
            "drawQuitGuardModal(guardModalState, testMode, guardController);") == 1,
        "notice publisher, visible diagnostic and modal no longer share one GuardModalState");
    assert(provider.indexOf("guardModalState.discardConfirmOpen") >= 0
        && provider.indexOf("guardModalState.noticeOpen") >= 0,
        "HTTP visible-state diagnostic no longer reads GuardModalState");

    immutable string[] retiredSlots = [
        "discardConfirmOpenPtr", "discardConfirmPendingPtr",
        "noticeTextPtr", "noticeOpenPtr", "noticePendingPtr",
    ];
    foreach (slot; retiredSlots)
        assert(!app.canFind(slot) && !editor.canFind(slot),
            "retired modal pointer slot/storage remains: " ~ slot);
    immutable string[] retiredLocals = [
        "bool   discardConfirmOpen;", "bool   discardConfirmPending;",
        "string noticeText;", "bool   noticeOpen;", "bool   noticePending;",
    ];
    foreach (local; retiredLocals)
        assert(!app.canFind(local),
            "old app.main modal storage remains beside GuardModalState: " ~ local);

    assert(panel.indexOf(
            "void drawQuitGuardModal(GuardModalState state, bool testMode,") >= 0
        && panel.indexOf("void drawQuitGuardModal(EditorApp") < 0,
        "quit modal regained the whole EditorApp instead of its three roles");
    assert(occurrences(panel,
            "cancelGuardPopup(state, guardController);") == 4,
        "Cancel button and ESC/X no longer share one answerCancel path");

    assert(panel.canFind("Until task 1521 this")
        && panel.canFind("guard a SECOND point")
        && panel.canFind("File → New and File → Open but NOT quit")
        && panel.canFind("one GuardedActionController"),
        "the measured task-1521 single-decision-point contract was lost");

    const raiseBegin = app.indexOf("    void raiseNotice(string text)");
    const raiseEnd = app.indexOf("    void raiseCommandNotice(Command cmd)");
    assert(raiseBegin >= 0 && raiseEnd > raiseBegin,
        "could not locate the production notice publisher");
    const raiseBody = app[cast(size_t)raiseBegin .. cast(size_t)raiseEnd];
    const emptyGate = raiseBody.indexOf("if (text.length == 0) return;");
    const testGate = raiseBody.indexOf("if (command.g_testMode) return;");
    const publish = raiseBody.indexOf("guardModalState.publishNotice(text);");
    assert(emptyGate >= 0 && testGate > emptyGate && publish > testGate,
        "notice reason/test-mode gating moved after visible publication");
}
