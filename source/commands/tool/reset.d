module commands.tool.reset;

import command;
import mesh;
import view;
import editmode;
import commands.tool.host : ToolHost;
import params : Param, wireArgs;

// ---------------------------------------------------------------------------
// ToolResetCommand — `tool.reset [<toolId>]`
//
// Resets a tool (the active one, or the named `optToolId_`) to its DECLARED
// defaults — constructor + preset-YAML, as if built with an empty sticky
// entry — and clears its sticky-tool-defaults entry. Delegates the actual
// work to `toolHost.resetActiveTool`, which discards any in-progress preview
// first (never commits it) and rebuilds the tool under a history suspend
// (no spurious undo entry). Non-undoable (SideEffect), matching the prior
// no-op's flags.
// ---------------------------------------------------------------------------
class ToolResetCommand : Command {
    private ToolHost toolHost;
    private string   optToolId_;

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host) {
        super(mesh, view, editMode);
        this.toolHost = host;
    }

    override string name()  const { return "tool.reset"; }
    override string label() const { return "Reset Tool"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override Param[] params() {
        return wireArgs(
            Param.string_("tool", "Tool", &optToolId_, "")
        );
    }

    void setToolId(string id) { optToolId_ = id; }

    protected override bool applyImpl() {
        return toolHost.resetActiveTool(optToolId_);
    }
}
