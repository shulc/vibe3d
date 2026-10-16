module commands.select.drop;

import command;
import vibe3d.mesh.core.mesh;
import vibe3d.viewport.camera.view;
import vibe3d.editing.contracts.editmode;
import vibe3d.editing.params.params : Param, wireArgs;
import vibe3d.mesh.snapshot.snapshot : SelectionSnapshot;

// Drop owns an ordered component image and restores the prior component mode
// through the host's promotion door, including accepted empty invocations.
// Task 20261900; doc/application_layers_wave3_plan_2026-10-09.md, Slice3A.
class SelectDropCommand : Command {
    private string targetType;
    private bool typePresent;
    private SelectionSnapshot snap;
    private EditMode* modeCell;
    private EditMode priorMode;
    private void delegate(EditMode) promoteType;

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* modeCell = null) {
        super(mesh, view, editMode);
        this.modeCell = modeCell;
    }

    SelectDropCommand setPromoteHook(void delegate(EditMode) hook) {
        promoteType = hook;
        return this;
    }

    override string name() const { return "select.drop"; }
    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }

    override Param[] params() {
        return wireArgs(Param.string_("type", "Type", &targetType, "").present(&typePresent));
    }

    void setTargetType(string t) { targetType = t; typePresent = true; }

    private void applyMode(EditMode mode) {
        if (promoteType !is null) promoteType(mode);
        else if (modeCell !is null) *modeCell = mode;
    }

    protected override bool applyImpl() {
        if (!typePresent) throw new Exception("select.drop: type is required");
        EditMode targetMode;
        switch (targetType) {
            case "vertex": targetMode = EditMode.Vertices; break;
            case "edge": targetMode = EditMode.Edges; break;
            case "polygon": targetMode = EditMode.Polygons; break;
            default:
                throw new Exception("select.drop: unknown type '" ~ targetType
                    ~ "' — expected vertex, edge, or polygon");
        }
        mesh.syncSelection();
        snap = SelectionSnapshot.capture(*mesh);
        priorMode = modeCell is null ? editMode : *modeCell;
        noteUndoRecorded();
        final switch (targetMode) {
            case EditMode.Vertices: mesh.clearVertexSelection(); break;
            case EditMode.Edges: mesh.clearEdgeSelection(); break;
            case EditMode.Polygons: mesh.clearFaceSelection(); break;
        }
        applyMode(targetMode);
        return true;
    }

    protected override void revertImpl() {
        snap.restore(*mesh);
        applyMode(priorMode);
    }
}
