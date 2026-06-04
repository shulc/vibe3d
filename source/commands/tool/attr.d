module commands.tool.attr;

import command;
import mesh;
import view;
import editmode;
import params : Param, injectParamsInto, paramToJson;
import commands.tool.host : ToolHost;

import std.json : JSONValue, JSONType;

// ---------------------------------------------------------------------------
// ToolAttrCommand — `tool.attr <toolId> <name> <value>`
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
    // Live re-eval discriminator (re-eval plan D4). Set ONLY via the
    // in-process setInteractive() setter — the FormsPanel calls it before
    // dispatch. It is NEVER wired into the argstring / app.d command-builder
    // bridge (which reads only _positional), so raw HTTP `tool.attr` has no
    // wire path to set it. That absence is the guarantee raw HTTP stays inert:
    // a fresh tool with interactive_==false stores the value and moves nothing.
    private bool      interactive_;
    // Query (read-back) mode — forms-engine `?` idiom. When set, apply()
    // RESOLVES attrName_ against the active tool's params() and boxes the live
    // value into queryResult_ instead of writing anything. A query mutates
    // nothing (no injectParamsInto / onParamChanged / evaluate / reEvaluate),
    // so the command stays a pure read even though it remains
    // CmdFlags.SideEffect. Set ONLY via setQuery() — like setInteractive() it
    // has no argstring wiring; app.d flips it when the value positional is the
    // literal "?" token.
    private bool      query_;
    private JSONValue queryResult_;

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host) {
        super(mesh, view, editMode);
        this.toolHost  = host;
        this.attrValue_ = JSONValue(null);
        this.queryResult_ = JSONValue(null);
    }

    override string name()  const { return "tool.attr"; }
    override string label() const { return "Set Tool Attribute"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    void setToolId(string id)       { toolId_   = id; }
    void setAttrName(string n)      { attrName_ = n; }
    void setAttrValue(JSONValue v)  { attrValue_ = v; }
    // Programmatic-only: marks this attr write as originating from an
    // interactive panel/form so the FIRST edit OPENS a live session via
    // reEvaluate() (D4). Deliberately has no argstring wiring.
    void setInteractive(bool v)     { interactive_ = v; }
    // Forms-engine query (read-back) mode. Programmatic-only; see query_ above.
    void setQuery(bool v)           { query_ = v; }
    bool isQuery() const            { return query_; }
    // Boxed live value of the queried attr, valid after a query-mode apply().
    JSONValue queryResult() const   { return queryResult_; }
    // Serialised query result for the HTTP marshal (empty if not a query).
    string queryResultJsonOrEmpty() const {
        import std.json : JSONType;
        if (!query_ || queryResult_.type == JSONType.null_) return "";
        return queryResult_.toString();
    }

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

        // Query (read-back) mode: resolve attrName_ in the active tool's
        // params() schema, box the live typed-pointer value, and return WITHOUT
        // mutating. Crucially this never touches injectParamsInto /
        // onParamChanged / evaluate / reEvaluate — a query is a pure read, so
        // it moves no geometry and opens no live session (guarding the
        // reEvaluate trigger path).
        if (query_) {
            foreach (ref p; t.params()) {
                if (p.name == attrName_) {
                    queryResult_ = paramToJson(p);
                    return true;
                }
            }
            throw new Exception(
                "tool.attr: unknown attribute '" ~ attrName_ ~
                "' on tool '" ~ toolId_ ~ "'");
        }

        // Build a single-key object and inject it.
        JSONValue pj = JSONValue(cast(JSONValue[string]) null);
        pj[attrName_] = attrValue_;
        injectParamsInto(t.params(), pj);
        // Mirror the property-panel contract (property_panel.d): fire
        // onParamChanged + evaluate after a runtime attribute write so the
        // tool can react (e.g. PenTool clamping currentPoint, mirroring the
        // posX/Y/Z field into the in-progress vertex buffer; SphereTool
        // re-permuting per-axis radii on axis change).
        t.onParamChanged(attrName_);
        t.evaluate();

        // Faithful gated re-eval (re-eval plan D4): the value is injected
        // BEFORE the trigger so reEvaluate() reads it absolutely from the
        // session baseline (no accumulation).
        //   - hasLiveEval(): a session is ALREADY open (e.g. a live drag or a
        //     prior panel/form edit) — re-run the apply from the session
        //     baseline using the just-written value.
        //   - interactive_: a forms-dispatched FIRST edit — reEvaluate() opens
        //     the session (idempotent beginEdit + baseline capture) and replays.
        //   - else: raw HTTP `tool.attr` on a fresh tool — inert (faithful;
        //     every existing HTTP tool.attr golden depends on this).
        // tool.attr stays CmdFlags.SideEffect; the geometry change is recorded
        // by the session's commitEdit at tool drop, not by this command.
        if (t.hasLiveEval())      t.reEvaluate();
        else if (interactive_)    t.reEvaluate();
        return true;
    }

    override bool revert() { return false; }
}
