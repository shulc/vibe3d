module commands.ui.layer_list;

import std.string : strip, toLower;

import command;
import mesh;
import view;
import editmode;

// ---------------------------------------------------------------------------
// g_layerListShown — test-mode visibility flag for the Layers window.
//
// In a normal (non-test) run the Layers window is always rendered; this flag
// is ignored. In --test mode the window is HIDDEN by default and only
// rendered when this flag is set true, so that synthetic mouse drags over the
// viewport are not captured by a panel whose position varies between parallel
// workers. Tests that genuinely need to drive the panel turn it on via
// `ui.layerList show`.
//
// This mirrors g_toolPropertiesShown in commands.ui.tool_properties exactly —
// the Layers panel is a second floating, draggable window and must obey the
// same imgui-determinism rule (no panel may swallow a viewport drag in tests).
//
// __gshared so the render loop (app.d) and the command apply (background HTTP
// thread) read/write the same flag.
// ---------------------------------------------------------------------------
__gshared bool g_layerListShown = false;

// ---------------------------------------------------------------------------
// UiLayerListCommand — `ui.layerList <show|hide>`
//
// Test-only. Flips g_layerListShown, which the Layers panel render guard in
// app.d reads while in --test mode. Gated behind g_testMode (set by --test),
// so it is inert and rejects itself in a normal build/run — the panel is
// unconditionally visible there and this command has no purpose.
//
// Wire format: one positional arg, "show" or "hide".
// ---------------------------------------------------------------------------
class UiLayerListCommand : Command {
    private bool show_ = true;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "ui.layerList"; }
    override string label() const { return "Show/Hide Layers (test)"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    // Positional arg: "show" | "hide".
    void setVisible(string arg) {
        auto a = arg.strip.toLower;
        switch (a) {
            case "show": show_ = true;  break;
            case "hide": show_ = false; break;
            default:
                throw new Exception(
                    "ui.layerList: expected 'show' or 'hide', got '"
                    ~ arg ~ "'");
        }
    }

    override bool apply() {
        if (!g_testMode)
            throw new Exception(
                "ui.layerList: only available in --test mode");
        g_layerListShown = show_;
        return true;
    }

    override bool revert() { return false; }
}
