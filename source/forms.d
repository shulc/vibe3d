module forms;

// ===========================================================================
// forms — config-driven Tool Properties forms engine: PURE schema types +
// binding resolver.
//
// This module is the unit-test surface of the forms engine. It is
// deliberately:
//   * ImGui-free   — no rendering. That lives in a future forms_render module.
//   * YAML-free    — no dyaml loader yet. Schema trees are constructed by hand
//                    (here in tests, by the loader in a later phase).
//   * app-free     — it imports only `params` (for Param/Kind/ParamHints +
//                    choicesOf) and `argstring` (for parseArgstring). It never
//                    reaches into global app state; resolution takes the
//                    provider's Param[] as an explicit argument.
//
// A *form* is a tree of *rows*. A row is exactly one kind (control / cmd /
// choice / group / sub / ref / divider / label). A value-bearing `control:`
// row carries a command line with exactly one `?` placeholder: reading queries
// the command, writing executes it with `?` substituted. The *binding* grammar
// (parseBinding) splits that line into a command id, a namespace (tool vs
// stage), a target id, an attr name, and the `?` index. The *resolver*
// (resolveControl) looks the attr up in a provider's Param[] snapshot and
// reports the matched Param + its popup choices + the chosen widget class.
//
// Two attr-resolution layers exist in the full plan; this module implements
// only the runtime layer (absent attr -> not found -> renderer hides the row).
// The startup-strict validation layer (throw on a YAML typo, resolved against
// the full static param universe) belongs to the YAML loader phase and is NOT
// built here — but the resolver returns a clean `found=false` that the loader
// can promote to a throw, so the seam is ready.
// ===========================================================================

import params : Param, ParamHints, choicesOf;
import argstring : parseArgstring;

import std.json : JSONValue, JSONType;
import std.string : strip, splitLines;
import std.format : format;

// ---------------------------------------------------------------------------
// Row kinds
// ---------------------------------------------------------------------------

/// Discriminator for the one-of `Row` payload. Mirrors the row kinds in the
/// YAML schema spec: a value-bound control, a momentary command button, a
/// curated command menu, a field group, a form embed/reference, a separator,
/// and a static text label.
enum RowKind {
    control,   // value field/button/toggle bound to a `?`-query command line
    cmd,       // momentary command button (fires a command; no `?`, no read)
    choice,    // curated command menu; each entry fires a command (no `?`)
    group,     // horizontal field cluster with nested rows
    sub,        // embed another form inline by id
    ref_,      // reference/assemble a shared form by id  (`ref:` in YAML)
    divider,   // horizontal separator
    label,     // static text row
}

/// Boolean control rendering style (only meaningful for a `control:` bound to
/// a Bool attr).
enum BooleanStyle { checkbox, button }

/// Widget variant hint authored on a control row. `default_` defers to the
/// datatype-derived widget; the others force a specific shape.
enum ControlStyle { default_, popup, slider, drag }

/// Layout placement hint.
enum AlignHint { default_, sameline, wide, full }

/// Group inner layout: `inline` packs children flush, `block` renders the
/// group as its own labeled sub-box, `buttons` lays the group's `cmd` children
/// out as a horizontal row of equal-width buttons filling the widget column
/// (e.g. the falloff "Auto Size" X/Y/Z row).
enum GroupStyle { inline_, block, buttons }

// ---------------------------------------------------------------------------
// Choice entry — one row of a `choice:` menu. Fires `cmd` on selection.
// ---------------------------------------------------------------------------

struct ChoiceEntry {
    string label;   // menu item text
    string cmd;     // command line to dispatch on selection (no `?`)
}

// ---------------------------------------------------------------------------
// Row — one entry in a form. Exactly one kind is active; the unused payload
// fields stay default. Kept as a plain value struct (no class hierarchy) so
// the loader and the tests can brace-initialise rows cheaply and so equality
// is structural.
// ---------------------------------------------------------------------------

struct Row {
    RowKind kind;

    // --- control / cmd payload --------------------------------------------
    // For RowKind.control: full command line with exactly one `?`.
    // For RowKind.cmd:     full command line, no `?` (fire-only on click).
    string command;

    // --- choice payload ----------------------------------------------------
    ChoiceEntry[] entries;        // RowKind.choice

    // --- group payload -----------------------------------------------------
    Row[] rows;                   // RowKind.group nested children
    GroupStyle groupStyle = GroupStyle.inline_;

    // --- sub / ref payload -------------------------------------------------
    string formId;                // RowKind.sub / RowKind.ref_ : target form id

    // --- shared / presentation --------------------------------------------
    // `label` doubles as the static text for RowKind.label, the menu title for
    // RowKind.choice, the group title for RowKind.group, and the control label
    // (empty => derive from the resolved Param.label) for control / cmd.
    string label;
    string id;                    // stable control id (PushID + edit targeting)
    ControlStyle style = ControlStyle.default_;
    BooleanStyle booleanStyle = BooleanStyle.checkbox;
    AlignHint align_ = AlignHint.default_;
    bool showLabel = true;
    string tooltip;

    // --- visibility gate ---------------------------------------------------
    // Row-level conditional visibility: when set, this row (of ANY kind —
    // control / cmd / group / …) is drawn ONLY if a param named `whenAttr` is
    // present in the live params() snapshot this frame. Empty => always shown.
    // Mirrors the value-driven hiding a `control` row already gets when its own
    // bound attr is absent, but lets a row that carries NO value bind of its
    // own (a `cmd` button, a `group` of buttons) ride a type-filtered attr.
    // Used by config/forms/falloff.yaml so the Linear-only Auto Size + Reverse
    // actions track `start` (exposed only by the Linear falloff type).
    string whenAttr;

    // --- convenience constructors -----------------------------------------
    // Brace-init works too; these read better at call sites and in tests.

    static Row makeControl(string command, string label = "", string id = "") {
        Row r; r.kind = RowKind.control; r.command = command;
        r.label = label; r.id = id; return r;
    }
    static Row makeCmd(string command, string label = "") {
        Row r; r.kind = RowKind.cmd; r.command = command; r.label = label;
        return r;
    }
    static Row makeChoice(string label, ChoiceEntry[] entries) {
        Row r; r.kind = RowKind.choice; r.label = label; r.entries = entries;
        return r;
    }
    static Row makeGroup(string label, Row[] rows,
                         GroupStyle gs = GroupStyle.inline_) {
        Row r; r.kind = RowKind.group; r.label = label; r.rows = rows;
        r.groupStyle = gs; return r;
    }
    static Row makeSub(string formId) {
        Row r; r.kind = RowKind.sub; r.formId = formId; return r;
    }
    static Row makeRef(string formId) {
        Row r; r.kind = RowKind.ref_; r.formId = formId; return r;
    }
    static Row makeDivider() { Row r; r.kind = RowKind.divider; return r; }
    static Row makeLabel(string text) {
        Row r; r.kind = RowKind.label; r.label = text; return r;
    }
}

// ---------------------------------------------------------------------------
// Form — a tree of rows plus the header fields that slot it into a tool's
// properties panel.
// ---------------------------------------------------------------------------

struct Form {
    string id;                    // stable form id (target of sub/ref)
    string label;                 // title text
    bool   showLabel = true;      // whether the title is drawn
    // Filter: form shown iff one of these matches the active tool id. Empty =>
    // always shown (shared sub-forms referenced by id). The loader populates
    // this from a single id or a YAML list.
    string[] whenTool;
    // Stage binding: when set, this form is the config-driven Tool Properties
    // form for the named pipe stage (the per-stage loop looks it up via
    // formByStage(stageId)). A form has whenTool OR whenStage OR neither — never
    // both: a tool form can never match a stage and a stage form can never match
    // a tool, so the two lookups (formsForTool / formByStage) stay disjoint.
    string whenStage;
    string category;              // slotting category (assembly order)
    double ordinal;               // sort within the category
    bool   hasOrdinal;            // YAML supplied an `ordinal:`
    Row[]  rows;

