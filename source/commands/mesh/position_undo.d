// position_undo — the undo holder the nine plain POSITION commands share
// (task 1903 §L0-d).
//
// Nine commands used to carry three fields and one loop each: a `uint[]` of
// touched indices, a `Vec3[]` of their pre-op values, and a `revert()` that
// wrote the second back over the first. That loop is a hand-rolled sparse
// revert of exactly the shape `MeshOpEntry.Kind.SetPos` already describes, so
// the migration replaces nine copies of it with one recorded delta and one
// `MeshEditDelta.revert` — the fast path `finalize` carved out at L0-P1
// (`mesh_edit_delta.d`), for which these nine are the FIRST production
// callers.
//
// WHAT THIS TYPE IS NOT. It is not a base class and not a mixin: the nine
// commands differ in their kernels and their guards, and this type holds the
// state and inverts the delta rather than trying to be their shape.
//
// TASK 2500 SETTLED THE ONE THING THIS COMMENT USED TO ARGUE THE OTHER WAY,
// and the argument is kept here rather than deleted, because it was a
// reasonable reading and it was wrong in an instructive way.
//
// It said the nine ALSO differ in what their `revert()` must answer on an
// EMPTY edit — four (`smooth`, `jitter`, `quantize`, `edge_slide`) answering
// TRUE because a `false` makes `CommandHistory.undo` discard the entry AND
// the whole trailing suffix (regression 0099, `tests/test_edge_slide.d:296`),
// the other five answering FALSE with that arm unreachable because their
// FORWARD already refused on the same predicate — and that folding the
// difference into one `revert()` would "decide nine questions with one
// answer".
//
// It is ONE question. The five whose arm is unreachable were not answering a
// different question; they were answering a question they could not be asked,
// and three of the four that COULD be asked had answered it wrongly for a
// year (task 2110). What made the difference look real was that the answer
// was derived twice — once by the forward's guard, once by the `revert()`
// body — in nine files that could not see each other. It is derived ONCE now,
// in `Command.revert`, from `arm` below: an empty delta leaves the holder
// disarmed AND the flag down, and the base answers `true` without entering
// any command body. The per-command arm is gone with the predicate that
// reached it.
module commands.mesh.position_undo;

import command         : Command;
import mesh            : Mesh;
import mesh_edit_delta : MeshEditDelta;

/// The `delta_` / `armed_` pair plus its inverse.
///
/// NAMED `RecordedUndo`, NOT `PositionUndo`, SINCE TASK 2230 — and the alias
/// below is why the eleven L0-d call sites did not move. Nothing in this type
/// is about positions: it holds a `MeshEditDelta` and a bit saying whether one
/// was installed, and Stage L1-a's five migrated map commands
/// (`commands/mesh/morph.d`) need exactly that with a `Kind.MapValueDelta`
/// log inside. Copying thirty lines under a second name so that the word
/// "position" could stay in it would have been two implementations of one
/// mechanism; renaming the eleven `recordedUndo()` accessors in one commit
/// would have been churn in files three concurrent lanes were building. The
/// alias costs one line and no diff.
///
/// `armed_` is NOT `delta_.isEmpty` spelled twice: `arm` refuses an empty
/// delta, and a command reads `armed()` to decide between the delta revert and
/// its own legacy loop. An empty delta reverting to `false` would look exactly
/// like a failed restoration to the history, which is the 0099 shape.
struct RecordedUndo {
    private MeshEditDelta delta_;
    private bool          armed_;

    /// True once a non-empty delta has been installed. The commands ALSO use
    /// this as the redo discriminator: a second `evaluate` on an armed command
    /// is `CommandHistory.redo` re-running the kernel, and must not record a
    /// second delta over the first.
    bool armed() const { return armed_; }

    /// Read-only diagnostic. `MeshEditDelta.log` is a public field, so the
    /// unit cells read the op-log SHAPE (kinds, entry count) through this
    /// without widening any mutator on the commands.
    ref const(MeshEditDelta) delta() const return { return delta_; }

    /// Install the delta a recording batch's `close()` handed back, and tell
    /// `owner` it now holds an undo image.
    ///
    /// TASK 2500 — `owner` IS THE POINT, and it is why this takes a command at
    /// all. An undo image comes into existence in exactly one statement, and
    /// the flag that says so is raised in that same statement; the twenty-four
    /// call sites cannot each decide it a second time, and cannot forget. An
    /// EMPTY delta leaves the holder disarmed AND the flag down — which is now
    /// what makes a forward that succeeded and moved nothing answer `true`
    /// from `Command.revert`, instead of nine commands each answering it in
    /// their own body (four `true`, five `false`, three of them wrong: task
    /// 2110).
    void arm(Command owner, MeshEditDelta d) {
        delta_ = d;
        armed_ = !d.isEmpty;
        if (armed_) owner.noteUndoRecorded();
    }

    /// Drop the delta. Used on the failure arm, where the forward already
    /// answered false and the entry must not carry a half-edit.
    void disarm(Command owner) {
        delta_ = MeshEditDelta.init;
        armed_ = false;
        owner.forgetUndoRecord();
    }

    /// LIFO inverse replay. `false` when nothing is armed — which
    /// `Command.revert` now makes unreachable for every caller (it answers the
    /// no-image case itself), so this arm survives only to keep a
    /// directly-constructed unit-test holder loud rather than silently
    /// successful.
    bool revert(ref Mesh m) { return armed_ ? delta_.revert(m) : false; }
}

/// The L0-d spelling, kept so that the nine plain position commands and their
/// `version (unittest)` accessors read unchanged. Not deprecated: for a
/// position command it is the more informative of the two names.
alias PositionUndo = RecordedUndo;
