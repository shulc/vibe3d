module commands.tool.attr;

import command;
import mesh;
import view;
import editmode;
import params : Param, injectParamsInto, paramToJson, wireArgs;
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
    // The wire form of the value slot: its RAW JSON TEXT (task 4062). The
    // value is FORWARDED to the active tool's own schema, so its JSON TYPE is
    // what decides whether the write lands — a scalar spelling would turn 1.5
    // into a string the tool's Float gate then refuses, and `{1,2,3}` into
    // something no gate accepts at all. `Param.jsonArg_` is the declared way
    // to say "this slot is a value of whatever kind"; the round-trip is exact.
    private string    attrValueJson_;
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
    // CmdFlags.SideEffect. The flag itself lives on `Command` since task 4062
    // (`acceptsQuery`/`isQuery`/`markQuery`); `bindArgs` raises it when the
    // value positional is the literal "?" token.
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

    override Param[] params() {
        return wireArgs(
            Param.string_("tool", "Tool", &toolId_, ""),
            Param.string_("attr", "Attribute", &attrName_, ""),
            Param.jsonArg_("value", "Value", &attrValueJson_)
        );
    }

    void setToolId(string id)       { toolId_   = id; }
    void setAttrName(string n)      { attrName_ = n; }
    void setAttrValue(JSONValue v)  { attrValue_ = v; attrValueJson_ = v.toString(); }
    // Programmatic-only: marks this attr write as originating from an
    // interactive panel/form so the FIRST edit OPENS a live session via
    // reEvaluate() (D4). Deliberately has no argstring wiring.
    void setInteractive(bool v)     { interactive_ = v; }
    /// This command answers a `?` read-back (task 4062 base protocol).
    override bool acceptsQuery() const { return true; }
    // Forms-engine query (read-back) mode. In-process callers still say
    // `setQuery(true)`; the flag is the base's.
    void setQuery(bool v)           { if (v) markQuery(); }
    // Boxed live value of the queried attr, valid after a query-mode apply().
    JSONValue queryResult() const   { return queryResult_; }
    // Serialised query result for the HTTP marshal (empty if not a query).
    override string queryResultJson() const {
        import std.json : JSONType;
        if (!isQuery() || queryResult_.type == JSONType.null_) return "";
        return queryResult_.toString();
    }

    protected override bool applyImpl() {
        import std.json : parseJSON;
        if (attrValueJson_.length > 0) attrValue_ = parseJSON(attrValueJson_);
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
        if (isQuery()) {
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
        if (interactive_)
            t.notifyInteractiveParamChanged(attrName_);
        else
            t.onParamChanged(attrName_);
        t.evaluate();

        // Faithful gated re-eval (re-eval plan D4): the value is injected
        // BEFORE the trigger; the gate itself (hasLiveAttrEval / interactive
        // opener / fresh-tool inertness, plus the value-attr vs pipe-config
        // asymmetry) lives in EditSession.onValueAttrApplied (task 0428).
        // tool.attr stays CmdFlags.SideEffect; the geometry change is
        // recorded by the session's commitEdit at tool drop, not by this
        // command. The session accessor is null only in bare-struct ToolHost
        // test contexts — same defensive shape as the getActiveTool guards.
        if (toolHost.session !is null)
            toolHost.session().onValueAttrApplied(interactive_);
        return true;
    }
}
