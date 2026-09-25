// close_reason_table_test — the operation's close, slice M2 of the tool session
// model (doc/tool_session_model_plan_2026-09-24.md R4.2 witness 3; opponent R3
// conditions C2 and C3).
//
// (1) `closeReasonFor` over every `ToolTransition`: the population floor (16)
//     and the whole table as a literal, `commandPreApplyDrop -> drop` included.
// (2) `EditSession.closeOperation(command, door)`: the four steps of the one
//     routine against the policy, driven through the production session with
//     stand-in tools that only count calls.
// (3) The written-row account (C2): a close marks the row it WROTE — by the
//     undo top's identity — and nothing when it wrote none, for a command
//     close and for a door close alike.
// (5) `endsLiveEditBeforeUiCommand`: which UI commands close a live operation.
// (4) The resume, through the production `CommandExecutor` wired to the
//     production `EditSession` exactly as `app.d` wires them (C3): it runs
//     after the command recorded, once, only from the non-reentrant frame,
//     and never on a tool the command dropped.
// Fast loop: tools/local/ut-standalone.sh tests/unit/close_reason_table_test.d
module tests.unit.close_reason_table_test;

import command : CmdFlags, Command, endsLiveEditBeforeUiCommand;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import edit_session : EditSession;
import editmode : EditMode;
import tool : CommandClose, Tool, ToolSessionPolicy;
import tool_activation_ownership;
import view : View;

import std.format : format;
import std.traits : EnumMembers;

// ---- (1) the table ------------------------------------------------------------

private immutable CloseReason[ToolTransition] kTable;
shared static this() {
    kTable = [
        ToolTransition.commandArm:             CloseReason.switch_,
        ToolTransition.interactiveArm:         CloseReason.switch_,
        ToolTransition.replayArm:              CloseReason.none,
        ToolTransition.resetRearm:             CloseReason.discard,
        ToolTransition.explicitDrop:           CloseReason.drop,
        ToolTransition.sameIdToggleDrop:       CloseReason.drop,
        ToolTransition.replayDrop:             CloseReason.none,
        ToolTransition.selTypeFlipDrop:        CloseReason.drop,
        ToolTransition.activeLayerChangedDrop: CloseReason.drop,
        ToolTransition.documentReplaceDisarm:  CloseReason.drop,
        ToolTransition.sceneResetDrop:         CloseReason.drop,
        ToolTransition.meshRebuildDrop:        CloseReason.drop,
        ToolTransition.commandPreApplyDrop:    CloseReason.drop,
        ToolTransition.editCancelDrop:         CloseReason.none,
        ToolTransition.panelDrop:              CloseReason.drop,
        ToolTransition.shutdownDrop:           CloseReason.drop,
    ];
}

unittest {
    enum n = [EnumMembers!ToolTransition].length;
    static assert(n == 16, "M2 close table: the transition population changed");
    assert(kTable.length == 16, format("M2 close table: %s literal rows, expected 16", kTable.length));
    size_t rows;
    foreach (t; EnumMembers!ToolTransition) {
        auto want = t in kTable;
        assert(want !is null, format("M2 close table: %s has no literal row", t));
        assert(closeReasonFor(t) == *want,
               format("M2 close table: %s closes as %s, expected %s", t, closeReasonFor(t), *want));
        ++rows;
    }
    assert(rows == 16);
    // `command` is the value of NO transition: it comes only from the funnel.
    foreach (t; EnumMembers!ToolTransition)
        assert(closeReasonFor(t) != CloseReason.command,
               format("M2 close table: %s maps to `command`", t));
}

// ---- stand-ins ------------------------------------------------------------------

private final class StubCommand : Command {
    private string id_;
    private CmdFlags flags_;
    private bool delegate() apply_;
    private View view_;
    this(string id, CmdFlags flags, bool delegate() apply = null) {
        view_ = new View(0, 0, 1, 1);
        super(null, view_, EditMode.Vertices);
        id_ = id; flags_ = flags; apply_ = apply;
    }
    override string name() const { return id_; }
    override CmdFlags cmdFlags() const { return flags_; }
    protected override bool applyImpl() { return apply_ is null || apply_(); }
}

/// A tool that counts the close routine's calls into it.
private class CountingTool : Tool {
    CommandClose cc;
    bool open;          // hasUncommittedEdit
    bool commits = true;
    CommandHistory writeTo;   // commitOperation records a row here when set
    string[]* log;
    size_t commitCalls, resumeCalls;
    this(CommandClose cc, bool open, string[]* log = null) {
        this.cc = cc; this.open = open; this.log = log;
    }
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        ToolSessionPolicy p;
        p.commandClose = cc;
        return p;
    }
    override bool hasUncommittedEdit() const { return open; }
    override bool commitOperation() {
        ++commitCalls;
        if (log !is null) *log ~= "commit";
        if (!commits) return false;
        if (writeTo !is null) writeTo.record(new StubCommand("op", CmdFlags.Model));
        open = false;
        return true;
    }
    override void resumeAfterClose() {
        ++resumeCalls;
        if (log !is null) *log ~= "resume";
    }
}

