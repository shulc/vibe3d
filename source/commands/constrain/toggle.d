module commands.constrain.toggle;

import command;
import mesh;
import view;
import editmode;

import toolpipe.pipeline           : g_pipeCtx;
import toolpipe.stages.constrain   : ConstrainStage;
import toolpipe.stage              : TaskCode;

// ---------------------------------------------------------------------------
// `constrain.toggle` — flip the ConstrainStage's master enable flag.
//
// Pipe configuration is UI state, not a mesh edit. Mirrors snap.toggle.
//
// This is one of the two explicit-user entry points that set
// `ConstrainStage.userLocked` (the other is `tool.pipe.attr constrain
// enabled <v>` — ToolPipeAttrCommand's constrain special case,
// commands/tool/pipe.d). ConstrainStage.onParamChanged() deliberately does
// NOT lock (topology-pen P0 review fix SF) — see its doc comment.
// ---------------------------------------------------------------------------
class ConstrainToggleCommand : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "constrain.toggle"; }
    override string label() const { return "Toggle Constrain"; }

    // Pipe configuration is UI state, not a mesh edit.
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override bool apply() {
        if (g_pipeCtx is null)
            throw new Exception("constrain.toggle: pipeline not initialised");
        auto cs = cast(ConstrainStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Cons);
        if (cs is null)
            throw new Exception("constrain.toggle: CONS stage not registered");
        bool next = !cs.enabled;
        cs.setAttr("enabled", next ? "true" : "false");
        cs.userLocked = next;   // lock on, clear on disable
        return true;
    }
}
