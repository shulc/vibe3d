module ui.action_menu;

import bindbc.sdl : SDL_Keymod, KMOD_ALT, KMOD_CTRL, KMOD_GUI, KMOD_SHIFT;
import ImGui = d_imgui;
import d_imgui.imgui_h : ImGuiHoveredFlags;
import buttonset : Action, ActionKind, Button, Checked, PopupItem, PopupItemKind;
import imgui_style : popPopupStyle, pushPopupStyle;
import io.assimp_runtime : isAssimpAvailable;
import toolpipe.pipeline : g_pipeCtx;
import ui.availability : recordDrawnButton;
import ui.mode_popup : dynamicModeCheckedLabel, dynamicModePopupItems;

alias ActionMenuDispatch = void delegate(string id, string paramsJson);
alias ActionMenuToolActivate = void delegate(string id);
alias ActionMenuArgsDialog = bool delegate(string id);
alias ActionMenuRefusal = string delegate(ref const Action action);
/// The session-aware history navigator (`app.d`'s `navHistory`): the one
/// door the panel's Undo/Redo rows take, same as Ctrl+Z (V19).
alias ActionMenuHistoryNav = bool delegate(bool isUndo);

struct ActionMenuRead {
private:
    ActionMenuRefusal refusal_;

public:
    @disable this();

    this(ActionMenuRefusal refusal) {
        assert(refusal !is null,
            "ActionMenuRead requires an availability read");
        refusal_ = refusal;
    }

    string refusal(ref const Action action) {
        return refusal_(action);
    }
}

struct ActionMenuActions {
private:
    ActionMenuToolActivate activateTool_;
    ActionMenuArgsDialog openArgs_;
    ActionMenuDispatch dispatch_;
    ActionMenuHistoryNav nav_;

public:
    @disable this();

    this(ActionMenuToolActivate activateTool, ActionMenuArgsDialog openArgs,
         ActionMenuDispatch dispatch, ActionMenuHistoryNav nav) {
        assert(activateTool !is null,
            "ActionMenuActions requires a tool-activation door");
        assert(openArgs !is null,
            "ActionMenuActions requires an args-dialog door");
        assert(dispatch !is null,
            "ActionMenuActions requires a UI command door");
        assert(nav !is null,
            "ActionMenuActions requires a history-navigation door");
        activateTool_ = activateTool;
        openArgs_ = openArgs;
        dispatch_ = dispatch;
        nav_ = nav;
    }

    void activateTool(string id) {
        if (activateTool_ !is null) activateTool_(id);
    }

    // The history rows leave for the navigator BEFORE the args-dialog and
    // command doors, as `InputRouter.handleKeyDown` does for Ctrl+Z: the raw
    // `history.undo` command undoes UNDER a live tool edit (task 7112, V19;
    // the script doors stay raw by design).
    void runCommandRow(string id) {
        if (id == "history.undo") { nav_(true); return; }
        if (id == "history.redo") { nav_(false); return; }
        if (openArgs_ !is null && openArgs_(id)) return;
        if (dispatch_ !is null) dispatch_(id, "");
    }

    void runScriptLine(string id, string paramsJson) {
        if (dispatch_ !is null) dispatch_(id, paramsJson);
    }
}

struct ActionMenuRoles {
    ActionMenuRead read;
    ActionMenuActions actions;
}

ActionMenuRoles bindActionMenu(ActionMenuRefusal refusal,
        ActionMenuDispatch dispatch, ActionMenuToolActivate activateTool,
        ActionMenuArgsDialog openArgs, ActionMenuHistoryNav nav) {
    assert(refusal !is null,
        "bindActionMenu requires an availability read");
    assert(dispatch !is null,
        "bindActionMenu requires a UI command door");
    assert(activateTool !is null,
        "bindActionMenu requires a tool-activation door");
    assert(openArgs !is null,
        "bindActionMenu requires an args-dialog door");
    assert(nav !is null,
        "bindActionMenu requires a history-navigation door");
    return ActionMenuRoles(ActionMenuRead(refusal),
        ActionMenuActions(activateTool, openArgs, dispatch, nav));
}

void dispatchAction(ActionMenuActions actions, ref Action action) {
    import argstring : parseArgstring;

    final switch (action.kind) {
        case ActionKind.tool:
            actions.activateTool(action.id);
            break;
        case ActionKind.command:
            // Task 4062: panel rows use the application UI binding rather
            // than constructing a raw command with no argument policy.
            actions.runCommandRow(action.id);
            break;
        case ActionKind.script:
            foreach (line; action.scriptLines) {
                auto parsed = parseArgstring(line);
                if (parsed.isEmpty) continue;
                actions.runScriptLine(parsed.commandId,
                                      parsed.params.toString());
            }
            break;
        case ActionKind.popup:
            break;
    }
}