    /// True if this form should be shown for `activeToolId`. A form with no
    /// `whenTool` filter is always shown (shared sub-form) — UNLESS it is a
    /// stage form (whenStage set), which must never leak into the per-tool
    /// lookup. So a tool match requires either a whenTool hit, or a filter-less
    /// form that is NOT a stage form.
    bool matchesTool(string activeToolId) const {
        // A tool form MUST declare an explicit `whenTool`. A filter-less form
        // is a stage form (whenStage), a shared sub-form (pulled via sub/ref),
        // or an id-lookup form (e.g. layer.props, rendered by the Layers panel
        // via formById) — none of those may leak into the Tool Properties
        // tool-matching pool, or they would render INSTEAD of the active tool's
        // own params() (app.d skips PropertyPanel.draw whenever any form
        // matches). Keeps this lookup disjoint from matchesStage by symmetry.
        if (whenTool.length == 0) return false;
        foreach (w; whenTool)
            if (w == activeToolId) return true;
        return false;
    }

    /// True if this form is the config-driven properties form for `stageId`.
    /// Only a form that explicitly declares `whenStage: <stageId>` matches; a
    /// tool form (whenTool) or a filter-less shared sub-form never matches a
    /// stage, keeping the stage lookup disjoint from matchesTool.
    bool matchesStage(string stageId) const {
        return whenStage.length != 0 && whenStage == stageId;
    }
}

// ===========================================================================
// Binding grammar
//
// A `control:` line is a full command line with EXACTLY one `?` placeholder.
// parseBinding splits it into the command id, the namespace (tool vs stage),
// the target id, the bound attr name, and the index of the `?` token among the
// positional args. It reuses argstring.parseArgstring so the form engine and
// the wire protocol agree byte-for-byte on tokenisation (the trailing `?` is
// admitted as a bareword by argstring's parser — Phase 1).
//
// Two namespaces, distinguished purely by the command id:
//   tool.attr      <toolId>  <attr> ?   -> Namespace.tool   (active tool)
//   tool.pipe.attr <stageId> <attr> ?   -> Namespace.stage  (named pipe stage)
//
// `cmd:` / `choice:` lines carry NO `?` and are fire-only; parseBinding still
// parses them (found via hasQuery=false) so the caller can validate the
// command id and dispatch on click without a value read.
// ===========================================================================

enum Namespace { tool, stage, layer, command }

/// Parsed shape of a control / cmd binding line.
struct Binding {
    string    commandId;     // e.g. "tool.attr" / "tool.pipe.attr" / "actr.auto"
    Namespace namespace;
    string    targetId;      // toolId or stageId; empty for plain commands
    string    attr;          // bound attribute name; empty when hasQuery=false
    bool      hasQuery;      // true iff the line carried exactly one `?`
    long      queryIdx;      // index of `?` in the positional list; -1 if none
    string[]  positionals;   // all positional tokens as raw strings
}

/// Rebind a namespaced control's TARGET id to the live id, returning the
/// rewritten Binding. A form line carries a CANONICAL target — the tool family
/// id (`xfrm.transform`) or the stage family id (`falloff`) — but the same form
/// serves many live ids: every XfrmTransformTool activation (move/rotate/…),
/// and every stacked FalloffStage instance (`falloff`, `falloff#1`, …). The
/// write must name the LIVE id or it lands on the wrong target. `positionals[0]`
/// is the target token; rewriting it (and `targetId`) is sufficient because the
/// line is reconstructed from positionals. An empty id keeps the literal target
/// (plain commands and callers that pass none). Tool/stage are mutually
/// exclusive by namespace, so at most one rebind applies.
Binding rebindBindingTarget(Binding b, string activeToolId, string stageId,
                            string layerIndex = "")
{
    if (b.namespace == Namespace.tool && activeToolId.length
        && b.positionals.length >= 1)
    {
        b.positionals[0] = activeToolId;
        b.targetId       = activeToolId;
    }
    else if (b.namespace == Namespace.stage && stageId.length
             && b.positionals.length >= 1)
    {
        b.positionals[0] = stageId;
        b.targetId       = stageId;
    }
    else if (b.namespace == Namespace.layer && layerIndex.length
             && b.positionals.length >= 1)
    {
        // A layer.attr line names the target LAYER by its index. The YAML
        // carries a literal placeholder index (there is no angle-bracket
        // template token); the live index is supplied here and overwrites
        // positionals[0] (and targetId), so the reconstructed write line names
        // the layer the panel is bound to. Namespaces are mutually exclusive,
        // so at most one rebind applies.
        b.positionals[0] = layerIndex;
        b.targetId       = layerIndex;
    }
    return b;
}

/// The query sentinel token. A control line marks its value slot with this.
enum string kQuerySentinel = "?";

/// Thrown by parseBinding on a malformed binding line (empty, >1 `?`, or a
/// namespaced attr line missing its target/attr operands).
class BindingException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

/// Parse a binding command line into its structured form.
///
/// Throws BindingException on:
///   * empty / comment-only line,
///   * more than one `?` placeholder,
///   * a `tool.attr` / `tool.pipe.attr` line that does not carry exactly
///     target + attr + `?` (a value-bound row must name what it binds to).
///
/// A `?`-less line (cmd / choice / plain command) parses with hasQuery=false
/// and leaves attr empty; the namespace is still classified from the command
/// id so the resolver / dispatcher can route it.
Binding parseBinding(string line)
{
    auto parsed = parseArgstring(line);
    if (parsed.isEmpty)
        throw new BindingException(
            "forms: empty/blank binding line: '" ~ line ~ "'");

    Binding b;
    b.commandId = parsed.commandId;
    b.queryIdx  = -1;
    b.namespace = classifyNamespace(parsed.commandId);

    // Collect positionals (argstring stores them under "_positional" as a JSON
    // array, omitting the key when there are none).
    string[] pos;
    if (parsed.params.type == JSONType.object &&
        ("_positional" in parsed.params)) {
        foreach (v; parsed.params["_positional"].array)
            pos ~= jsonToToken(v);
    }
    b.positionals = pos;

    // Count `?` sentinels and record the (single) index.
    size_t qCount = 0;
    foreach (i, t; pos) {
        if (t == kQuerySentinel) { qCount++; b.queryIdx = cast(long) i; }
    }
    if (qCount > 1)
        throw new BindingException(
            "forms: binding line has more than one '?' placeholder: '"
            ~ line ~ "'");
    b.hasQuery = (qCount == 1);

    // For the attr namespaces, a value-bound line MUST be
    // `<cmd> <targetId> <attr> ?` — extract target + attr. A `?`-less line in
    // these namespaces is a malformed value bind (a control row needs its `?`,
    // a cmd/choice row should not use a tool.attr line at all). The layer
    // namespace (`layer.attr <index> <attr> ?`) follows the same `[id, attr, ?]`
    // shape — the `id` token is the live layer INDEX (a literal placeholder in
    // YAML, overwritten by rebindBindingTarget at draw time).
    if (b.namespace == Namespace.tool || b.namespace == Namespace.stage
        || b.namespace == Namespace.layer) {
        if (!b.hasQuery)
            throw new BindingException(
                "forms: '" ~ b.commandId ~ "' binding has no '?' value slot: '"
                ~ line ~ "'");
        // Expect exactly: [targetId, attr, "?"] with the "?" last.
        if (pos.length != 3 || b.queryIdx != 2)
            throw new BindingException(
                "forms: '" ~ b.commandId ~
                "' binding must be '<id> <attr> ?' (got '" ~ line ~ "')");
        b.targetId = pos[0];
        b.attr     = pos[1];
    }
    return b;
}

/// Classify a command id into a resolution namespace. Only the two attr
/// commands carry a queryable namespace; everything else is a plain command
/// (cmd / choice entries — fire-only, validated against the command registry
/// in a later phase).
Namespace classifyNamespace(string commandId)
{
    if (commandId == "tool.attr")       return Namespace.tool;
    if (commandId == "tool.pipe.attr")  return Namespace.stage;
    if (commandId == "layer.attr")      return Namespace.layer;
    return Namespace.command;
}

