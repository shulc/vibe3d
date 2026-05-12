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
                bool enabled = active.paramEnabled(p.name);
                if (!enabled) ImGui.BeginDisabled();
                bool changed = drawParamWidget(p);
                if (!enabled) ImGui.EndDisabled();
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

    /// Whether `cmd` requires a modal dialog (has any params).
    static bool needsDialog(Command cmd) {
        return cmd !is null && cmd.params().length > 0;
    }
}
