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
    import commands.tool.lifecycle : ToolActivationCommand;

    Mesh m = makeCube();
    View v = new View(0, 0, 800, 600);
    auto hist = new CommandHistory();

    string[] lines;
    hist.onRecord = (string line, uint flags) { lines ~= line; };
    hist.recordToolLifecycle(new ToolActivationCommand(
        &m, v, EditMode.Vertices, "move", ""));

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

version (unittest) {
    // A row of a tool session (`token`) whose revert succeeds; `applied`
    // false and nothing recorded makes its revert answer false instead.
    private final class _SessionRowCmd : Command {
        import mesh     : Mesh;
        import view     : View;
        import editmode : EditMode;
        private Mesh _mesh;
        private View _view = new View(0, 0, 1, 1);
        this(ulong token, bool revertible = true, bool mergeable = false) {
            super(&_mesh, _view, EditMode.Vertices);
            mergeable_ = mergeable;
            markSession(token);
            if (revertible) noteUndoRecorded();
        }
        private bool mergeable_;
        override CompareResult compareOp(const Command prev) const {
            return mergeable_ && cast(const _SessionRowCmd) prev !is null
                ? CompareResult.Compatible : CompareResult.Different;
        }
        override bool mergeFrom(Command newer) { return mergeable_; }
        override string name() const { return "test.sessionrow"; }
        override string label() const { return "SessionRow"; }
        protected override bool applyImpl() { return true; }
        protected override void revertImpl() {}
    }
}

unittest { // task 9508 (findings_K-RD rule 2): one undo of a session-reverting drop row
    import mesh : Mesh, makeCube;
    import view : View;
    import editmode : EditMode;
    import commands.tool.lifecycle : ToolActivationCommand;
    Mesh m = makeCube();
    View v = new View(0, 0, 800, 600);
    ToolActivationCommand drop(ulong token) {
        auto d = new ToolActivationCommand(&m, v, EditMode.Vertices, "", "move", false, false,
            false, 0, token, true, false, false, true);
        import tool : DropUndoPolicy, DropUndoExtent, DropRedoPopulation;
        d.setDropUndoPolicy(DropUndoPolicy(DropUndoExtent.wholeSession, DropRedoPopulation.editRows));
        return d;
    }
    // The drop row takes the session's two rows (to redo, oldest first) and
    // stops at the activation row, which carries the same token.
    auto h = new CommandHistory();
    auto act = new ToolActivationCommand(&m, v, EditMode.Vertices, "move", "", false, false,
        false, 7);
    auto r1 = new _SessionRowCmd(7), r2 = new _SessionRowCmd(7);
    foreach (Command c; [cast(Command) act, r1, r2, drop(7)]) h.pushEntryForTest(c);
    assert(h.undo() && h.undoEntries().length == 1 && h.undoEntries()[0].cmd is act,
        "the drop row pops with its session's rows, down to the activation row");
    assert(h.redoEntries().length == 2 && h.redoEntries()[0].cmd is r1 && h.redoEntries()[1].cmd is r2,
        "the session's rows go to the redo, oldest first; the drop row does not");
    // A foreign row (no session) between ends the run: only the drop row pops.
    h = new CommandHistory();
    auto foreign = new _SessionRowCmd(0);
    foreach (Command c; [cast(Command) act, r1, foreign, drop(7)]) h.pushEntryForTest(c);
    assert(h.undo() && h.undoEntries().length == 3 && h.undoEntries()[$ - 1].cmd is foreign,
        "a foreign row stops the drop's undo");
    // A plain row pops alone, even over rows of a session.
    h = new CommandHistory();
    foreach (Command c; [cast(Command) r1, r2, new _SessionRowCmd(0)]) h.pushEntryForTest(c);
    assert(h.undo() && h.undoEntries().length == 2 && h.redoEntries().length == 1,
        "a row that is no drop row pops alone");
    // A row whose revert fails: undo answers false, the row is gone, no redo.
    h = new CommandHistory();
    foreach (Command c; [cast(Command) r1, new _SessionRowCmd(0, false)]) h.pushEntryForTest(c);
    assert(!h.undo() && h.undoEntries().length == 1 && h.redoEntries().length == 0,
        "a refused revert answers false and leaves no redo");
}


