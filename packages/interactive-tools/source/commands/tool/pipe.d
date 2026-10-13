module commands.tool.pipe;

import command;
import mesh;
import view;
import editmode;
import commands.tool.host : ToolHost;

import toolpipe.pipeline : g_pipeCtx, noteUserStageChoice;
import toolpipe.stage    : Stage;
import params : Param, paramToJson, parseInto, wireArgs;
import tool_attr_bounds : applyToolAttrBound;

import std.json : JSONValue, JSONType;

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
    // calling setAttr / reEvaluate. A query mutates nothing. The flag itself
    // lives on `Command` since task 4062.
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

    /// The three declared arguments (task 4062). The value slot is an
    /// ordinary String: unlike `tool.attr`, this command hands the stage a
    /// STRING and the stage parses it (`Stage.setAttr(name, text)`), so the
    /// scalar spelling is exactly what it wants.
    override Param[] params() {
        return wireArgs(
            Param.string_("stage", "Stage", &stageId_, ""),
            Param.string_("attr", "Attribute", &attrName_, ""),
            Param.string_("value", "Value", &attrValue_, "")
        );
    }

    void setStageId(string id)    { stageId_   = id; }
    void setAttrName(string n)    { attrName_  = n; }
    void setAttrValue(string v)   { attrValue_ = v; }
    /// This command answers a `?` read-back (task 4062 base protocol).
    override bool acceptsQuery() const { return true; }
    // Forms-engine query (read-back) mode. In-process callers still say
    // `setQuery(true)`; the flag is the base's.
    void setQuery(bool v)         { if (v) markQuery(); }
    JSONValue queryResult() const { return queryResult_; }
    override string queryResultJson() const {
        import std.json : JSONType;
        if (!isQuery() || queryResult_.type == JSONType.null_) return "";
        return queryResult_.toString();
    }

    protected override bool applyImpl() {
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
        if (isQuery()) {
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

        // Normalize only a captured numeric row before the stage's own setter.
        // Detached storage keeps rejected parses from changing live fields;
        // internal/restore callers of setAttr never consult tool_attr_bounds.
        foreach (p; matched.fullParams()) {
            if (p.name != attrName_ || !applyToolAttrBound(matched.id(), p)) continue;
            Param.DefaultValue storage; // all numeric kinds share this union
            p.iptr = &storage.i;
            if (!parseInto(p, attrValue_))
                throw new Exception("tool.pipe.attr: invalid bounded value '" ~ attrValue_ ~ "'");
            const normalized = paramToJson(p);
            attrValue_ = normalized.type == JSONType.string
                ? normalized.str : normalized.toString();
            break;
        }
        if (!matched.setAttr(attrName_, attrValue_))
            throw new Exception(
                "tool.pipe.attr: stage '" ~ stageId_ ~ "' rejected attr '"
                ~ attrName_ ~ "' = '" ~ attrValue_ ~ "'");

        if (attrName_ == "type") {
            import toolpipe.stages.falloff : FalloffStage;
            if (cast(FalloffStage)matched !is null)
                noteUserStageChoice(g_pipeCtx.pipeline, matched,
                    attrValue_ != "none");
        } else if ((stageId_ == "actionCenter" || stageId_ == "axis") &&
                   attrName_ == "mode") {
            noteUserStageChoice(g_pipeCtx.pipeline, matched, false);
            // With NO tool armed a CENTRE mode write has no session to belong
            // to: it is the user's choice and survives the next arm, as a
            // hand-set node does (gap 384, M0e floor; slice M7); `none` there
            // withdraws that choice, as falloff's `type none` does. Armed, the
            // write stays loose (L1-L3, below). The axis stays loose until its
            // node is captured (cell C-M7-axis-node).
            const bool noTool = toolHost.getActiveTool !is null
                                && toolHost.getActiveTool() is null;
            if (noTool && stageId_ == "actionCenter") {
                import toolpipe.stages.actcenter : ActionCenterStage;
                if (auto ac = cast(ActionCenterStage) matched) {
                    if (attrValue_ != "none") ac.promoteClaimToUserChoice();
                    else ac.userLocked = false;
                }
            }
        }

        // A falloff TYPE write here locks the stage until `none`; if the armed
        // preset had claimed it, the preset breaks (its other claimed stages
        // become user choices, C5b; an unclaimed slot breaks nothing, X1p). An
        // action-centre/axis MODE write is loose (L1-L3). Task 5911; fixture
        // tool_drop_pipe_stages.json.
        if (attrName_ == "type") {
            import toolpipe.stages.falloff : FalloffStage;
            if (auto fo = cast(FalloffStage) matched)
                fo.userLocked = (attrValue_ != "none");
        }

        // Any user write of a CONS attr locks the settings while enabled
        // (TS-keep); an `enabled` write also remembers or forgets the
        // constraint. A tool's own composition calls the stage's
        // setAttr directly and never reaches here (review fix SF).
        if (stageId_ == "constrain") {
            import toolpipe.stages.constrain : ConstrainStage, Remembered;
            if (auto cs = cast(ConstrainStage) matched) {
                cs.userLocked = cs.enabled;
                if (attrName_ == "enabled")
                    cs.remembered = cs.enabled ? Remembered.inPipe : Remembered.no;
            }
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
}
