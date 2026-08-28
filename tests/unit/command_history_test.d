// Module unittests for `command_history`, moved verbatim out of source/command_history.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.command_history_test;

import command;
import command : CmdFlags;
import argstring : serializeParams, serializeCommandLine;
import perf_probe : g_perf, Cat;
import mesh    : Mesh;
import view    : View;
import editmode : EditMode;
import mesh     : Mesh;
import view     : View;
import std.stdio : writeln;
import command_history;

// task 0678 D9-a (REVERTED) — recordToolLifecycle deliberately does NOT feed
// the macro recorder; see the comment at its emit point for the measurements
// that overturned the original finding. Pin the silence so a future "fix" has
// to re-read that reasoning instead of re-deriving the same broken line.
unittest {
    import mesh : Mesh, makeCube;
    import view : View;
    import editmode : EditMode;
    import commands.tool.lifecycle : ToolDeactivationCommand;

    Mesh m = makeCube();
    View v = new View(0, 0, 800, 600);
    auto hist = new CommandHistory();

    string[] lines;
    hist.onRecord = (string line, uint flags) { lines ~= line; };
    hist.recordToolLifecycle(new ToolDeactivationCommand(&m, v, EditMode.Vertices, "move"));

    assert(lines.length == 0,
           "a tool drop must not reach the macro recorder on its own: the "
           ~ "matching arm step never does either, and `tool.set <id> off` "
           ~ "ignores the id and would drop whatever tool the replay finds armed");
    assert(hist.canUndo(), "the lifecycle entry itself must still be recorded");
}

// ---------------------------------------------------------------------------
// Task 0708 — the dangling-refire commit is the SAME commit as refireEnd's.
//
// `refireBegin`/`fire`/`refireEnd` model one interactive edit cycle, and the
// live command has TWO ways out of it:
//
//   normal  — `refireEnd()` calls `record()`, and says so in its own comment:
//             "record()'s flag-and-state checks (isUndoable, _state) apply".
//   dangling — a second `refireBegin()` while a block is still open (the tool
//             was dropped or crashed mid-drag without an end) commits the live
//             command so the entry is not lost.
//
// The two used to disagree. The dangling arm appended straight to the stack
// and applied NEITHER `!cmd.isUndoable` NOR `_state != Active` — the two gates
// every other recorder in this class applies, and the two `refireEnd`'s
// comment claims apply to this object. One command, one block, two exits, two
// answers, and nothing anywhere saying the difference was meant.
//
// It is not a policy that the defensive path saves entries at all costs: the
// only entries the gates drop are ones no recorder in this class would have
// kept — a command that declares itself non-undoable, and a commit issued from
// a SUSPENDED context, which is exactly the context whose whole purpose is
// that mutations inside it do not reach the user's stack. Every entry that IS
// the user's work still lands, because for an undoable command in the Active
// state `record()` and the old append build a byte-identical entry.
//
// Each unittest below pairs the dangling exit with the normal exit on the SAME
// command, so it fails if the two ever answer differently again, in either
// direction — not merely if the dangling arm regresses.
// ---------------------------------------------------------------------------

version (unittest) {
    // Minimal live command for the refire cycle: apply/revert always succeed
    // and touch nothing, so the only thing under test is which entries the
    // history keeps. `_flags` is a constructor argument so one class covers
    // both an undoable and a non-undoable subject.
    private final class _RefireGateCmd : Command {
        import mesh     : Mesh;
        import view     : View;
        import editmode : EditMode;
        private Mesh  _mesh;
        private View  _view = new View(0, 0, 1, 1);
        private CmdFlags _flags;
        this(CmdFlags f) {
            super(&_mesh, _view, EditMode.Vertices);
            _flags = f;
        }
        override string   name()     const { return "test.refiregate"; }
        override string   label()    const { return "RefireGate"; }
        override CmdFlags cmdFlags() const { return _flags; }
        protected override bool applyImpl()  { return true; }
        // No `revert` override since task 2500 — the base answers `true` for a
        // forward that succeeded and recorded nothing.
    }

    // Open a refire block, fire one command into it, and walk away — the
    // "tool dropped mid-drag" shape. Leaves `liveCmd` set and the block open.
    private void leaveRefireDangling(CommandHistory h, Command cmd) {
        h.refireBegin();
        assert(h.fire(cmd), "precondition: fire() must accept the command");
        assert(h.refireActive(), "precondition: the refire block must be open");
    }
}

