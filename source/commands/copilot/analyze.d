module commands.copilot.analyze;

// version(WithAI)-only — see copilot_panel.d's matching gate.
version (WithAI):

import command;
import mesh;
import view;
import editmode;
import copilot_panel : CopilotPanel;
import ai.analysis    : analyzeMesh;

/// copilot.analyze — (re)run the whole-mesh analysis engine and store the
/// result on the passive `CopilotPanel` (task 0402 Phase 2,
/// doc/ai_copilot_plan.md, Phase-0 Q6: analysis runs ON-DEMAND, not live-
/// on-change-bus). A pure READ of the live mesh — it never mutates
/// mesh/document/selection state, so it carries no undo entry (SideEffect,
/// same class as ai.toggle): "Analyze" is a refresh, not an edit.
///
/// The panel's "Analyze" button and the HTTP test both dispatch this SAME
/// command id through commandHandlerDelegate — exactly one code path
/// populates the findings list.
class CopilotAnalyzeCommand : Command {
    private CopilotPanel panel;

    this(Mesh* mesh, ref View view, EditMode editMode, CopilotPanel panel) {
        super(mesh, view, editMode);
        this.panel = panel;
    }

    override string name()  const { return "copilot.analyze"; }
    override string label() const { return "Analyze"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override bool apply() {
        if (panel is null)
            throw new Exception("copilot.analyze: panel not wired");
        panel.setFindings(analyzeMesh(*mesh));
        return true;
    }

    override bool revert() { return false; }
}
