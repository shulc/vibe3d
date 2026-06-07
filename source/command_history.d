module command_history;

import command;
import command : CmdFlags;
import argstring : serializeParams;

// ---------------------------------------------------------------------------
// CommandHistory — linear undo/redo stack of Command instances.
//
// Lifecycle: a Command is created via the registry, its apply() is invoked
// (possibly by the HTTP dispatcher or interactive tool), and on success the
// dispatcher passes the command to record(). The history retains the
// instance for the lifetime of the entry; revert() / re-apply() are called
// directly on it.
//
// State machine:
//   - Active   — record() pushes new entries, redo stack cleared on push.
//   - Suspend  — record() silently drops entries (no stack mutation). Used
//                during file load / internal sub-commands so they don't
//                pollute the undo timeline.
//   - Invalid  — record() refuses; treated as a programming error in
//                debug builds.
//
// Refire blocks (Phase C) — refire-begin/end pattern for interactive drags.
// Inside a refire block, each fire() reverts the previous live command
// before applying the new one.
// refireEnd() commits the latest live command as a single undo entry — the
// net effect of an interactive drag is one stack entry, regardless of how
// many sub-fires happened.
//
// Command blocks (blockBegin/blockEnd) — general N-commands-as-one grouping.
// While a block is open, record() appends each command into the open block's
// child list instead of pushing its own entry. blockEnd() wraps the children
// in a CompositeCommand and records that as ONE undo entry (so undo/redo of
// the block re-applies/reverts every child as a unit). Distinct from refire:
// refire keeps only the LAST live command (interactive drag), whereas a block
// retains and re-runs ALL children in order. Nested blockBegin flattens into
// the outermost block (children accumulate in one flat list); blockEnd matches
// the innermost open block. An empty block (no children recorded) is a no-op.
// ---------------------------------------------------------------------------

enum UndoState { Invalid, Active, Suspend }

/// Per-entry status flags (Phase 7 of the history-panel design doc).
/// Drives the history panel's per-row visual cues: badge column shows
/// ✓ for Succeeded, ✗ for Failed, `·` for Quiet, `⋯` for SideEffect.
/// `Undoable` is implicit for
/// anything that actually landed on the stack but kept as a bit
/// for future filter toggles (e.g. "hide undoable" in Phase 4).
///
/// Set at record() time from the command's CmdFlags: Undoable mirrors
/// CmdFlags.Model, Quiet mirrors CmdFlags.Quiet, SideEffect mirrors
/// CmdFlags.SideEffect; Succeeded is always set here (the dispatcher
/// only records on a successful apply()). Failed is reserved for a
/// future widening that records failed applies too.
enum HistoryFlags : uint {
    None       = 0,
    Succeeded  = 1 << 0,
    Failed     = 1 << 1,
    Quiet      = 1 << 2,
    SideEffect = 1 << 3,
    Undoable   = 1 << 4,
    UiUndo     = 1 << 5, // Entry is UI-undo class (selection / edit-mode
                         // state) rather than Model-undo (geometry). Mirrors
                         // Command.isUiUndo(). Surfaced per-entry so the
                         // history panel + /api/history can distinguish the
                         // two undoable classes.
    UndoForced = 1 << 6, // Entry landed because the command carried
                         // CmdFlags.UndoForce (explicit opt-IN overriding the
                         // derived rule). Provenance only — surfaced for the
                         // panel / api; behaviour is identical to any other
                         // undoable entry once it is on the stack.
    InSession  = 1 << 7, // Entry was recorded mid tool-session as one step of
                         // a RUN — a sequence of in-session gestures that share
                         // a runId and consolidate into ONE surviving entry at
                         // the run boundary / tool drop. Set by
                         // recordInSession(); the matching entry carries the
                         // run's id in HistoryEntry.runId. Surfaced per-entry so
                         // a future command-history panel can group + badge the
                         // per-gesture steps of an open run. Navigation-neutral:
                         // an in-session entry is a normal undoable stack entry
                         // until consolidate() rewrites the run.
}

struct HistoryEntry {
    string  label;          // human-readable
    string  args;           // serialized argstring (user-set params only)
    string  commandName;    // internal id (e.g. "mesh.bevel")
    Command cmd;            // owns the snapshot via instance fields
    long    timestampMs;    // monotonic ms since session start; written
                            //  by record() at push time. Phase 6 of the
                            //  history-panel design doc surfaces this in
                            //  the panel's display options.
    uint    flags;          // bitfield of HistoryFlags; Phase 7.
    ulong   runId;          // Run identity for in-session entries. Meaningful
                            //  only when (flags & HistoryFlags.InSession): all
                            //  gestures of one run share the same id, and
                            //  consolidate(runId) collapses that run's
                            //  contiguous tail into one surviving entry. 0 for
                            //  ordinary (non-in-session) entries.
}