/// Render a parsed positional JSON value back to its source token string.
/// argstring already typed numbers/bools/strings; we re-stringify so the
/// binding can be substituted and re-dispatched (the write path replaces the
/// `?` token with the edited value and re-serialises the whole line).
private string jsonToToken(JSONValue v)
{
    import std.conv : to;
    final switch (v.type) {
        case JSONType.string:        return v.str;
        case JSONType.integer:       return v.integer.to!string;
        case JSONType.uinteger:      return v.uinteger.to!string;
        case JSONType.float_:        return v.floating.to!string;
        case JSONType.true_:         return "true";
        case JSONType.false_:        return "false";
        case JSONType.null_:         return "null";
        case JSONType.object:
        case JSONType.array:         return v.toString();
    }
}

// ===========================================================================
// Widget-class decision (datatype pass-through)
//
// The widget for a value-bound control is derived from the RESOLVED Param's
// Kind + ParamHints — NEVER authored in YAML. This is the datatype-pass-through
// analog: a binding whose attr resolves to an Enum renders a combo
// automatically; the YAML never lists the choices (they come from the Param).
//
// A control row MAY override the derived widget with an explicit `style:`
// (popup / slider / drag); resolveControl applies that override on top of the
// datatype-derived default, so the renderer reads exactly one WidgetKind.
// ===========================================================================

enum WidgetKind {
    none,        // unresolved / non-value row
    checkbox,    // Bool, default boolean style
    button,      // Bool, booleanStyle == button (momentary toggle button)
    dragInt,     // Int
    sliderInt,   // Int with a Slider hint or forced slider style
    dragFloat,   // Float
    sliderFloat, // Float with a Slider hint or forced slider style
    combo,       // Enum / IntEnum  (choices come from the Param)
    text,        // String
    vec3,        // Vec3_ (three-drag, or expanded into a group by the renderer)
}

/// Map a resolved Param's datatype + hints to a default widget class. Pure;
/// the `style`/`booleanStyle` overrides from the row are applied by
/// resolveControl on top of this.
WidgetKind widgetForKind(Param.Kind kind, ParamHints hints)
{
    final switch (kind) {
        case Param.Kind.Bool:
            // Bool default is a checkbox; the booleanStyle override (button) is
            // applied by resolveControl, not here.
            return WidgetKind.checkbox;
        case Param.Kind.Int:
            return (hints.widget == ParamHints.Widget.Slider)
                 ? WidgetKind.sliderInt : WidgetKind.dragInt;
        case Param.Kind.Float:
            return (hints.widget == ParamHints.Widget.Slider)
                 ? WidgetKind.sliderFloat : WidgetKind.dragFloat;
        case Param.Kind.Enum:
        case Param.Kind.IntEnum:
            return WidgetKind.combo;
        case Param.Kind.String:
            return WidgetKind.text;
        case Param.Kind.Vec3_:
            return WidgetKind.vec3;
        // Array kinds are never form-bound value controls (they carry parallel
        // index/before/after arrays for headless commands, not a single
        // editable value). Treat as unrenderable.
        case Param.Kind.IntArray:
        case Param.Kind.Vec3Array:
            return WidgetKind.none;
    }
}

// ===========================================================================
// Resolver
//
// resolveControl takes a parsed control Binding and a SNAPSHOT of the active
// provider's params() (the caller takes that snapshot once per frame — see the
// plan's per-frame-cost mitigation) and resolves the bound attr to a Param.
//
//   found == false  -> the attr is absent from the CURRENT params(). The
//                       renderer hides the row this frame (runtime visibility).
//                       The STARTUP-strict layer (throw on a YAML typo) is a
//                       loader concern resolved against the full static
//                       universe; this resolver only reports presence, leaving
//                       the loader free to promote a false to a throw.
//   found == true   -> param holds a COPY of the matched Param (so the renderer
//                       reads its typed pointer + hints + label), choices holds
//                       the enum/intEnum choice list (empty otherwise), and
//                       widget is the final WidgetKind after applying the row's
//                       style / booleanStyle overrides.
// ===========================================================================

struct ResolvedControl {
    bool       found;
    Param      param;        // valid iff found; a copy of the matched Param
    string[2][] choices;     // enum/intEnum [tag,label] pairs; empty otherwise
    WidgetKind widget = WidgetKind.none;
}

/// Resolve a control row against a provider's params() snapshot. `row` supplies
/// the binding line (row.command) plus the style / booleanStyle overrides;
/// `providerParams` is the live schema of the active tool or stage.
///
/// Only RowKind.control rows are value-resolvable; passing any other kind
/// returns found=false (cmd / choice rows fire commands and read no value).
ResolvedControl resolveControl(Row row, Param[] providerParams)
{
    ResolvedControl rc;
    if (row.kind != RowKind.control)
        return rc;                       // not a value bind

    auto b = parseBinding(row.command);  // throws on a malformed line
    return resolveBinding(b, providerParams, row.style, row.booleanStyle);
}

/// Resolve a parsed Binding directly (used by resolveControl and by tests that
/// build a Binding by hand). `styleOverride` / `boolStyle` come from the row.
ResolvedControl resolveBinding(const ref Binding b, Param[] providerParams,
                               ControlStyle styleOverride = ControlStyle.default_,
                               BooleanStyle boolStyle = BooleanStyle.checkbox)
{
    ResolvedControl rc;
    if (!b.hasQuery)
        return rc;                       // fire-only line, nothing to read

    foreach (ref p; providerParams) {
        if (p.name == b.attr) {
            rc.found   = true;
            rc.param   = p;
            rc.choices = choicesOf(p);
            rc.widget  = decideWidget(p, styleOverride, boolStyle);
            return rc;
        }
    }
    // Absent from the CURRENT params() — runtime-hidden. The loader's
    // startup-strict pass resolves against the full static universe and may
    // promote this to a throw; the resolver itself stays non-throwing.
    return rc;
}

/// Apply the row's style / booleanStyle overrides on top of the
/// datatype-derived widget.
private WidgetKind decideWidget(const ref Param p, ControlStyle styleOverride,
                                BooleanStyle boolStyle)
{
    WidgetKind w = widgetForKind(p.kind, p.hints);

    // Bool: the row chooses checkbox vs momentary button.
    if (p.kind == Param.Kind.Bool)
        return (boolStyle == BooleanStyle.button)
             ? WidgetKind.button : WidgetKind.checkbox;

    // Explicit style override (popup / slider / drag) wins over the
    // datatype default for the numeric / enum kinds it applies to.
    final switch (styleOverride) {
        case ControlStyle.default_:
            break;
        case ControlStyle.popup:
            // Force a dropdown — only meaningful for enum-backed kinds.
            if (p.kind == Param.Kind.Enum || p.kind == Param.Kind.IntEnum)
                w = WidgetKind.combo;
            break;
        case ControlStyle.slider:
            if (p.kind == Param.Kind.Int)   w = WidgetKind.sliderInt;
            if (p.kind == Param.Kind.Float) w = WidgetKind.sliderFloat;
            break;
        case ControlStyle.drag:
            if (p.kind == Param.Kind.Int)   w = WidgetKind.dragInt;
            if (p.kind == Param.Kind.Float) w = WidgetKind.dragFloat;
            break;
    }
    return w;
}

// ===========================================================================
// Write-path serialization (Phase 4)
//
// The renderer (forms_render.d) writes an edited value by substituting it for
// the `?` token in the control's command line and dispatching the result. These
// helpers do the value->token formatting + the line reconstruction. They live
// HERE (not in forms_render.d) so they stay ImGui-free and headless-unit-
// testable: a test can import `forms` and exercise them without linking d_imgui.
//
// Float formatting uses %g to match argstring._fmtFloat (forms_engine_plan.md
// Phase 2 review TODO), so a UI-originated write argstring is byte-identical to
// what serializeParams() would emit for the same value — the existing
// `tool.attr` write tests stay valid for forms-originated writes.
// ===========================================================================

