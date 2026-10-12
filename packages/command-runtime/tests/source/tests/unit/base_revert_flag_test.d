// Module unittests for the BASE `Command.revert()` and the one flag it reads
// (task 2500).
//
// WHAT THIS FILE IS FOR, AND WHAT IT DELIBERATELY DOES NOT TRY TO BE.
//
// The defect this task closed — `revert()` answering `false` because the
// forward recorded NOTHING, which makes `CommandHistory.undo` discard the
// entry AND the whole trailing suffix above it (regression 0099, task 2110) —
// is NOT tested here, because it is no longer expressible. `Command.revert` is
// `final` and `revertImpl()` returns `void`: a command body has no `bool` to
// return, and it is not entered at all unless an undo image exists. The
// compiler is that gate, and `dub build` is its run: not one
// `override bool revert()` survives anywhere under `source/`.
//
// What IS testable, and what these blocks pin, is the THREE-STATE answer the
// base gives — including the two states that must stay DIFFERENT from each
// other, and the one channel that must stay reachable:
//
//   (1) no image, no forward          → false   (the mis-ordered-caller belt)
//   (2) forward succeeded, no image   → TRUE    (2110's fix, made structural)
//   (3) an image                      → revertImpl(), which fails only by
//                                       NAMING a failure
//
// (1) and (2) are the pair three shipped suite cells depend on
// (`test_uv_transform.d`'s "revert without apply must return false",
// `test_uv_pack.d`, `test_uv_project.d`): "the forward refused / never ran"
// and "the forward succeeded and moved nothing" are BOTH "no image", and the
// old code told them apart with a hand-maintained `applied_` bit in twenty
// files. They are told apart HERE now, once, by a bit `Command.apply()` writes
// itself.
module tests.unit.base_revert_flag_test;

import std.format : format;

import command;
import command_history;
import editmode : EditMode;
import mesh     : Mesh;
import view     : View;

// ---------------------------------------------------------------------------
// Probes. Each is the smallest command that can occupy one of the three
// states; `entered` counts `revertImpl` entries so a block can tell "answered
// true" from "answered true AFTER running the body".
// ---------------------------------------------------------------------------