/// Map a command's CmdFlags to the per-entry HistoryFlags recorded on
/// the stack. Succeeded is always set here because record() / refire
/// only fire after a successful apply().
private uint historyFlagsFor(const Command cmd) {
    CmdFlags cf = cmd.cmdFlags();
    uint flags = HistoryFlags.Succeeded;
    // Undoable mirrors "lands on the stack" — true for BOTH undo classes
    // (Model-undo and UI-undo). The UiUndo bit then narrows which class it is.
    if (cmd.isUndoable())          flags |= HistoryFlags.Undoable;
    if (cmd.isUiUndo())            flags |= HistoryFlags.UiUndo;
    if (cf & CmdFlags.Quiet)       flags |= HistoryFlags.Quiet;
    if (cf & CmdFlags.SideEffect)  flags |= HistoryFlags.SideEffect;
    if (cf & CmdFlags.UndoForce)   flags |= HistoryFlags.UndoForced;
    return flags;
}

// ---------------------------------------------------------------------------
// CompositeCommand — a single Command that wraps N child commands recorded
// inside a blockBegin/blockEnd pair. It IS its own undo object (same model as
// a plain Command): the history entry holds the composite, and undo()/redo()
// call revert()/apply() on it without ever peeking at the children.
//
// The children have ALREADY been apply()'d once (record() is called after a
// successful apply), so the composite's first life on the stack needs no
// re-apply. revert() walks children in REVERSE order; a later redo's apply()
// walks them forward again — symmetric with how a sequence of single commands
// would undo/redo if they were separate entries.
//
// cmdFlags(): union of the children's flags. Model (=> undoable) is set if ANY
// child is a model-mutating command, so a block that contains at least one
// real edit lands on the stack. A block of purely non-model commands carries
// no Model bit and record() drops it (consistent with single-command rules).
// ---------------------------------------------------------------------------
final class CompositeCommand : Command {
    private Command[] children_;
    private string    blockLabel_;
    private CmdFlags   unionFlags_;

    this(Command[] children, string blockLabel) {
        // Construct the Command base with the first child's mesh/view/editMode
        // context (the base ctor requires them). The composite never uses these
        // fields directly — it delegates to children — but they must be set so
        // the base is well-formed and any generic Command consumer is safe.
        assert(children.length > 0,
            "CompositeCommand requires at least one child");
        super(children[0].meshPtr, children[0].viewRef, children[0].editModeVal);
        children_   = children;
        blockLabel_ = blockLabel;
        CmdFlags u = CmdFlags.None;
        foreach (c; children_) u |= c.cmdFlags();
        unionFlags_ = u;
    }

    /// Children, in record order. Exposed for inspection/tests.
    const(Command)[] children() const { return children_; }

    override string name() const {
        return blockLabel_.length > 0 ? blockLabel_ : "command.block";
    }
    override string label() const {
        return blockLabel_.length > 0 ? blockLabel_ : "Command block";
    }

    // Re-apply children forward. Used by redo(). Stops and reports failure on
    // the first child that fails to apply (partial state — same best-effort
    // contract as the single-command redo path).
    override bool apply() {
        foreach (c; children_) {
            if (!c.apply()) return false;
        }
        return true;
    }

    // Revert children in REVERSE order (mirror of the apply order). Used by
    // undo(). Stops and reports failure on the first child that fails to
    // revert.
    override bool revert() {
        foreach_reverse (c; children_) {
            if (!c.revert()) return false;
        }
        return true;
    }

    override CmdFlags cmdFlags() const { return unionFlags_; }
}

final class CommandHistory {
    private HistoryEntry[] undoStack;
    private HistoryEntry[] redoStack;
    private size_t maxDepth = 50;
    private UndoState _state = UndoState.Active;

    // Lockout — a hard, queryable gate over the WHOLE history service, DISTINCT
    // from Suspend. While locked out, record / recordCoalescing / undo / redo /
    // fire and the block/refire commit paths all early-return as no-ops: the
    // stacks are frozen and navigation is refused. Suspend, by contrast, only
    // silently drops new RECORDS during an internal revert (undo/redo still
    // work). Lockout is the switch automation flips to assert "no history
    // mutation may happen right now" — e.g. while a non-undoable external
    // operation owns the document — and to query that state via /api/undo/status.
    private bool _lockout = false;

    // Refire block state. One slot — refire blocks don't nest. fire()
    // checks `refireOpen` to decide whether to revert the previous live
    // command before applying the new one.
    private bool    refireOpen = false;
    private Command liveCmd;

