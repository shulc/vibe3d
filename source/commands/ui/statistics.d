module commands.ui.statistics;

import std.string : strip, toLower;

import command;
import mesh;
import view;
import editmode;
import params : Param, wireArgs;
import ui.stat_rows : StatExpand;

// ---------------------------------------------------------------------------
// g_statisticsShown — test-mode visibility flag for the Statistics window
// (task 1100), mirroring `commands/ui/channels.d`'s flag exactly.
//
// In a normal run the window is always rendered and this flag is ignored. In
// --test it is HIDDEN by default and only rendered once `ui.statistics show`
// sets it, so a new floating window cannot start swallowing the synthetic
// viewport drags every existing test drives.
// ---------------------------------------------------------------------------
__gshared bool g_statisticsShown = false;

// ---------------------------------------------------------------------------
// g_statExpand — WHICH sections and categories are open.
//
// Owned by the panel layer and never by the row model, which reads it as a
// `ref const` parameter. It is here rather than a function-local `static` in
// the drawer (the `rootExpanded` precedent in `ui/panels.d`) for two stated
// reasons: there are ~24 bits rather than one, and a function-local `static`
// cannot be reset between unittest blocks in a shared process, which the
// widget tests need.
//
// It survives a rebuild of the row model and does NOT survive a restart —
// which is also what the reference does: its own flags live in process memory,
// not in the config. This panel persists nothing.
//
// The TYPE lives in `ui/stat_rows.d`, beside the model that reads it, so that
// the row model and its unittests need no import of the command layer.
// ---------------------------------------------------------------------------
__gshared StatExpand g_statExpand;

// ---------------------------------------------------------------------------
// UiStatisticsCommand — `ui.statistics <show|hide>`
//
// Test-only, gated behind g_testMode, exactly like `ui.channels`.
// ---------------------------------------------------------------------------
class UiStatisticsCommand : Command {
    private bool show_ = true;
    private string visibleArg_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "ui.statistics"; }
    override string label() const { return "Show/Hide Statistics (test)"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    /// The declared argument (task 4062); the parse and its message stay in
    /// `setVisible`, which now runs at apply rather than at bind.
    override Param[] params() {
        return wireArgs(
            Param.string_("visible", "Visible", &visibleArg_, "")
        );
    }

    // Positional arg: "show" | "hide".
    void setVisible(string arg) {
        auto a = arg.strip.toLower;
        switch (a) {
            case "show": show_ = true;  break;
            case "hide": show_ = false; break;
            default:
                throw new Exception(
                    "ui.statistics: expected 'show' or 'hide', got '"
                    ~ arg ~ "'");
        }
    }

    protected override bool applyImpl() {
        if (visibleArg_.length > 0) setVisible(visibleArg_);
        if (!g_testMode)
            throw new Exception(
                "ui.statistics: only available in --test mode");
        g_statisticsShown = show_;
        return true;
    }
}

// ---------------------------------------------------------------------------
// ui.statistics.expand — open/close a section or a category, by NAME.
//
// The panel's own disclosure triangles are the user's way in; this is the
// test's, and it exists for a reason the plan states outright: a test that
// asserted on rows it had not expanded EXPLICITLY would go red the day the
// first-open default changes — and that default is OURS, not measured, so it
// is exactly the kind of thing that changes.
//
// `target` is either a section label ("Vertices") or a category key
// ("Vertices/By Edge"), which is the same key the row model publishes.
// ---------------------------------------------------------------------------
class UiStatisticsExpandCommand : Command {
    private string target_ = "";
    private bool   open_   = true;
    private string stateArg_ = "open";

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "ui.statistics.expand"; }
    override string label() const { return "Expand/Collapse Statistics Row (test)"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    /// The two declared arguments (task 4062). The state slot defaults to
    /// "open" — the same default the injector's `pos.length >= 2 ? … : "open"`
    /// supplied, moved to the declaration where it can be read.
    override Param[] params() {
        return wireArgs(
            Param.string_("target", "Target", &target_, ""),
            Param.string_("state", "State", &stateArg_, "open")
        );
    }

    void setArgs(string target, string state) {
        target_ = target.strip;
        auto s = state.strip.toLower;
        switch (s) {
            case "":
            case "open":  open_ = true;  break;
            case "close": open_ = false; break;
            default:
                throw new Exception(
                    "ui.statistics.expand: expected 'open' or 'close', got '"
                    ~ state ~ "'");
        }
    }

    protected override bool applyImpl() {
        setArgs(target_, stateArg_);
        import seltype : SelType;
        if (!g_testMode) {
            baseRefusal_ = "ui.statistics.expand: only available in --test mode";
            return false;
        }
        if (target_.length == 0) {
            baseRefusal_ = "ui.statistics.expand: name a section or a "
                ~ "'<Section>/<Category>' key";
            return false;
        }
        switch (target_) {
            case "Vertices":
                g_statExpand.section[cast(size_t) SelType.Vertex] = open_;  return true;
            case "Edges":
                g_statExpand.section[cast(size_t) SelType.Edge] = open_;    return true;
            case "Polygons":
                g_statExpand.section[cast(size_t) SelType.Polygon] = open_; return true;
            case "Items":
                g_statExpand.section[cast(size_t) SelType.Item] = open_;    return true;
            default:
                // A category key. Deliberately NOT validated against the tree:
                // the tree depends on the mesh, and a key for a category that
                // does not exist right now is harmless (it is read by lookup).
                g_statExpand.category[target_] = open_;
                return true;
        }
    }
}
