module copilot_panel;

// ===========================================================================
// copilot_panel — CopilotPanel: the ImGui renderer for the AI Modeling
// Copilot's passive findings list (task 0402 Phase 2, doc/ai_copilot_plan.md).
//
// Owner-redirect design (see the plan's "Design update" block): the copilot
// is NOT a new tool. `CopilotPanel` is a plain class — it does not extend
// `Tool`, it is never assigned to `activeTool`, and it cannot hook
// `onKeyDown` (there is no viewport-key cycle; panel up/down + click only,
// per the Phase-0 Q3 decision). It is a passive, read-only list surface
// exactly like `drawLayerListPanel` (app.d:8319) is a passive layer list —
// modeled on it directly, including its "NEVER mutates directly" rule
// (app.d:8312): every interaction here dispatches through the SAME
// (commandId, paramsJson) delegate `/api/command` uses, never touching
// Mesh/selection/document state itself. This class owns only its own
// display state (the last-computed `Finding[]` + which row is "active").
//
// Act-on is SELECT-ONLY (Phase-0 Q1, the strictest reading of "recommend
// without applying" — no frame-to-fit, no tool-arming, no geometry
// mutation): a row click dispatches `copilot.selectFinding`, whose
// implementation (commands/copilot/select_finding.d) wraps the existing
// `mesh.select` command so the change is undoable and routes through
// `promoteGeometryType`. "Dismiss" only drops the finding from this
// panel's own local list — it is not mesh/document state, so it is a plain
// local mutation, not a dispatched command.
//
// Gating: the whole body is inert when AI is off (mirrors the existing AI
// status-bar button's disabled affordance) — draw() takes the caller's
// `aiEnabled` snapshot and renders a disabled placeholder instead of the
// list/Analyze button when false. The commands themselves ALSO gate on
// `EditorAiState.enabled` (commands/copilot/select_finding.d) so a direct
// `/api/command` call is inert too, not merely hidden behind a disabled
// button — see that module's doc comment.
// ===========================================================================

import ai.analysis : Finding, findingCategoryId, findingSeverityId,
    FindingSeverity;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.format : format;

/// Plain command dispatch — identical shape to app.d's `commandHandlerDelegate`
/// / forms_render's `DispatchFn`, so this module stays decoupled from the
/// command registry and the toolpipe.
alias DispatchFn = void delegate(string commandId, string paramsJson);

class CopilotPanel {
    private Finding[] findings_;
    private int        active_ = -1;

    // -----------------------------------------------------------------
    // Model — mutated ONLY by the copilot.* commands (via these setters)
    // and by this panel's own local Dismiss action.
    // -----------------------------------------------------------------

    /// Replace the findings list (copilot.analyze's result). Resets the
    /// active row — the previous active index has no guaranteed meaning
    /// against a freshly-recomputed list.
    void setFindings(Finding[] f) {
        findings_ = f;
        active_ = -1;
    }

    const(Finding)[] findings() const { return findings_; }

    int active() const { return active_; }

    /// Mark row `i` as the active (last acted-on) finding. Called by
    /// copilot.selectFinding on a successful act-on; out-of-range is a
    /// silent no-op (defensive — callers already range-check).
    void setActive(int i) {
        if (i < 0 || i >= cast(int) findings_.length) return;
        active_ = i;
    }

    /// Drop finding `index` from the list. Local UI housekeeping only —
    /// NOT mesh/document/selection state, so (unlike act-on) this is a
    /// plain local mutation, not a dispatched command.
    void dismiss(int index) {
        if (index < 0 || index >= cast(int) findings_.length) return;
        findings_ = findings_[0 .. index] ~ findings_[index + 1 .. $];
        if (active_ == index)      active_ = -1;
        else if (active_ > index)  active_--;
    }

    // -----------------------------------------------------------------
    // View
    // -----------------------------------------------------------------

    /// Draw the "AI Findings" window. Caller wraps this in
    /// pushPanelChromeStyle()/popPanelChromeStyle() (app.d convention —
    /// see drawLayerListPanel), so this method only calls Begin/End.
    void draw(bool aiEnabled, DispatchFn dispatch) {
        if (ImGui.Begin("AI Findings")) {
            if (!aiEnabled) {
                ImGui.TextDisabled(
                    "AI is off. Enable AI (status bar) to see modeling findings.");
            } else {
                drawBody(dispatch);
            }
        }
        ImGui.End();
    }

    private void drawBody(DispatchFn dispatch) {
        if (ImGui.SmallButton("Analyze")) {
            if (dispatch !is null) dispatch("copilot.analyze", "{}");
        }
        ImGui.SameLine();
        // TextUnformatted (not Text) — Text treats its arg as a printf fmt
        // (ImFormatStringToTempBufferV); feed the already-formatted string raw
        // to stay inside the codebase's printf-hazard convention.
        ImGui.TextUnformatted(format("%d finding(s)", findings_.length));
        ImGui.Separator();

        if (findings_.length == 0) {
            ImGui.TextDisabled("No findings — click Analyze.");
            return;
        }

        // Deferred: removing from findings_ mid-`foreach` would invalidate
        // the iteration; Dismiss is applied once after the loop instead.
        int dismissRequested = -1;

        foreach (i, ref f; findings_) {
            immutable int idx = cast(int) i;
            ImGui.PushID(idx);

            ImGui.PushStyleColor(ImGuiCol.Text, severityColor(f.severity));
            immutable string label =
                "[" ~ findingCategoryId(f.category) ~ "/" ~
                findingSeverityId(f.severity) ~ "] " ~ f.message;
            // Row click = act-on = SELECT-ONLY (see module doc comment).
            // AllowItemOverlap so the same-line Dismiss button (below)
            // stays clickable over the Selectable's full-width hit box
            // (mirrors drawLayerListPanel's row marker, app.d:8367).
            bool clicked = ImGui.Selectable(label, active_ == idx,
                                             ImGuiSelectableFlags.AllowItemOverlap);
            ImGui.PopStyleColor(1);

            if (clicked && dispatch !is null)
                dispatch("copilot.selectFinding", format(`{"index":%d}`, idx));

            ImGui.SameLine();
            if (ImGui.SmallButton("Dismiss"))
                dismissRequested = idx;

            ImGui.PopID();
        }

        if (dismissRequested >= 0) dismiss(dismissRequested);
    }

    private static ImVec4 severityColor(FindingSeverity s) {
        final switch (s) {
            case FindingSeverity.Info:    return ImVec4(0.35f, 0.35f, 0.35f, 1.0f);
            case FindingSeverity.Suggest: return ImVec4(0.05f, 0.05f, 0.05f, 1.0f);
            case FindingSeverity.Warn:    return ImVec4(0.65f, 0.20f, 0.0f,  1.0f);
        }
    }
}