    // Command-block state (blockBegin/blockEnd). `blockDepth` counts open
    // blocks; nesting FLATTENS — every blockBegin past the first just bumps
    // the depth, and all recorded children accumulate in the single flat
    // `blockChildren` list. blockEnd decrements; only the outermost blockEnd
    // (depth → 0) actually records the composite. `blockLabel` is captured at
    // the first (outermost) blockBegin. record() routes into blockChildren
    // whenever blockDepth > 0.
    private int       blockDepth = 0;
    private Command[] blockChildren;
    private string    blockLabel;

    // In-session run state. A RUN is a sequence of in-session gestures that
    // share one runId and consolidate into ONE surviving stack entry at the
    // run boundary / tool drop. `_currentRunId` is a monotone allocator (bumped
    // by nextRun()); `_runOpen` is true between the first recordInSession() of a
    // run and the consolidate() that closes it. The open-run flag is what the
    // foreign-record guard in record()/recordCoalescing() keys on (Q-a, layer A
    // of the design doc): a NON-tagged undoable entry appending while a run is
    // open first consolidates that run, so the run's tagged entries are always a
    // contiguous tail with no foreign entry buried inside.
    //
    // THREAD NOTE: every recorder (interactive commits, navHistory, and the
    // epoch-marshalled HTTP /api/command, /api/select, /api/toolpipe/eval
    // handlers) runs on the MAIN thread, so this run state — like the rest of
    // CommandHistory — needs no locking. A future HTTP-thread-direct recorder
    // would have to marshal to main like every existing path.
    private ulong _currentRunId = 0;
    private bool  _runOpen      = false;

    /// Phase 7 macro recorder hook. Invoked AFTER an entry lands on
    /// the undo stack — receives the canonical argstring command
    /// line (commandName + " " + args, or just commandName) plus the
    /// entry's flags. The macro recorder, when active, appends the
    /// line to its capture buffer. nullable.
    void delegate(string commandLine, uint flags) onRecord;

    // ----- state -----------------------------------------------------------

    UndoState state() const { return _state; }
    void setState(UndoState s) { _state = s; }

    // RAII helper for "suspend during this scope, restore on exit".
    struct Suspend {
        private CommandHistory h;
        private UndoState prev;
        @disable this(this);
        ~this() { h._state = prev; }
    }
    Suspend suspended() {
        Suspend s = { h: this, prev: _state };
        _state = UndoState.Suspend;
        return s;
    }

    // ----- lockout ---------------------------------------------------------

    /// Whether the history is currently locked out (all mutation / navigation
    /// refused). Read-only — safe to call from the HTTP server thread for
    /// /api/undo/status alongside state() / canUndo() / canRedo().
    bool lockedOut() const { return _lockout; }

    /// Engage or release the lockout. Direct setter for callers that pair
    /// set(true)/set(false) themselves; prefer locked() for RAII scoping so a
    /// lockout can never stick if an exception unwinds the scope.
    void setLockout(bool on) { _lockout = on; }

    // RAII helper mirroring Suspend: "lock out for this scope, restore on exit".
    // Restores the PRIOR value (not unconditionally false) so nested scopes
    // compose. Use as: `auto g = history.locked();`.
    struct Lockout {
        private CommandHistory h;
        private bool prev;
        @disable this(this);
        ~this() { h._lockout = prev; }
    }
    Lockout locked() {
        Lockout g = { h: this, prev: _lockout };
        _lockout = true;
        return g;
    }

    // ----- in-session runs -------------------------------------------------

    /// The current run id — the value recordInSession() stamps and a
    /// consolidate() target. Monotone; publicly readable so a tool can read
    /// it to tag a commit (it does NOT change merely by reading).
    ulong currentRunId() const { return _currentRunId; }

    /// Whether an in-session run is currently open (between its first
    /// recordInSession() and the consolidate() that closes it).
    bool runOpen() const { return _runOpen; }

    /// Allocate + return a fresh run id. A run boundary (hard boundary, bank
    /// switch, tool drop) consolidates the just-ended run then bumps to a new
    /// id so the next run's gestures are tagged distinctly.
    ulong nextRun() { return ++_currentRunId; }

    // Foreign-record guard (Q-a, layer A). Invoked at the top of the public
    // record() / recordCoalescing() entry points: if an open in-session run
    // exists, consolidate it FIRST so the foreign (non-tagged) entry lands on
    // top of one surviving consolidated entry rather than buried inside the
    // run. Idempotent — a no-op once the run is closed (so the internal
    // recordCoalescing()->record() hop does not double-consolidate).
    private void consolidateOpenRunIfForeign() {
        if (_runOpen) consolidate(_currentRunId);
    }

    // ----- recording -------------------------------------------------------

