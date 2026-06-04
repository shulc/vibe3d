module commands.ui.tool_properties;

import std.string : strip, toLower;

import command;
import mesh;
import view;
import editmode;

// ---------------------------------------------------------------------------
// g_toolPropertiesShown — test-mode visibility flag for the Tool Properties
// window.
//
// In a normal (non-test) run the Tool Properties window is always rendered
// while a tool is active; this flag is ignored. In --test mode the window is
// HIDDEN by default and only rendered when this flag is set true, so that
// synthetic mouse drags over the viewport are not captured by a panel whose
// position varies between parallel workers. Tests that genuinely need to
// drive the panel turn it on via `ui.toolProperties show`.
//
// __gshared so the render loop (app.d) and the command apply (background HTTP
// thread) read/write the same flag.
// ---------------------------------------------------------------------------
__gshared bool g_toolPropertiesShown = false;

// ---------------------------------------------------------------------------
// UiToolPropertiesCommand — `ui.toolProperties <show|hide>`
//
// Test-only. Flips g_toolPropertiesShown, which the Tool Properties render
// guard in app.d reads while in --test mode. Gated behind g_testMode (set by
// --test), so it is inert and rejects itself in a normal build/run — the
// panel is unconditionally visible there and this command has no purpose.
//
// Wire format: one positional arg, "show" or "hide".
// ---------------------------------------------------------------------------
class UiToolPropertiesCommand : Command {
    private bool show_ = true;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "ui.toolProperties"; }
    override string label() const { return "Show/Hide Tool Properties (test)"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    // Positional arg: "show" | "hide".
    void setVisible(string arg) {
        auto a = arg.strip.toLower;
        switch (a) {
            case "show": show_ = true;  break;
            case "hide": show_ = false; break;
            default:
                throw new Exception(
                    "ui.toolProperties: expected 'show' or 'hide', got '"
                    ~ arg ~ "'");
        }
    }

    override bool apply() {
        if (!g_testMode)
            throw new Exception(
                "ui.toolProperties: only available in --test mode");
        g_toolPropertiesShown = show_;
        return true;
    }

    override bool revert() { return false; }
}
