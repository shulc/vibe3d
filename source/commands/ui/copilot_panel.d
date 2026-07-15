module commands.ui.copilot_panel;

// version(WithAI)-only — see copilot_panel.d's matching gate. Includes
// g_copilotPanelShown: every app.d reference to it is likewise wrapped in
// version(WithAI).
version (WithAI):

import command;
import mesh;
import view;
import editmode;
import params : Param;

// ---------------------------------------------------------------------------
// g_copilotPanelShown — test-mode visibility flag for the "AI Findings"
// window. Mirrors g_layerListShown (commands.ui.layer_list) exactly: in a
// normal (non-test) run the panel is always drawn (this flag is ignored);
// in --test mode it is HIDDEN by default and only rendered when this flag
// is set true, so synthetic viewport drags are never captured by a panel
// whose position varies between parallel workers. A test that genuinely
// needs to drive the panel's ImGui widgets opts in via
// `ui.copilotPanel show:true` — the HTTP act-on test (test_copilot_panel.d)
// does NOT need this: it drives copilot.analyze / copilot.selectFinding
// directly, the same commands the panel's own widgets dispatch.
//
// __gshared so the render loop (app.d) and the command apply (background
// HTTP thread, marshaled through the main-thread command bridge) read/write
// the same flag.
// ---------------------------------------------------------------------------
__gshared bool g_copilotPanelShown = false;

/// ui.copilotPanel show:<bool> — test-only visibility flip. Schema-driven
/// (a bool Param, not a positional string) so /api/command's generic
/// injectParamsInto path handles it with no special-case needed in
/// app.d's commandHandlerDelegate closure (contrast commands.ui.layer_list,
/// whose positional string arg IS special-cased there).
class UiCopilotPanelCommand : Command {
    private bool show_ = true;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "ui.copilotPanel"; }
    override string label() const { return "Show/Hide AI Findings (test)"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override Param[] params() {
        return [ Param.bool_("show", "Show", &show_, true) ];
    }

    override bool apply() {
        if (!g_testMode)
            throw new Exception(
                "ui.copilotPanel: only available in --test mode");
        g_copilotPanelShown = show_;
        return true;
    }

    override bool revert() { return false; }
}