    // Called by the HTTP dispatcher AFTER a successful apply(). The command
    // must already be holding its pre-apply snapshot in instance fields.
    void record(Command cmd) {
        if (_lockout) return;
        if (cmd is null) return;
        if (!cmd.isUndoable) return;
        if (_state != UndoState.Active) return;

        // Q-a guard: a foreign (non-tagged) undoable append closes any open
        // in-session run first, keeping a run's tagged entries a contiguous
        // tail. Block children defer to the open block, not the stack, so they
        // are not a foreign append in the run sense — but consolidating before
        // routing is still correct (a run cannot be open inside a command block
        // in practice), and keeps the single touch point simple.
        consolidateOpenRunIfForeign();

        // Inside an open command block, the command becomes a child of the
        // block instead of its own stack entry. The composite lands as one
        // entry at blockEnd(). Same undoable/Active gating as a normal record
        // applied above, so non-model commands never enter the child list.
        if (blockDepth > 0) {
            blockChildren ~= cmd;
            // Still feed the macro recorder per child so a captured macro
            // mirrors the individual commands the user ran (the block is a
            // history-grouping concept, not a scripting one).
            if (onRecord !is null) {
                string args = serializeParams(cmd.params());
                string line = args.length > 0
                    ? (cmd.name ~ " " ~ args) : cmd.name;
                onRecord(line, historyFlagsFor(cmd));
            }
            return;
        }

        import core.time : MonoTime;
        long tMs = MonoTime.currTime.ticks
                 * 1000 / MonoTime.ticksPerSecond;
        uint flags = historyFlagsFor(cmd);
        string args = serializeParams(cmd.params());
        HistoryEntry e = { label: cmd.label,
                           args:  args,
                           commandName: cmd.name,
                           cmd: cmd,
                           timestampMs: tMs,
                           flags: flags };
        undoStack ~= e;
        if (undoStack.length > maxDepth) {
            undoStack = undoStack[$ - maxDepth .. $];
        }
        // Any new action invalidates the redo timeline.
        redoStack.length = 0;

        // Phase 7: hand the canonical command line to the macro
        // recorder. Macro recorder filters by its `active` flag —
        // we don't gate the callback here so future hooks can
        // observe all entries unconditionally.
        if (onRecord !is null) {
            string line = args.length > 0
                ? (cmd.name ~ " " ~ args) : cmd.name;
            onRecord(line, flags);
        }
    }

    // Coalescing record (Phase 2 op-merge). Used by the PROGRAMMATIC command
    // dispatcher (HTTP /api/command, keyboard/UI command shortcuts, scripted
    // commands) — NOT by interactive tool commits, which call record()
    // directly so each gesture is its own entry.
    //
    // If the freshly-applied `cmd` reports compareOp(top) == Compatible against
    // the command currently on top of the undo stack, the two are merged in
    // place: the existing top entry adopts `cmd`'s post-state while keeping its
    // own pre-state, so the run collapses to ONE undo step. Otherwise this
    // falls through to record() for a normal append.
    //
    // Honors the SAME guards record() honors: dropped while not Active
    // (Suspend), and routed into the open command block while blockDepth > 0
    // (coalescing is bypassed inside a block — the block IS the grouping).
    void recordCoalescing(Command cmd) {
        if (_lockout) return;
        if (cmd is null) return;
        if (!cmd.isUndoable) return;
        if (_state != UndoState.Active) return;
        // Q-a guard: close any open in-session run before a foreign coalescing
        // append (same rationale as record()). Done here too — the coalescing
        // merge path below can return early without reaching the inner
        // record() hop, so the guard must run at this entry point as well.
        consolidateOpenRunIfForeign();
        // Inside an open command block, defer to record()'s block-child path
        // (no in-place coalesce — the block already collapses its children).
        if (blockDepth > 0) { record(cmd); return; }

        // Try to merge into the current top entry. The merge is type-erased:
        // compareOp() decides COMPATIBLE, then the top command's mergeFrom()
        // folds `cmd`'s post-state in place (each coalescing command type —
        // MeshVertexEdit, MeshSelectionEdit — implements its own downcast).
        if (undoStack.length > 0) {
            auto top = &undoStack[$ - 1];
            if (cmd.compareOp(top.cmd) == CompareResult.Compatible) {
                // The dispatcher already applied `cmd`, so the mesh holds the
                // merged post-state — do NOT re-apply. Fold the newer post-state
                // into the kept-older top entry via the type-erased hook.
                if (top.cmd.mergeFrom(cmd)) {
                    // Refresh the top entry's args/label from the (now merged)
                    // top command so /api/history reflects the latest values.
                    top.args  = serializeParams(top.cmd.params());
                    top.label = top.cmd.label;

                    // MANDATORY invariant 1: a merge diverges the mesh from any
                    // redo entry, so the redo timeline MUST be cleared.
                    redoStack.length = 0;

                    // Fire the macro hook exactly as record() does, so a
                    // running macro still observes coalesced edits.
                    if (onRecord !is null) {
                        string line = top.args.length > 0
                            ? (top.cmd.name ~ " " ~ top.args) : top.cmd.name;
                        onRecord(line, historyFlagsFor(top.cmd));
                    }
                    return;
                }
            }
        }

        // No compatible top entry → normal append (record() clears redo +
        // fires onRecord).
        record(cmd);
    }

