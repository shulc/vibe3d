module commands.test_undo_flags;

import command;
import mesh;
import view;
import editmode;

// ---------------------------------------------------------------------------
// Test-automation-only commands exercising the explicit undoability override
// flags (CmdFlags.UndoForce / CmdFlags.UndoSuppress). They let a headless test
// drive both override paths through the normal /api/command dispatch +
// recordCoalescing() chokepoint, asserting on the resulting undo-stack length:
//
//   * UndoSuppressNoop — carries CmdFlags.Model (would normally be undoable)
//     PLUS UndoSuppress, so isUndoable() returns false and NO entry lands.
//
//   * UndoForceNoop — carries CmdFlags.SideEffect (would normally be skipped)
//     PLUS UndoForce, so isUndoable() returns true and an entry DOES land.
//
// Both apply() are intentional no-ops: the flag layering, not any mesh effect,
// is what the test observes. Not in any menu / UI; registered like the other
// test-only command factories.
// ---------------------------------------------------------------------------

/// Model-flavored command that opts OUT of undo via UndoSuppress → no entry.
class UndoSuppressNoop : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }
    override string name()  const { return "undo.test.suppress"; }
    override string label() const { return "Undo Suppress Test"; }
    override CmdFlags cmdFlags() const {
        return CmdFlags.Model | CmdFlags.UndoSuppress;
    }
    override bool apply() { return true; }
}

/// SideEffect-flavored command that opts IN to undo via UndoForce → entry lands.
class UndoForceNoop : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }
    override string name()  const { return "undo.test.force"; }
    override string label() const { return "Undo Force Test"; }
    override CmdFlags cmdFlags() const {
        return CmdFlags.SideEffect | CmdFlags.UndoForce;
    }
    override bool apply() { return true; }
    // Undoable, so revert() must succeed to keep undo()/redo() well-behaved;
    // the no-op apply means there is nothing to restore.
    override bool revert() { return true; }
}

unittest {
    import view : View;
    Mesh m;
    View v;
    auto sup = new UndoSuppressNoop(&m, v, EditMode.Vertices);
    // Model bit present, but UndoSuppress wins → not undoable.
    assert(!sup.isUndoable());

    auto frc = new UndoForceNoop(&m, v, EditMode.Vertices);
    // No Model/UiState bit, but UndoForce opts in → undoable.
    assert(frc.isUndoable());
}
