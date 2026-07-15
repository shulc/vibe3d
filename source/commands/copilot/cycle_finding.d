module commands.copilot.cycle_finding;

// version(WithAI)-only — see copilot_panel.d's matching gate.
version (WithAI):

import command;
import mesh;
import view;
import editmode;
import params        : Param;
import copilot_panel : CopilotPanel;
import ai.state       : EditorAiState;
import commands.copilot.select_finding : CopilotSelectFindingCommand;

/// copilot.cycleFinding dir:{+1|-1} — move the panel's active finding by
/// `dir` (task 0402 Phase 3, doc/ai_copilot_plan.md: "cycle = set active +
/// select, sharing Phase-2's act-on code"). This command computes ONLY the
/// new index (clamped/wrapped into `[0, findings.length)`); the actual
/// select-and-mark-active work is fully delegated to a
/// `CopilotSelectFindingCommand` built with that index — composition, not
/// duplication, so there is exactly one place an act-on's
/// selection/undo/staleness logic lives (see that module's doc comment).
/// The panel's Prev/Next buttons and its Up/Down-while-focused handling
/// (`copilot_panel.d`) both dispatch this SAME command id.
///
/// No active finding yet (`panel.active() == -1`, e.g. right after
/// `copilot.analyze` before any row was clicked) starts the cycle at the
/// front for `dir >= 0` / the back for `dir < 0` — the natural first-press
/// behaviour for a Prev/Next pair with nothing selected yet. With N == 1
/// finding the wrap is a no-op index-wise (next == 0 always); the inner
/// select-only act-on still re-runs (idempotent — the same element set is
/// re-selected), matching "reuse the exact act-on path" rather than
/// special-casing N == 1 to skip it.
///
/// AI-off inert (same gate as `copilot.selectFinding`, checked HERE too so
/// a direct `/api/command` call is inert, not merely hidden behind a
/// disabled panel button — the copilot surface as a whole is a modulation
/// of `aiState.enabled`, doc/ai_copilot_plan.md "Design update"): apply()
/// returns false, `active_`/selection unchanged.
class CopilotCycleFindingCommand : Command {
    private CopilotPanel       panel;
    private EditorAiState      aiState;
    private Command delegate() meshSelectFactory;
    private int                dir_ = 1;
    private CopilotSelectFindingCommand inner;

    this(Mesh* mesh, ref View view, EditMode editMode,
         CopilotPanel panel, EditorAiState aiState,
         Command delegate() meshSelectFactory) {
        super(mesh, view, editMode);
        this.panel             = panel;
        this.aiState           = aiState;
        this.meshSelectFactory = meshSelectFactory;
    }

    override string name()  const { return "copilot.cycleFinding"; }
    override string label() const { return "Cycle Finding"; }

    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }

    override Param[] params() {
        return [ Param.int_("dir", "Direction", &dir_, 1) ];
    }

    void setDir(int d) { dir_ = d; }

    override bool apply() {
        if (aiState is null || !aiState.enabled) return false;
        if (panel is null) return false;

        immutable int n = cast(int) panel.findings().length;
        if (n == 0) return false; // nothing to cycle

        immutable int cur = panel.active();
        int next = (cur < 0) ? (dir_ >= 0 ? 0 : n - 1) : cur + dir_;
        next = ((next % n) + n) % n; // wrap into [0, n)

        // Delegate the entire select-only act-on (element-set priority,
        // staleness filtering, panel.setActive, undo snapshot) to the same
        // command a row click dispatches — see this module's doc comment.
        // meshPtr()/viewRef()/editModeVal() are the Command base's
        // sibling-forwarding accessors (command.d, same mechanism
        // CompositeCommand uses to wrap another command's construction
        // context across a module boundary).
        inner = new CopilotSelectFindingCommand(meshPtr(), viewRef(), editModeVal(),
                                                 panel, aiState, meshSelectFactory);
        inner.setIndex(next);
        return inner.apply();
    }

    override bool revert() {
        if (inner is null) return false;
        return inner.revert();
    }
}