/// Records nothing, ever. `applyImpl` succeeds — the no-op-edit shape
/// (`mesh.smooth {iter:0}`, `uv.rotate` by zero degrees, an empty operand).
private final class NeverRecords : Command {
    int entered = 0;
    private Mesh _mesh;
    private View _view;
    this() { _view = new View(0, 0, 1, 1); super(&_mesh, _view, EditMode.Vertices); }
    override string   name()     const { return "test.neverRecords"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    protected override bool applyImpl() { return true; }
    protected override void revertImpl() { ++entered; }
}

/// Records on a successful forward, and can be asked to refuse instead.
private final class Records : Command {
    int  entered = 0;
    bool refuse  = false;
    private Mesh _mesh;
    private View _view;
    this() { _view = new View(0, 0, 1, 1); super(&_mesh, _view, EditMode.Vertices); }
    override string   name()     const { return "test.records"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    protected override bool applyImpl() {
        if (refuse) return false;
        noteUndoRecorded();
        return true;
    }
    protected override void revertImpl() { ++entered; }
}

/// Records, and then cannot put its image back — the GENUINE failure, the one
/// thing `false` is still reserved for.
private final class FailsToRestore : Command {
    private Mesh _mesh;
    private View _view;
    this() { _view = new View(0, 0, 1, 1); super(&_mesh, _view, EditMode.Vertices); }
    override string   name()     const { return "test.failsToRestore"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    protected override bool applyImpl() { noteUndoRecorded(); return true; }
    protected override void revertImpl() {
        failRevert("the thing this command recorded is no longer there");
    }
}

// ---------------------------------------------------------------------------
// STATE 1 — nobody applied it, nobody handed it an image.
// ---------------------------------------------------------------------------
unittest {
    auto c = new Records();
    assert(!c.undoRecorded(),  "a fresh command holds no undo image");
    assert(!c.forwardApplied(), "a fresh command has not been applied");
    assert(!c.revert(),
        "revert() WITHOUT a forward must answer false — this is the "
      ~ "mis-ordered-caller belt `RecordedUndo.revert` exists to make loud, "
      ~ "and three suite cells assert it (test_uv_transform / uv_pack / "
      ~ "uv_project)");
    assert(c.entered == 0, "revertImpl must not be entered with no image");
}

// A forward that REFUSED is the same state, and that is the half a
// forward-only flag would get wrong in the other direction.
unittest {
    auto c = new Records();
    c.refuse = true;
    assert(!c.apply(), "the probe was asked to refuse");
    assert(!c.forwardApplied(), "a refused forward must not raise the forward bit");
    assert(!c.revert(), "revert() after a REFUSED forward must answer false");
    assert(c.entered == 0, "revertImpl must not be entered after a refusal");
}

// ---------------------------------------------------------------------------
// STATE 2 — the forward succeeded and recorded nothing. THE 2110 FIX, and the
// one state that has to be told apart from state 1.
// ---------------------------------------------------------------------------
unittest {
    auto c = new NeverRecords();
    assert(c.apply(), "the no-op probe's forward succeeds");
    assert(c.forwardApplied(), "apply() writes the forward bit itself");
    assert(!c.undoRecorded(), "the no-op probe records nothing");
    assert(c.revert(),
        "a forward that SUCCEEDED and recorded nothing must answer TRUE — a "
      ~ "false here is regression 0099: CommandHistory.undo discards the "
      ~ "entry and every entry below it");
    assert(c.entered == 0,
        "and it must answer without entering revertImpl at all — the empty "
      ~ "case is decided by the base, which is what makes the old per-command "
      ~ "emptiness guard unnecessary AND unreachable");
    assert(c.revertFailureReason().length == 0,
        "answering true leaves no failure reason behind");
}

// ---------------------------------------------------------------------------
// STATE 3 — an image exists, so the body runs.
// ---------------------------------------------------------------------------
unittest {
    auto c = new Records();
    assert(c.apply());
    assert(c.undoRecorded(), "the forward raised the flag");
    assert(c.revert(), "a recorded command reverts");
    assert(c.entered == 1, "revertImpl ran exactly once");
    assert(c.revert() && c.entered == 2,
        "revert() is repeatable — undo/redo/undo drives it more than once");
}

// ---------------------------------------------------------------------------
// `false` IS STILL REACHABLE, and only by NAMING the failure. Without this the
// task would have replaced one inexpressible case with another:
// `CompositeCommand.revert` stops its child chain on a false and
// `CommandHistory.undo` treats it as unrecoverable, so the channel has to
// stay open for a real one.
// ---------------------------------------------------------------------------
unittest {
    auto c = new FailsToRestore();
    assert(c.apply());
    assert(!c.revert(),
        "a command that reports a GENUINE restore failure must still answer "
      ~ "false — `false` is reserved for that, and reserved from emptiness");
    assert(c.revertFailureReason() ==
           "the thing this command recorded is no longer there",
        format("the reason must survive to the caller, got '%s'",
               c.revertFailureReason()));
}

// The same, through the production type that DEPENDS on the channel: a child
// that genuinely fails stops the block and the block reports it.
unittest {
    auto ok1  = new Records();
    auto bad  = new FailsToRestore();
    auto ok2  = new Records();
    foreach (c; [cast(Command) ok1, cast(Command) bad, cast(Command) ok2])
        assert(c.apply());

    auto block = new CompositeCommand([cast(Command) ok1, cast(Command) bad,
                                       cast(Command) ok2], "block");
    assert(!block.revert(),
        "a block whose child fails to restore must answer false — this is "
      ~ "the caveat task 2500 had to preserve while removing the emptiness "
      ~ "false");
    assert(block.revertFailureReason().length > 0,
        "and it must say which child, not merely decline");
    // Reverse order: ok2 first, then `bad` stops the chain before ok1.
    assert(ok2.entered == 1, "the child ABOVE the failure was reverted");
    assert(ok1.entered == 0, "the child BELOW it was not — the chain stopped");
}

// A block of children that all recorded nothing is state 2 all the way down,
// and must answer TRUE rather than stopping on the first one.
unittest {
    auto a = new NeverRecords();
    auto b = new NeverRecords();
    assert(a.apply() && b.apply());
    auto block = new CompositeCommand([cast(Command) a, cast(Command) b], "noop block");
    assert(block.revert(),
        "a block of no-op children must revert cleanly — before task 2500 "
      ~ "each child answered its own emptiness question and five of the nine "
      ~ "position commands answered it `false`");
}

// ---------------------------------------------------------------------------
// THE 0099 SHAPE AT THE HISTORY LEVEL — the failure is a LOST ENTRY, not a
// wrong position, so the assertion is on the STACK DEPTH. This is the same
// sequence the three suite regressions drive over HTTP
// (`tests/test_mesh_{jitter,quantize,smooth}.d`, task 2110), reduced to the
// two commands and one history it actually needs.
// ---------------------------------------------------------------------------
unittest {
    auto h = new CommandHistory();

    auto real_ = new Records();      // a real edit — records an image
    auto noop  = new NeverRecords(); // an edit that succeeds and records nothing
    assert(real_.apply());
    assert(noop.apply());
    h.record(real_);
    h.record(noop);

    immutable size_t depth0 = h.undoEntries().length;
    assert(depth0 == 2, format("expected two entries, got %d", depth0));

    assert(h.undo(), "undo of the NO-OP entry must report ok");
    immutable size_t depth1 = h.undoEntries().length;
    assert(depth1 == depth0 - 1, format(
        "undoing the no-op entry must remove EXACTLY one entry (%d -> %d). "
      ~ "The 0099 failure is a truncation: `undo()` pops the entry before "
      ~ "calling revert() and, on a false, does `undoStack.length = mi` — so "
      ~ "the real edit below would go with it and neither undo nor redo could "
      ~ "reach it again.", depth0, depth1));

    assert(h.undo(), "undo of the REAL entry must report ok afterwards");
    assert(h.undoEntries().length == depth1 - 1, "and remove exactly one more");
    assert(real_.entered == 1, "the real edit's revertImpl ran");
    assert(noop.entered  == 0, "the no-op's did not — there was nothing to run");
}