/// Format a value JSON as the argstring token it should occupy in the `?` slot.
/// Floats use %g (argstring._fmtFloat's strategy); bools/ints/strings pass
/// through as their canonical token text.
string valueToArgToken(JSONValue v)
{
    import std.conv : to;
    final switch (v.type) {
        case JSONType.true_:    return "true";
        case JSONType.false_:   return "false";
        case JSONType.integer:  return v.integer.to!string;
        case JSONType.uinteger: return v.uinteger.to!string;
        case JSONType.float_:   return fmtFloatG(v.floating);
        case JSONType.string:   return v.str;
        case JSONType.null_:    return "null";
        case JSONType.object:
        case JSONType.array:    return v.toString();
    }
}

/// %g float formatting, matching argstring._fmtFloat's [1e-4,1e5] strategy
/// (NaN/Inf emit textual sentinels rather than the platform default).
private string fmtFloatG(double f)
{
    import std.math : isNaN, isInfinity;
    if (isNaN(f))      return "nan";
    if (isInfinity(f)) return f > 0 ? "inf" : "-inf";
    return format("%g", f);
}

/// Reconstruct a `<cmd> <targetId> <attr> <value>` argstring from a parsed
/// Binding by substituting `value` into the `?` slot. Tokens that would break
/// argstring tokenization (whitespace / structural chars) are quoted so the
/// reconstructed line re-parses to the same positionals.
string substituteQuery(const ref Binding b, JSONValue value)
{
    import std.array : join;
    string[] toks;
    toks ~= b.commandId;
    foreach (i, p; b.positionals) {
        if (cast(long) i == b.queryIdx)
            toks ~= quoteIfNeeded(valueToArgToken(value));
        else
            toks ~= quoteIfNeeded(p);
    }
    return toks.join(" ");
}

/// Quote a token iff it contains whitespace or argstring-significant chars.
/// Numbers / bools / simple identifiers pass through unquoted (matching
/// serializeParams() output, so forms writes stay byte-identical).
private string quoteIfNeeded(string s)
{
    if (s.length == 0) return `""`;
    // Quote a literal "?" so a written string value can never morph into the
    // query sentinel if the line is ever re-parsed by parseBinding.
    if (s == "?") return `"?"`;
    foreach (c; s)
        if (c == ' ' || c == '\t' || c == '"' || c == '{' || c == '}'
            || c == ',' || c == ':')
            return `"` ~ s ~ `"`;
    return s;
}

/// Read the current enum / intEnum tag string from a Param (what a combo
/// matches its choices against). Enum => `*sptr`; IntEnum => the wireTag of the
/// entry whose value equals `*iePtr`.
string currentEnumTag(const ref Param p)
{
    import std.conv : to;
    if (p.kind == Param.Kind.Enum)
        return *p.sptr;
    if (p.kind == Param.Kind.IntEnum) {
        foreach (ref e; p.intEnumValues)
            if (e.value == *p.iePtr) return e.wireTag;
        return (*p.iePtr).to!string;
    }
    return "";
}

// ===========================================================================
// YAML loader  (Phase 3)
//
// loadForms parses `config/forms/*.yaml` into the Form/Row tree above. It is a
// cousin of buttonset.loadButtons / tool_presets.loadToolPresets: dyaml-based,
// strict (explicit containsKey checks, descriptive throws carrying the file
// path + form/row context), fails loud at startup on a malformed file.
//
// The YAML shape is the schema spec'd in doc/forms_engine_plan.md:
//
//   forms:
//     - id: transform.main
//       label: Transform
//       showLabel: false
//       whenTool: xfrm.transform        # scalar OR a list
//       category: toolprops/main
//       ordinal: 150.45
//       rows:
//         - { control: "tool.attr xfrm.transform T ?", label: Translate,
//             booleanStyle: checkbox }
//         - { divider: true }
//         - group: Position
//           style: inline
//           rows:
//             - { control: "tool.attr xfrm.transform TX ?", label: X }
//         - choice: "Action Center"
//           entries:
//             - { label: Auto, cmd: "actr.auto" }
//         - { cmd: "mesh.flip", label: Flip }
//         - { sub: transform.aux }
//         - { ref: toolprops.falloff }
//         - { label: "Some text" }
//
// A row is exactly one kind, detected by which discriminator key it carries:
// control / cmd / choice / group / sub / ref / divider / label. Parsing throws
// if a row carries zero or more than one discriminator key.
//
// Loading is decoupled from validation. loadForms does PURELY structural work
// (parse + shape checks + exactly-one-`?` per control line) so it stays
// app-free and unit-testable from a YAML string. The startup-strict ATTR
// validation (resolve every binding against the live tool/stage/command
// universe, throw on a typo) lives in validateForms below, which takes the
// universe as caller-supplied delegates so this module never imports the
// registry or the live pipeline.
// ===========================================================================

/// Thrown by loadForms on a malformed form file (missing keys, bad row shape,
/// a control line without exactly one `?`, etc.). Carries the file path.
class FormLoadException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

/// Parse a forms YAML file into a Form[] tree. Structural validation only;
/// call validateForms afterwards for the startup-strict attr universe pass.
Form[] loadForms(string path)
{
    import dyaml;
    Node root;
    try {
        root = Loader.fromFile(path).load();
    } catch (Exception e) {
        throw new FormLoadException(
            format("forms: failed to load '%s': %s", path, e.msg));
    }
    return parseFormsRoot(root, path);
}

/// Parse a forms YAML document already loaded into a dyaml Node. Split out so
/// tests can drive it from `Loader.fromString` without touching the disk.
Form[] loadFormsFromString(string yaml, string ctx = "<string>")
{
    import dyaml;
    Node root;
    try {
        root = Loader.fromString(yaml).load();
    } catch (Exception e) {
        throw new FormLoadException(
            format("forms: failed to parse %s: %s", ctx, e.msg));
    }
    return parseFormsRoot(root, ctx);
}

private Form[] parseFormsRoot(ref /*dyaml.*/ DyamlNodeT root, string ctx)
{
    import dyaml : Node, NodeID;
    if (!root.containsKey("forms"))
        throw new FormLoadException(
            format("forms: '%s' missing top-level 'forms' key", ctx));

    Form[] forms;
    foreach (DyamlNodeT node; root["forms"])
        forms ~= parseForm(node, ctx);
    return forms;
}

private Form parseForm(ref /*dyaml.*/ DyamlNodeT node, string ctx)
{
    import dyaml : Node, NodeID;
    if (!node.containsKey("id"))
        throw new FormLoadException(
            format("forms: a form in '%s' is missing its 'id'", ctx));

    Form f;
    f.id = node["id"].as!string;

    if (node.containsKey("label"))     f.label     = node["label"].as!string;
    if (node.containsKey("showLabel")) f.showLabel = node["showLabel"].as!bool;
    if (node.containsKey("category"))  f.category  = node["category"].as!string;
    if (node.containsKey("ordinal")) {
        f.ordinal    = node["ordinal"].as!double;
        f.hasOrdinal = true;
    }

    // whenTool: scalar id OR a list of ids. Absent => always shown.
    if (node.containsKey("whenTool")) {
        Node wt = node["whenTool"];
        if (wt.nodeID == NodeID.sequence) {
            foreach (Node w; wt) f.whenTool ~= w.as!string;
        } else if (wt.nodeID == NodeID.scalar) {
            f.whenTool ~= wt.as!string;
        } else {
            throw new FormLoadException(format(
                "forms: form '%s' in '%s' has a non-scalar/sequence 'whenTool'",
                f.id, ctx));
        }
    }

    // whenStage: scalar pipe-stage id. Binds this form to a single stage's
    // Tool Properties section (looked up by formByStage). A form is a tool form
    // (whenTool), a stage form (whenStage), or a shared sub-form (neither) —
    // never both, so the two lookups stay disjoint.
    if (node.containsKey("whenStage")) {
        f.whenStage = node["whenStage"].as!string;
        if (f.whenTool.length != 0)
            throw new FormLoadException(format(
                "forms: form '%s' in '%s' declares both 'whenTool' and "
                ~ "'whenStage' — a form binds to a tool OR a stage, not both",
                f.id, ctx));
    }

    if (node.containsKey("rows"))
        foreach (Node r; node["rows"])
            f.rows ~= parseRow(r, f.id, ctx);

    return f;
}