    /// Record `cmd` as ONE in-session entry of the run identified by `runId`.
    /// Identical to record() in every guard + side-effect (lockout / null /
    /// undoable / Active gating, maxDepth trim, macro hook) EXCEPT:
    ///   - the entry is stamped HistoryFlags.InSession + runId, and
    ///   - it sets _runOpen so the foreign-record guard knows a run is live.
    /// Like record()/recordCoalescing() it CLEARS the redo stack (N1): a fresh
    /// in-session gesture invalidates the redo timeline exactly as a committed
    /// record does, so an in-session redo can never re-apply a stale entry.
    ///
    /// Does NOT call the foreign-record guard — an in-session entry is, by
    /// definition, NOT a foreign append (it extends the open run).
    void recordInSession(Command cmd, ulong runId) {
        if (_lockout) return;
        if (cmd is null) return;
        if (!cmd.isUndoable) return;
        if (_state != UndoState.Active) return;

        // Inside an open command block, an in-session gesture is not a designed
        // scenario (gizmo runs do not open blocks); defer to record()'s
        // block-child path so behaviour matches a plain record there.
        if (blockDepth > 0) { record(cmd); return; }

        import core.time : MonoTime;
        long tMs = MonoTime.currTime.ticks
                 * 1000 / MonoTime.ticksPerSecond;
        uint flags = historyFlagsFor(cmd) | HistoryFlags.InSession;
        string args = serializeParams(cmd.params());
        HistoryEntry e = { label: cmd.label,
                           args:  args,
                           commandName: cmd.name,
                           cmd: cmd,
                           timestampMs: tMs,
                           flags: flags,
                           runId: runId };
        undoStack ~= e;
        if (undoStack.length > maxDepth) {
            undoStack = undoStack[$ - maxDepth .. $];
        }
        // N1: a fresh in-session gesture invalidates the redo timeline.
        redoStack.length = 0;

        // The run is now open until consolidate(runId) closes it.
        _runOpen = true;

        if (onRecord !is null) {
            string line = args.length > 0
                ? (cmd.name ~ " " ~ args) : cmd.name;
            onRecord(line, flags);
        }
    }

    /// Replace the open run's in-session TAIL entry with `cmd` (still tagged
    /// InSession + runId), keeping the run length stable. This is the REPLACE
    /// primitive used when a re-graded gesture should supersede the prior
    /// re-grade entry of the SAME run rather than append a second one (so N
    /// consecutive re-grades stay ONE undo step). It is the narrow stack-mutation
    /// seam a tool routes through instead of reaching into the stack itself —
    /// command_history stays the single owner of stack mutation (mirrors the
    /// consolidate() ownership boundary).
    ///
    /// Behaviour:
    ///   - If the undo-stack tail is (InSession && runId == runId), DROP it
    ///     (length -= 1, NOT onto the redo stack — a superseded re-grade entry
    ///     is not a navigable step), then recordInSession(cmd, runId). The net
    ///     stack length is unchanged; the run stays open; recordInSession clears
    ///     the redo stack (N1) and fires onRecord as usual.
    ///   - Otherwise (empty stack, or the tail is not this run's in-session
    ///     entry) it degrades to a plain recordInSession(cmd, runId) append —
    ///     i.e. the FIRST re-grade of a run, where there is no prior re-grade
    ///     entry to replace, simply appends.
    ///
    /// The caller owns the BEFORE[] of `cmd` (it anchors before[] to the
    /// once-per-run post-gesture snapshot, NOT to the dropped entry's before[],
    /// so a widening support reverts cleanly). This primitive only owns the
    /// stack rewrite.
    ///
    /// Main-thread only (all recorders are; recordInSession asserts the same).
    void replaceInSessionTail(Command cmd, ulong runId) {
        if (cmd is null) return;
        // Drop the matching in-session tail if present (superseded re-grade).
        if (undoStack.length > 0) {
            auto tail = undoStack[$ - 1];
            if ((tail.flags & HistoryFlags.InSession) && tail.runId == runId) {
                undoStack.length -= 1;
            }
        }
        // Append the replacement as a fresh tagged in-session entry. This also
        // clears the redo stack (N1) and re-sets _runOpen — both correct.
        recordInSession(cmd, runId);
    }

