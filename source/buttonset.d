module buttonset;

import std.format : format;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

enum ActionKind { tool, command, script, popup }

struct Action {
    ActionKind kind;
    string     id;            // empty for kind == script / popup
    // For kind == script: each entry is a MODO-style argstring line that
    // gets dispatched through the same path as /api/command. Empty for
    // kind == tool / command / popup.
    string[]   scriptLines;
    // For kind == popup: items rendered in the dropdown when the button
    // is clicked. See doc/popup_buttons_plan.md.
    PopupItem[] popupItems;
    // For kind == popup: optional state-query that drives the parent
    // button's "pressed" appearance — same shape as PopupItem.checked
    // (e.g. Work Plane button glows when workplane/auto != "true").
    Checked    checked;
    // For kind == popup: when true, the parent button's label changes
    // dynamically to the label of the first popup item whose `checked:`
    // resolves true (mirrors MODO's `<atom type="PopupFace">optionOrLabel
    // </atom>` — see resrc/701_frm_modomodes_forms.cfg:683). When no
    // item is checked, falls back to the static `Button.label`.
    bool       dynamicLabel;
}

// ---------------------------------------------------------------------------
// PopupItem — a row inside a dropdown opened by a `kind: popup` button.
//
// Three kinds (mirroring the 3-state behaviour described in
// doc/popup_buttons_plan.md §"Item types in items[]"):
//
//   - `action`   — a clickable row that runs an Action (tool / command
//                  / script). `label` is the row text. Optional
//                  `checked` (Checked struct, see below) draws a ✓ on
//                  the left when its state-path query matches.
//   - `divider`  — non-interactive horizontal separator. Drawn as
//                  `ImGui.Separator`. `label` ignored.
//   - `header`   — non-interactive bold label that titles a sub-group
//                  of items. Drawn as `ImGui.TextDisabled`. No action.
//
// `kind: separator` is accepted as a YAML alias of `divider` (matches
// the term used by config/statusline.yaml's grouping plan).
// ---------------------------------------------------------------------------
enum PopupItemKind { action, divider, header, submenu }

/// Optional state-query attached to action items — when present, the
/// row gets a checkmark indicator if the comparison matches.
///
/// Two modes (mutually exclusive):
///   `equals`   exact string equality with state[path]
///   `contains` substring or list-element match in state[path]
///
/// State paths are slash-separated (e.g. `workplane/mode`). The
/// state map is populated by subsystems and resolved at render time
/// — see doc/popup_buttons_plan.md §"State paths examples" + the
/// 8.2 subphase that adds the registry.
struct Checked {
    bool   present;       // true when YAML had a `checked:` block
    string path;
    string equals_;       // populated when `equals:` was given
    string contains;      // populated when `contains:` was given
    string notEquals;     // populated when `notEquals:` was given —
                          // true iff state[path] != notEquals (handy
                          // for "pressed when not none" semantics).
}

struct PopupItem {
    PopupItemKind kind;
    string        label;        // valid for action / header / submenu
    Action        action;       // valid for action only
    Checked       checked;      // valid for action only — optional
    PopupItem[]   subItems;     // valid for submenu only — children
                                // rendered in a child popup
                                // (BeginMenu/EndMenu).
}

// One-modifier override: when the corresponding key is held, the button
// shows `label` and dispatches `action` instead of the default ones.
struct ButtonVariant {
    bool   present;
    string label;
    Action action;
}

