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
// Inline unit tests — schema construction (no parse / resolve yet; those are
// covered further down once parseBinding / resolveControl exist).
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
}