    /// Consolidate one in-session RUN: collapse its CONTIGUOUS tail of entries
    /// tagged (InSession + runId) into ONE merged entry, in place at the
    /// position of the FIRST gathered entry. Clears _runOpen.
    ///
    /// Merge semantics (design doc Q1, MERGE-OF-ENTRIES):
    ///   - indices = sorted union of the gathered entries' indices,
    ///   - before[vid] = the EARLIEST gathered entry's before for vid
    ///     (first-touch-wins → run-start state),
    ///   - after[vid]  = the LATEST gathered entry's after for vid,
    ///   - hooks = first gathered entry's revert-hook + last's apply-hook,
    /// all built by MeshVertexEdit.mergeRun() (which owns the module-private
    /// payload + GPU/cache pointers). Consolidation does NOT mutate geometry —
    /// the mesh already holds the run-end state; this only rewrites the stack.
    ///
    /// Defense-in-depth (Q-a): even though contiguity holds BY CONSTRUCTION (a
    /// foreign record consolidates the run first, so nothing interleaves), the
    /// gather walks from the stack tail and STOPS at the first entry that is not
    /// (InSession && runId == runId). A future invariant violation thus
    /// degrades to a graceful partial merge rather than a corrupt one.
    ///
    /// Edge cases (all safe no-ops): an empty stack, no matching tail (run never
    /// opened or already consolidated), or a single gathered entry — in each the
    /// stack is left untouched apart from clearing _runOpen. Cap-50 interplay
    /// (Q1 risk 6): if the run-start entry already fell off maxDepth, the gather
    /// merges only the SURVIVING tail, so before[] anchors to the earliest
    /// surviving gesture — graceful degradation, not a crash.
    ///
    /// Redo-split safety (the in-session-undo-then-boundary case). undo() POPS
    /// an entry off undoStack ONTO redoStack — it does NOT keep a cursor with
    /// entries straddling a single stack. So if the user steps in-session
    /// Ctrl+Z over some of a run's gestures and THEN a boundary fires, the
    /// undone gestures live entirely on redoStack and only the still-applied
    /// gestures remain as a contiguous undoStack tail. consolidate() gathers
    /// ONLY that undo tail; it never merges across the undo/redo split. The
    /// merge preserves continuity: merged.after = the LAST gathered (undo-tail)
    /// gesture's after = exactly the `before` state of the first still-pending
    /// redo entry, so a later redo() re-applies that entry coherently on top of
    /// the consolidated entry. Stale tagged redo entries are therefore never
    /// re-applied against a wrong baseline; and any NEW gesture clears the redo
    /// stack via recordInSession()/record() (N1) before it could matter. No
    /// explicit redo-stack scrub is needed here.
    void consolidate(ulong runId) {
        scope(exit) _runOpen = false;
        if (undoStack.length == 0) return;

        // Gather the contiguous matching-runId InSession tail (oldest→newest).
        size_t end = undoStack.length;       // one past the last gathered
        size_t start = end;
        while (start > 0) {
            auto e = undoStack[start - 1];
            if (!(e.flags & HistoryFlags.InSession) || e.runId != runId)
                break;
            --start;
        }
        size_t n = end - start;
        if (n == 0) return;                   // no matching tail — no-op.

        // Downcast the gathered commands to MeshVertexEdit. Any non-vertex-edit
        // in the run (not expected — runs are vertex edits) aborts the merge as
        // a safe no-op rather than guessing a cross-type union.
        import commands.mesh.vertex_edit : MeshVertexEdit;
        MeshVertexEdit[] gathered;
        gathered.reserve(n);
        foreach (i; start .. end) {
            auto mve = cast(MeshVertexEdit) undoStack[i].cmd;
            if (mve is null) return;          // unexpected type — leave as-is.
            gathered ~= mve;
        }

        // Single-entry run: nothing to merge, but the run HAS ended, so the
        // lone gesture entry IS the surviving consolidated form. Strip its
        // InSession tag + runId in place so it presents as an ordinary
        // surviving entry: /api/history no longer reports a closed run's
        // entry as inSession, and a per-gesture-count consumer (test / panel)
        // sees exactly the OPEN run's tagged steps. Navigation is unaffected
        // (the entry's command + before/after are untouched).
        if (n == 1) {
            undoStack[start].flags &= ~cast(uint)HistoryFlags.InSession;
            undoStack[start].runId  = 0;
            return;
        }

        auto merged = MeshVertexEdit.mergeRun(gathered);

        // Replace the gathered entries with ONE entry at the first's position.
        // The merged entry is an ordinary (non-in-session) surviving entry —
        // the run has ended. Preserve the first entry's label/timestamp shape
        // via a fresh entry built from the merged command.
        auto first = undoStack[start];
        HistoryEntry mergedEntry = {
            label:       merged.label,
            args:        serializeParams(merged.params()),
            commandName: merged.name,
            cmd:         merged,
            timestampMs: first.timestampMs,
            flags:       historyFlagsFor(merged),
            runId:       0,
        };

        undoStack = undoStack[0 .. start] ~ mergedEntry ~ undoStack[end .. $];
    }