struct Button {
    string label;
    Action action;
    // Optional state-query that drives the button's "pressed" appearance,
    // independent of action.kind. Useful for `kind: command` / `kind: script`
    // toggles whose on/off state lives somewhere else in the pipeline
    // (e.g. Snap toggle reflecting `snap/enabled`). For `kind: popup` the
    // legacy action-level `checked:` still works — button-level wins
    // when both are set.
    Checked checked;
    // YAML `disable: true` — placeholder / not-yet-implemented row.
    // Background and bevel render as normal; the label is drawn with
    // an engraved (dark text + 1-px highlight shadow) look and the
    // button doesn't react to hover or click. MODO-side-panel
    // convention for "tool listed in this panel but not implemented".
    bool disabled;
    // Optional state-path override for the visible label. When the path
    // resolves to a non-empty string at render time, that value replaces
    // the static `label`. Useful for command-kind toggles that want to
    // surface the current state on the button face (e.g. Symmetry
    // showing "Symmetry: X" when enabled, "Symmetry" when off) —
    // `action.dynamicLabel` covers the popup case but is gated on a
    // popup action kind, so command/script buttons need this alt path.
    string dynamicLabelPath;
    // Optional alternate behaviors keyed by modifier (MODO convention).
    // YAML keys: `ctrl`, `alt`, `shift`. Each block is itself a mini-button
    // entry: `label` + `action`. Combinations (e.g. ctrl+shift) are not
    // currently supported — first-set modifier in the order ctrl > alt >
    // shift wins. When no modifier is held, the default label/action apply.
    ButtonVariant ctrl;
    ButtonVariant alt;
    ButtonVariant shift;
}

struct Group {
    string   title;    // optional (may be empty → group renders with no header)
    Button[] buttons;
}

struct PanelItem {
    bool   isGroup;
    Button button;    // valid when !isGroup
    Group  group;     // valid when isGroup
}

struct Panel {
    string      title;
    PanelItem[] items;
}

// ---------------------------------------------------------------------------
// Load config/buttons.yaml
//
// Each entry in 'items' is either:
//   - a plain button (has 'label')
//   - a group of buttons (has 'buttons'; optional 'title')
// ---------------------------------------------------------------------------

Panel[] loadButtons(string path) {
    import dyaml;

    Node root;
    try {
        root = Loader.fromFile(path).load();
    } catch (Exception e) {
        throw new Exception(format("buttonset: failed to load '%s': %s", path, e.msg));
    }

    if (!root.containsKey("panels"))
        throw new Exception(format("buttonset: '%s' missing top-level 'panels' key", path));

    Panel[] panels;
    foreach (Node panelNode; root["panels"]) {
        if (!panelNode.containsKey("title"))
            throw new Exception(format("buttonset: panel in '%s' is missing 'title'", path));
        if (!panelNode.containsKey("items"))
            throw new Exception(
                format("buttonset: panel '%s' in '%s' is missing 'items'",
                       panelNode["title"].as!string, path));

        Panel panel;
        panel.title = panelNode["title"].as!string;

        foreach (Node itemNode; panelNode["items"]) {
            bool hasLabel   = itemNode.containsKey("label");
            bool hasButtons = itemNode.containsKey("buttons");

            if (hasLabel && hasButtons)
                throw new Exception(
                    format("buttonset: item in panel '%s' ('%s') has both 'label' and 'buttons' — must be one or the other",
                           panel.title, path));
            if (!hasLabel && !hasButtons)
                throw new Exception(
                    format("buttonset: item in panel '%s' ('%s') must have 'label' (plain button) or 'buttons' (group)",
                           panel.title, path));

            PanelItem pi;
            if (hasButtons) {
                pi.isGroup = true;
                if (itemNode.containsKey("title"))
                    pi.group.title = itemNode["title"].as!string;
                foreach (Node btnNode; itemNode["buttons"])
                    pi.group.buttons ~= parseButton(btnNode, panel.title, pi.group.title, path);
            } else {
                pi.isGroup = false;
                pi.button  = parseButton(itemNode, panel.title, "", path);
            }
            panel.items ~= pi;
        }

        panels ~= panel;
    }

    return panels;
}

// ---------------------------------------------------------------------------
// Load config/statusline.yaml — horizontal row of grouped buttons rendered
// in the bottom status bar. Same per-button schema as buttons.yaml entries.
//
// Two YAML shapes accepted:
//
//   1. New (preferred — `doc/button_grouping_plan.md`):
//        groups:
//          - title: editmode
//            buttons:
//              - { label: Vertices, ... }
//              ...
//          - title: workplane
//            buttons:
//              - { label: Work Plane, ... }
//
//      `Group.title` is grouping-only (NOT rendered in the status bar) —
//      used as a stable PushID key and for diagnostics. The renderer
//      adds an inter-group gap so adjacent groups read as separate
//      concerns.
//
//   2. Legacy (kept for backward-compat — wraps in a single anonymous
//      Group with title="default"):
//        buttons:
//          - { label: Vertices, ... }
//          ...
// ---------------------------------------------------------------------------

