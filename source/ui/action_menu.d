module ui.action_menu;

import bindbc.sdl : SDL_Keymod, KMOD_ALT, KMOD_CTRL, KMOD_GUI, KMOD_SHIFT;
import buttonset : Action, ActionKind, Button, Checked, PopupItem, PopupItemKind;
import ui.mode_popup : dynamicModeCheckedLabel;

// Resolve a popup item's `checked:` block via the popup_state
// registry. Producers publish via setStatePath; this is the only
// consumer site.
bool popupItemChecked(ref Checked chk) {
    import popup_state : resolveChecked;
    return resolveChecked(chk);
}

// True when a File-menu Import/Export command id targets a format that
// routes through assimp (so it must be greyed out when libassimp is
// unavailable). Ids look like "file.import.obj" / "file.export.gltf";
// the trailing token is the extension consulted in the format registry.
bool popupActionNeedsAssimp(string commandId) {
    import std.algorithm.searching : startsWith, findSplitAfter;
    import io.formats : formatNeedsAssimp;
    if (!commandId.startsWith("file.import.") &&
        !commandId.startsWith("file.export."))
        return false;
    // last dot-separated token = bare ext ("obj", "gltf", ...)
    auto split = commandId.findSplitAfter("file.import.");
    string ext = split[1].length ? split[1]
                                 : commandId.findSplitAfter("file.export.")[1];
    return formatNeedsAssimp(ext);
}

// Walk popup items (recursing into submenus) and return the label
// of the first one whose `checked:` resolves true. Powers
// `Action.dynamicLabel` — a "popup face" that reflects the active
// option. Returns "" when nothing matches.
string firstCheckedLabel(ref PopupItem[] items) {
    foreach (ref it; items) {
        final switch (it.kind) {
            case PopupItemKind.action:
                if (it.checked.present && popupItemChecked(it.checked))
                    return it.label;
                break;
            case PopupItemKind.submenu:
                string s = firstCheckedLabel(it.subItems);
                if (s.length > 0) return s;
                break;
            case PopupItemKind.dynamic:
                string s = dynamicModeCheckedLabel(it);
                if (s.length > 0) return s;
                break;
            case PopupItemKind.divider:
            case PopupItemKind.header:
                break;
        }
    }
    return "";
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
void selectButtonVariant(ref Button btn, SDL_Keymod mods, string activeToolId,
                         out string label, out Action action, out string variant) {
    label = btn.label;
    action = btn.action;
    variant = "";

    static bool isActiveTool(ref Action a, string activeToolId) {
        return a.kind == ActionKind.tool && a.id == activeToolId
            && activeToolId.length > 0;
    }

    // macOS: a `ctrl:` variant answers to ⌘ and deliberately not Control,
    // whose click is delivered as a secondary button by the platform.
    version (OSX) enum ctrlMask = KMOD_GUI;
    else          enum ctrlMask = KMOD_CTRL;

    if      (btn.ctrl.present  && (mods & ctrlMask))   { label = btn.ctrl.label;  action = btn.ctrl.action;  variant = "_ctrl";  }
    else if (btn.alt.present   && (mods & KMOD_ALT))   { label = btn.alt.label;   action = btn.alt.action;   variant = "_alt";   }
    else if (btn.shift.present && (mods & KMOD_SHIFT)) { label = btn.shift.label; action = btn.shift.action; variant = "_shift"; }
    else if (btn.ctrl.present  && isActiveTool(btn.ctrl.action,  activeToolId)) { label = btn.ctrl.label;  action = btn.ctrl.action;  variant = "_ctrl";  }
    else if (btn.alt.present   && isActiveTool(btn.alt.action,   activeToolId)) { label = btn.alt.label;   action = btn.alt.action;   variant = "_alt";   }
    else if (btn.shift.present && isActiveTool(btn.shift.action, activeToolId)) { label = btn.shift.label; action = btn.shift.action; variant = "_shift"; }
}