// Dispatch stays after the copied `findAllByTask` walk: removing a falloff can
// re-fire live evaluation, which must not run between two rows of one popup.
void renderFalloffStackItems(ActionMenuActions actions) {
    if (g_pipeCtx is null) {
        ImGui.TextDisabled("(no pipeline)");
        return;
    }
    import toolpipe.stage : TaskCode;
    import toolpipe.stages.falloff : FalloffStage;

    string pending;
    int shown;
    foreach (stage; g_pipeCtx.pipeline.findAllByTask(TaskCode.Wght)) {
        auto falloff = cast(FalloffStage) stage;
        if (falloff is null) continue;
        immutable primary = falloff.isPrimary();
        if (primary && !falloff.isActive()) continue;
        ++shown;
        const label = primary
            ? falloff.displayName()
            : falloff.displayName() ~ "  (" ~ falloff.id() ~ ")";
        const commandLine = primary
            ? "tool.pipe.attr falloff type none"
            : "falloff.remove " ~ falloff.id();
        recordDrawnButton("popup", label, ActionKind.script, commandLine,
                          false, "");
        if (ImGui.MenuItem(label, "", false)) {
            pending = commandLine;
        }
    }
    if (shown == 0) ImGui.TextDisabled("(no active falloff)");
    if (pending.length > 0) {
        Action action;
        action.kind = ActionKind.script;
        action.scriptLines = [pending];
        dispatchAction(actions, action);
    }
}

void renderDynamicPopupItems(ActionMenuRead read, ActionMenuActions actions,
                             ref PopupItem provider) {
    switch (provider.dynamicKind) {
        case "falloffStack":
            renderFalloffStackItems(actions);
            break;
        case "acenModes":
        case "acenStageModes":
        case "axisModes":
            PopupItem[] rows = dynamicModePopupItems(provider);
            if (rows.length == 0)
                ImGui.TextDisabled("(no modes configured)");
            else
                renderPopupItems(read, actions, rows);
            break;
        default:
            ImGui.TextDisabled("(unknown dynamic '%s')", provider.dynamicKind);
            break;
    }
}

void renderPopupItems(ActionMenuRead read, ActionMenuActions actions,
                      ref PopupItem[] items) {
    foreach (ref item; items) {
        final switch (item.kind) {
            case PopupItemKind.divider:
                ImGui.Separator();
                break;
            case PopupItemKind.header:
                ImGui.TextDisabled("%s", item.label);
                break;
            case PopupItemKind.action:
                immutable checked = popupItemChecked(item.checked);
                bool decoderBlocked;
                if (item.action.kind == ActionKind.command)
                    decoderBlocked = popupActionNeedsAssimp(item.action.id)
                        && !isAssimpAvailable();
                string reason = decoderBlocked
                    ? "Requires libassimp — not loaded"
                    : read.refusal(item.action);
                immutable blocked = decoderBlocked || reason.length > 0;
                recordDrawnButton("popup", item.label, item.action.kind,
                                  item.action.id, blocked,
                                  decoderBlocked ? "" : reason);
                if (blocked) ImGui.BeginDisabled(true);
                if (ImGui.MenuItem(item.label, "", checked) && !blocked)
                    dispatchAction(actions, item.action);
                if (blocked) {
                    ImGui.EndDisabled();
                    if (ImGui.IsItemHovered(
                            ImGuiHoveredFlags.AllowWhenDisabled))
                        ImGui.SetTooltip(reason);
                }
                break;
            case PopupItemKind.submenu:
                if (ImGui.BeginMenu(item.label)) {
                    renderPopupItems(read, actions, item.subItems);
                    ImGui.EndMenu();
                }
                break;
            case PopupItemKind.dynamic:
                renderDynamicPopupItems(read, actions, item);
                break;
        }
    }
}

void renderVariantPopup(string buttonLabel, string variantSuffix, ref Action action,
                        ActionMenuRead read, ActionMenuActions actions) {
    if (action.kind != ActionKind.popup) return;
    pushPopupStyle();
    scope (exit) popPopupStyle();
    if (ImGui.BeginPopup(popupWidgetId(buttonLabel, variantSuffix))) {
        renderPopupItems(read, actions, action.popupItems);
        ImGui.EndPopup();
    }
}

void renderButtonPopups(ref Button button, ActionMenuRead read,
                        ActionMenuActions actions) {
    renderVariantPopup(button.label, "", button.action, read, actions);
    if (button.ctrl.present)
        renderVariantPopup(button.label, "_ctrl", button.ctrl.action,
                           read, actions);
    if (button.alt.present)
        renderVariantPopup(button.label, "_alt", button.alt.action,
                           read, actions);
    if (button.shift.present)
        renderVariantPopup(button.label, "_shift", button.shift.action,
                           read, actions);
}