    // ----- navigation ------------------------------------------------------

    bool canUndo() const { return undoStack.length > 0; }
    bool canRedo() const { return redoStack.length > 0; }

    bool undo() {
        if (_lockout) return false;
        if (undoStack.length == 0) return false;
        auto e = undoStack[$ - 1];
        undoStack.length -= 1;
        // Suspend recording while reverting so any internal sub-commands
        // the revert path triggers (e.g. selection/edge cache invalidate)
        // don't pollute the redo timeline.
        auto prev = _state;
        _state = UndoState.Suspend;
        scope(exit) _state = prev;
        if (!e.cmd.revert()) {
            // Revert failed; drop the entry (don't put back) to avoid a
            // stuck stack. Caller can detect via state changes.
            return false;
        }
        redoStack ~= e;
        return true;
    }

    bool redo() {
        if (_lockout) return false;
        if (redoStack.length == 0) return false;
        auto e = redoStack[$ - 1];
        redoStack.length -= 1;
        auto prev = _state;
        _state = UndoState.Suspend;
        scope(exit) _state = prev;
        if (!e.cmd.apply()) {
            return false;
        }
        undoStack ~= e;
        return true;
    }

    // ----- inspection (Edit menu, /api/history) ---------------------------

    // Composed format: "Label  args" (two spaces) for non-empty args,
    // or just "Label" when args is empty. Used by the UI history panel.
    string[] undoLabels() const {
        string[] out_;
        out_.reserve(undoStack.length);
        foreach (e; undoStack)
            out_ ~= e.args.length > 0 ? (e.label ~ "  " ~ e.args) : e.label;
        return out_;
    }

    string[] redoLabels() const {
        string[] out_;
        out_.reserve(redoStack.length);
        foreach (e; redoStack)
            out_ ~= e.args.length > 0 ? (e.label ~ "  " ~ e.args) : e.label;
        return out_;
    }

    // Structured access — used by /api/history JSON serializer.
    const(HistoryEntry)[] undoEntries() const { return undoStack; }
    const(HistoryEntry)[] redoEntries() const { return redoStack; }

    /// Returns the canonical argstring line for undoStack[index]:
    /// `commandName + " " + args` if args is non-empty, else `commandName`.
    /// Returns "" when index is out of range.
    /// Used by /api/history/replay to re-execute past commands through the
    /// same dispatch path as /api/command without modifying the original entry.
    string undoEntryCommandLine(size_t index) const {
        if (index >= undoStack.length) return "";
        auto e = undoStack[index];
        return e.args.length > 0 ? (e.commandName ~ " " ~ e.args) : e.commandName;
    }

    void clear() {
        // Empties BOTH stacks deliberately: leaving redoStack populated would
        // let jumpTo()'s maxTarget (= undoStack.length + redoStack.length) point
        // into an orphaned redo timeline with no matching undo entries. Both
        // must go together so the jump range stays well-formed after a clear.
        undoStack.length = 0;
        redoStack.length = 0;
    }

    /// Multi-step history jump (Phase 2 of the history-panel design
    /// doc). `target` is the DESIRED length of `undoStack` after the
    /// jump — i.e. how many
    /// entries should be "applied" once the operation finishes.
    /// Valid range: [0, undoStack.length + redoStack.length].
    ///
    ///   target < undoStack.length → call undo() (undoStack.length - target) times.
    ///   target > undoStack.length → call redo() (target - undoStack.length) times.
    ///   target == undoStack.length → no-op.
    ///
    /// If any undo() / redo() returns false (revert failure), the
    /// jump stops at that point and the method returns false. The
    /// caller sees a partially-walked stack — exactly what a user
    /// would see if they single-stepped manually past a broken
    /// entry. Out-of-range `target` is clamped silently.
    bool jumpTo(size_t target) {
        size_t maxTarget = undoStack.length + redoStack.length;
        if (target > maxTarget) target = maxTarget;
        while (undoStack.length > target) {
            if (!undo()) return false;
        }
        while (undoStack.length < target) {
            if (!redo()) return false;
        }
        return true;
    }

    // ----- refire ----------------------------------------------------------
    // refireBegin / fire / refireEnd model an interactive edit cycle:
    //   begin, fire, fire, fire, ..., end.
    // Each fire reverts the previous one and applies the new (so the mesh
    // walks "from pre-cycle state → newest params" without accumulation).
    // refireEnd pushes the latest live command onto the undo stack as one
    // entry. Outside a refire block, callers should use record() for the
    // post-mutation Record-flavor or apply()+record() for the standard path.