// ---- (5) the UI-door predicate ------------------------------------------------------

unittest {
    struct P { string id; CmdFlags flags; bool closes; }
    immutable P[] rows = [
        P("mesh.hide",            CmdFlags.UiState, true),
        P("select.invert",        CmdFlags.Model,   true),
        P("mesh.flip",            CmdFlags.Model,   true),
        P("mesh.delete",          CmdFlags.Model,   true),
        P("mesh.subpatch_toggle", CmdFlags.Model,   true),
        P("layer.select",         CmdFlags.UiState, true),
        P("viewport.fit",         CmdFlags.SideEffect, false),
        P("falloff.set",          CmdFlags.SideEffect, false),
        P("mesh.quiet",           cast(CmdFlags)(CmdFlags.Model | CmdFlags.UndoSuppress), false),
        P("tool.doApply",         CmdFlags.Model,   false),
        P("history.undo",         CmdFlags.Model,   false),
        P("scene.reset",          CmdFlags.Model,   false),
        P("file.new",             CmdFlags.Model,   false),
        P("layer.attr",           CmdFlags.Model,   false),
    ];
    size_t n;
    foreach (r; rows) {
        assert(endsLiveEditBeforeUiCommand(new StubCommand(r.id, r.flags)) == r.closes,
               format("M2 UI-door predicate: %s (%s) closes=%s, expected %s", r.id, r.flags,
                      !r.closes, r.closes));
        ++n;
    }
    assert(n == 14, format("M2 UI-door predicate: %s rows, expected 14", n));
}

// ---- (2) the routine ------------------------------------------------------------

unittest {
    Tool held;
    auto history = new CommandHistory();
    auto es = new EditSession(() => held, history, () {});
    size_t cells;

    // (1) no tool.
    assert(es.closeOperation(CloseReason.command, CommandDoor.ui) == CloseOutcome(false, false));
    ++cells;

    // (2) `none` on either door: not called, not kept.
    auto none = new CountingTool(CommandClose.none, true);
    held = none;
    foreach (door; [CommandDoor.ui, CommandDoor.script]) {
        assert(es.closeOperation(CloseReason.command, door) == CloseOutcome(false, false),
               format("M2 close: a `none` tool is kept on the %s door", door));
        ++cells;
    }
    assert(none.commitCalls == 0, "M2 close: a `none` tool was asked to commit");

    // (2) `uiDoor` on the script door: not called, not kept.
    auto ui = new CountingTool(CommandClose.uiDoor, true);
    held = ui;
    assert(es.closeOperation(CloseReason.command, CommandDoor.script) == CloseOutcome(false, false),
           "M2 close: the script door closed a `uiDoor` tool");
    assert(ui.commitCalls == 0, "M2 close: the script door called a `uiDoor` tool's commit");
    ++cells;

    // (3) `uiDoor`, idle: kept, not called.
    ui.open = false;
    assert(es.closeOperation(CloseReason.command, CommandDoor.ui) == CloseOutcome(false, true),
           "M2 close: an idle `uiDoor` tool was not kept (R20 law, K-tab)");
    assert(ui.commitCalls == 0, "M2 close: an idle `uiDoor` tool was asked to commit");
    ++cells;

    // (4) `uiDoor`, open: committed and kept.
    ui.open = true;
    assert(es.closeOperation(CloseReason.command, CommandDoor.ui) == CloseOutcome(true, true),
           "M2 close: an open `uiDoor` tool was not closed and kept");
    assert(ui.commitCalls == 1);
    es.finishClose();
    assert(ui.resumeCalls == 1, "M2 close: the closed tool was not resumed once");
    es.finishClose();
    assert(ui.resumeCalls == 1, "M2 close: a second finishClose resumed again");
    ++cells;

    // (4) a refused commit: not kept, no resume.
    ui.open = true;
    ui.commits = false;
    assert(es.closeOperation(CloseReason.command, CommandDoor.ui) == CloseOutcome(false, false),
           "M2 close: a refused commit kept the tool");
    es.finishClose();
    assert(ui.resumeCalls == 1, "M2 close: a refused commit resumed the tool");
    ++cells;

    // `allDoors`, idle, script door: called even between gestures (the
    // transform's run is open when its edit is not).
    auto all = new CountingTool(CommandClose.allDoors, false);
    held = all;
    assert(es.closeOperation(CloseReason.command, CommandDoor.script) == CloseOutcome(true, true),
           "M2 close: an `allDoors` tool was not closed on the script door");
    assert(all.commitCalls == 1, "M2 close: an idle `allDoors` tool was not asked to commit");
    es.finishClose();
    ++cells;

    // Every other reason is the door's: the session does not call the tool.
    foreach (r; [CloseReason.drop, CloseReason.switch_, CloseReason.discard, CloseReason.none]) {
        auto t = new CountingTool(CommandClose.allDoors, true);
        held = t;
        assert(es.closeOperation(r) == CloseOutcome(false, false));
        es.finishClose();
        assert(t.commitCalls == 0 && t.resumeCalls == 0,
               format("M2 close: reason %s called into the tool", r));
        ++cells;
    }
    assert(cells == 12, format("M2 close: routine cell population %s, expected 12", cells));
}

