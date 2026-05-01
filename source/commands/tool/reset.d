module commands.tool.reset;

import command;
import mesh;
import view;
import editmode;
import commands.tool.host : ToolHost;

// ---------------------------------------------------------------------------
// ToolResetCommand — MODO-style `tool.reset [<toolId>]`
//
// Resets the active tool's parameters to their defaults by calling
// dialogInit() on the tool.  The base Tool.dialogInit() is a no-op;
// concrete tools override it if they want an explicit reset.
//
// TODO (phase 4.4): respect optToolId — activate the named tool if it is not
// already active before calling dialogInit().
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

    override bool isUndoable() const { return false; }

    void setToolId(string id) { optToolId_ = id; }

    override bool apply() {
        auto t = toolHost.getActiveTool();
        if (t is null) return false;
        // TODO (4.4): if optToolId_ is set and != activeToolId, activate it first.
        t.dialogInit();
        return true;
    }

    override bool revert() { return false; }
}
