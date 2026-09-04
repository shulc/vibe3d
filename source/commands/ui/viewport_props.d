module commands.ui.viewport_props;

import std.string : strip, toLower;

import command;
import mesh;
import view;
import editmode;
import params : Param, wireArgs;

// ---------------------------------------------------------------------------
// g_viewportPropsShown — test-mode visibility flag for the Viewport Properties
// window.  Mirrors g_toolPropertiesShown / g_layerListShown exactly: hidden
// by default in --test so synthetic viewport drags cannot be captured by it;
// shown via `ui.viewportProps show`.  In a normal run the panel is always
// rendered (g_testMode false ⇒ guard passes).
// ---------------------------------------------------------------------------
__gshared bool g_viewportPropsShown = false;

// ---------------------------------------------------------------------------
// UiViewportPropsCommand — `ui.viewportProps <show|hide>`
//
// Test-only.  Flips g_viewportPropsShown.  Gated behind g_testMode; inert in
// a normal run where the panel is unconditionally visible.
// ---------------------------------------------------------------------------
class UiViewportPropsCommand : Command {
    private bool show_ = true;
    private string visibleArg_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "ui.viewportProps"; }
    override string label() const { return "Show/Hide Viewport Properties (test)"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    /// The declared argument, and therefore positional slot 0 (task 4062).
    /// The parse — and its message — stays in `setVisible`; only the moment
    /// moved, from the dispatcher's injector to `applyImpl`. An ABSENT
    /// argument keeps the command's own default rather than being parsed as
    /// an empty string, which is what the injector's `pos.length >= 1` guard
    /// did.
    override Param[] params() {
        return wireArgs(
            Param.string_("visible", "Visible", &visibleArg_, "")
        );
    }

    void setVisible(string arg) {
        auto a = arg.strip.toLower;
        switch (a) {
            case "show": show_ = true;  break;
            case "hide": show_ = false; break;
            default:
                throw new Exception(
                    "ui.viewportProps: expected 'show' or 'hide', got '" ~ arg ~ "'");
        }
    }

    protected override bool applyImpl() {
        if (visibleArg_.length > 0) setVisible(visibleArg_);
        if (!g_testMode)
            throw new Exception("ui.viewportProps: only available in --test mode");
        g_viewportPropsShown = show_;
        return true;
    }
}
