module commands.tool.attr;

import command;
import mesh;
import view;
import editmode;
import params : Param, injectParamsInto;
import commands.tool.host : ToolHost;

import std.json : JSONValue, JSONType;

// ---------------------------------------------------------------------------
// ToolAttrCommand — MODO-style `tool.attr <toolId> <name> <value>`
//
// Sets a single named parameter on the currently active tool.  The toolId is
// validated against getActiveToolId() — a mismatch throws so callers notice
// script sequencing bugs early.
//
// Wire format (from argstring / _positional):
//   positional[0] = toolId
//   positional[1] = attrName
//   positional[2] = attrValue (JSONValue of any scalar/vec type)
// ---------------------------------------------------------------------------
class ToolAttrCommand : Command {
    private ToolHost  toolHost;
    private string    toolId_;
    private string    attrName_;
    private JSONValue attrValue_;

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host) {
        super(mesh, view, editMode);
        this.toolHost  = host;
        this.attrValue_ = JSONValue(null);
    }

    override string name()  const { return "tool.attr"; }
    override string label() const { return "Set Tool Attribute"; }

    override bool isUndoable() const { return false; }

    void setToolId(string id)       { toolId_   = id; }
    void setAttrName(string n)      { attrName_ = n; }
    void setAttrValue(JSONValue v)  { attrValue_ = v; }

    override bool apply() {
        if (toolId_.length == 0)
            throw new Exception("tool.attr: no tool id specified");
        if (attrName_.length == 0)
            throw new Exception("tool.attr: no attribute name specified");

        string activeId = toolHost.getActiveToolId();
        if (activeId != toolId_)
            throw new Exception(
                "tool.attr: active tool is '" ~ activeId ~
                "', expected '" ~ toolId_ ~ "'");

        auto t = toolHost.getActiveTool();
        if (t is null)
            throw new Exception("tool.attr: no active tool");

        // Build a single-key object and inject it.
        JSONValue pj = JSONValue(cast(JSONValue[string]) null);
        pj[attrName_] = attrValue_;
        injectParamsInto(t.params(), pj);
        return true;
    }

    override bool revert() { return false; }
}