private Row parseRow(ref /*dyaml.*/ DyamlNodeT node, string formId, string ctx)
{
    import dyaml : Node, NodeID;

    // Detect the single active discriminator key. Exactly one of these must
    // be present (label-only static text counts as the `label` discriminator,
    // but only when no other discriminator is present — see below).
    static immutable string[] discriminators = [
        "control", "cmd", "choice", "group", "sub", "ref", "divider",
    ];
    string kind;
    int kindCount = 0;
    foreach (d; discriminators)
        if (node.containsKey(d)) { kind = d; kindCount++; }

    // A row carrying `label:` and nothing else is a static text row. When a
    // discriminator IS present, `label:` is that row's presentation label.
    if (kindCount == 0 && node.containsKey("label"))
        kind = "label";

    if (kindCount > 1)
        throw new FormLoadException(format(
            "forms: a row in form '%s' (%s) carries more than one row-kind key "
            ~ "(%s) — a row is exactly one kind", formId, ctx, kind));
    if (kind.length == 0)
        throw new FormLoadException(format(
            "forms: a row in form '%s' (%s) has no recognised row-kind key "
            ~ "(control/cmd/choice/group/sub/ref/divider/label)", formId, ctx));

    Row row;
    switch (kind) {
        case "control":
            row.kind    = RowKind.control;
            row.command = node["control"].as!string;
            applyControlFields(row, node, formId, ctx);
            // Structural: a control line must carry exactly one `?`. parseBinding
            // throws on 0 or >1, surfacing the file context.
            try {
                parseBinding(row.command);
            } catch (BindingException e) {
                throw new FormLoadException(format(
                    "forms: form '%s' (%s) control '%s': %s",
                    formId, ctx, row.command, e.msg));
            }
            break;

        case "cmd":
            row.kind    = RowKind.cmd;
            row.command = node["cmd"].as!string;
            applyControlFields(row, node, formId, ctx);
            break;

        case "choice":
            row.kind  = RowKind.choice;
            row.label = node["choice"].as!string;
            if (!node.containsKey("entries"))
                throw new FormLoadException(format(
                    "forms: choice row '%s' in form '%s' (%s) has no 'entries'",
                    row.label, formId, ctx));
            foreach (Node e; node["entries"]) {
                if (!e.containsKey("cmd"))
                    throw new FormLoadException(format(
                        "forms: a choice entry under '%s' in form '%s' (%s) "
                        ~ "is missing its 'cmd'", row.label, formId, ctx));
                ChoiceEntry ce;
                ce.cmd   = e["cmd"].as!string;
                ce.label = e.containsKey("label") ? e["label"].as!string : ce.cmd;
                row.entries ~= ce;
            }
            applyControlFields(row, node, formId, ctx);
            break;

        case "group":
            row.kind  = RowKind.group;
            row.label = node["group"].as!string;
            row.groupStyle = parseGroupStyle(node, formId, ctx);
            if (node.containsKey("rows"))
                foreach (Node r; node["rows"])
                    row.rows ~= parseRow(r, formId, ctx);
            break;

        case "sub":
            row.kind   = RowKind.sub;
            row.formId = node["sub"].as!string;
            applyControlFields(row, node, formId, ctx);
            break;

        case "ref":
            row.kind   = RowKind.ref_;
            row.formId = node["ref"].as!string;
            break;

        case "divider":
            row.kind = RowKind.divider;
            break;

        case "label":
            row.kind  = RowKind.label;
            row.label = node["label"].as!string;
            break;

        default:
            assert(false, "unreachable row kind");
    }

    // Optional visibility gate — applies to ANY row kind, so it is parsed here
    // rather than in applyControlFields (group rows skip that helper).
    if (node.containsKey("whenAttr"))
        row.whenAttr = node["whenAttr"].as!string;

    return row;
}

/// Parse the shared presentation fields (label / id / style / booleanStyle /
/// align / showLabel / tooltip) onto a row that carries them.
private void applyControlFields(ref Row row, ref /*dyaml.*/ DyamlNodeT node,
                                string formId, string ctx)
{
    if (node.containsKey("label"))    row.label    = node["label"].as!string;
    if (node.containsKey("id"))       row.id       = node["id"].as!string;
    if (node.containsKey("tooltip"))  row.tooltip  = node["tooltip"].as!string;
    if (node.containsKey("showLabel"))row.showLabel= node["showLabel"].as!bool;

    if (node.containsKey("style"))
        row.style = parseControlStyle(node["style"].as!string, formId, ctx);
    if (node.containsKey("booleanStyle"))
        row.booleanStyle =
            parseBooleanStyle(node["booleanStyle"].as!string, formId, ctx);
    if (node.containsKey("align"))
        row.align_ = parseAlign(node["align"].as!string, formId, ctx);
}

private ControlStyle parseControlStyle(string s, string formId, string ctx) {
    switch (s.strip) {
        case "default": case "":  return ControlStyle.default_;
        case "popup":             return ControlStyle.popup;
        case "slider":            return ControlStyle.slider;
        case "drag":              return ControlStyle.drag;
        default: throw new FormLoadException(format(
            "forms: form '%s' (%s) has unknown control style '%s' "
            ~ "(default/popup/slider/drag)", formId, ctx, s));
    }
}

private BooleanStyle parseBooleanStyle(string s, string formId, string ctx) {
    switch (s.strip) {
        case "checkbox": case "": return BooleanStyle.checkbox;
        case "button":            return BooleanStyle.button;
        default: throw new FormLoadException(format(
            "forms: form '%s' (%s) has unknown booleanStyle '%s' "
            ~ "(checkbox/button)", formId, ctx, s));
    }
}

private AlignHint parseAlign(string s, string formId, string ctx) {
    switch (s.strip) {
        case "default": case "": return AlignHint.default_;
        case "sameline":         return AlignHint.sameline;
        case "wide":             return AlignHint.wide;
        case "full":             return AlignHint.full;
        default: throw new FormLoadException(format(
            "forms: form '%s' (%s) has unknown align '%s' "
            ~ "(default/sameline/wide/full)", formId, ctx, s));
    }
}

private GroupStyle parseGroupStyle(ref /*dyaml.*/ DyamlNodeT node,
                                   string formId, string ctx) {
    if (!node.containsKey("style")) return GroupStyle.inline_;
    string s = node["style"].as!string.strip;
    switch (s) {
        case "inline": case "": return GroupStyle.inline_;
        case "block":           return GroupStyle.block;
        case "buttons":         return GroupStyle.buttons;
        default: throw new FormLoadException(format(
            "forms: form '%s' (%s) group has unknown style '%s' "
            ~ "(inline/block/buttons)",
            formId, ctx, s));
    }
}

// dyaml's Node type, aliased once so the parse helpers above read cleanly and
// the dyaml import stays scoped to this section.
private alias DyamlNodeT = imported!"dyaml".Node;

// ===========================================================================
// Startup-strict attr validation  (Phase 3 step 4)
//
// The runtime resolver (resolveControl above) reports a clean found=false for
// an attr that is dynamically absent from the CURRENT params() — the renderer
// hides that row. That is the RUNTIME layer. The STARTUP-strict layer below
// rejects a YAML typo against the full STATIC universe so a misspelt attr or
// an unknown command id fails LOUD at load, exactly like tool_presets.d does.
//
// The two namespaces resolve their universe differently because the registry
// holds only tool + command factories (no stage-factory map): a tool's
// universe is its params() names; a stage's universe is its knownAttrs()
// (the static union — see Stage.knownAttrs()); a cmd/choice command id must
// exist in the command registry. This module never imports the registry or
// the live pipeline — the caller (app.d) supplies these three universes as
// delegates, keeping forms.d unit-testable in isolation.
// ===========================================================================

