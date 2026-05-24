module commands.tool.pipe;

import command;
import mesh;
import view;
import editmode;

import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stage    : Stage;

// ---------------------------------------------------------------------------
// ToolPipeAttrCommand — `tool.pipe.attr <stageId> <name> <value>`.
//
// Mutates a single attribute on a registered Tool Pipe stage. Phase-7.1
// only target is the WorkplaneStage's `mode` attr (auto / worldX /
// worldY / worldZ); later subphases register more stages with their own
// attrs and reuse this same command path.
//
// Wire format (from argstring / _positional):
//   positional[0] = stageId    (e.g. "workplane")
//   positional[1] = attrName   (e.g. "mode")
//   positional[2] = attrValue  (string)
//
// Mirrors the shape of tool.attr but operates on the global Pipeline
// rather than the active Tool's params.
// ---------------------------------------------------------------------------
class ToolPipeAttrCommand : Command {
    private string stageId_;
    private string attrName_;
    private string attrValue_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "tool.pipe.attr"; }
    override string label() const { return "Set Tool Pipe Attribute"; }

    // Not undoable — pipe configuration is UI state, not mesh edit.
    override bool isUndoable() const { return false; }

    void setStageId(string id)    { stageId_   = id; }
    void setAttrName(string n)    { attrName_  = n; }
    void setAttrValue(string v)   { attrValue_ = v; }

    override bool apply() {
        if (g_pipeCtx is null)
            throw new Exception("tool.pipe.attr: pipeline not initialised");
        if (stageId_.length == 0)
            throw new Exception("tool.pipe.attr: no stage id specified");
        if (attrName_.length == 0)
            throw new Exception("tool.pipe.attr: no attribute name specified");

        Stage matched;
        foreach (s; g_pipeCtx.pipeline.all()) {
            if (s.id() == stageId_) { matched = cast(Stage)s; break; }
        }
        if (matched is null)
            throw new Exception(
                "tool.pipe.attr: stage '" ~ stageId_ ~ "' not registered");

        if (!matched.setAttr(attrName_, attrValue_))
            throw new Exception(
                "tool.pipe.attr: stage '" ~ stageId_ ~ "' rejected attr '"
                ~ attrName_ ~ "' = '" ~ attrValue_ ~ "'");
        return true;
    }

    override bool revert() { return false; }
}