// ---- (3) the written-row account (C2) --------------------------------------------

unittest {
    Tool held;
    auto history = new CommandHistory();
    auto es = new EditSession(() => held, history, () {});
    history.record(new StubCommand("earlier", CmdFlags.Model));
    const earlier = history.undoEntries()[$ - 1].cmd;

    // A command close that commits NOTHING (the transform between gestures
    // shape): nothing is marked, least of all the earlier row on top.
    auto quiet = new CountingTool(CommandClose.allDoors, false);
    held = quiet;
    assert(es.closeOperation(CloseReason.command, CommandDoor.script).closed);
    assert(es.lastClosedRow() is null,
           "M2 close account: a close that wrote no row marked the earlier top");
    es.finishClose();
    assert(es.lastClosedRow() is null);

    // A command close that writes a row: that row, before the command.
    auto writer = new CountingTool(CommandClose.uiDoor, true);
    writer.writeTo = history;
    held = writer;
    assert(es.closeOperation(CloseReason.command, CommandDoor.ui).closed);
    const written = history.undoEntries()[$ - 1].cmd;
    assert(written !is earlier && es.lastClosedRow() is written,
           "M2 close account: the row the command close wrote is not the one marked");
    es.finishClose();

    // A door close: the row is marked after the door, if the door wrote one.
    held = new CountingTool(CommandClose.none, true);
    es.closeOperation(CloseReason.drop);
    assert(es.lastClosedRow() is null, "M2 close account: a drop marked before its door");
    history.record(new StubCommand("door row", CmdFlags.Model));
    const doorRow = history.undoEntries()[$ - 1].cmd;
    es.finishClose();
    assert(es.lastClosedRow() is doorRow, "M2 close account: the drop door's row is not marked");

    // ... and nothing when the door wrote nothing.
    es.closeOperation(CloseReason.drop);
    es.finishClose();
    assert(es.lastClosedRow() is null,
           "M2 close account: a drop that wrote no row marked the earlier top");
}

// ---- (4) the resume through the production funnel (C3) ----------------------------

private CommandExecutor wire(CommandHistory history, EditSession es, ref Tool held,
                             size_t* drops) {
    // Exactly app.d's two close delegates (census:
    // tests/unit/model_command_rearm_census_test.d reads them from app.d).
    Tool* h = &held;
    return new CommandExecutor(history,
        () => *h !is null,
        (ToolTransition why) { ++*drops; es.closeOperation(closeReasonFor(why));
                               *h = null; es.finishClose(); },
        (CommandDoor door) => es.closeOperation(CloseReason.command, door),
        () { es.finishClose(); });
}