    bool refireActive() const { return refireOpen; }

    void refireBegin() {
        if (_lockout) return;
        // Defensive: if a prior refire block was left dangling (e.g. tool
        // crashed mid-drag), commit it first so we don't lose the entry.
        if (refireOpen && liveCmd !is null) {
            import core.time : MonoTime;
            long tMs = MonoTime.currTime.ticks
                     * 1000 / MonoTime.ticksPerSecond;
            uint flags = historyFlagsFor(liveCmd);
            string args = serializeParams(liveCmd.params());
            HistoryEntry e = { label: liveCmd.label,
                               args:  args,
                               commandName: liveCmd.name,
                               cmd: liveCmd,
                               timestampMs: tMs,
                               flags: flags };
            undoStack ~= e;
            if (undoStack.length > maxDepth)
                undoStack = undoStack[$ - maxDepth .. $];
            redoStack.length = 0;
            if (onRecord !is null) {
                string line = args.length > 0
                    ? (liveCmd.name ~ " " ~ args) : liveCmd.name;
                onRecord(line, flags);
            }
        }
        refireOpen = true;
        liveCmd    = null;
    }

    // Apply cmd. If a live command from a previous fire() is present, its
    // revert() runs first so the mesh walks back to the pre-block state
    // before the new command lays down its mutation. Sub-commands fired
    // during apply()/revert() are suspended so they don't pollute history.
    bool fire(Command cmd) {
        if (_lockout) return false;
        if (cmd is null) return false;
        if (!refireOpen) {
            // Caller forgot refireBegin(); treat as a plain apply+record.
            if (!cmd.apply()) return false;
            record(cmd);
            return true;
        }
        auto prev = _state;
        _state = UndoState.Suspend;
        scope(exit) _state = prev;

        if (liveCmd !is null) {
            if (!liveCmd.revert()) return false;
        }
        if (!cmd.apply()) {
            liveCmd = null;
            return false;
        }
        liveCmd = cmd;
        return true;
    }

    // Closes the refire block. The latest live command (if any) lands on
    // the undo stack as ONE entry. record()'s flag-and-state checks
    // (isUndoable, _state) apply: a non-undoable live command is dropped.
    void refireEnd() {
        if (_lockout) return;
        if (!refireOpen) return;
        Command final_ = liveCmd;
        refireOpen = false;
        liveCmd    = null;
        if (final_ !is null) record(final_);
    }

    // ----- command blocks --------------------------------------------------
    // blockBegin / blockEnd group N commands run between them into ONE undo
    // entry (a CompositeCommand). Each command's apply() is invoked by the
    // caller as usual; the caller then passes it to record(), which — while a
    // block is open — appends it to the block's child list instead of pushing
    // a standalone entry. blockEnd() records the composite as the single
    // grouped entry.
    //
    // Nesting flattens: a blockBegin inside a blockBegin shares ONE flat child
    // list and ONE label (the outermost). blockEnd matches the innermost open
    // block (decrements the depth); only the outermost blockEnd commits.
    //
    // Interaction with refire (deliberately kept simple & safe): blocks and
    // refire are independent grouping primitives and are NOT designed to be
    // interleaved. fire() is unaware of blocks, so a refire cycle run inside a
    // block would push its committed entry through record() at refireEnd() and
    // thus be folded in as ONE child of the block (the block stays the single
    // user-visible entry — no regression to refire's own coalescing). Callers
    // should not open a block in the middle of a live refire drag; doing so is
    // undefined and not exercised by any consumer.

    bool blockActive() const { return blockDepth > 0; }

    /// Open a command block. `label` names the resulting composite entry; for
    /// nested calls only the outermost label is used.
    void blockBegin(string label) {
        if (_lockout) return;
        if (blockDepth == 0) {
            blockChildren.length = 0;
            blockLabel = label;
        }
        blockDepth++;
    }

    /// Close the innermost open block. On the outermost close (depth → 0),
    /// wrap the collected children in a CompositeCommand and record it as ONE
    /// entry. An empty block (no children collected) records nothing.
    /// Calling blockEnd() with no open block is a harmless no-op.
    void blockEnd() {
        if (_lockout) return;
        if (blockDepth == 0) return;
        blockDepth--;
        if (blockDepth > 0) return;   // inner end of a nested block — defer.

        Command[] kids = blockChildren;
        string lbl     = blockLabel;
        blockChildren.length = 0;
        blockLabel = "";

        if (kids.length == 0) return; // empty block → drop, no entry.

        // Single-child blocks could be unwrapped, but wrapping keeps the
        // entry's label = the block label (the user named the group) and the
        // behaviour uniform. Wrap unconditionally.
        auto composite = new CompositeCommand(kids, lbl);
        record(composite);
    }
}
