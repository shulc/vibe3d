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

struct Panel {
    string   title;
    Button[] buttons;
}

// ---------------------------------------------------------------------------
// Load config/buttons.yaml
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
            throw new Exception(
                format("buttonset: panel in '%s' is missing 'title'", path));
        if (!panelNode.containsKey("buttons"))
            throw new Exception(
                format("buttonset: panel '%s' in '%s' is missing 'buttons'",
                       panelNode["title"].as!string, path));

        Panel panel;
        panel.title = panelNode["title"].as!string;

        foreach (Node btnNode; panelNode["buttons"]) {
            if (!btnNode.containsKey("label"))
                throw new Exception(
                    format("buttonset: button in panel '%s' ('%s') is missing 'label'",
                           panel.title, path));
            if (!btnNode.containsKey("action"))
                throw new Exception(
                    format("buttonset: button '%s' in panel '%s' ('%s') is missing 'action'",
                           btnNode["label"].as!string, panel.title, path));

            Node actionNode = btnNode["action"];
            if (!actionNode.containsKey("kind"))
                throw new Exception(
                    format("buttonset: action for button '%s' in panel '%s' ('%s') is missing 'kind'",
                           btnNode["label"].as!string, panel.title, path));
            if (!actionNode.containsKey("id"))
                throw new Exception(
                    format("buttonset: action for button '%s' in panel '%s' ('%s') is missing 'id'",
                           btnNode["label"].as!string, panel.title, path));

            string kindStr = actionNode["kind"].as!string;
            ActionKind kind;
            if      (kindStr == "tool")    kind = ActionKind.tool;
            else if (kindStr == "command") kind = ActionKind.command;
            else throw new Exception(
                format("buttonset: unknown action kind '%s' for button '%s' in '%s'",
                       kindStr, btnNode["label"].as!string, path));

            Button btn;
            btn.label        = btnNode["label"].as!string;
            btn.action.kind  = kind;
            btn.action.id    = actionNode["id"].as!string;
            panel.buttons   ~= btn;
        }

        panels ~= panel;
    }

    return panels;
}
