module commands.tool.lifecycle;

import command;
import mesh;
import view;
import editmode;
import seltype : SelType;

// ---------------------------------------------------------------------------
// ToolActivationCommand — tool.activate
//
// Records that a tool was armed, with the previously active tool as its undo
// image. Emitted after a prepared tool transition installs successfully.
//
// revert() (undo) = restore the predecessor identity. Geometry no-op.
// apply()  (redo) = re-activate the armed tool. Geometry no-op.
//
// The history cursor treats this entry as an ordinary strict-LIFO step.
// Undo restores the captured predecessor before any earlier UI or Model entry.
// ---------------------------------------------------------------------------
interface ToolArmLifecyclePolicy {
    string armedId() const;
    string previousId() const;
    bool carriesRedoAfterUndo() const;
    bool joinsFirstGroup() const;
    /// K-RD rule 2 (task 9508): the undo of this row also undoes the rows of
    /// the session `previousToken` names, below it (a drop row only).
    bool revertsSession() const;
    ulong previousToken() const;
}

class ToolActivationCommand : Command, ToolArmLifecyclePolicy {
    private string armedId_;
    private string previousId_;
    // Slice M3 — DATA the arm decided, replacing the id list this row used to
    // read. `sessionSteps_`: the armed tool's session owns its gesture steps
    // (`ToolSessionPolicy.sessionSteps`). `joinsFirstGroup_`: the arm came
    // through the key/UI door (`ArmDoor.key`), so the undo that removes the
    // window's first group also pops this row (C-H1-door, gap 300); a
    // script-door row is its own undo step.
    private bool sessionSteps_;
    private bool historyRecordedSteps_;
    private bool joinsFirstGroup_;
    // Slice M4 — `recordCarries_`: the armed tool's policy says the record
    // that closes its window's first operation carries this row (gap 218).
    // The row's own session token is `Command.sessionToken` (the arm's);
    // `previousToken_` is the predecessor's, which a restore hands back to it
    // so the restored instance continues ITS session (gap 221/241).
    private bool recordCarries_;
    private ulong previousToken_;
    // Whether the predecessor itself writes activation rows (review of slice
    // M4): the redo of this row is kept only over a predecessor that does NOT
    // (the none->session law of gap 205 / §22 counts an unclassified
    // predecessor as "none"), whatever `previousId_` now records for the restore.
    private bool previousClassified_;
    private bool previousHistoryTopology_;
    private bool dormantTopology_;
    // Wave plan 8640 S6: a DROP row (armed = none), written by a user drop of
    // a tool whose policy says `dropWritesRow` (`ToolSession.finishClose`).
    // Stored, never derived from `armedId == ""`: its undo empties the redo
    // stack (L32, `carriesRedoAfterUndo`), so its redo is unreachable.
    private bool dropRow_;
    private bool flipsSelType_;
    private SelType selBefore_;
    private bool revertsSession_;

    // Hooks wired by app.d after construction.
    void delegate(string) onActivate;
    void delegate() onDeactivate;
    // S6: restores a selection type through the funnel that does NOT drop the
    // tool (app.d `promoteGeometryType` / `promoteItemType`).
    void delegate(SelType) onRestoreSelType;

    this(Mesh* mesh, ref View view, EditMode editMode,
         string armedId, string previousId,
         bool sessionSteps = false, bool joinsFirstGroup = false,
         bool recordCarries = false, ulong sessionToken = 0,
         ulong previousToken = 0, bool previousClassified = false,
         bool previousHistoryTopology = false,
         bool historyRecordedSteps = false, bool dropRow = false) {
        super(mesh, view, editMode);
        armedId_ = armedId.idup;
        previousId_ = previousId.idup;
        sessionSteps_ = sessionSteps;
        historyRecordedSteps_ = historyRecordedSteps;
        joinsFirstGroup_ = joinsFirstGroup;
        recordCarries_ = recordCarries;
        previousToken_ = previousToken;
        previousClassified_ = previousClassified;
        previousHistoryTopology_ = previousHistoryTopology;
        dropRow_ = dropRow;
        markSession(sessionToken);
        // The whole undo image is the predecessor identity. It exists from the
        // constructor, so the flag is raised there.
        noteUndoRecorded();
    }

