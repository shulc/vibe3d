module commands.copilot.select_finding;

// version(WithAI)-only — see copilot_panel.d's matching gate.
version (WithAI):

import command;
import mesh;
import view;
import editmode;
import params        : Param;
import copilot_panel : CopilotPanel;
import ai.state       : EditorAiState;
import commands.mesh.select : MeshSelect;

/// copilot.selectFinding index:N — the copilot's ONLY act-on: SELECT the
/// Nth finding's element set (task 0402 Phase 2, doc/ai_copilot_plan.md,
/// Phase-0 Q1: act-on = SELECT-ONLY). This NEVER dispatches a geometry-
/// mutating command, arms no tool, and does no frame-to-fit.
///
/// Implementation: wraps the existing `mesh.select` command via the SAME
/// factory app.d registers for "mesh.select" (injected as
/// `meshSelectFactory`), so it inherits that factory's already-wired
/// `promoteGeometryType` hook (the geometry-selection funnel that does NOT
/// drop the active tool — NOT `switchGeometryType`) and resolved-viewport
/// provider — see app.d's `reg.commandFactories["mesh.select"]` entry. This
/// is a reuse, not a reimplementation: undo/history/the SelType funnel all
/// behave exactly like every other selection UI (see MeshSelect's doc
/// comment + drawLayerListPanel's "NEVER mutates directly" rule, app.d:8312).
/// cmdFlags mirrors the inner command (UiState) and revert() delegates to
/// it, so Ctrl+Z undoes an act-on selection exactly like any other pick.
///
/// AI-off inert (doc/ai_copilot_plan.md "Design update" — the whole copilot
/// surface is a modulation of the AI master switch): apply() returns false
/// (no selection change, no undo entry recorded) when `aiState.enabled` is
/// false. Checked HERE, not just at the UI layer, so a direct /api/command
/// call while AI is off is inert too, not merely hidden behind a disabled
/// button.
class CopilotSelectFindingCommand : Command {
    private CopilotPanel       panel;
    private EditorAiState      aiState;
    private Command delegate() meshSelectFactory;
    private int                index_ = -1;
    private MeshSelect         inner;
    private int                prevActive_ = -1; // panel.active() before this act-on; restored on revert

    this(Mesh* mesh, ref View view, EditMode editMode,
         CopilotPanel panel, EditorAiState aiState,
         Command delegate() meshSelectFactory) {
        super(mesh, view, editMode);
        this.panel             = panel;
        this.aiState           = aiState;
        this.meshSelectFactory = meshSelectFactory;
    }

    override string name()  const { return "copilot.selectFinding"; }
    override string label() const { return "Select Finding"; }

    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }

    override Param[] params() {
        return [ Param.int_("index", "Index", &index_, -1) ];
    }

    void setIndex(int i) { index_ = i; }

    override bool apply() {
        // AI-off ⇒ inert (see module doc comment) — not an error, just a
        // no-op: no selection change, no undo entry (return false skips
        // history.record/recordCoalescing, mirroring every other
        // guard-clause command in this codebase, e.g. MeshAddPoint's
        // t<=0||t>=1 guard).
        if (aiState is null || !aiState.enabled) return false;
        if (panel is null) return false;

        const findings = panel.findings();
        if (index_ < 0 || index_ >= cast(int) findings.length) return false;
        const f = findings[index_];

        // Element-set priority. Assumes ONE non-empty element set per finding
        // (Phase-1 SubdivReadiness carries edges only); if a future category
        // ever populates two, only this top-priority set is selected.
        string mode;
        int[]  indices;
        size_t bound;
        if (f.edges.length > 0)      { mode = "edges";     indices = toIntIndices(f.edges); bound = mesh.edges.length; }
        else if (f.faces.length > 0) { mode = "polygons";  indices = toIntIndices(f.faces); bound = mesh.faces.length; }
        else if (f.verts.length > 0) { mode = "vertices";  indices = toIntIndices(f.verts); bound = mesh.vertices.length; }
        else return false; // finding carries no element set to select

        // Findings persist on-demand (Phase-0 Q6) across mesh edits, so a row can
        // go stale after a topology change. Drop any index past the LIVE mesh
        // bound: a stale finding becomes an inert no-op rather than a partial
        // select that throws inside MeshSelect.apply() AFTER already mutating the
        // selection (which would leave a changed selection with no undo entry).
        int[] live;
        foreach (i; indices) if (i >= 0 && i < cast(int) bound) live ~= i;
        if (live.length == 0) return false;
        indices = live;

        if (meshSelectFactory is null) return false;
        inner = cast(MeshSelect) meshSelectFactory();
        if (inner is null) return false;
        inner.setMode(mode);
        inner.setIndices(indices);
        if (!inner.apply()) return false;

        prevActive_ = panel.active(); // remember pre-act-on row (still the old one — setActive below hasn't run)
        panel.setActive(index_);
        return true;
    }

    override bool revert() {
        if (inner is null) return false;
        const ok = inner.revert();
        // Restore the panel's active row too — reverting the selection alone
        // left active_ pointing at the just-selected row. Fixes the undo
        // highlight/ghost desync AND makes copilot.cycleFinding redo-idempotent
        // (its apply() recomputes the next index from panel.active(), so the
        // active row must be back to its pre-apply value after an undo).
        if (panel !is null) panel.restoreActive(prevActive_);
        return ok;
    }
}

private int[] toIntIndices(const(uint)[] u) {
    auto r = new int[u.length];
    foreach (i, v; u) r[i] = cast(int) v;
    return r;
}
