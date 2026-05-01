module commands.tool.set;

import command;
import mesh;
import view;
import editmode;
import params : Param, injectParamsInto;
import commands.tool.host : ToolHost;

import std.json : JSONValue, JSONType;

// ---------------------------------------------------------------------------
// ToolSetCommand — MODO-style `tool.set <toolId> [off] [name:val ...]`
//
// Activates or deactivates a tool by id.  Optional named params are injected
// into the new tool's params() schema immediately after activation.
//
// Wire format (from argstring / _positional):
//   positional[0] = toolId
//   positional[1] = "off"   (optional — deactivate instead of activate)
//   named pairs   = forwarded to injectParamsInto(tool.params(), ...)
// ---------------------------------------------------------------------------
class ToolSetCommand : Command {
    private ToolHost toolHost;
    private string   toolId_;
    private bool     turnOff_;
    private JSONValue namedArgs_;

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host) {
        super(mesh, view, editMode);
        this.toolHost   = host;
        this.namedArgs_ = JSONValue(cast(JSONValue[string]) null);
    }

    override string name()  const { return "tool.set"; }
    override string label() const { return "Set Tool"; }

    // Not undoable — tool activation is UI state, not mesh edit.
    override bool isUndoable() const { return false; }

    void setToolId(string id)      { toolId_  = id; }
    void setTurnOff(bool v)        { turnOff_ = v; }
    void setNamedArgs(JSONValue pj) { namedArgs_ = pj; }

    override bool apply() {
        if (turnOff_) {
            toolHost.deactivate();
            return true;
        }
        if (toolId_.length == 0)
            throw new Exception("tool.set: no tool id specified");
        toolHost.activate(toolId_);
        // Inject any named params into the freshly-activated tool.
        if (namedArgs_.type == JSONType.object && namedArgs_.object.length > 0) {
            auto t = toolHost.getActiveTool();
            if (t !is null && t.params().length > 0)
                injectParamsInto(t.params(), namedArgs_);
        }
        return true;
    }

    // No mesh mutation — revert is a no-op.
    override bool revert() { return false; }
}