    override string name()  const { return "tool.activate"; }
    override string label() const { return dropRow_ ? "Tool Drop" : "Activate Tool"; }

    override CmdFlags cmdFlags() const { return CmdFlags.ToolLifecycle; }

    // Redo exists only for the captured none->session law (a tool whose
    // session owns its steps, armed over no predecessor — gap row 205). The
    // session's first gesture is NOT re-applied here: the session replays it
    // after this redo (ToolSession.redo, task 7137, §22), so the raw redo doors
    // re-arm bare.
    // A drop row (S6) is never redone: its undo empties the redo stack (L32),
    // so it has no arm to re-apply (wave plan 8640 [A6-n7]).
    protected override bool applyImpl() {
        if (armedId_.length != 0 && onActivate !is null) onActivate(armedId_);
        return true;
    }

    // Undo restores the predecessor (whichever tool it was: slice M4, the
    // C-M4-token switch twin), or leaves no active family. The predecessor
    // re-arms through the replay arm, which recalls the values its drop stored
    // (the per-preset cache, slice M5); the session hands it its token.
    protected override void revertImpl() {
        if (previousId_.length == 0) {
            if (onDeactivate !is null) onDeactivate();
        } else if (onActivate !is null) {
            onActivate(previousId_);
        }
        // S6 (drop-sel, captured C1-X-sel z1): a drop row of a selection-type
        // key restores the type the key left. The two legs commute, so their
        // order is not a claim: the restore goes through the promote funnel,
        // which never drops a tool, and no `dropWritesRow` tool reads the
        // selection type when it arms (the Topology Pen only, pinned by the
        // policy census). A declarer whose arm reads it makes the order a
        // law to capture, not to pick.
        if (flipsSelType_ && onRestoreSelType !is null)
            onRestoreSelType(selBefore_);
    }

    string armedId() const { return armedId_; }
    string previousId() const { return previousId_; }
    bool carriesRedoAfterUndo() const {
        // L32 (captured X-bare-redo, X-sel-redo): undoing a drop row empties
        // the redo stack, before every other term (wave plan 8640 [A6-1]).
        if (dropRow_) return false;
        return dormantTopology_ || previousHistoryTopology_ ||
            (sessionSteps_ && !historyRecordedSteps_ && !previousClassified_);
    }
    bool dropRow() const { return dropRow_; }
    /// S6: the selection type a drop row's undo restores (a drop by a
    /// selection-type key only).
    void restoresSelType(SelType before) {
        flipsSelType_ = true;
        selBefore_ = before;
    }
    void markRevertsSession() { revertsSession_ = true; }
    bool revertsSession() const { return dropRow_ && revertsSession_ && previousToken_ != 0; }
    void markDormantTopology() { dormantTopology_ = true; }
    bool dormantTopology() const { return dormantTopology_; }
    bool previousHistoryTopology() const { return previousHistoryTopology_; }
    bool joinsFirstGroup() const { return joinsFirstGroup_; }
    /// Whether the record closing this session's first operation is undone
    /// together with this row (slice M4, gap 218): the arm's policy, and only
    /// for a row that joined the first group (the key/UI door).
    bool carriesFirstRecord() const { return recordCarries_ && joinsFirstGroup_; }
    ulong previousToken() const { return previousToken_; }
    /// The mesh the armed tool edits (the first-gesture replay checks it is
    /// the same mesh, unchanged, before re-seating the gesture).
    inout(Mesh)* armedMesh() inout { return mesh; }
}

// ---------------------------------------------------------------------------
// ToolTaskClearCommand — the empty row the Esc rung writes above a drop row
// (wave plan 8640 S6, L39; captured X-esc, X-esc-r R-task): it changes
// nothing, its undo keeps the redo stack, and its redo brings it back.
// ---------------------------------------------------------------------------
class ToolTaskClearCommand : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
        noteUndoRecorded();
    }
    override string name()  const { return "tool.taskClear"; }
    override string label() const { return "Clear Tool Task"; }
    override CmdFlags cmdFlags() const { return CmdFlags.ToolLifecycle; }
    protected override bool applyImpl() { return true; }
    protected override void revertImpl() {}
}
