module args_dialog;

import command : Command;
import params  : Param, ParamHints;
import params_widgets : drawParamWidget;

import ImGui = d_imgui;
import d_imgui.imgui_h;

// ---------------------------------------------------------------------------
// ArgsDialog — universal modal renderer for Command parameter dialogs.
//
// One instance lives on App. Call open(cmd) when a command with params is
// triggered from the UI. Call draw(runCmd) once per frame inside the ImGui
// frame (between NewFrame and Render).
//
// Pattern mirrors the existing vert.merge/vert.join popup blocks in app.d:
//   pendingOpen  → ImGui.OpenPopup once, then cleared
//   BeginPopupModal returns true while open, false after ESC/[X] or after
//   CloseCurrentPopup().
// ---------------------------------------------------------------------------

class ArgsDialog {
    private Command active;      // null = nothing pending/showing
    private bool    pendingOpen; // set by open(), consumed by draw()

    /// Queue a modal popup for `cmd`. Calls cmd.dialogInit() so the command
    /// can set defaults from current selection state.
    void open(Command cmd) {
        active      = cmd;
        pendingOpen = true;
        cmd.dialogInit();
    }

    /// Render the modal. Call once per frame, inside the ImGui frame.
    /// On OK: invokes runCmd(active) then clears state.
    /// On Cancel / ESC / [X]: clears state without running.
    void draw(void delegate(Command) runCmd) {
        if (active is null) return;

        string title = active.label();

        if (pendingOpen) {
            ImGui.OpenPopup(title);
            pendingOpen = false;
        }

        if (ImGui.BeginPopupModal(title, null,
                ImGuiWindowFlags.AlwaysAutoResize))
        {
            foreach (ref p; active.params()) {
                if (p.hidden_) continue;
                // Disabled if the command greys it out for the current state
                // (paramEnabled) OR the param is flagged readonly (static).
                bool disabled = !active.paramEnabled(p.name) || p.readonly_;
                if (disabled) ImGui.BeginDisabled();
                bool changed = drawParamWidget(p);
                if (disabled) ImGui.EndDisabled();
                if (changed) active.onParamChanged(p.name);
            }

            ImGui.Separator();

            if (ImGui.Button("OK")) {
                ImGui.CloseCurrentPopup();
                Command toRun = active;
                active = null;
                runCmd(toRun);
            }
            ImGui.SameLine();
            if (ImGui.Button("Cancel")) {
                ImGui.CloseCurrentPopup();
                active = null;
            }
            ImGui.EndPopup();
        } else {
            // BeginPopupModal returns false when the popup has been dismissed
            // via ESC or the [X] button (same semantics as Cancel).
            // Guard: only treat this as a dismiss when we are not in the
            // pendingOpen frame — pendingOpen is already false by this point.
            if (active !is null) {
                active = null;
            }
        }
    }

    /// Whether `cmd` requires a modal dialog: it has at least one param the
    /// dialog would actually DRAW.
    ///
    /// TASK 4062 — "has any params" is no longer the same question. Since
    /// `params()` became the positional-argument declaration, a command that
    /// takes a wire argument declares one whether or not a human should ever
    /// be asked to fill it in: `select.vertex`, `ui.about`, `viewport.view`
    /// and thirty more now carry a schema and would every one of them have
    /// popped an empty-looking modal in front of a menu click or a shortcut.
    /// A dialog is for a param a user can SEE, so the gate counts the ones the
    /// renderer draws.
    static bool needsDialog(Command cmd) {
        return cmd !is null && visibleParamCount(cmd) > 0;
    }
}

/// The params a generic renderer would draw for `cmd` — the schema minus the
/// hidden rows. The single answer to "would an args dialog show anything?",
/// read by `ArgsDialog.needsDialog` and by `EditorApp.tryOpenArgsDialog`.
size_t visibleParamCount(Command cmd) {
    if (cmd is null) return 0;
    size_t n = 0;
    foreach (ref p; cmd.params()) if (!p.hidden_()) ++n;
    return n;
}
