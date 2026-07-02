module command_history;

import command;
import command : CmdFlags;
import argstring : serializeParams;
// Byte-neutral in the default build (perf_probe.g_perf.count is a no-op
// inline stub without version(PerfProbe) — task 0200's undoApply counter).
import perf_probe : g_perf, Cat;

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
    Refire     = 1 << 8, // Entry is an in-session RE-GRADE (a falloff re-fire of
                         // the open run's last gesture), recorded by
                         // replaceInSessionTail(). ALWAYS accompanies InSession.
                         // It is the trustworthy "the tail is a re-grade" signal
                         // the REPLACE-vs-APPEND decision keys on: a fresh
                         // re-grade REPLACES the prior re-grade tail (so N
                         // consecutive tweaks stay ONE undo step) ONLY when the
                         // tail itself is a Refire of the same run — a plain
                         // gesture entry (InSession but NOT Refire) is never
                         // dropped, so a second gesture's geometry contribution
                         // is never lost (the multi-gesture-run REPLACE hazard).
                         // The contiguous-run gather (consolidate) keys on
                         // InSession+runId, so a Refire entry merges normally;
                         // the n==1 tag-strip clears BOTH bits.
    UndoBoundary = 1 << 9, // Entry is a hard-stop for the T-SEP cursor scan.
                           // The entry IS undoable and stays on the stack, but
                           // nearestModelIndexFromTail() stops before it (not at
                           // it), triggering the B1 UI-head fallback. Mirrors
                           // CmdFlags.UndoBoundary. Applied to scene.reset /
                           // file.new so a plain geometry undo never reaches
                           // across a session-reset boundary.
    ToolLifecycle = 1 << 10, // Entry is a tool-lifecycle step (ToolDeactivationCommand).
                             // Transparent to the Model cursor scan (like UiUndo) when a
                             // Model entry sits directly below it; otherwise a hard STEP
                             // that re-activates the dropped tool. Never counted in
                             // modelDepth / uiDepth; excluded from /api/history serialization.
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
    ulong   tweakGeneration;// Pipe-tweak GENERATION token (P-E). Stamped on every
                            //  recorded entry from CommandHistory._tweakGeneration
                            //  at record time. Load-bearing ONLY on a Refire
                            //  entry: replaceInSessionTail() REPLACES the tail
                            //  Refire ONLY when the tail's generation == the new
                            //  entry's generation — i.e. both re-grades belong to
                            //  ONE continuous tweak interaction (a held slider
                            //  scrub / a falloff-handle drag, whose setAttr stream
                            //  shares one generation). Two DISCRETE tweaks (each a
                            //  separate setAttr command / handle gesture) carry
                            //  DIFFERENT generations, so the second APPENDS — it
                            //  is its own in-session undo step (reference fact G2:
                            //  drag + 2 discrete tweaks = 3 steps; one continuous
                            //  scrub = 1 step). The generation is bumped by
                            //  bumpTweakGeneration() at a tweak boundary: per
                            //  discrete (non-interactive) tool.pipe.attr command,
                            //  and at the END of a continuous interaction (panel-
                            //  slider deactivate / falloff-handle mouse-up). 0 for
                            //  ordinary entries (irrelevant — the gate consults it
                            //  only for Refire tails).
}

