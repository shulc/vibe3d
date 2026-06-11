module commands.falloff;

import command;
import mesh;
import view;
import editmode;
import commands.tool.host : ToolHost;

import toolpipe.pipeline         : g_pipeCtx;
import toolpipe.stages.falloff   : FalloffStage;
import toolpipe.stage            : TaskCode;

// ---------------------------------------------------------------------------
// `falloff.<type>` — bare named falloff sub-tools.
//
// Activating a falloff by name (`falloff.linear`, `falloff.radial`,
// `falloff.cylinder`, `falloff.screen`, `falloff.lasso`) just SETS the
// falloff (WGHT) stage's `type` and KEEPS the active transform tool. It is
// NOT a tool that replaces the active tool, and NOT a transform bundle — a
// falloff is a modifier the active transform consumes.
//
// This is the exact analog of the status-bar Falloff pulldown action
// (`tool.pipe.attr falloff type <type>`): it routes the type write through
// the SAME FalloffStage.setAttr path, so the on-switch auto-size and
// state-publish side-effects are identical, and it fires the SAME live
// re-evaluation when a session is already open.
//
// Argument shape: positional, none. Just `falloff.linear` etc. The two
// existing bundle presets (`falloff.element`, `falloff.selection`) live in
// config/tool_presets.yaml and are left unchanged.
// ---------------------------------------------------------------------------
class FalloffPresetCommand : Command {
    private ToolHost toolHost;
    private string   typeName_;

    this(Mesh* mesh, ref View view, EditMode editMode,
         ToolHost host, string typeName)
    {
        super(mesh, view, editMode);
        this.toolHost  = host;
        this.typeName_ = typeName;
    }

    override string name()  const { return "falloff." ~ typeName_; }
    override string label() const {
        // Human label consistent with FalloffStage.displayName() output
        // ("Linear Falloff", "Radial Falloff", ...): capitalised type name
        // plus " Falloff".
        import std.ascii  : toUpper;
        import std.conv   : to;
        string cap = typeName_.length
            ? to!string(cast(char)toUpper(typeName_[0])) ~ typeName_[1 .. $]
            : typeName_;
        return cap ~ " Falloff";
    }

    // Pipe configuration is UI state, not a mesh edit — not undoable.
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override bool apply() {
        if (g_pipeCtx is null)
            throw new Exception(name() ~ ": pipeline not initialised");

        auto fo = cast(FalloffStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Wght);
        if (fo is null)
            throw new Exception(name() ~ ": no falloff (WGHT) stage registered");

        // Route through setAttr so the on-switch auto-size + state-publish
        // side-effects match the status-bar pulldown exactly. Fail loudly if
        // the stage rejects the type (catches a typo-ed registration).
        if (!fo.setAttr("type", typeName_))
            throw new Exception(
                name() ~ ": falloff stage rejected type '" ~ typeName_ ~ "'");

        // Mid-session immediacy: if a tool already has a live evaluation
        // session, re-run its apply now so the new falloff takes effect this
        // edit instead of on the next update() tick. Mirrors
        // ToolPipeAttrCommand.apply(). The active tool is NOT changed.
        if (toolHost.getActiveTool !is null) {
            auto t = toolHost.getActiveTool();
            if (t !is null && t.hasLiveEval()) t.reEvaluate();
        }
        return true;
    }

    override bool revert() { return false; }
}