/// Resolvers the caller supplies so validateForms can reach the live
/// tool/stage/command universe without forms.d importing the registry.
struct FormValidators {
    /// Full static attr names for a tool id (its params() names). Returns
    /// null if the tool id is unknown to the registry.
    string[] delegate(string toolId)  toolAttrs;
    /// Full static attr names for a pipe-stage id (its knownAttrs()). Returns
    /// null if the stage id is not in the live pipeline.
    string[] delegate(string stageId) stageAttrs;
    /// True iff a plain command id exists in the command registry.
    bool     delegate(string cmdId)   commandExists;
}

/// Thrown by validateForms when a binding references an attr / stage / tool /
/// command that does not exist in the static universe. Carries form + binding
/// context, mirroring tool_presets.d's "sets unknown attr '%s' on '%s'".
class FormValidationException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

/// Strict-validate every binding in `forms` against the static universe the
/// `v` delegates expose. Throws FormValidationException on the first typo.
/// `ctx` is the source path/string, threaded into every message.
void validateForms(Form[] forms, FormValidators v, string ctx)
{
    foreach (ref f; forms) {
        validateFormStageBinding(f, v, ctx);
        foreach (ref r; f.rows)
            validateRow(r, f.id, v, ctx);
    }
}

/// A `whenStage:` form must name a LIVE pipe stage (the per-stage loop will
/// otherwise never find it), and every value control it carries must target
/// THAT stage's namespace — pinning the contract that a stage form configures
/// its own stage. Skipped when the stageAttrs delegate is absent (pure-loader
/// callers that don't supply the live universe). The runtime resolver still
/// hides type-filtered rows; this is the boot-time typo fence.
private void validateFormStageBinding(ref Form f, FormValidators v, string ctx)
{
    if (f.whenStage.length == 0) return;
    if (v.stageAttrs is null) return;          // no live universe to check against

    if (v.stageAttrs(f.whenStage) is null)
        throw new FormValidationException(format(
            "forms: form '%s' (%s) binds to unknown pipe stage '%s' via "
            ~ "whenStage", f.id, ctx, f.whenStage));

    auto stageUniverse = v.stageAttrs(f.whenStage);

    // Every value-bound control in a stage form must target this same stage.
    void checkRow(ref Row r) {
        if (r.kind == RowKind.control) {
            auto b = parseBinding(r.command);
            if (b.namespace != Namespace.stage || b.targetId != f.whenStage)
                throw new FormValidationException(format(
                    "forms: form '%s' (%s) is a whenStage:'%s' form but control "
                    ~ "'%s' does not target that stage (expected "
                    ~ "'tool.pipe.attr %s <attr> ?')",
                    f.id, ctx, f.whenStage, r.command, f.whenStage));
        }
        // A `whenAttr` gate names an attr of THIS stage's universe — typo-fence
        // it at boot like a control binding (the runtime resolver only hides;
        // it never errors on an unknown gate).
        if (r.whenAttr.length && !hasName(stageUniverse, r.whenAttr))
            throw new FormValidationException(format(
                "forms: form '%s' (%s) row gates on unknown attr '%s' "
                ~ "(whenAttr) for stage '%s'",
                f.id, ctx, r.whenAttr, f.whenStage));
        foreach (ref c; r.rows) checkRow(c);
    }
    foreach (ref r; f.rows) checkRow(r);
}

private void validateRow(ref Row r, string formId, FormValidators v, string ctx)
{
    final switch (r.kind) {
        case RowKind.control:
            validateControlBinding(r.command, formId, v, ctx);
            break;

        case RowKind.cmd:
            validateCommandLine(r.command, formId, v, ctx);
            break;

        case RowKind.choice:
            foreach (ref e; r.entries)
                validateCommandLine(e.cmd, formId, v, ctx);
            break;

        case RowKind.group:
            foreach (ref child; r.rows)
                validateRow(child, formId, v, ctx);
            break;

        // sub / ref / divider / label carry no command binding to validate
        // here (cross-form reference resolution is a renderer/assembly concern,
        // out of scope for the strict attr pass).
        case RowKind.sub:
        case RowKind.ref_:
        case RowKind.divider:
        case RowKind.label:
            break;
    }
}

/// Resolve a `control:` binding's attr against its namespace's static universe.
private void validateControlBinding(string line, string formId,
                                    FormValidators v, string ctx)
{
    auto b = parseBinding(line);   // already structurally OK from the loader
    final switch (b.namespace) {
        case Namespace.tool:
            if (v.toolAttrs is null) break;
            auto universe = v.toolAttrs(b.targetId);
            if (universe is null)
                throw new FormValidationException(format(
                    "forms: form '%s' (%s) binds to unknown tool '%s' "
                    ~ "in '%s'", formId, ctx, b.targetId, line));
            if (!hasName(universe, b.attr))
                throw new FormValidationException(format(
                    "forms: form '%s' (%s) sets unknown attr '%s' on tool "
                    ~ "'%s' (binding '%s')", formId, ctx, b.attr,
                    b.targetId, line));
            break;

        case Namespace.stage:
            if (v.stageAttrs is null) break;
            auto universe = v.stageAttrs(b.targetId);
            if (universe is null)
                throw new FormValidationException(format(
                    "forms: form '%s' (%s) binds to unknown pipe stage '%s' "
                    ~ "in '%s'", formId, ctx, b.targetId, line));
            if (!hasName(universe, b.attr))
                throw new FormValidationException(format(
                    "forms: form '%s' (%s) sets unknown attr '%s' on stage "
                    ~ "'%s' (binding '%s')", formId, ctx, b.attr,
                    b.targetId, line));
            break;

        case Namespace.layer:
            // `layer.attr <index> <attr> ?` — a layer (item) property bind.
            // The bound attr resolves at runtime against the live
            // LayerPropsProvider's params() (the static 14: pos/rot/scl/pivot
            // components + name + visible); the renderer hides a row whose attr
            // is absent, exactly like the tool/stage runtime path. There is no
            // layer-attr universe delegate here, so the boot-strict pass accepts
            // the line unconditionally (its shape was already checked by
            // parseBinding). The `<index>` token is a literal placeholder
            // overwritten with the live layer index by rebindBindingTarget; it
            // is NOT validated as a target id here.
            break;

        case Namespace.command:
            // A `control:` line in the plain-command namespace is malformed —
            // a value bind must be tool.attr / tool.pipe.attr / layer.attr.
            // parseBinding already rejects a `?`-less tool/stage/layer line; a
            // `?`-bearing plain command (e.g. "actr.auto ?") is nonsensical as a
            // value bind.
            throw new FormValidationException(format(
                "forms: form '%s' (%s) control binds to plain command '%s' — "
                ~ "value controls must use tool.attr / tool.pipe.attr / "
                ~ "layer.attr (binding '%s')", formId, ctx, b.commandId, line));
    }
}

/// Validate a fire-only `cmd:` / choice-entry command id against the registry.
private void validateCommandLine(string line, string formId,
                                 FormValidators v, string ctx)
{
    auto b = parseBinding(line);
    if (b.hasQuery)
        throw new FormValidationException(format(
            "forms: form '%s' (%s) cmd/choice line carries a '?' value slot "
            ~ "(fire-only commands take no query): '%s'", formId, ctx, line));
    if (v.commandExists !is null && !v.commandExists(b.commandId))
        throw new FormValidationException(format(
            "forms: form '%s' (%s) references unknown command '%s' "
            ~ "(binding '%s')", formId, ctx, b.commandId, line));
}

private bool hasName(string[] names, string n) {
    foreach (x; names) if (x == n) return true;
    return false;
}

