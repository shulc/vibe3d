module commands.snap.mode;

import command;
import mesh;
import view;
import editmode;

import toolpipe.pipeline    : g_pipeCtx;
import toolpipe.stages.snap : SnapStage;
import toolpipe.stage       : TaskCode;

// ---------------------------------------------------------------------------
// `snap.mode <global|component|item>` — set the SnapStage's scope mode.
// Mirrors snap/toggle.d in structure; delegates the value set to
// SnapStage.setAttr("snapMode", <mode>).
//
// Wire format (from argstring):
//   positional[0] = mode name ("global", "component", or "item")
// ---------------------------------------------------------------------------
class SnapModeCommand : Command {
    private string modeName_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "snap.mode"; }
    override string label() const { return "Set Snap Mode"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    void setModeName(string n) { modeName_ = n; }

    override bool apply() {
        if (g_pipeCtx is null)
            throw new Exception("snap.mode: pipeline not initialised");
        auto sn = cast(SnapStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Snap);
        if (sn is null)
            throw new Exception("snap.mode: SNAP stage not registered");
        if (modeName_.length == 0)
            throw new Exception("snap.mode: mode name required");
        if (!sn.setAttr("snapMode", modeName_))
            throw new Exception(
                "snap.mode: SNAP stage rejected mode '"
                ~ modeName_ ~ "'");
        return true;
    }

    override bool revert() { return false; }
}