unittest { // task 9508: an in-place coalesce moves history without replacing its row
    auto h = new CommandHistory();
    auto row = new _SessionRowCmd(0, true, true);
    h.record(row);
    const before = h.generation();
    h.recordCoalescing(new _SessionRowCmd(0, true, true));
    assert(h.undoEntries().length == 1 && h.undoEntries()[0].cmd is row,
        "generation coalesce floor: same row retained");
    assert(h.generation() > before, "an in-place coalesce advances history generation");
}

unittest { // task 9508: replacing a re-grade tail is a record too
    auto h = new CommandHistory();
    const run = h.currentRunId();
    h.replaceInSessionTail(new _SessionRowCmd(7), run);
    const before = h.generation();
    auto row = new _SessionRowCmd(7);
    h.replaceInSessionTail(row, run);
    assert(h.undoEntries().length == 1 && h.undoEntries()[0].cmd is row,
        "generation re-grade floor: one replacement row");
    assert(h.generation() > before, "a re-grade replacement advances history generation");
}

unittest { // task 9508: committing a run by splice bypasses the append recorder
    auto h = new CommandHistory();
    const run = h.currentRunId();
    h.recordInSession(new _SessionRowCmd(7), run);
    const before = h.generation();
    auto row = new _SessionRowCmd(7);
    h.replaceInSessionTailWith(run, row);
    assert(h.undoEntries().length == 1 && h.undoEntries()[0].cmd is row,
        "generation splice floor: one committed row");
    assert(h.generation() > before, "a run splice advances history generation");
}

unittest { // task 9508: even a refused revert removes its row
    auto h = new CommandHistory();
    h.record(new _SessionRowCmd(0, false));
    const before = h.generation();
    assert(!h.undo() && h.undoEntries().length == 0, "generation refused-undo floor: row removed");
    assert(h.generation() > before, "a refused revert that removes a row advances history generation");
}

unittest { // task 9508: a suspended re-grade can remove the matching tail without appending
    auto h = new CommandHistory();
    const run = h.currentRunId();
    h.replaceInSessionTail(new _SessionRowCmd(7), run);
    const before = h.generation();
    {
        auto guard = h.suspended();
        h.replaceInSessionTail(new _SessionRowCmd(7), run);
    }
    assert(h.undoEntries().length == 0, "generation suspended-tail floor: tail removed");
    assert(h.generation() > before, "a removed re-grade tail advances history generation");
}

