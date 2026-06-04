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
/// group as its own labeled sub-box.
enum GroupStyle { inline_, block }

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
    string category;              // slotting category (assembly order)
    double ordinal;               // sort within the category
    bool   hasOrdinal;            // YAML supplied an `ordinal:`
    Row[]  rows;

    /// True if this form should be shown for `activeToolId`. A form with no
    /// `whenTool` filter is always shown (shared sub-form).
    bool matchesTool(string activeToolId) const {
        if (whenTool.length == 0) return true;
        foreach (w; whenTool)
            if (w == activeToolId) return true;
        return false;
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

enum Namespace { tool, stage, command }

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

    // For the two attr namespaces, a value-bound line MUST be
    // `<cmd> <targetId> <attr> ?` — extract target + attr. A `?`-less line in
    // these namespaces is a malformed value bind (a control row needs its `?`,
    // a cmd/choice row should not use a tool.attr line at all).
    if (b.namespace == Namespace.tool || b.namespace == Namespace.stage) {
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

    unittest { // Form.matchesTool: empty filter => always; list membership
        Form shared_;                       // no whenTool
        assert(shared_.matchesTool("anything"));

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