unittest {
    auto history = new CommandHistory();
    Tool held;
    string[] log;
    size_t drops;
    auto es = new EditSession(() => held, history, () {});
    auto ex = wire(history, es, held, &drops);

    // The UI door: close, then the command applies and records, THEN resume.
    auto t = new CountingTool(CommandClose.uiDoor, true, &log);
    held = t;
    auto sel = new StubCommand("select.invert", CmdFlags.Model,
                               () { log ~= "apply"; return true; });
    assert(ex.applyOrRefireFromUi(sel, RecordMode.Record, null));
    assert(log == ["commit", "apply", "resume"],
           format("M2 funnel: close/apply/resume order %s", log));
    assert(held is t && drops == 0, "M2 funnel: the closed tool did not stay armed");

    // The script door with the same command: the funnel's old rules (drop).
    log = null;
    t.open = true;
    assert(ex.applyOrRefire(sel, RecordMode.Record, null));
    assert(log == ["apply"] && drops == 1 && held is null,
           format("M2 funnel: the script door is no longer raw: %s, drops %s", log, drops));

    // An `allDoors` tool (the transform) on the SCRIPT door: only the 6250
    // command closes it there; any other command keeps the old drop rule.
    log = null;
    drops = 0;
    auto xf = new CountingTool(CommandClose.allDoors, false, &log);
    held = xf;
    assert(ex.applyOrRefire(new StubCommand("select.invert", CmdFlags.Model), RecordMode.Record, null));
    assert(xf.commitCalls == 0 && drops == 1 && held is null,
           format("M2 funnel: a script command other than the 6250 one closed an `allDoors` tool: "
                  ~ "commits %s, drops %s", xf.commitCalls, drops));
    held = xf;
    drops = 0;
    assert(ex.applyOrRefire(new StubCommand("mesh.subpatch_toggle", CmdFlags.Model), RecordMode.Record, null));
    assert(xf.commitCalls == 1 && drops == 0 && held is xf,
           "M2 funnel: the 6250 command no longer closes an `allDoors` tool on the script door");

    // The 6250 command reached RE-ENTRANTLY (inside another command's apply)
    // neither closes nor drops: the re-entry suppresses the close branch, and
    // the command is not in the drop set.
    log = null;
    drops = 0;
    auto re = new CountingTool(CommandClose.none, true, &log);
    held = re;
    auto host = new StubCommand("mesh.hide", CmdFlags.UiState, () {
        return ex.applyOrRefire(new StubCommand("mesh.subpatch_toggle", CmdFlags.Model),
                                RecordMode.Record, null);
    });
    assert(ex.applyOrRefire(host, RecordMode.Record, null));
    assert(held is re && drops == 0 && re.commitCalls == 0,
           format("M2 funnel: a re-entrant 6250 command dropped or closed the tool: drops %s", drops));

    // A nested command inside the outer command's apply: the nested frame
    // must not run the outer close's resume before the outer command records.
    log = null;
    drops = 0;
    auto t2 = new CountingTool(CommandClose.uiDoor, true, &log);
    held = t2;
    auto inner = new StubCommand("mesh.hide", CmdFlags.UiState,
                                 () { log ~= "inner"; return true; });
    auto outer = new StubCommand("select.invert", CmdFlags.Model, () {
        assert(ex.applyOrRefireFromUi(inner, RecordMode.Record, null));
        log ~= "outer";
        return true;
    });
    assert(ex.applyOrRefireFromUi(outer, RecordMode.Record, null));
    assert(log == ["commit", "inner", "outer", "resume"],
           format("M2 funnel: a nested command moved the resume: %s", log));
    assert(t2.resumeCalls == 1, "M2 funnel: the resume did not run exactly once");

    // A command that drops the tool while it applies: the resume is not
    // delivered — neither to the gone tool nor to the next one.
    log = null;
    auto t3 = new CountingTool(CommandClose.uiDoor, true, &log);
    held = t3;
    auto dropper = new StubCommand("layer.delete", CmdFlags.Model, () {
        ex.applyOrRefire(new StubCommand("mesh.subdivide", CmdFlags.Model),
                         RecordMode.Record, null);   // nested pre-apply drop
        return true;
    });
    assert(ex.applyOrRefireFromUi(dropper, RecordMode.Record, null));
    assert(held is null && t3.resumeCalls == 0,
           format("M2 funnel: a dropped tool was resumed: %s", log));

    // A tool that does not close on commands (`none`) meeting a UiState UI
    // command: the funnel's old rule — nothing happens to it.
    log = null;
    auto quiet = new CountingTool(CommandClose.none, true, &log);
    held = quiet;
    drops = 0;
    assert(ex.applyOrRefireFromUi(new StubCommand("mesh.hide", CmdFlags.UiState), RecordMode.Record, null));
    assert(held is quiet && drops == 0 && quiet.commitCalls == 0,
           format("M2 funnel: a UiState UI command changed a `none` tool's path: drops %s", drops));

    // A command that REPLACES the tool while it applies (no drop door ran):
    // the closed tool's resume must not reach its successor.
    auto t4 = new CountingTool(CommandClose.uiDoor, true, &log);
    auto next = new CountingTool(CommandClose.uiDoor, false, &log);
    held = t4;
    auto swapper = new StubCommand("select.invert", CmdFlags.Model,
                                   () { held = next; return true; });
    assert(ex.applyOrRefireFromUi(swapper, RecordMode.Record, null));
    assert(t4.commitCalls == 1 && held is next, "M2 funnel: the swap rig did not run");
    assert(next.resumeCalls == 0 && t4.resumeCalls == 0,
           "M2 funnel: the closed tool's resume reached the tool that replaced it");
}
