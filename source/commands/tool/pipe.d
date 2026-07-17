module commands.tool.pipe;

import command;
import mesh;
import view;
import editmode;
import commands.tool.host : ToolHost;

import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stage    : Stage;
import params            : paramToJson;

import std.json : JSONValue;

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
    // Query (read-back) mode — forms-engine `?` idiom, mirroring
    // ToolAttrCommand. When set, apply() resolves attrName_ against the named
    // stage's params() and boxes the live value into queryResult_ instead of
    // calling setAttr / reEvaluate. A query mutates nothing.
    private bool      query_;
    private JSONValue queryResult_;

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host) {
        super(mesh, view, editMode);
        this.toolHost = host;
        this.queryResult_ = JSONValue(null);
    }

    override string name()  const { return "tool.pipe.attr"; }
    override string label() const { return "Set Tool Pipe Attribute"; }

    // Not undoable — pipe configuration is UI state, not mesh edit.
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    void setStageId(string id)    { stageId_   = id; }
    void setAttrName(string n)    { attrName_  = n; }
    void setAttrValue(string v)   { attrValue_ = v; }
    // Forms-engine query (read-back) mode. Programmatic-only; see query_ above.
    void setQuery(bool v)         { query_ = v; }
    bool isQuery() const          { return query_; }
    JSONValue queryResult() const { return queryResult_; }
    string queryResultJsonOrEmpty() const {
        import std.json : JSONType;
        if (!query_ || queryResult_.type == JSONType.null_) return "";
        return queryResult_.toString();
    }

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

        // Query (read-back) mode: resolve attrName_ in the stage's params()
        // and box the live value WITHOUT mutating (no setAttr / reEvaluate).
        // params() is type-filtered for some stages (e.g. falloff), so an attr
        // not exposed by the CURRENT state resolves as unknown — that matches
        // the runtime-visibility model and is fine for Phase 1's read-back.
        if (query_) {
            foreach (ref p; matched.params()) {
                if (p.name == attrName_) {
                    queryResult_ = paramToJson(p);
                    return true;
                }
            }
            throw new Exception(
                "tool.pipe.attr: unknown attribute '" ~ attrName_ ~
                "' on stage '" ~ stageId_ ~ "'");
        }

        if (!matched.setAttr(attrName_, attrValue_))
            throw new Exception(
                "tool.pipe.attr: stage '" ~ stageId_ ~ "' rejected attr '"
                ~ attrName_ ~ "' = '" ~ attrValue_ ~ "'");

        // A user-driven falloff TYPE change (the status-bar Falloff pulldown
        // fires `tool.pipe.attr falloff type <X>`) locks the stage so it
        // survives a tool switch — reference parity (2026-06-16). type=none clears
        // the lock. Preset-bundle config applies via Stage.setAttr DIRECTLY (not
        // through this command), so it never locks and stays transient.
        if (attrName_ == "type") {
            import toolpipe.stages.falloff : FalloffStage;
            if (auto fo = cast(FalloffStage) matched)
                fo.userLocked = (attrValue_ != "none");
        }

        // Stage-attr edits (falloff/ACEN/AXIS/snap) gain mid-session
        // immediacy: when a tool ALREADY has a live evaluation session, the
        // session driver re-runs its apply now so the new stage state takes
        // effect this edit instead of on the next update() tick (re-eval
        // plan, stage re-eval; gate in EditSession.onStageConfigChanged —
        // task 0428). setAttr above has already published the new stage
        // state, so the re-eval reads the new packet. Stage edits never carry
        // the forms `interactive` opener — a falloff edit with no live
        // session stays inert.
        if (toolHost.session !is null)
            toolHost.session().onStageConfigChanged();
        return true;
    }

    override bool revert() { return false; }
}