Group[] loadStatusLine(string path) {
    import dyaml;

    Node root;
    try {
        root = Loader.fromFile(path).load();
    } catch (Exception e) {
        throw new Exception(format("statusline: failed to load '%s': %s", path, e.msg));
    }

    bool hasGroups  = root.containsKey("groups");
    bool hasButtons = root.containsKey("buttons");

    if (hasGroups && hasButtons)
        throw new Exception(format(
            "statusline: '%s' has both 'groups:' and 'buttons:' top-level keys — pick one",
            path));
    if (!hasGroups && !hasButtons)
        throw new Exception(format(
            "statusline: '%s' must have either 'groups:' (preferred) or 'buttons:' (legacy)",
            path));

    Group[] groups;
    if (hasGroups) {
        foreach (Node groupNode; root["groups"])
            groups ~= parseGroup(groupNode, "<statusline>", path);
    } else {
        // Legacy flat-list — wrap in a single anonymous group.
        Group g;
        g.title = "default";
        foreach (Node btnNode; root["buttons"])
            g.buttons ~= parseButton(btnNode, "<statusline>", g.title, path);
        groups ~= g;
    }
    return groups;
}

// ---------------------------------------------------------------------------
// Helper: flatten all buttons in a panel (used by startup validation).
// ---------------------------------------------------------------------------

