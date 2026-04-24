module buttonset;

import std.format : format;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

enum ActionKind { tool, command }

struct Action {
    ActionKind kind;
    string     id;
}

struct Button {
    string label;
    Action action;
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
// Helper: flatten all buttons in a panel (used by startup validation).
// ---------------------------------------------------------------------------

Button[] allButtons(const ref Panel p) {
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

private Button parseButton(NodeT)(NodeT btnNode, string panelTitle, string groupTitle, string path) {
    if (!btnNode.containsKey("label"))
        throw new Exception(
            format("buttonset: button in group '%s' of panel '%s' ('%s') is missing 'label'",
                   groupTitle, panelTitle, path));
    if (!btnNode.containsKey("action"))
        throw new Exception(
            format("buttonset: button '%s' in panel '%s' ('%s') is missing 'action'",
                   btnNode["label"].as!string, panelTitle, path));

    auto actionNode = btnNode["action"];
    if (!actionNode.containsKey("kind"))
        throw new Exception(
            format("buttonset: action for button '%s' in panel '%s' ('%s') is missing 'kind'",
                   btnNode["label"].as!string, panelTitle, path));
    if (!actionNode.containsKey("id"))
        throw new Exception(
            format("buttonset: action for button '%s' in panel '%s' ('%s') is missing 'id'",
                   btnNode["label"].as!string, panelTitle, path));

    string kindStr = actionNode["kind"].as!string;
    ActionKind kind;
    if      (kindStr == "tool")    kind = ActionKind.tool;
    else if (kindStr == "command") kind = ActionKind.command;
    else throw new Exception(
        format("buttonset: unknown action kind '%s' for button '%s' in '%s'",
               kindStr, btnNode["label"].as!string, path));

    Button btn;
    btn.label       = btnNode["label"].as!string;
    btn.action.kind = kind;
    btn.action.id   = actionNode["id"].as!string;
    return btn;
}
