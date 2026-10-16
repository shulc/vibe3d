module history_lifecycle_contract;

import vibe3d.editing.contracts.tool_policy_values : DropUndoPolicy;

interface ToolArmLifecyclePolicy {
    string armedId() const;
    string previousId() const;
    bool carriesRedoAfterUndo() const;
    bool joinsFirstGroup() const;
    /// K-RD rule 2: the undo of this row also undoes the rows of
    /// the session `previousToken` names, below it (a drop row only).
    bool dropRow() const;
    DropUndoPolicy dropUndoPolicy() const;
    void completeDropUndo();
    ulong previousToken() const;
}

