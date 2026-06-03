module commands.mesh.selection_edit;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

/// Record-flavor selection command (the mutation has ALREADY happened —
/// captured before/after the interactive picking / lasso / clear path).
/// apply() restores `after`; revert() restores `before`. Mirrors the role
/// of MeshVertexEdit but for selection state.
///
/// Used by app.d's interactive selection wrapping in handleMouseButtonDown
/// / handleMouseButtonUp: capture before on LMB-down (or RMB-down for
/// lasso), capture after on the matching mouse-up, and record one entry.
class MeshSelectionEdit : Command, Operator {
    mixin OperatorActrCommon;
    private EditMode*         editModePtr;
    private SelectionSnapshot before;
    private SelectionSnapshot after;
    private EditMode          beforeMode;
    private EditMode          afterMode;

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr) {
        super(mesh, view, editMode);
        this.editModePtr = editModePtr;
    }

    override string name()  const { return "mesh.selection_edit"; }
    override string label() const { return "Select"; }

    // Selection is undoable but in the UI-undo class, NOT Model-undo: it lands
    // on the same stack and Ctrl+Z reverts it, but history/panel/tests can tell
    // it apart from geometry edits (migration P5 — supersedes the earlier Model
    // classification).
    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }

    /// Coalescing predicate (P5): consecutive selection edits of the SAME
    /// gesture chain collapse into ONE undo entry. `prev` is COMPATIBLE iff it
    /// is also a MeshSelectionEdit whose AFTER edit mode matches THIS edit's
    /// BEFORE mode (the links are contiguous and in the same mode). A mode flip
    /// between them, or any non-selection top entry, breaks the run → Different
    /// → a fresh entry (the automatic gesture boundary, like P2's vertex-edit
    /// coalescing).
    override CompareResult compareOp(const Command prev) const {
        auto p = cast(const(MeshSelectionEdit))prev;
        if (p is null) return CompareResult.Different;
        if (p.afterMode != this.beforeMode) return CompareResult.Different;
        return CompareResult.Compatible;
    }

    /// In-place merge of a newer, COMPATIBLE selection edit into this (the
    /// existing top entry): KEEP this entry's older `before`/`beforeMode` (the
    /// selection before the FIRST click of the run) and ADOPT `newer`'s
    /// `after`/`afterMode` (the latest selection). One undo then unwinds the
    /// whole run back to the pre-run selection.
    override bool mergeFrom(Command newer) {
        auto n = cast(MeshSelectionEdit)newer;
        if (n is null) return false;
        this.after     = n.after;
        this.afterMode = n.afterMode;
        return true;
    }

    void setBefore(SelectionSnapshot s, EditMode m) {
        this.before     = s;
        this.beforeMode = m;
    }
    void setAfter(SelectionSnapshot s, EditMode m) {
        this.after     = s;
        this.afterMode = m;
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        after.restore(*mesh);
        *editModePtr = afterMode;
        return true;
    }

    override bool revert() {
        before.restore(*mesh);
        *editModePtr = beforeMode;
        return true;
    }
}
