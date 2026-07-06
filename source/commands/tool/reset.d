module commands.tool.reset;

import command;
import mesh;
import view;
import editmode;
import commands.tool.host : ToolHost;

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

    void setToolId(string id) { optToolId_ = id; }

    override bool apply() {
        return toolHost.resetActiveTool(optToolId_);
    }

    override bool revert() { return false; }
}