Button[] allButtons(ref Panel p) {
    Button[] result;
    foreach (ref item; p.items) {
        if (item.isGroup) {
            foreach (ref b; item.group.buttons)
                result ~= b;
        } else {
            result ~= item.button;
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Private
// ---------------------------------------------------------------------------

// Parse one Group node — { title (mandatory), buttons: [...] }. Used by
// the status-bar loader; the side-panel loader has its own inline
// equivalent for now since it also accepts standalone-Button entries
// (see `doc/buttonset_unification_plan.md` for the eventual merge).
private Group parseGroup(NodeT)(NodeT groupNode, string ctxLabel, string path) {
    if (!groupNode.containsKey("title"))
        throw new Exception(format(
            "buttonset: group in %s ('%s') is missing 'title'", ctxLabel, path));
    if (!groupNode.containsKey("buttons"))
        throw new Exception(format(
            "buttonset: group in %s ('%s') is missing 'buttons'", ctxLabel, path));

    Group g;
    g.title = groupNode["title"].as!string;
    import dyaml : Node;
    foreach (Node btnNode; groupNode["buttons"])
        g.buttons ~= parseButton(btnNode, ctxLabel, g.title, path);
    return g;
}

private Action parseAction(NodeT)(NodeT actionNode, string ctxLabel, string path) {
    if (!actionNode.containsKey("kind"))
        throw new Exception(
            format("buttonset: action for '%s' ('%s') is missing 'kind'",
                   ctxLabel, path));
    string kindStr = actionNode["kind"].as!string;
    ActionKind kind;
    if      (kindStr == "tool")    kind = ActionKind.tool;
    else if (kindStr == "command") kind = ActionKind.command;
    else if (kindStr == "script")  kind = ActionKind.script;
    else if (kindStr == "popup")   kind = ActionKind.popup;
    else throw new Exception(
        format("buttonset: unknown action kind '%s' for '%s' in '%s'",
               kindStr, ctxLabel, path));

    Action a;
    a.kind = kind;
    final switch (kind) {
        case ActionKind.script: {
            if (!actionNode.containsKey("lines"))
                throw new Exception(
                    format("buttonset: script action for '%s' ('%s') is missing 'lines'",
                           ctxLabel, path));
            import dyaml : Node;
            foreach (Node lineNode; actionNode["lines"]) {
                string line = lineNode.as!string;
                if (line.length > 0)
                    a.scriptLines ~= line;
            }
            if (a.scriptLines.length == 0)
                throw new Exception(
                    format("buttonset: script action for '%s' ('%s') has no non-empty lines",
                           ctxLabel, path));
            break;
        }
        case ActionKind.popup: {
            if (!actionNode.containsKey("items"))
                throw new Exception(
                    format("buttonset: popup action for '%s' ('%s') is missing 'items'",
                           ctxLabel, path));
            import dyaml : Node;
            size_t idx = 0;
            foreach (Node itemNode; actionNode["items"]) {
                a.popupItems ~= parsePopupItem(itemNode, ctxLabel, idx, path);
                ++idx;
            }
            if (a.popupItems.length == 0)
                throw new Exception(
                    format("buttonset: popup action for '%s' ('%s') has empty 'items'",
                           ctxLabel, path));
            if (actionNode.containsKey("checked"))
                a.checked = parseChecked(actionNode["checked"], ctxLabel, path);
            if (actionNode.containsKey("dynamicLabel"))
                a.dynamicLabel = actionNode["dynamicLabel"].as!bool;
            break;
        }
        case ActionKind.tool:
        case ActionKind.command: {
            if (!actionNode.containsKey("id"))
                throw new Exception(
                    format("buttonset: action for '%s' ('%s') is missing 'id'",
                           ctxLabel, path));
            a.id = actionNode["id"].as!string;
            break;
        }
    }
    return a;
}

// Parse one PopupItem node. Three shapes accepted:
//
//   { kind: divider }                  → divider row (no label, no action)
//   { kind: separator }                → alias of divider
//   { kind: header, label: "..." }     → bold header row (no action)
//   { label: "...", action: {...},     → action row (clickable)
//     checked: { path: ..., equals: "..." | contains: "..." } }
//
// For the action shape, `kind:` is OPTIONAL (defaults to action). `kind:
// action` is also accepted for explicitness.
private PopupItem parsePopupItem(NodeT)(NodeT itemNode, string ctxLabel,
                                         size_t idx, string path) {
    string kindStr = itemNode.containsKey("kind") ? itemNode["kind"].as!string : "action";

    PopupItem pi;
    if (kindStr == "divider" || kindStr == "separator") {
        pi.kind = PopupItemKind.divider;
        return pi;
    }
    if (kindStr == "header") {
        if (!itemNode.containsKey("label"))
            throw new Exception(format(
                "buttonset: popup header item #%d for '%s' ('%s') is missing 'label'",
                idx, ctxLabel, path));
        pi.kind  = PopupItemKind.header;
        pi.label = itemNode["label"].as!string;
        return pi;
    }
    if (kindStr == "submenu") {
        if (!itemNode.containsKey("label"))
            throw new Exception(format(
                "buttonset: popup submenu item #%d for '%s' ('%s') is missing 'label'",
                idx, ctxLabel, path));
        if (!itemNode.containsKey("items"))
            throw new Exception(format(
                "buttonset: popup submenu item '%s' for '%s' ('%s') is missing 'items'",
                itemNode["label"].as!string, ctxLabel, path));
        pi.kind  = PopupItemKind.submenu;
        pi.label = itemNode["label"].as!string;
        import dyaml : Node;
        size_t subIdx = 0;
        foreach (Node subNode; itemNode["items"]) {
            pi.subItems ~= parsePopupItem(
                subNode, ctxLabel ~ "/" ~ pi.label, subIdx, path);
            ++subIdx;
        }
        if (pi.subItems.length == 0)
            throw new Exception(format(
                "buttonset: popup submenu '%s' for '%s' ('%s') has empty 'items'",
                pi.label, ctxLabel, path));
        return pi;
    }
    if (kindStr != "action")
        throw new Exception(format(
            "buttonset: unknown popup item kind '%s' (#%d) for '%s' in '%s'",
            kindStr, idx, ctxLabel, path));

    if (!itemNode.containsKey("label"))
        throw new Exception(format(
            "buttonset: popup item #%d for '%s' ('%s') is missing 'label'",
            idx, ctxLabel, path));
    if (!itemNode.containsKey("action"))
        throw new Exception(format(
            "buttonset: popup item '%s' for '%s' ('%s') is missing 'action'",
            itemNode["label"].as!string, ctxLabel, path));

    pi.kind   = PopupItemKind.action;
    pi.label  = itemNode["label"].as!string;
    pi.action = parseAction(itemNode["action"], ctxLabel ~ "/" ~ pi.label, path);

    if (itemNode.containsKey("checked"))
        pi.checked = parseChecked(itemNode["checked"], ctxLabel, path);
    return pi;
}

private Checked parseChecked(NodeT)(NodeT chkNode, string ctxLabel, string path) {
    if (!chkNode.containsKey("path"))
        throw new Exception(format(
            "buttonset: 'checked' for '%s' ('%s') is missing 'path'",
            ctxLabel, path));
    bool hasEquals    = chkNode.containsKey("equals");
    bool hasContains  = chkNode.containsKey("contains");
    bool hasNotEquals = chkNode.containsKey("notEquals");
    int present = (hasEquals ? 1 : 0) + (hasContains ? 1 : 0) + (hasNotEquals ? 1 : 0);
    if (present > 1)
        throw new Exception(format(
            "buttonset: 'checked' for '%s' ('%s') has multiple of equals/contains/notEquals",
            ctxLabel, path));
    if (present == 0)
        throw new Exception(format(
            "buttonset: 'checked' for '%s' ('%s') has none of equals/contains/notEquals",
            ctxLabel, path));
    Checked chk;
    chk.present = true;
    chk.path    = chkNode["path"].as!string;
    if (hasEquals)    chk.equals_   = chkNode["equals"].as!string;
    if (hasContains)  chk.contains  = chkNode["contains"].as!string;
    if (hasNotEquals) chk.notEquals = chkNode["notEquals"].as!string;
    return chk;
}

private ButtonVariant parseModifierVariant(NodeT)(NodeT btnNode, string key,
                                                   string parentLabel, string path) {
    if (!btnNode.containsKey(key)) return ButtonVariant.init;
    auto sub = btnNode[key];
    if (!sub.containsKey("label"))
        throw new Exception(
            format("buttonset: modifier '%s' for button '%s' ('%s') is missing 'label'",
                   key, parentLabel, path));
    if (!sub.containsKey("action"))
        throw new Exception(
            format("buttonset: modifier '%s' for button '%s' ('%s') is missing 'action'",
                   key, parentLabel, path));
    ButtonVariant v;
    v.present = true;
    v.label   = sub["label"].as!string;
    v.action  = parseAction(sub["action"], parentLabel ~ "/" ~ key, path);
    return v;
}

private Button parseButton(NodeT)(NodeT btnNode, string panelTitle, string groupTitle, string path) {
    if (!btnNode.containsKey("label"))
        throw new Exception(
            format("buttonset: button in group '%s' of panel '%s' ('%s') is missing 'label'",
                   groupTitle, panelTitle, path));
    if (!btnNode.containsKey("action"))
        throw new Exception(
            format("buttonset: button '%s' in panel '%s' ('%s') is missing 'action'",
                   btnNode["label"].as!string, panelTitle, path));

    Button btn;
    btn.label  = btnNode["label"].as!string;
    btn.action = parseAction(btnNode["action"], btn.label, path);
    if (btnNode.containsKey("checked"))
        btn.checked = parseChecked(btnNode["checked"], btn.label, path);
    if (btnNode.containsKey("dynamicLabel")) {
        auto dl = btnNode["dynamicLabel"];
        if (dl.containsKey("path"))
            btn.dynamicLabelPath = dl["path"].as!string;
    }
    if (btnNode.containsKey("disable"))
        btn.disabled = btnNode["disable"].as!bool;
    else if (btnNode.containsKey("disabled"))
        btn.disabled = btnNode["disabled"].as!bool;
    btn.ctrl   = parseModifierVariant(btnNode, "ctrl",  btn.label, path);
    btn.alt    = parseModifierVariant(btnNode, "alt",   btn.label, path);
    btn.shift  = parseModifierVariant(btnNode, "shift", btn.label, path);
    return btn;
}
