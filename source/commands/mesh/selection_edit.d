module commands.mesh.selection_edit;

import command;
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
class MeshSelectionEdit : Command {
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

    void setBefore(SelectionSnapshot s, EditMode m) {
        this.before     = s;
        this.beforeMode = m;
    }
    void setAfter(SelectionSnapshot s, EditMode m) {
        this.after     = s;
        this.afterMode = m;
    }

    override bool apply() {
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