/// Map a command's CmdFlags to the per-entry HistoryFlags recorded on
/// the stack. Succeeded is always set here because record() / refire
/// only fire after a successful apply().
private uint historyFlagsFor(const Command cmd) {
    CmdFlags cf = cmd.cmdFlags();
    uint flags = HistoryFlags.Succeeded;
    // Undoable mirrors "lands on the stack" — true for BOTH undo classes
    // (Model-undo and UI-undo). The UiUndo bit then narrows which class it is.
    if (cmd.isUndoable())            flags |= HistoryFlags.Undoable;
    if (cmd.isUiUndo())              flags |= HistoryFlags.UiUndo;
    if (cf & CmdFlags.Quiet)         flags |= HistoryFlags.Quiet;
    if (cf & CmdFlags.SideEffect)    flags |= HistoryFlags.SideEffect;
    if (cf & CmdFlags.UndoForce)     flags |= HistoryFlags.UndoForced;
    if (cf & CmdFlags.UndoBoundary)  flags |= HistoryFlags.UndoBoundary;
    if (cf & CmdFlags.ToolLifecycle) flags |= HistoryFlags.ToolLifecycle;
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

    this() {
        // Allow emergency rollback of class-aware stepping via env var.
        // VIBE3D_UNDO_CLASS_STEP=0 disables T-SEP-cursor; any other value (or
        // absent) keeps the default ON. Removed in Stage 6 once burn-in is done.
        import std.process : environment;
        string ev = environment.get("VIBE3D_UNDO_CLASS_STEP", "");
        if (ev == "0") _classAwareStepping = false;
    }

    // Undo-epoch counter — bumped exactly once in the SUCCESS branch of undo()
    // (after e.cmd.revert() succeeds, alongside redoStack ~= e). Never bumped
    // by redo(), record*(), consolidate(), replaceInSessionTail(), or coalesce.
    // Purpose: gives the exploration controller a reliable undo signal that is
    // immune to consolidate/coalesce/replace side-effects on stack length.
    private ulong _undoEpoch = 0;

    // Class-aware stepping (T-SEP-cursor). When true, undo()/redo() use the
    // carried-suffix algorithm: a plain undo finds the nearest Model-class entry
    // from the tail and moves the SUFFIX (that entry + any trailing UI entries)
    // to the redo stack as a unit, calling revert() only on the Model entry (so
    // interleaved selection entries are carried inert — the selection holds).
    // When the tail is all-UI (B1 fallback), the UI head is reverted normally.
    // redo() is the inverse block move.
    // The env-var override (VIBE3D_UNDO_CLASS_STEP=0) provides an emergency
    // rollback during burn-in; it is removed in Stage 6.
    private bool _classAwareStepping = true;

    /// Read-only access to the undo epoch counter. Callers snapshot the value
    /// at "interesting" moments and compare later; a strict increase means at
    /// least one successful user undo occurred between snapshots.
    ulong undoEpoch() const { return _undoEpoch; }

    // Lockout — a hard, queryable gate over the WHOLE history service, DISTINCT
    // from Suspend. While locked out, record / recordCoalescing / undo / redo /
    // fire and the block/refire commit paths all early-return as no-ops: the
    // stacks are frozen and navigation is refused. Suspend, by contrast, only
    // silently drops new RECORDS during an internal revert (undo/redo still
    // work). Lockout is the switch automation flips to assert "no history
    // mutation may happen right now" — e.g. while a non-undoable external
    // operation owns the document — and to query that state via /api/undo/status.
    private bool _lockout = false;

    // One-shot coalesce barrier. When set, the NEXT recordCoalescing() refuses
    // to merge into the current top entry (it appends a fresh entry instead) and
    // then clears the flag. Used by the active-layer-switch hook: a selection /
    // delta edit recorded right after switching layers must start a fresh
    // history entry rather than coalesce with the prior layer's top entry. The
    // compareOp target-mesh equality term already prevents cross-mesh merges
    // statelessly; this barrier is the explicit belt-and-braces for the case
    // where an undo of layer.select resurfaces an older SAME-mesh entry as top
    // and a new edit on that same mesh could otherwise merge across the switch.
    private bool _coalesceBarrier = false;

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

    // Pipe-tweak GENERATION (P-E). A monotone token that distinguishes a
    // CONTINUOUS tweak interaction (one held slider scrub / one falloff-handle
    // drag — its setAttr stream shares ONE generation) from a DISCRETE tweak
    // (each a separate setAttr command / handle gesture, its own generation).
    // recordInSession()/replaceInSessionTail() stamp the recorded entry with
    // this value; replaceInSessionTail() REPLACES a Refire tail ONLY when the
    // tail's generation matches (same continuous interaction), else APPENDS. The
    // counter starts at 0 and is bumped by bumpTweakGeneration() at a tweak
    // boundary (see the field doc on HistoryEntry.tweakGeneration). Default 0
    // means a caller that never bumps (e.g. the replaceInSessionTail unit tests)
    // sees pure REPLACE — the historical Refire-keyed behaviour, unchanged.
    private ulong _tweakGeneration = 0;

    /// Phase 7 macro recorder hook. Invoked AFTER an entry lands on
    /// the undo stack — receives the canonical argstring command
    /// line (commandName + " " + args, or just commandName) plus the
    /// entry's flags. The macro recorder, when active, appends the
    /// line to its capture buffer. nullable.
    void delegate(string commandLine, uint flags) onRecord;

    // ----- class-aware stepping -------------------------------------------

    /// Enable or disable class-aware (T-SEP-cursor) stepping. Default ON.
    /// Exposed for emergency rollback during burn-in via env var
    /// VIBE3D_UNDO_CLASS_STEP=0, and for in-module unit tests.
    void setClassAwareStepping(bool on) { _classAwareStepping = on; }
    bool classAwareStepping() const { return _classAwareStepping; }

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

    /// The current pipe-tweak generation token (P-E). Read by
    /// replaceInSessionTail()/recordInSession() to stamp a recorded entry;
    /// publicly readable so a caller can correlate. Does NOT change merely by
    /// reading. See the field doc on HistoryEntry.tweakGeneration.
    ulong currentTweakGeneration() const { return _tweakGeneration; }

    /// Open a NEW pipe-tweak generation (P-E) and return it. Called at a tweak
    /// BOUNDARY so the NEXT re-grade's entry carries a generation distinct from
    /// the prior re-grade's — making two DISCRETE tweaks APPEND as separate
    /// in-session undo steps (G2), while the contiguous setAttr stream of ONE
    /// continuous interaction (which does NOT bump between its frames) stays at
    /// one generation and REPLACEs into one step. Call sites:
    ///   - per discrete (non-interactive) tool.pipe.attr command (app.d
    ///     command dispatch): each HTTP/script setAttr is its own generation;
    ///   - at the END of a continuous interaction: a forms-panel slider
    ///     deactivate (IsItemDeactivatedAfterEdit, forms_render.d) and a
    ///     falloff-handle drag mouse-up (xfrm_transform.d onMouseButtonUp), so
    ///     the following tweak starts fresh.
    /// Monotone; never decreases. Idempotent in effect — a redundant bump only
    /// skips a generation value, never breaks the gate (a fresh generation can
    /// never spuriously match a prior Refire tail).
    ulong bumpTweakGeneration() { return ++_tweakGeneration; }

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

        // One-shot coalesce barrier (set by the active-layer-switch hook):
        // refuse to merge into the current top, append a fresh entry instead.
        if (_coalesceBarrier) {
            _coalesceBarrier = false;
            record(cmd);
            return;
        }

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

    /// Arm a one-shot coalesce barrier: the NEXT recordCoalescing() will append
    /// a fresh entry rather than merge into the current top, then disarm. Called
    /// by the active-layer-switch hook so a selection/delta edit immediately
    /// after a layer switch starts a new history entry on the new layer.
    void breakCoalescing() { _coalesceBarrier = true; }

    /// Record a tool-lifecycle entry (ToolDeactivationCommand). Unlike record(),
    /// this does NOT call consolidateOpenRunIfForeign (the run is already closed
    /// at the emit point — consolidate() ran inside deactivate()). Appends to
    /// undoStack, clears redo. Respects _state != Active (so re-entry during a
    /// Suspend-wrapped revert/apply is silently dropped).
    void recordToolLifecycle(Command cmd) {
        if (_lockout) return;
        if (cmd is null) return;
        if (_state != UndoState.Active) return;
        import core.time : MonoTime;
        long tMs = MonoTime.currTime.ticks * 1000 / MonoTime.ticksPerSecond;
        uint flags = historyFlagsFor(cmd);
        string args = "";
        HistoryEntry e = { label: cmd.label,
                           args:  args,
                           commandName: cmd.name,
                           cmd: cmd,
                           timestampMs: tMs,
                           flags: flags };
        undoStack ~= e;
        if (undoStack.length > maxDepth)
            undoStack = undoStack[$ - maxDepth .. $];
        redoStack.length = 0;
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
                           runId: runId,
                           // P-E: stamp the live tweak generation. Load-bearing
                           // only when this entry is later a Refire tail (see
                           // replaceInSessionTail). A plain gesture entry carries
                           // it harmlessly.
                           tweakGeneration: _tweakGeneration };
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

    /// Record `cmd` as an in-session RE-GRADE (a falloff re-fire) of the open
    /// run, tagged InSession + Refire + runId. This is the ONE primitive the
    /// re-fire path routes through (the caller no longer makes the
    /// REPLACE-vs-APPEND decision itself — this primitive owns it, keyed on the
    /// trustworthy Refire bit). It keeps N consecutive re-grades at ONE undo
    /// step while never dropping a plain gesture entry. It is the narrow
    /// stack-mutation seam a tool routes through instead of reaching into the
    /// stack itself — command_history stays the single owner of stack mutation
    /// (mirrors the consolidate() ownership boundary).
    ///
    /// REPLACE-vs-APPEND, keyed on the Refire bit (NOT on whether ANY re-grade
    /// happened this run):
    ///   - If the undo-stack tail is (InSession && Refire && runId == runId) —
    ///     i.e. the tail is THIS run's prior RE-GRADE entry — DROP it (length
    ///     -= 1, NOT onto the redo stack: a superseded re-grade is not a
    ///     navigable step), then append the new one. The net stack length is
    ///     unchanged: N consecutive tweaks stay ONE undo step.
    ///   - Otherwise (empty stack; or the tail is a plain GESTURE entry
    ///     (InSession but NOT Refire); or it belongs to a different run; or it is
    ///     untagged/foreign) it DEGRADES TO APPEND — recordInSession then sets
    ///     the Refire bit. This is the load-bearing safety property: when a
    ///     SECOND gesture lands after a first tweak (stack tail = the gesture,
    ///     not a re-grade), a following tweak APPENDS rather than dropping the
    ///     gesture, so the gesture's geometry contribution is never lost from
    ///     the consolidated drop entry.
    ///
    /// Both arms tag the recorded entry with the Refire bit (so the NEXT
    /// re-grade sees a Refire tail and replaces it). recordInSession clears the
    /// redo stack (N1), re-sets _runOpen, and fires onRecord as usual.
    ///
    /// The caller owns the BEFORE[] of `cmd` (it anchors before[] to the
    /// once-per-re-fire-window post-gesture snapshot, NOT to the dropped entry's
    /// before[], so a widening support reverts cleanly). This primitive only
    /// owns the stack rewrite + the Refire tag.
    ///
    /// Main-thread only (all recorders are; recordInSession asserts the same).
    void replaceInSessionTail(Command cmd, ulong runId) {
        if (cmd is null) return;
        // Drop the matching in-session tail ONLY when it is this run's prior
        // RE-GRADE entry (InSession && Refire && runId) AND it belongs to the
        // SAME continuous tweak interaction (P-E: tail.tweakGeneration ==
        // _tweakGeneration). A plain gesture entry (InSession but NOT Refire) is
        // NEVER dropped — that is the fix for the multi-gesture-run hazard (g1 ->
        // tweak1 -> g2 -> tweak2 must NOT erase g2). A non-matching tail (a
        // gesture, a different run, foreign — OR a Refire of a DIFFERENT
        // generation, i.e. a DISCRETE prior tweak) degrades to a plain append
        // below.
        //
        // P-E GATE: the generation token distinguishes continuous from discrete.
        // Within ONE held interaction (a slider scrub / a falloff-handle drag)
        // the setAttr stream does NOT bump the generation, so consecutive
        // re-grades share it and REPLACE (N pixel increments = ONE undo step).
        // Between two DISCRETE tweaks (each its own tool.pipe.attr command, each
        // bumping the generation) the tail's generation differs from the new
        // entry's, so this APPENDS — each discrete tweak is its own in-session
        // step (reference fact G2). A caller that never bumps (default
        // generation 0 throughout — the replaceInSessionTail unit tests) keeps
        // pure REPLACE, the historical Refire-keyed behaviour.
        if (undoStack.length > 0) {
            auto tail = undoStack[$ - 1];
            if ((tail.flags & HistoryFlags.InSession)
             && (tail.flags & HistoryFlags.Refire)
             && tail.runId == runId
             && tail.tweakGeneration == _tweakGeneration) {
                undoStack.length -= 1;
            }
        }
        // Append the replacement as a fresh tagged in-session entry, then stamp
        // the Refire bit so the NEXT re-grade recognises it as a re-grade tail.
        // recordInSession clears the redo stack (N1) and re-sets _runOpen.
        recordInSession(cmd, runId);
        if (undoStack.length > 0)
            undoStack[$ - 1].flags |= HistoryFlags.Refire;
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
            undoStack[start].flags &=
                ~cast(uint)(HistoryFlags.InSession | HistoryFlags.Refire);
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

    /// Replace the current matching in-session tail with `cmd` as a normal
    /// history entry. Used by live tools whose final committed command is not a
    /// merge of the transient in-session command type.
    void replaceInSessionTailWith(ulong runId, Command cmd) {
        scope(exit) _runOpen = false;
        if (_lockout) return;
        if (cmd is null) return;
        if (!cmd.isUndoable) return;
        if (_state != UndoState.Active) return;
        if (blockDepth > 0) { record(cmd); return; }

        size_t end = undoStack.length;
        size_t start = end;
        while (start > 0) {
            auto e = undoStack[start - 1];
            if (!(e.flags & HistoryFlags.InSession) || e.runId != runId)
                break;
            --start;
        }

        import core.time : MonoTime;
        long tMs = MonoTime.currTime.ticks
                 * 1000 / MonoTime.ticksPerSecond;
        if (start < end)
            tMs = undoStack[start].timestampMs;

        uint flags = historyFlagsFor(cmd);
        string args = serializeParams(cmd.params());
        HistoryEntry e = { label: cmd.label,
                           args: args,
                           commandName: cmd.name,
                           cmd: cmd,
                           timestampMs: tMs,
                           flags: flags,
                           runId: 0 };

        if (start < end) {
            undoStack = undoStack[0 .. start] ~ [e] ~ undoStack[end .. $];
        } else {
            undoStack ~= e;
            if (undoStack.length > maxDepth)
                undoStack = undoStack[$ - maxDepth .. $];
        }
        redoStack.length = 0;

        if (onRecord !is null) {
            string line = args.length > 0
                ? (cmd.name ~ " " ~ args) : cmd.name;
            onRecord(line, flags);
        }
    }

    // ----- navigation ------------------------------------------------------

    bool canUndo() const { return undoStack.length > 0; }
    bool canRedo() const { return redoStack.length > 0; }

    // Scan undoStack from the tail toward the head for the nearest Model-class
    // entry (Undoable && !UiUndo). Returns the index into undoStack, or
    // undoStack.length if no Model entry is found (all-UI stack).
    //
    // The scan stops (returns "not found") when it hits an entry carrying
    // HistoryFlags.UndoBoundary: a boundary entry (scene.reset / file.new)
    // delimits the current editing session. A plain geometry undo must not
    // reach across it to revert work from a prior session.
    private size_t nearestModelIndexFromTail() const {
        if (undoStack.length == 0) return 0;
        size_t i = undoStack.length;
        while (i > 0) {
            --i;
            uint f = undoStack[i].flags;
            // Hard stop: boundary entries are not stepped to by a model undo.
            if (f & HistoryFlags.UndoBoundary)
                return undoStack.length; // sentinel: treat as "no model entry"
            // Skip ToolLifecycle entries (transparent to the Model scan, like UiUndo).
            if (f & HistoryFlags.ToolLifecycle) continue;
            if ((f & HistoryFlags.Undoable) && !(f & HistoryFlags.UiUndo))
                return i;
        }
        return undoStack.length; // sentinel: no Model entry found
    }

    // Count Model and UI entries currently on the undo stack (within the
    // current session boundary). Boundary entries (UndoBoundary) are not
    // counted — they are not reachable by the T-SEP cursor. Used by
    // /api/undo/status to give tests fine-grained depth assertions.
    void undoDepthCounts(out size_t modelCount, out size_t uiCount) const {
        modelCount = 0;
        uiCount    = 0;
        foreach_reverse (ref e; undoStack) {
            // Stop counting at a session boundary (same scope as the scan).
            if (e.flags & HistoryFlags.UndoBoundary) break;
            if (!(e.flags & HistoryFlags.Undoable)) continue;
            if (e.flags & HistoryFlags.ToolLifecycle) continue; // excluded from model/ui counts
            if (e.flags & HistoryFlags.UiUndo) ++uiCount;
            else                                ++modelCount;
        }
    }

    // Whether a plain undo would step a Model entry (true) or fall back to
    // the UI head (false). Used by /api/undo/status.
    //
    // When a session-boundary entry sits at the tail with no Model entry above
    // it (nearestModelIndexFromTail returns the sentinel), the B1 fallback
    // reverts the boundary entry itself — which IS a Model-class entry. Report
    // canUndoModel=true in that case so callers see "Model undo available"
    // rather than the misleading "UI undo available".
    bool canUndoModel() const {
        if (!_classAwareStepping) return canUndo();
        size_t mi = nearestModelIndexFromTail();
        if (mi < undoStack.length) return true; // found a reachable Model entry
        // No reachable Model entry. Check whether the B1-fallback target (tail)
        // is itself a Model-class entry (e.g. a boundary) — if so, the undo
        // action is still a Model revert, not a UI revert.
        if (undoStack.length == 0) return false;
        uint tailFlags = undoStack[$ - 1].flags;
        return (tailFlags & HistoryFlags.Undoable) != 0
            && (tailFlags & HistoryFlags.UiUndo)   == 0;
    }

    bool undo() {
        if (_lockout) return false;
        if (undoStack.length == 0) return false;

        if (!_classAwareStepping) {
            // Legacy LIFO path (OFF branch — emergency rollback, Stage 6 removes).
            auto e = undoStack[$ - 1];
            undoStack.length -= 1;
            auto prev = _state;
            _state = UndoState.Suspend;
            scope(exit) _state = prev;
            if (!e.cmd.revert()) return false;
            redoStack ~= e;
            ++_undoEpoch;
            return true;
        }

        // T-SEP-cursor: carried-suffix move over the chronological stack.
        //
        // Find the nearest Model-class entry from the tail (mi).
        // Case A — Model entry found (mi < undoStack.length):
        //   Revert undoStack[mi] only. Move the suffix undoStack[mi..$]
        //   (the Model entry + any trailing UI entries) to the FRONT of
        //   redoStack as a unit. The trailing UI entries are carried inert
        //   (no revert() called) — the selection holds (B2).
        // Case B — all-UI tail (mi == undoStack.length, B1 fallback):
        //   The tail is all UI entries and no Model entry exists. Revert
        //   the top UI entry and move it to redo — this is B1 (select A →
        //   select B → undo → A).
        // (R1) ToolLifecycle tail: transparent-vs-step classification.
        // A ToolLifecycle tail entry is transparent (step past to the Model below)
        // iff a Model entry exists below it before any other ToolLifecycle/UndoBoundary.
        // Otherwise it is a hard STEP (revert it alone = re-activate tool).
        if (undoStack.length > 0
            && (undoStack[$ - 1].flags & HistoryFlags.ToolLifecycle) != 0) {
            // Scan downward skipping UiUndo to find first non-UiUndo entry.
            bool foundModel = false;
            size_t si = undoStack.length - 1;
            while (si > 0) {
                --si;
                uint sf = undoStack[si].flags;
                if (sf & HistoryFlags.UndoBoundary) break;
                if (sf & HistoryFlags.ToolLifecycle) break;
                if ((sf & HistoryFlags.UiUndo) != 0) continue;
                // First non-UiUndo, non-lifecycle, non-boundary entry.
                if ((sf & HistoryFlags.Undoable) != 0) foundModel = true;
                break;
            }
            if (!foundModel) {
                // Hard STEP: revert the ToolLifecycle tail entry alone.
                auto e = undoStack[$ - 1];
                undoStack.length -= 1;
                auto prev2 = _state;
                _state = UndoState.Suspend;
                scope(exit) _state = prev2;
                if (!e.cmd.revert()) return false;
                redoStack = [e] ~ redoStack;
                ++_undoEpoch;
                return true;
            }
            // foundModel = true: fall through to the normal Case A path.
            // (R2) will splice the lifecycle entry back after the Model revert.
        }

        size_t mi = nearestModelIndexFromTail();

        if (mi < undoStack.length) {
            // Case A: model entry at index mi.
            auto modelEntry = undoStack[mi];

            // Suspend to keep internal sub-commands off the stack.
            auto prev = _state;
            _state = UndoState.Suspend;
            scope(exit) _state = prev;

            if (!modelEntry.cmd.revert()) {
                // Revert failed — degenerate stuck-stack avoidance. Drop the
                // failed model entry AND the entire trailing suffix [mi..$]
                // from the undo stack (entry count is NOT conserved: the suffix
                // that would have been carried to redoStack is silently
                // discarded). This prevents the cursor from looping on the same
                // broken entry forever. The caller sees false → no redo entry
                // is pushed, and the suffix is gone. A command author who
                // returns false from revert() accepts that the history beyond
                // this point is unrecoverable.
                undoStack = undoStack[0 .. mi];
                return false;
            }

            // (R2) Splice-not-carry: ToolLifecycle entries in the suffix [mi..$]
            // stay on undoStack (they are NOT carried to redo). Only Model + UiUndo go.
            HistoryEntry[] toRedo;
            HistoryEntry[] toKeep;
            foreach (ref se; undoStack[mi .. $]) {
                if (se.flags & HistoryFlags.ToolLifecycle)
                    toKeep ~= se;
                else
                    toRedo ~= se;
            }
            undoStack = undoStack[0 .. mi] ~ toKeep;
            redoStack = toRedo ~ redoStack;
        } else {
            // Case B: no Model entry — B1 fallback, revert the UI head.
            auto e = undoStack[$ - 1];
            undoStack.length -= 1;

            auto prev = _state;
            _state = UndoState.Suspend;
            scope(exit) _state = prev;

            if (!e.cmd.revert()) return false;
            redoStack = [e] ~ redoStack;
        }

        ++_undoEpoch;  // bump exactly once per successful undo
        g_perf.count(Cat.undoApply, 1);  // task 0200 F-I7 (no-op in default build)
        return true;
    }

    bool redo() {
        if (_lockout) return false;
        if (redoStack.length == 0) return false;

        if (!_classAwareStepping) {
            // Legacy LIFO path.
            auto e = redoStack[$ - 1];
            redoStack.length -= 1;
            auto prev = _state;
            _state = UndoState.Suspend;
            scope(exit) _state = prev;
            if (!e.cmd.apply()) return false;
            undoStack ~= e;
            return true;
        }

        // Mirror of (R1): a ToolLifecycle head on the redo stack is a lifecycle
        // step — re-apply it alone (re-drop the tool, geometry no-op), move it
        // alone back to undoStack tail. Do NOT let it fall into the Model branch.
        if ((redoStack[0].flags & HistoryFlags.ToolLifecycle) != 0) {
            auto e = redoStack[0];
            redoStack = redoStack[1 .. $];
            auto prev2 = _state;
            _state = UndoState.Suspend;
            scope(exit) _state = prev2;
            if (!e.cmd.apply()) return false;
            undoStack ~= e;
            return true;
        }

        // T-SEP-cursor redo: inverse of the carried-suffix undo.
        //
        // The redo stack is organised so that the LEADING block
        // (redoStack[0 .. blockLen]) is exactly the suffix that the
        // matching undo detached as a unit. The first entry of that block
        // is the Model entry (or, for a B1 fallback, the lone UI entry).
        // We re-apply ONLY that first entry, then move the whole leading
        // block back onto the undoStack tail in its original order.
        //
        // Determining block length: a block is delimited by the first
        // Model-class entry at or after index 0 of the redo stack, plus
        // all UI entries that follow it until the next Model entry (or
        // end). Equivalently: the block spans from index 0 to (and
        // including) the last consecutive UI entry before the NEXT
        // Model entry.
        //
        // B1 fallback block: if redoStack[0] is itself UI-class, the
        // undo that put it there was a B1-fallback (lone UI undo). The
        // block is just that one UI entry.
        size_t blockLen = 1; // at minimum we pop redoStack[0]
        {
            uint f0 = redoStack[0].flags;
            bool head0isUi = (f0 & HistoryFlags.UiUndo) != 0;

            if (!head0isUi) {
                // redoStack[0] is the Model entry. The block also includes
                // the run of UI entries immediately following it (those were
                // carried inert by the undo that moved this block).
                size_t j = 1;
                while (j < redoStack.length) {
                    uint fj = redoStack[j].flags;
                    // Stop at the next Model entry — it belongs to a
                    // different undo block.
                    if ((fj & HistoryFlags.Undoable) && !(fj & HistoryFlags.UiUndo)
                        && !(fj & HistoryFlags.ToolLifecycle))
                        break;
                    if (fj & HistoryFlags.ToolLifecycle) break; // also stop at lifecycle
                    ++j;
                }
                blockLen = j;
            }
            // If head0isUi: B1-fallback block = just redoStack[0].
        }

        // The model entry to re-apply is always redoStack[0].
        auto modelEntry = redoStack[0];

        auto prev = _state;
        _state = UndoState.Suspend;
        scope(exit) _state = prev;

        if (!modelEntry.cmd.apply()) return false;

        // Re-apply the UI suffix entries in the block (indices 1 .. blockLen-1).
        // These are the selection/edit-mode entries that were carried INERT by
        // the matching undo; on redo they ARE re-applied so the round-trip
        // restores the selection to the state it was in after the original
        // recording. Only the geometry undo carries them inert (B2 invariant);
        // redo always restores the full block's effect.
        foreach (k; 1 .. blockLen) {
            // Best-effort: if a UI entry fails to re-apply, continue so the
            // geometry redo still lands. A failing selection re-apply leaves the
            // selection at whatever state it was in before — graceful degradation.
            redoStack[k].cmd.apply();
        }

        // Move the block [0 .. blockLen] from redoStack front to undoStack tail.
        HistoryEntry[] block = redoStack[0 .. blockLen].dup;
        redoStack = redoStack[blockLen .. $];
        undoStack ~= block;

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
        // ToolLifecycle entries (tool.deactivate) are not registered as command
        // factories and cannot be replayed via commandHandlerDelegate. Return ""
        // so both history.saveAsScript and the panel replay button skip them.
        if (e.flags & HistoryFlags.ToolLifecycle) return "";
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

    /// Whether the next undo would step a ToolLifecycle entry (re-activate tool).
    bool canUndoLifecycle() const {
        if (!_classAwareStepping) return false;
        if (undoStack.length == 0) return false;
        uint tf = undoStack[$ - 1].flags;
        if (!(tf & HistoryFlags.ToolLifecycle)) return false;
        // Same scan as (R1): is there a Model below before another lifecycle/boundary?
        size_t si = undoStack.length - 1;
        while (si > 0) {
            --si;
            uint sf = undoStack[si].flags;
            if (sf & HistoryFlags.UndoBoundary) return true; // hard step
            if (sf & HistoryFlags.ToolLifecycle) return true; // hard step
            if ((sf & HistoryFlags.UiUndo) != 0) continue;
            if ((sf & HistoryFlags.Undoable) != 0) return false; // transparent
            break;
        }
        return true; // bottom of stack = hard step
    }

    size_t toolLifecycleCount() const {
        size_t n = 0;
        foreach_reverse (ref e; undoStack) {
            if (e.flags & HistoryFlags.UndoBoundary) break;
            if (e.flags & HistoryFlags.ToolLifecycle) ++n;
        }
        return n;
    }

    /// undo entries EXCLUDING ToolLifecycle — for /api/history serialization.
    const(HistoryEntry)[] undoEntriesVisible() const {
        const(HistoryEntry)[] result;
        foreach (ref e; undoStack)
            if (!(e.flags & HistoryFlags.ToolLifecycle))
                result ~= e;
        return result;
    }
    const(HistoryEntry)[] redoEntriesVisible() const {
        const(HistoryEntry)[] result;
        foreach (ref e; redoStack)
            if (!(e.flags & HistoryFlags.ToolLifecycle))
                result ~= e;
        return result;
    }

    /// Like jumpTo but `target` is expressed in filtered (non-lifecycle)
    /// coordinates — i.e. the desired number of VISIBLE entries that should
    /// be in the "applied" (undo) stack. Maps to internal coordinates by
    /// stepping undo/redo until visible count matches.
    bool jumpToVisible(size_t filteredTarget) {
        // Compute total visible entries (for clamping).
        size_t totalVisible = 0;
        foreach (ref e; undoStack)
            if (!(e.flags & HistoryFlags.ToolLifecycle)) ++totalVisible;
        foreach (ref e; redoStack)
            if (!(e.flags & HistoryFlags.ToolLifecycle)) ++totalVisible;
        if (filteredTarget > totalVisible) filteredTarget = totalVisible;
        while (true) {
            size_t vis = 0;
            foreach (ref e; undoStack)
                if (!(e.flags & HistoryFlags.ToolLifecycle)) ++vis;
            if (vis == filteredTarget) break;
            if (vis > filteredTarget) { if (!undo()) return false; }
            else                      { if (!redo()) return false; }
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

    version(unittest)
    void pushEntryForTest(Command cmd, uint extraFlags = 0) {
        uint flags = historyFlagsFor(cmd) | extraFlags;
        HistoryEntry e = { label: cmd.name, args: "", commandName: cmd.name,
                           cmd: cmd, timestampMs: 0, flags: flags };
        undoStack ~= e;
    }
}

// ---------------------------------------------------------------------------
// Phase 0 unit tests: undoEpoch is bumped exactly once per successful undo.
// No GL context needed — uses a trivial revert()=true stub command.
// ---------------------------------------------------------------------------
version (unittest) {
    private final class _EpochTestCmd : Command {
        import mesh    : Mesh;
        import view    : View;
        import editmode : EditMode;
        private Mesh  _mesh;
        private View  _view = new View(0, 0, 1, 1);
        this() { super(&_mesh, _view, EditMode.Vertices); }
        override string   name()  const { return "test.epoch"; }
        override string   label() const { return "EpochTest"; }
        override CmdFlags cmdFlags() const { return CmdFlags.Model; }
        override bool apply()  { return true; }
        override bool revert() { return true; }
    }

    // Stub command for class-aware stepping unit tests.
    // Tracks how many times apply()/revert() were called — used to verify
    // UI entries are carried INERT during a model step (no revert()).
    private final class _TrackedCmd : Command {
        import mesh     : Mesh;
        import view     : View;
        import editmode : EditMode;
        private Mesh  _mesh;
        private View  _view = new View(0, 0, 1, 1);
        CmdFlags _flags;
        int applyCalls  = 0;
        int revertCalls = 0;
        this(CmdFlags f) {
            super(&_mesh, _view, EditMode.Vertices);
            _flags = f;
        }
        override string   name()     const { return "test.tracked"; }
        override string   label()    const { return "Tracked"; }
        override CmdFlags cmdFlags() const { return _flags; }
        override bool apply()  { ++applyCalls;  return true; }
        override bool revert() { ++revertCalls; return true; }
    }

    // Convenience: record a Model-class entry.
    private void recModel(_TrackedCmd cmd, CommandHistory h) {
        cmd.apply(); h.record(cmd);
    }
    // Convenience: record a UiState-class entry.
    private void recUi(_TrackedCmd cmd, CommandHistory h) {
        cmd.apply(); h.record(cmd);
    }
}

unittest { // record→undo bumps undoEpoch by 1; redo does NOT bump
    auto h = new CommandHistory();
    assert(h.undoEpoch == 0);

    auto cmd = new _EpochTestCmd();
    cmd.apply();
    h.record(cmd);
    assert(h.undoEpoch == 0, "record must not bump epoch");

    assert(h.undo());
    assert(h.undoEpoch == 1, "undo must bump epoch to 1");

    assert(h.redo());
    assert(h.undoEpoch == 1, "redo must NOT bump epoch");

    assert(h.undo());
    assert(h.undoEpoch == 2, "second undo bumps to 2");
}

unittest { // consolidate does NOT bump undoEpoch
    import mesh    : Mesh, GpuMesh;
    import view    : View;
    import editmode : EditMode;
    import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
    import commands.mesh.vertex_edit : MeshVertexEdit;
    import math : Vec3;

    auto h = new CommandHistory();
    assert(h.undoEpoch == 0);

    // record two in-session entries and consolidate — epoch stays 0
    auto run = h.nextRun();
    Mesh mesh;
    View view = new View(0, 0, 1, 1);
    GpuMesh gpu;
    VertexCache vc; EdgeCache ec; FaceBoundsCache fc;

    auto e1 = new MeshVertexEdit(&mesh, view, EditMode.Vertices, &gpu, &vc, &ec, &fc);
    e1.setEdit([0u], [Vec3(0,0,0)], [Vec3(1,0,0)], "e1");
    h.recordInSession(e1, run);

    auto e2 = new MeshVertexEdit(&mesh, view, EditMode.Vertices, &gpu, &vc, &ec, &fc);
    e2.setEdit([0u], [Vec3(1,0,0)], [Vec3(2,0,0)], "e2");
    h.recordInSession(e2, run);

    h.consolidate(run);
    assert(h.undoEpoch == 0, "consolidate must not bump epoch");
}

// ---------------------------------------------------------------------------
// Class-aware stepping unit tests (T-SEP-cursor).
// All use _TrackedCmd stubs — no GL context needed.
// ---------------------------------------------------------------------------

// B1 analogue: pure-UI stack → undo falls back to the UI head.
// Stack: [UI-A, UI-B] → undo → reverts UI-B → stack: [UI-A].
unittest {
    auto h = new CommandHistory();
    // Force env-var to ON regardless of the test environment.
    h.setClassAwareStepping(true);

    auto uiA = new _TrackedCmd(CmdFlags.UiState);
    auto uiB = new _TrackedCmd(CmdFlags.UiState);
    recUi(uiA, h);
    recUi(uiB, h);
    assert(h.undoStack.length == 2, "B1 setup: expected 2 entries");

    size_t mc, uc;
    h.undoDepthCounts(mc, uc);
    assert(mc == 0 && uc == 2, "B1: 0 model, 2 UI before undo");

    // undo → B1 fallback: revert UI-B.
    assert(h.undo(), "B1: undo should succeed");
    assert(uiB.revertCalls == 1, "B1: UI-B must be revert()'d once");
    assert(uiA.revertCalls == 0, "B1: UI-A must NOT be revert()'d");
    assert(h.undoStack.length == 1,  "B1: undoStack should have 1 entry");
    assert(h.redoStack.length == 1,  "B1: redoStack should have 1 entry");
    assert(h.undoEpoch == 1, "B1: epoch bumped");
}

// B2 analogue: [UI-A, Model-mA, UI-B, Model-mB] → undo×2.
// undo₁: suffix=[Model-mB] → reverts mB; UI-B NOT revert()'d.
// undo₂: suffix=[Model-mA, UI-B] → reverts mA; UI-B carried inert.
// Chronology: UI-B is never revert()'d during either model undo.
unittest {
    auto h = new CommandHistory();
    h.setClassAwareStepping(true);

    auto uiA  = new _TrackedCmd(CmdFlags.UiState);
    auto modA = new _TrackedCmd(CmdFlags.Model);
    auto uiB  = new _TrackedCmd(CmdFlags.UiState);
    auto modB = new _TrackedCmd(CmdFlags.Model);
    recUi(uiA, h);
    recModel(modA, h);
    recUi(uiB, h);
    recModel(modB, h);
    assert(h.undoStack.length == 4, "B2 setup: expected 4 entries");

    size_t mc, uc;
    h.undoDepthCounts(mc, uc);
    assert(mc == 2 && uc == 2, "B2: 2 model, 2 UI");

    // undo₁: nearest Model from tail = modB (index 3). suffix=[modB].
    assert(h.undo(), "B2 undo₁ should succeed");
    assert(modB.revertCalls == 1, "B2 undo₁: modB revert()'d");
    assert(uiB.revertCalls  == 0, "B2 undo₁: uiB NOT revert()'d (carried inert)");
    assert(uiA.revertCalls  == 0, "B2 undo₁: uiA NOT revert()'d");
    assert(modA.revertCalls == 0, "B2 undo₁: modA NOT revert()'d");
    // undoStack: [uiA, modA, uiB], redoStack: [modB]
    assert(h.undoStack.length == 3, "B2 undo₁: undoStack has 3");
    assert(h.redoStack.length == 1, "B2 undo₁: redoStack has 1");

    // undo₂: nearest Model from tail = modA (index 1). suffix=[modA, uiB].
    assert(h.undo(), "B2 undo₂ should succeed");
    assert(modA.revertCalls == 1, "B2 undo₂: modA revert()'d");
    assert(uiB.revertCalls  == 0, "B2 undo₂: uiB still NOT revert()'d (carried inert)");
    assert(uiA.revertCalls  == 0, "B2 undo₂: uiA NOT revert()'d");
    // undoStack: [uiA], redoStack: [modA, uiB, modB]
    assert(h.undoStack.length == 1, "B2 undo₂: undoStack has 1");
    assert(h.redoStack.length == 3, "B2 undo₂: redoStack has 3");
    assert(h.undoEpoch == 2, "B2: epoch == 2 after two undos");
}

// CHRONOLOGY: [UI-A, Model-mA, UI-B, Model-mB] → undo×ALL → redo×ALL.
// After the full round-trip the undo stack must have the SAME 4 entries
// in the SAME order, and revert()/apply() must have been called ONLY on
// model entries during model steps (UI entries carried inert).
unittest {
    auto h = new CommandHistory();
    h.setClassAwareStepping(true);

    auto uiA  = new _TrackedCmd(CmdFlags.UiState);
    auto modA = new _TrackedCmd(CmdFlags.Model);
    auto uiB  = new _TrackedCmd(CmdFlags.UiState);
    auto modB = new _TrackedCmd(CmdFlags.Model);
    recUi(uiA, h);
    recModel(modA, h);
    recUi(uiB, h);
    recModel(modB, h);

    // Snapshot the initial stack order by cmd identity.
    Command[] initialOrder;
    foreach (ref e; h.undoStack) initialOrder ~= e.cmd;

    // Undo all the way down.
    while (h.canUndo()) h.undo();

    // Stack: empty; redo has all 4.
    assert(h.undoStack.length == 0, "CHRON: undoStack empty after full undo");
    assert(h.redoStack.length == 4, "CHRON: redoStack has 4 after full undo");

    // UI entries were NEVER revert()'d during model steps.
    assert(uiA.revertCalls == 1,
        "CHRON: uiA should be revert()'d once (B1 fallback at the end)");
    assert(uiB.revertCalls == 0,
        "CHRON: uiB must NOT be revert()'d (always carried inert)");
    assert(modA.revertCalls == 1, "CHRON: modA revert()'d once");
    assert(modB.revertCalls == 1, "CHRON: modB revert()'d once");

    // Reset apply counters so we can count redo-apply calls.
    uiA.applyCalls = 0; modA.applyCalls = 0;
    uiB.applyCalls = 0; modB.applyCalls = 0;

    // Redo all the way back up.
    while (h.canRedo()) h.redo();

    // Stack restored to 4 entries; redo empty.
    assert(h.undoStack.length == 4, "CHRON: undoStack restored to 4 after full redo");
    assert(h.redoStack.length == 0, "CHRON: redoStack empty after full redo");

    // Verify original chronological order is preserved.
    foreach (i, ref e; h.undoStack) {
        import std.conv : to;
        assert(e.cmd is initialOrder[i],
            "CHRON: entry " ~ i.to!string ~ " is wrong cmd after round-trip");
    }

    // Model entries are re-applied during their redo block.
    // uiA was B1-reverted during undo → its redo block is B1 (just uiA) → apply()'d once.
    // modA's redo block = [modA, uiB]: modA is re-applied AND the UI suffix uiB is
    //   re-applied so the round-trip restores the full selection/active-layer state.
    // uiB was NEVER revert()'d during undo (carried inert), but IS apply()'d during
    //   its redo (as the UI suffix of modA's block) to restore the selection state.
    // modB's redo block = [modB] (no UI suffix) → modB is re-applied once.
    assert(modA.applyCalls == 1, "CHRON redo: modA apply()'d once");
    assert(modB.applyCalls == 1, "CHRON redo: modB apply()'d once");
    assert(uiA.applyCalls  == 1, "CHRON redo: uiA apply()'d once (it was B1-reverted)");
    assert(uiB.applyCalls  == 1, "CHRON redo: uiB apply()'d once (UI suffix of modA block, restores selection state)");
}

// OFF path: class-aware OFF → legacy LIFO, all 4 entries reverted in order.
unittest {
    auto h = new CommandHistory();
    h.setClassAwareStepping(false);

    auto uiA  = new _TrackedCmd(CmdFlags.UiState);
    auto modA = new _TrackedCmd(CmdFlags.Model);
    auto uiB  = new _TrackedCmd(CmdFlags.UiState);
    auto modB = new _TrackedCmd(CmdFlags.Model);
    recUi(uiA, h);
    recModel(modA, h);
    recUi(uiB, h);
    recModel(modB, h);

    // undo×4: legacy LIFO reverts every entry in reverse.
    assert(h.undo()); assert(modB.revertCalls == 1);
    assert(h.undo()); assert(uiB.revertCalls  == 1); // LIFO hits uiB
    assert(h.undo()); assert(modA.revertCalls  == 1);
    assert(h.undo()); assert(uiA.revertCalls   == 1);
    assert(!h.undo(), "OFF: stack empty, undo must fail");
}

version(unittest) {
    // Hand-built stack matching the §Derived trace (two gestures A then B):
    // [SelA(UiUndo), geomA(Model), DeactA(ToolLifecycle),
    //  SelB(UiUndo), geomB(Model), DeactB(ToolLifecycle)]
    // Walk: undo₁=geom(True), undo₂=reenter(False), undo₃=geom(True), undo₄=reenter(False)
    unittest {
        import std.stdio : writeln;

        auto h = new CommandHistory();
        h.setClassAwareStepping(true);

        static class StubModel : Command {
            import mesh     : Mesh;
            import view     : View;
            import editmode : EditMode;
            bool reverted = false;
            bool applied  = false;
            private Mesh  _mesh;
            private View  _view = new View(0, 0, 1, 1);
            this() {
                super(&_mesh, _view, EditMode.Vertices);
            }
            override string name() const { return "stub.model"; }
            override CmdFlags cmdFlags() const { return CmdFlags.Model; }
            override bool apply()  { applied = true;  return true; }
            override bool revert() { reverted = true; return true; }
        }
        static class StubUi : Command {
            import mesh     : Mesh;
            import view     : View;
            import editmode : EditMode;
            private Mesh  _mesh;
            private View  _view = new View(0, 0, 1, 1);
            this() {
                super(&_mesh, _view, EditMode.Vertices);
            }
            override string name() const { return "stub.ui"; }
            override CmdFlags cmdFlags() const { return CmdFlags.UiState; }
            override bool apply()  { return true; }
            override bool revert() { return true; }
        }
        static class StubLifecycle : Command {
            import mesh     : Mesh;
            import view     : View;
            import editmode : EditMode;
            bool reverted = false;
            bool applied  = false;
            private Mesh  _mesh;
            private View  _view = new View(0, 0, 1, 1);
            this() {
                super(&_mesh, _view, EditMode.Vertices);
            }
            override string name() const { return "tool.deactivate"; }
            override CmdFlags cmdFlags() const { return CmdFlags.ToolLifecycle; }
            override bool apply()  { applied = true;  return true; }
            override bool revert() { reverted = true; return true; }
        }

        auto selA   = new StubUi();
        auto geomA  = new StubModel();
        auto deactA = new StubLifecycle();
        auto selB   = new StubUi();
        auto geomB  = new StubModel();
        auto deactB = new StubLifecycle();

        h.pushEntryForTest(selA);
        h.pushEntryForTest(geomA);
        h.pushEntryForTest(deactA);
        h.pushEntryForTest(selB);
        h.pushEntryForTest(geomB);
        h.pushEntryForTest(deactB);

        assert(h.undoStack.length == 6);

        // undo₁: tail=DeactB (ToolLifecycle), geomB below → transparent → revert geomB.
        bool u1 = h.undo();
        assert(u1, "undo₁ should succeed");
        assert(geomB.reverted, "undo₁ should revert geomB");
        assert(!deactB.reverted, "undo₁ should NOT revert DeactB (transparent)");
        // DeactB stays on undoStack (R2 splice).
        bool deactBOnUndo = false;
        foreach (ref e; h.undoStack)
            if (e.cmd is deactB) deactBOnUndo = true;
        assert(deactBOnUndo, "DeactB must stay on undoStack after undo₁ (R2 splice)");

        // undo₂: tail=DeactB, below=DeactA (lifecycle) → hard STEP → revert DeactB alone.
        bool u2 = h.undo();
        assert(u2, "undo₂ should succeed");
        assert(deactB.reverted, "undo₂ should revert DeactB (hard step)");
        assert(!geomA.reverted, "undo₂ should NOT touch geomA");

        // undo₃: revert geomA.
        bool u3 = h.undo();
        assert(u3, "undo₃ should succeed");
        assert(geomA.reverted, "undo₃ should revert geomA");

        // undo₄: hard step DeactA.
        bool u4 = h.undo();
        assert(u4, "undo₄ should succeed");
        assert(deactA.reverted, "undo₄ should revert DeactA (hard step)");

        writeln("command_history lifecycle unittest: PASS");
    }
}
