module commands.snap.toggle;

import command;
import mesh;
import view;
import editmode;

import toolpipe.pipeline       : g_pipeCtx;
import toolpipe.stages.snap    : SnapStage;
import toolpipe.stage          : TaskCode;

// ---------------------------------------------------------------------------
// `snap.toggle` — flip the SnapStage's master enable flag. Mirrors
// MODO's `X`-keyed `tool.snapState true` from `inmapdefault.cfg`
// (their `true` arg means "toggle").
//
// Hooked up via config/shortcuts.yaml:
//   commands:
//     snap.toggle: X
//
// Argstring takes no args.
// ---------------------------------------------------------------------------
class SnapToggleCommand : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "snap.toggle"; }
    override string label() const { return "Toggle Snap"; }

    // Pipe configuration is UI state, not a mesh edit.
    override bool isUndoable() const { return false; }

    override bool apply() {
        if (g_pipeCtx is null)
            throw new Exception("snap.toggle: pipeline not initialised");
        auto sn = cast(SnapStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Snap);
        if (sn is null)
            throw new Exception("snap.toggle: SNAP stage not registered");
        sn.setAttr("enabled", sn.enabled ? "false" : "true");
        return true;
    }

    override bool revert() { return false; }
}