string popupWidgetId(string buttonLabel, string variantSuffix) {
    return "##popup" ~ variantSuffix ~ "_" ~ buttonLabel;
}

// Pick the variant a button currently represents.
//
// A HELD modifier wins — that is the preview while you hold Ctrl/Alt/Shift.
// Otherwise, if a variant's action is a tool AND that tool is the active one,
// the button represents THAT variant: it keeps the variant's label and, because
// the caller derives the pressed state from the returned `action`, it stays lit
// after the modifier is released.
//
// Without the second rule a sticky tool reached through a modifier can never
// show as active: the moment you let go of Ctrl the button falls back to its
// primary action, compares the active tool against the WRONG id, goes dark, and
// re-labels itself as the primary tool — so it reads as "the button did
// nothing" while the tool is in fact running. (Found on the Pen button's Ctrl
// variant, which activates the topology pen.) One-shot variants — command or
// script — have no active state to latch and are unaffected.
void selectButtonVariant(ref Button button, SDL_Keymod mods, string activeToolId,
                         out string label, out Action action, out string variant) {
    label = button.label;
    action = button.action;
    variant = "";

    static bool isActiveTool(ref Action candidate, string activeId) {
        return candidate.kind == ActionKind.tool && candidate.id == activeId
            && activeId.length > 0;
    }

    // macOS: a `ctrl:` variant answers to ⌘ and DELIBERATELY NOT to Control.
    //
    // Control+click is reserved by macOS itself as the secondary click — the OS
    // delivers it as a RIGHT button, our ImGui backend maps right → button 1,
    // and `ImGui.Button` only fires on button 0. So a Control+click on a panel
    // button can never land, no matter what this function returns. Reported
    // exactly that way: "with Ctrl I see the changed buttons, but I can't press
    // them" — every ctrl: variant, not just the pen.
    //
    // Reacting to Control here would keep that trap alive: the label would
    // promise a variant the click cannot reach. So on macOS Control selects
    // nothing and ⌘ — a plain left click carrying a modifier — selects the
    // variant. shortcuts.d is untouched; it keeps `ctrl+` and `cmd+` as
    // distinct SHORTCUT spellings, which is a separate concern from clicks.
    // Elsewhere the mask is plain KMOD_CTRL, so Linux/Windows are unchanged.
    version (OSX) enum ctrlMask = KMOD_GUI;
    else          enum ctrlMask = KMOD_CTRL;

    if      (button.ctrl.present  && (mods & ctrlMask))   { label = button.ctrl.label;  action = button.ctrl.action;  variant = "_ctrl";  }
    else if (button.alt.present   && (mods & KMOD_ALT))   { label = button.alt.label;   action = button.alt.action;   variant = "_alt";   }
    else if (button.shift.present && (mods & KMOD_SHIFT)) { label = button.shift.label; action = button.shift.action; variant = "_shift"; }
    else if (button.ctrl.present  && isActiveTool(button.ctrl.action,  activeToolId)) { label = button.ctrl.label;  action = button.ctrl.action;  variant = "_ctrl";  }
    else if (button.alt.present   && isActiveTool(button.alt.action,   activeToolId)) { label = button.alt.label;   action = button.alt.action;   variant = "_alt";   }
    else if (button.shift.present && isActiveTool(button.shift.action, activeToolId)) { label = button.shift.label; action = button.shift.action; variant = "_shift"; }
}

bool popupItemChecked(ref Checked checked) {
    import popup_state : resolveChecked;
    return resolveChecked(checked);
}

bool popupActionNeedsAssimp(string commandId) {
    import std.algorithm.searching : startsWith, findSplitAfter;
    import io.formats : formatNeedsAssimp;
    if (!commandId.startsWith("file.import.") &&
        !commandId.startsWith("file.export."))
        return false;
    auto split = commandId.findSplitAfter("file.import.");
    string extension = split[1].length
        ? split[1]
        : commandId.findSplitAfter("file.export.")[1];
    return formatNeedsAssimp(extension);
}

string firstCheckedLabel(ref PopupItem[] items) {
    foreach (ref item; items) {
        final switch (item.kind) {
            case PopupItemKind.action:
                if (item.checked.present && popupItemChecked(item.checked))
                    return item.label;
                break;
            case PopupItemKind.submenu:
                string label = firstCheckedLabel(item.subItems);
                if (label.length > 0) return label;
                break;
            case PopupItemKind.dynamic:
                string label = dynamicModeCheckedLabel(item);
                if (label.length > 0) return label;
                break;
            case PopupItemKind.divider:
            case PopupItemKind.header:
                break;
        }
    }
    return "";
}