// ===========================================================================
// Loaded-forms registry
//
// The startup-loaded, strict-validated Form[] live here so the Phase-4 renderer
// (FormsPanel, main thread) can look up the form(s) matching the active tool.
// Populated once at app startup (see app.d) AFTER the pipeline + registry are
// constructed. Main-thread only — no locking.
// ===========================================================================

__gshared Form[] g_forms;

/// Forms enablement gate. As of Phase 5 (forms_engine_plan.md) FormsPanel is the
/// PRIMARY Tool Properties UI: when TRUE (the default), a tool that has a matching
/// loaded form renders through FormsPanel; a tool WITHOUT a form keeps the
/// unchanged PropertyPanel / drawProperties() fallback. The `VIBE3D_FORMS=0`
/// kill-switch flips this back OFF (every tool on the legacy panel) for
/// debugging / A-B comparison.
///
/// Two-live-widget resolution (forms_engine_plan.md Phase 5 step 2): the
/// transform tool's form owns the translate value rows (Position TX/TY/TZ) plus
/// the T/R/S checkboxes, so when its form renders, app.d suppresses the legacy
/// translate sliders (`moveSub.drawProperties()`) while still drawing the Rotate
/// / Scale sliders (R/S value editing has no form rows until Phase 5b and lives
/// ONLY in those legacy sliders). The transform tool already sets
/// renderParamsAsPanel()==false, so PropertyPanel.draw early-returns for it and
/// there is no schema-panel double-edit either.
__gshared bool g_formsPanelEnabled = true;

/// Forms whose `whenTool` filter matches `activeToolId` (empty filter => always
/// shown). Caller renders these in `category`/`ordinal` order.
Form[] formsForTool(string activeToolId)
{
    Form[] hits;
    foreach (ref f; g_forms)
        if (f.matchesTool(activeToolId))
            hits ~= f;
    return hits;
}

/// Look up a loaded form by its stable `id` (the target of `sub`/`ref`, and —
/// as of Phase 6 — the key the Tool Properties per-stage loop uses to prefer a
/// config-driven stage form over the legacy drawProvider path). Returns a
/// pointer into `g_forms` (so the caller renders it without copying its rows),
/// or null when no form carries that id. Main-thread only — `g_forms` is
/// populated once at startup and never mutated afterwards.
Form* formById(string id)
{
    foreach (ref f; g_forms)
        if (f.id == id)
            return &f;
    return null;
}

/// Look up the config-driven Tool Properties form bound to a pipe stage. The
/// Phase-6 per-stage loop calls this with the stage's `id()` (e.g. "falloff");
/// it matches ONLY a form that declared `whenStage: <stageId>` (form `id`s are
/// a separate form-reference namespace — `sub`/`ref` targets — and are NOT the
/// stage id, which is why the loop cannot use formById(stage.id())). Returns a
/// pointer into `g_forms`, or null when no stage form is bound. Main-thread
/// only — `g_forms` is populated once at startup and never mutated afterwards.
Form* formByStage(string stageId)
{
    foreach (ref f; g_forms)
        if (f.matchesStage(stageId))
            return &f;
    return null;
}

// ===========================================================================
// Inline unit tests — schema construction + binding parse + resolver.
// ===========================================================================

