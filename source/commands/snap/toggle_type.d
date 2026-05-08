module commands.snap.toggle_type;

import command;
import mesh;
import view;
import editmode;

import toolpipe.pipeline       : g_pipeCtx;
import toolpipe.stages.snap    : SnapStage;
import toolpipe.stage          : TaskCode;

// ---------------------------------------------------------------------------
// `snap.toggleType <name>` — flip a single SnapType bit in the
// SnapStage's `enabledTypes` mask. Powers the Snap popup's per-type
// checkboxes (see config/statusline.yaml).
//
// Wire format (from argstring):
//   positional[0] = type name (e.g. "vertex", "edgeCenter", "grid")
//
// Recognised type names match the strings accepted by SnapStage's
// setAttr("types", ...) parser. Delegates the bit-flip to the stage
// via setAttr("typeToggle", <name>) so all mutation goes through one
// path (which also takes care of re-publishing popup_state).
// ---------------------------------------------------------------------------
class SnapToggleTypeCommand : Command {
    private string typeName_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "snap.toggleType"; }
    override string label() const { return "Toggle Snap Type"; }

    override bool isUndoable() const { return false; }

    void setTypeName(string n) { typeName_ = n; }

    override bool apply() {
        if (g_pipeCtx is null)
            throw new Exception("snap.toggleType: pipeline not initialised");
        auto sn = cast(SnapStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Snap);
        if (sn is null)
            throw new Exception("snap.toggleType: SNAP stage not registered");
        if (typeName_.length == 0)
            throw new Exception("snap.toggleType: type name required");
        if (!sn.setAttr("typeToggle", typeName_))
            throw new Exception(
                "snap.toggleType: SNAP stage rejected type '"
                ~ typeName_ ~ "'");
        return true;
    }

    override bool revert() { return false; }
}
