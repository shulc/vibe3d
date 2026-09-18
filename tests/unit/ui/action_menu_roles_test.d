module tests.unit.ui.action_menu_roles_test;

import bindbc.sdl : SDL_Keymod, KMOD_ALT, KMOD_CTRL, KMOD_GUI, KMOD_NONE;
import buttonset : Action, ActionKind, Button;
import ui.action_menu : selectButtonVariant;

private Button penButton() {
    Button b;
    b.label  = "Pen";
    b.action = Action(ActionKind.tool, "pen");
    b.ctrl.present = true;
    b.ctrl.label   = "Topology Pen";
    b.ctrl.action  = Action(ActionKind.tool, "mesh.topoPen");
    return b;
}

unittest { // C2a: the six relocated variant cells
    string label;
    Action action;
    string variant;
    auto btn = penButton();

    assert(btn.ctrl.present, "6560 variant floor: the ctrl fixture is absent");
    selectButtonVariant(btn, KMOD_CTRL, "", label, action, variant);
    assert(action.id == "mesh.topoPen" && label == "Topology Pen" && variant == "_ctrl");

    assert(btn.ctrl.present, "6560 variant floor: the ctrl fixture is absent");
    selectButtonVariant(btn, KMOD_NONE, "mesh.topoPen", label, action, variant);
    assert(action.id == "mesh.topoPen", "released modifier must not drop an active variant tool");
    assert(label == "Topology Pen", "an active variant must keep its own label");

    assert(btn.ctrl.present, "6560 variant floor: the ctrl fixture is absent");
    selectButtonVariant(btn, KMOD_NONE, "pen", label, action, variant);
    assert(action.id == "pen" && label == "Pen" && variant == "");

    assert(btn.ctrl.present, "6560 variant floor: the ctrl fixture is absent");
    selectButtonVariant(btn, KMOD_NONE, "", label, action, variant);
    assert(action.id == "pen" && variant == "");

    assert(btn.ctrl.present, "6560 variant floor: the ctrl fixture is absent");
    version (OSX) {
        selectButtonVariant(btn, KMOD_GUI, "", label, action, variant);
        assert(action.id == "mesh.topoPen", "macOS: Cmd must reach a ctrl: variant");
        selectButtonVariant(btn, KMOD_CTRL, "", label, action, variant);
        assert(action.id == "pen" && label == "Pen", "macOS: Control must not preview a variant it cannot click");
    } else {
        selectButtonVariant(btn, KMOD_GUI, "", label, action, variant);
        assert(action.id == "pen", "non-macOS: Super/Cmd must NOT alias Ctrl");
        selectButtonVariant(btn, KMOD_CTRL, "", label, action, variant);
        assert(action.id == "mesh.topoPen", "non-macOS: Control selects the ctrl: variant");
    }

    Button cmdBtn;
    cmdBtn.label  = "Arc";
    cmdBtn.action = Action(ActionKind.tool, "prim.arc");
    cmdBtn.ctrl.present = true;
    cmdBtn.ctrl.label   = "Unit Arc";
    cmdBtn.ctrl.action  = Action(ActionKind.command, "prim.arc.unit");
    assert(cmdBtn.ctrl.present, "6560 variant floor: the command ctrl fixture is absent");
    selectButtonVariant(cmdBtn, KMOD_NONE, "prim.arc", label, action, variant);
    assert(action.id == "prim.arc" && variant == "", "a command variant must not claim the button");
}

unittest { // C2b: simultaneous held modifiers keep Ctrl above Alt
    string label;
    Action action;
    string variant;
    auto btn = penButton();
    btn.alt.present = true;
    btn.alt.label = "Alt Pen";
    btn.alt.action = Action(ActionKind.tool, "mesh.altPen");
    assert(btn.ctrl.present && btn.alt.present,
        "6560 modifier-priority floor: both variants must exist");
    version (OSX) enum testCtrl = KMOD_GUI;
    else          enum testCtrl = KMOD_CTRL;
    selectButtonVariant(btn, cast(SDL_Keymod)(testCtrl | KMOD_ALT), "",
                        label, action, variant);
    assert(variant == "_ctrl",
        "6560 modifier priority: ctrl must win over a simultaneously held alt");
}

unittest { // C2c: active variant claims retain Ctrl-before-Alt ordering
    string label;
    Action action;
    string variant;
    auto btn = penButton();
    btn.ctrl.action = Action(ActionKind.tool, "mesh.sharedPen");
    btn.alt.present = true;
    btn.alt.label = "Alt Shared Pen";
    btn.alt.action = Action(ActionKind.tool, "mesh.sharedPen");
    immutable activeToolId = "mesh.sharedPen";
    assert(btn.ctrl.present && btn.alt.present && activeToolId.length > 0,
        "6560 active-variant floor: both variants and an active id must exist");
    selectButtonVariant(btn, KMOD_NONE, activeToolId, label, action, variant);
    assert(label == btn.ctrl.label,
        "6560 active variant priority: ctrl must claim before alt when both name the active tool");
}