unittest { // 0708 — a NON-UNDOABLE live command is dropped by BOTH exits.
    import std.conv : to;
    // UndoSuppress is the documented opt-out: `Command.isUndoable` returns
    // false for it whatever else the flags say, and every recorder in
    // CommandHistory refuses it.
    enum CmdFlags kSuppressed = CmdFlags.Model | CmdFlags.UndoSuppress;
    assert(!(new _RefireGateCmd(kSuppressed)).isUndoable,
        "precondition: UndoSuppress must make the command non-undoable, or "
        ~ "this test is asserting nothing about the isUndoable gate");

    // (a) the NORMAL exit — the reference answer.
    auto viaEnd = new CommandHistory();
    leaveRefireDangling(viaEnd, new _RefireGateCmd(kSuppressed));
    viaEnd.refireEnd();
    assert(viaEnd.undoEntries().length == 0,
        "reference: refireEnd() routes through record(), which refuses a "
        ~ "non-undoable command — got "
        ~ viaEnd.undoEntries().length.to!string ~ " entries");

    // (b) the DANGLING exit — must agree.
    auto viaDangle = new CommandHistory();
    leaveRefireDangling(viaDangle, new _RefireGateCmd(kSuppressed));
    viaDangle.refireBegin();   // re-entry commits the dangling block
    assert(viaDangle.undoEntries().length == 0,
        "refireBegin()'s dangling-commit arm must apply the same isUndoable "
        ~ "gate refireEnd() applies to the same object. It pushed "
        ~ viaDangle.undoEntries().length.to!string ~ " entry/entries for a "
        ~ "command that declares itself non-undoable — so which exit the "
        ~ "refire block took decides whether a non-undoable command reaches "
        ~ "the user's undo stack. That is task 0708.");
}

unittest { // 0708 — a commit issued from a SUSPENDED context is dropped by BOTH.
    import std.conv : to;
    enum CmdFlags kModel = CmdFlags.Model;
    assert((new _RefireGateCmd(kModel)).isUndoable,
        "precondition: the Model command must be undoable, so the ONLY thing "
        ~ "keeping it off the stack below is the state gate");

    // Control: with the history Active, the dangling exit DOES keep it. This
    // is what stops the fix from being "gate everything away".
    auto active = new CommandHistory();
    leaveRefireDangling(active, new _RefireGateCmd(kModel));
    active.refireBegin();
    assert(active.undoEntries().length == 1,
        "an undoable command committed from the Active state must still land "
        ~ "— the dangling arm exists to not lose it. Got "
        ~ active.undoEntries().length.to!string ~ " entries");

    // (a) the NORMAL exit under Suspend — the reference answer.
    auto viaEnd = new CommandHistory();
    leaveRefireDangling(viaEnd, new _RefireGateCmd(kModel));
    {
        auto g = viaEnd.suspended();
        viaEnd.refireEnd();
    }
    assert(viaEnd.undoEntries().length == 0,
        "reference: refireEnd() under Suspend routes through record(), which "
        ~ "refuses while not Active — got "
        ~ viaEnd.undoEntries().length.to!string ~ " entries");

    // (b) the DANGLING exit under Suspend — must agree.
    auto viaDangle = new CommandHistory();
    leaveRefireDangling(viaDangle, new _RefireGateCmd(kModel));
    {
        auto g = viaDangle.suspended();
        viaDangle.refireBegin();
    }
    assert(viaDangle.undoEntries().length == 0,
        "refireBegin()'s dangling-commit arm must apply the same _state gate "
        ~ "refireEnd() applies. It pushed "
        ~ viaDangle.undoEntries().length.to!string ~ " entry/entries from a "
        ~ "SUSPENDED context — the one context whose entire purpose is that "
        ~ "mutations inside it never reach the user's stack. That is task "
        ~ "0708.");
}
