module commands.tool.pipe;

import command;
import mesh;
import view;
import editmode;
import commands.tool.host : ToolHost;

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
    private ToolHost toolHost;
    private string stageId_;
    private string attrName_;
    private string attrValue_;

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host) {
        super(mesh, view, editMode);
        this.toolHost = host;
    }

    override string name()  const { return "tool.pipe.attr"; }
    override string label() const { return "Set Tool Pipe Attribute"; }

    // Not undoable — pipe configuration is UI state, not mesh edit.
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

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

        // Stage-attr edits (falloff/ACEN/AXIS/snap) gain mid-session
        // immediacy: when a tool ALREADY has a live evaluation session, re-run
        // its apply now so the new stage state takes effect this edit instead
        // of on the next update() tick (re-eval plan, stage re-eval). setAttr
        // above has already published the new stage state, so reEvaluate()
        // reads the new packet. Stage edits never carry the forms `interactive`
        // opener — a falloff edit with no live session stays inert.
        if (toolHost.getActiveTool !is null) {
            auto t = toolHost.getActiveTool();
            if (t !is null && t.hasLiveEval()) t.reEvaluate();
        }
        return true;
    }

    override bool revert() { return false; }
}