unittest {
    import tool : DropUndoPolicy, DropUndoExtent, DropRedoPopulation, AttrImage, StepOrigin;
    import commands.tool.lifecycle : ToolActivationCommand;
    import commands.mesh.session_edit : MeshSessionEdit;
    import mesh : Mesh, makeCube;
    import view : View;
    import editmode : EditMode;
    import snapshot : MeshSnapshot;
    Mesh m = makeCube();
    View v = new View(0, 0, 800, 600);
    MeshSessionEdit press(ulong token) {
        auto p = new MeshSessionEdit(&m, v, EditMode.Vertices, "test.press", "Press");
        const image = MeshSnapshot.capture(m);
        p.setSnapshots(image, image);
        p.markSession(token);
        p.setTopologyStep(AttrImage.init, AttrImage.init, image, image, true, 1, StepOrigin.opens, 1);
        return p;
    }
    foreach (population; [DropRedoPopulation.discard, DropRedoPopulation.editRows, DropRedoPopulation.selectedSuffix]) {
        auto h = new CommandHistory();
        auto activation = new ToolActivationCommand(&m, v, EditMode.Vertices, "pen", "", false, false, false, 7);
        auto first = press(7), last = press(7);
        auto field = new _SessionRowCmd(7);
        auto drop = new ToolActivationCommand(&m, v, EditMode.Vertices, "", "pen", false, false, false, 0, 7, true, false, false, true);
        drop.setDropUndoPolicy(DropUndoPolicy(DropUndoExtent.newestPressBlock, population));
        assert(drop.carriesRedoAfterUndo() == (population == DropRedoPopulation.selectedSuffix),
            "drop lifecycle redo admission follows the retained population");
        size_t completions;
        bool armed;
        const before = h.generation();
        drop.onActivate = (string id) { armed = id == "pen"; };
        drop.onDeactivate = () { armed = false; };
        drop.onCompleteDropUndo = (string id, ulong token) {
            ++completions;
            assert(armed && id == "pen" && token == 7, "drop completion restored identity and token");
            assert(h.state() != UndoState.Suspend, "drop completion must run outside Suspend");
            assert(h.undoEntries().length == 2 && h.undoEntries()[$ - 1].cmd is first,
                "completion must see the final selected suffix");
        };
        foreach (Command c; [cast(Command) activation, first, last, field, drop]) h.pushEntryForTest(c);
        h.markEntryFold(field, HistoryFlags.JoinsBelow);
        const generation = h.generation();
        assert(h.undo() && completions == 1 && h.generation() == generation + 1,
            "one completion and one generation update per drop undo");
        assert(h.undoEntries().length == 2 && h.undoEntries()[0].cmd is activation && h.undoEntries()[1].cmd is first,
            "newest press selection retains the older press and original activation");
        const expected = population == DropRedoPopulation.discard ? 0 : population == DropRedoPopulation.editRows ? 2 : 3;
        assert(h.redoEntries().length == expected, "drop redo population");
        if (expected) {
            assert(h.redoEntries()[0].cmd is last && h.redoEntries()[1].cmd is field,
                "press and folded fields retain chronological redo identity");
            assert(h.redo() && armed, "redo first restores the press while armed");
            assert(h.redo() && armed, "redo second restores its folded field while armed");
            if (population == DropRedoPopulation.selectedSuffix) {
                assert(h.redoEntries()[0].cmd is drop, "lifecycle drop is last in retained suffix");
                assert(h.redo() && !armed, "retained lifecycle drop must replay deactivation");
            }
        }
    }
    // An immediate foreign row, a non-press base and an empty session cannot
    // make the bounded selection search reach an older eligible press.
    foreach (barrier; [cast(Command)new _SessionRowCmd(9), new _SessionRowCmd(7),
            new ToolActivationCommand(&m, v, EditMode.Vertices, "other", "pen", false, false, false, 7)]) {
        auto h = new CommandHistory();
        auto older = press(7);
        auto drop = new ToolActivationCommand(&m, v, EditMode.Vertices, "", "pen", false, false, false, 0, 7, true, false, false, true);
        drop.setDropUndoPolicy(DropUndoPolicy(DropUndoExtent.newestPressBlock, DropRedoPopulation.discard));
        foreach (Command c; [cast(Command)older, barrier, drop]) h.pushEntryForTest(c);
        assert(h.undo() && h.undoEntries().length == 2 && h.undoEntries()[$ - 1].cmd is barrier,
            "newest press cannot cross a foreign, lifecycle or non-press base");
    }
    auto empty = new CommandHistory();
    auto d = new ToolActivationCommand(&m, v, EditMode.Vertices, "", "pen", false, false, false, 0, 7, true, false, false, true);
    d.setDropUndoPolicy(DropUndoPolicy(DropUndoExtent.newestPressBlock, DropRedoPopulation.discard));
    size_t called;
    d.onCompleteDropUndo = (string id, ulong token) { ++called; assert(empty.state() != UndoState.Suspend); };
    empty.pushEntryForTest(d);
    assert(empty.undo() && called == 1 && empty.undoEntries().length == 0 && empty.redoEntries().length == 0,
        "zero-block drop still completes once and discards redo");
}