version (unittest)
{
    unittest { // RowKind discriminator + makeControl payload
        auto r = Row.makeControl("tool.attr xfrm.transform TX ?", "X", "tx");
        assert(r.kind == RowKind.control);
        assert(r.command == "tool.attr xfrm.transform TX ?");
        assert(r.label == "X");
        assert(r.id == "tx");
        assert(r.showLabel);
        assert(r.booleanStyle == BooleanStyle.checkbox);
    }

    unittest { // group nests rows; choice carries entries
        auto g = Row.makeGroup("Position", [
            Row.makeControl("tool.attr xfrm.transform TX ?", "X"),
            Row.makeControl("tool.attr xfrm.transform TY ?", "Y"),
        ]);
        assert(g.kind == RowKind.group);
        assert(g.rows.length == 2);
        assert(g.groupStyle == GroupStyle.inline_);

        auto c = Row.makeChoice("Action Center", [
            ChoiceEntry("Auto",   "actr.auto"),
            ChoiceEntry("Select", "actr.select"),
        ]);
        assert(c.kind == RowKind.choice);
        assert(c.entries.length == 2);
        assert(c.entries[0].cmd == "actr.auto");
    }

    unittest { // divider / label / sub / ref kinds
        assert(Row.makeDivider().kind == RowKind.divider);
        assert(Row.makeLabel("hello").kind == RowKind.label);
        assert(Row.makeLabel("hello").label == "hello");
        assert(Row.makeSub("transform.main").formId == "transform.main");
        assert(Row.makeRef("toolprops.falloff").kind == RowKind.ref_);
    }

    unittest { // Form.matchesTool: filter-less never matches; list membership
        Form shared_;                       // no whenTool — id-lookup / sub-form
        assert(!shared_.matchesTool("anything"));

        Form stageForm;                     // stage form — not a tool form
        stageForm.whenStage = "falloff";
        assert(!stageForm.matchesTool("anything"));

        Form f;
        f.whenTool = ["xfrm.transform", "move"];
        assert(f.matchesTool("xfrm.transform"));
        assert(f.matchesTool("move"));
        assert(!f.matchesTool("scale"));
    }

    // --- binding parse ----------------------------------------------------

    unittest { // tool.attr round-trip: namespace + target + attr + query idx
        auto b = parseBinding("tool.attr xfrm.transform TX ?");
        assert(b.commandId == "tool.attr");
        assert(b.namespace == Namespace.tool);
        assert(b.targetId  == "xfrm.transform");
        assert(b.attr      == "TX");
        assert(b.hasQuery);
        assert(b.queryIdx  == 2);
        assert(b.positionals == ["xfrm.transform", "TX", "?"]);
    }

    unittest { // tool.pipe.attr -> stage namespace
        auto b = parseBinding("tool.pipe.attr falloff start ?");
        assert(b.namespace == Namespace.stage);
        assert(b.targetId  == "falloff");
        assert(b.attr      == "start");
        assert(b.hasQuery);
    }

    unittest { // bool attr binds the same way as a float attr
        auto b = parseBinding("tool.attr xfrm.transform T ?");
        assert(b.namespace == Namespace.tool);
        assert(b.attr == "T");
        assert(b.hasQuery);
    }

    unittest { // plain command (choice/cmd entry) -> command namespace, no query
        auto b = parseBinding("actr.auto");
        assert(b.commandId == "actr.auto");
        assert(b.namespace == Namespace.command);
        assert(!b.hasQuery);
        assert(b.queryIdx == -1);
        assert(b.attr.length == 0);
    }

    unittest { // malformed: empty / blank line throws
        bool threw = false;
        try parseBinding("   "); catch (BindingException) threw = true;
        assert(threw);
    }

    unittest { // malformed: two '?' placeholders throws
        bool threw = false;
        try parseBinding("tool.attr xfrm.transform ? ?");
        catch (BindingException) threw = true;
        assert(threw);
    }

    unittest { // malformed: tool.attr value bind missing its '?' throws
        bool threw = false;
        try parseBinding("tool.attr xfrm.transform TX");
        catch (BindingException) threw = true;
        assert(threw);
    }

    unittest { // malformed: tool.attr with the '?' not in the value slot throws
        bool threw = false;
        try parseBinding("tool.attr xfrm.transform ? TX");
        catch (BindingException) threw = true;
        assert(threw);
    }

    // --- widget-class decision -------------------------------------------

    unittest { // datatype -> widget table (no overrides)
        ParamHints none;
        assert(widgetForKind(Param.Kind.Bool,    none) == WidgetKind.checkbox);
        assert(widgetForKind(Param.Kind.Int,     none) == WidgetKind.dragInt);
        assert(widgetForKind(Param.Kind.Float,   none) == WidgetKind.dragFloat);
        assert(widgetForKind(Param.Kind.Enum,    none) == WidgetKind.combo);
        assert(widgetForKind(Param.Kind.IntEnum, none) == WidgetKind.combo);
        assert(widgetForKind(Param.Kind.String,  none) == WidgetKind.text);
        assert(widgetForKind(Param.Kind.Vec3_,   none) == WidgetKind.vec3);
        assert(widgetForKind(Param.Kind.IntArray, none) == WidgetKind.none);

        ParamHints sl; sl.widget = ParamHints.Widget.Slider;
        assert(widgetForKind(Param.Kind.Int,   sl) == WidgetKind.sliderInt);
        assert(widgetForKind(Param.Kind.Float, sl) == WidgetKind.sliderFloat);
    }

    // --- resolver against a synthetic provider ---------------------------

    // Build a small fake provider universe by hand (no running app). Mirrors
    // the real XfrmTransformTool attr names so the test reads naturally.
    version (unittest)
    private Param[] fakeTransformParams(ref bool flagT, ref float tx,
                                        ref float ty, ref int seg,
                                        ref string mode, ref float dist)
    {
        import params : IntEnumEntry;
        return [
            Param.bool_  ("T",  "Translate",   &flagT, true),
            Param.float_ ("TX", "Translate X", &tx, 0.0f),
            Param.float_ ("TY", "Translate Y", &ty, 0.0f),
            Param.int_   ("seg","Segments",    &seg, 1),
            Param.enum_  ("mode", "Mode", &mode,
                          [["offset","Offset"], ["width","Width"]], "offset"),
            Param.float_ ("dist", "Distance", &dist, 0.5f),
        ];
    }

    unittest { // a control line resolves to the right attr, kind, widget
        bool flagT = true; float tx = 1.5f, ty = 0; int seg = 2;
        string mode = "width"; float dist = 0.5f;
        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);

        auto rc = resolveControl(
            Row.makeControl("tool.attr xfrm.transform TX ?"), prov);
        assert(rc.found);
        assert(rc.param.name == "TX");
        assert(rc.param.kind == Param.Kind.Float);
        assert(rc.widget == WidgetKind.dragFloat);
        assert(rc.choices.length == 0);
    }

    unittest { // bool attr -> checkbox by default, button under booleanStyle
        bool flagT = true; float tx = 0, ty = 0; int seg = 1;
        string mode = "offset"; float dist = 0.5f;
        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);

        auto cb = resolveControl(
            Row.makeControl("tool.attr xfrm.transform T ?"), prov);
        assert(cb.found);
        assert(cb.widget == WidgetKind.checkbox);

        auto r = Row.makeControl("tool.attr xfrm.transform T ?");
        r.booleanStyle = BooleanStyle.button;
        auto bt = resolveControl(r, prov);
        assert(bt.widget == WidgetKind.button);
    }

    unittest { // enum attr -> combo + choices come from the Param, not YAML
        bool flagT = true; float tx = 0, ty = 0; int seg = 1;
        string mode = "width"; float dist = 0.5f;
        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);

        auto rc = resolveControl(
            Row.makeControl("tool.attr xfrm.transform mode ?"), prov);
        assert(rc.found);
        assert(rc.widget == WidgetKind.combo);
        assert(rc.choices.length == 2);
        assert(rc.choices[0] == ["offset", "Offset"]);
        assert(rc.choices[1] == ["width", "Width"]);
    }

    unittest { // absent attr -> found=false (runtime-hidden, no throw)
        bool flagT = true; float tx = 0, ty = 0; int seg = 1;
        string mode = "offset"; float dist = 0.5f;
        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);

        auto rc = resolveControl(
            Row.makeControl("tool.attr xfrm.transform NOPE ?"), prov);
        assert(!rc.found);
        assert(rc.widget == WidgetKind.none);
    }

    unittest { // style override: force slider / drag on a Float
        bool flagT = true; float tx = 0, ty = 0; int seg = 1;
        string mode = "offset"; float dist = 0.5f;
        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);

        auto sl = Row.makeControl("tool.attr xfrm.transform dist ?");
        sl.style = ControlStyle.slider;
        assert(resolveControl(sl, prov).widget == WidgetKind.sliderFloat);

        auto dr = Row.makeControl("tool.attr xfrm.transform seg ?");
        dr.style = ControlStyle.slider;
        assert(resolveControl(dr, prov).widget == WidgetKind.sliderInt);
    }

    unittest { // non-control rows do not resolve a value
        bool flagT = true; float tx = 0, ty = 0; int seg = 1;
        string mode = "offset"; float dist = 0.5f;
        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);

        // a cmd row carries no '?' — resolveControl returns not-found
        assert(!resolveControl(Row.makeCmd("actr.auto", "Auto"), prov).found);
        // a divider is not a value bind
        assert(!resolveControl(Row.makeDivider(), prov).found);
    }

    // --- write-path serialization (Phase 4) ------------------------------

    unittest { // float token uses %g (byte-identical to argstring._fmtFloat)
        assert(valueToArgToken(JSONValue(1.5))   == "1.5");
        assert(valueToArgToken(JSONValue(1.0))   == "1");      // %g drops .0
        assert(valueToArgToken(JSONValue(0.001)) == "0.001");
    }

    unittest { // bool / int / string tokens
        assert(valueToArgToken(JSONValue(true))  == "true");
        assert(valueToArgToken(JSONValue(false)) == "false");
        assert(valueToArgToken(JSONValue(42))    == "42");
        assert(valueToArgToken(JSONValue("offset")) == "offset");
    }

    unittest { // substituteQuery reconstructs a tool.attr write line
        auto b = parseBinding("tool.attr xfrm.transform TX ?");
        auto line = substituteQuery(b, JSONValue(1.5));
        assert(line == "tool.attr xfrm.transform TX 1.5", line);
    }

    unittest { // substituteQuery: bool checkbox write
        auto b = parseBinding("tool.attr xfrm.transform T ?");
        assert(substituteQuery(b, JSONValue(true))
               == "tool.attr xfrm.transform T true");
    }

    unittest { // substituteQuery: stage namespace round-trip
        auto b = parseBinding("tool.pipe.attr falloff start ?");
        assert(substituteQuery(b, JSONValue(0.25))
               == "tool.pipe.attr falloff start 0.25");
    }

    unittest { // substituteQuery: an enum tag that needs no quoting
        auto b = parseBinding("tool.attr prim.sphere axis ?");
        assert(substituteQuery(b, JSONValue("x"))
               == "tool.attr prim.sphere axis x");
    }

    unittest { // round-trip: the substituted line re-parses to the same args
        auto b = parseBinding("tool.attr xfrm.transform TX ?");
        auto line = substituteQuery(b, JSONValue(2.75));
        auto p = parseArgstring(line);
        assert(p.commandId == "tool.attr");
        auto pos = p.params["_positional"].array;
        assert(pos.length == 3);
        assert(pos[0].str == "xfrm.transform");
        assert(pos[1].str == "TX");
        double n = pos[2].type == JSONType.float_ ? pos[2].floating
                 : cast(double) pos[2].integer;
        assert(n > 2.74 && n < 2.76);
    }

    unittest { // currentEnumTag reads the live Enum tag through *sptr
        string mode = "width";
        auto p = Param.enum_("mode", "Mode", &mode,
                             [["offset","Offset"], ["width","Width"]], "offset");
        assert(currentEnumTag(p) == "width");
    }

    unittest { // stage-namespace binding resolves against a stage's params()
        // The resolver is namespace-agnostic: it takes whatever Param[] the
        // caller hands it. Here we stand in for a falloff stage's params().
        float start = 0.1f, end_ = 0.9f;
        Param[] stageParams = [
            Param.float_("start", "Start", &start, 0.0f),
            Param.float_("end",   "End",   &end_,  1.0f),
        ];
        auto b = parseBinding("tool.pipe.attr falloff start ?");
        assert(b.namespace == Namespace.stage);
        auto rc = resolveBinding(b, stageParams);
        assert(rc.found);
        assert(rc.param.name == "start");
        assert(rc.widget == WidgetKind.dragFloat);
    }
}
