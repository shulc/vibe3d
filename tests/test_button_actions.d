// Button action resolver test — asserts every action.id in config/buttons.yaml
// and config/statusline.yaml resolves to a registered command or tool factory.
//
// Primary guard: the startup validator (source/app.d) already throws on
// unresolved ids at boot — so a bad id fails the entire suite before any
// test runs.  This test is the belt-and-suspenders layer:
//   - It is named and CI-visible (not an anonymous boot side-effect).
//   - It checks statusline.yaml ids explicitly (the startup validator covers
//     them too, but this makes failures easy to triage).
//   - It is rename-proof: a future registry rename causes a diff here, not
//     just a silent boot failure on the branch that added the rename.
//
// Parsing goes through the REAL buttonset loader (same production path).
// Registry ids come from GET /api/registry (new endpoint, source/http_server.d).
// Both sides must agree — any mismatch is a hard failure with a
// "panel/group/label → kind:id" breadcrumb.

import std.net.curl  : get;
import std.json      : parseJSON, JSONValue;
import std.conv      : to;
import std.string    : strip;
import std.stdio     : writeln, writefln;
import buttonset     : loadButtons, loadStatusLine, Panel, Group, Button,
                       Action, ActionKind, PopupItemKind, allButtons;
import argstring     : parseArgstring;

void main() {}

string baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

struct RegSets {
    bool[string] commands;
    bool[string] tools;
    string[string] commandNames;  // command key -> factory().name()
}

RegSets fetchRegistry() {
    auto resp = cast(string) get(baseUrl ~ "/api/registry");
    auto jv = parseJSON(resp);
    RegSets r;
    foreach (v; jv["commands"].array) r.commands[v.str] = true;
    foreach (v; jv["tools"].array)    r.tools[v.str]    = true;
    foreach (k, v; jv["commandNames"].object) r.commandNames[k] = v.str;
    return r;
}

// ---------------------------------------------------------------------------
// Resolver unittest
// ---------------------------------------------------------------------------

unittest {
    auto panels       = loadButtons("config/buttons.yaml");
    auto statusGroups = loadStatusLine("config/statusline.yaml");
    auto reg          = fetchRegistry();

    int      checked  = 0;
    string[] failures;

    void checkAction(string ctx, ref const(Action) a) {
        final switch (a.kind) {
            case ActionKind.command:
                if (a.id !in reg.commands)
                    failures ~= ctx ~ " → command:" ~ a.id;
                else
                    ++checked;
                break;

            case ActionKind.tool:
                if (a.id !in reg.tools)
                    failures ~= ctx ~ " → tool:" ~ a.id;
                else
                    ++checked;
                break;

            case ActionKind.script:
                foreach (line; a.scriptLines) {
                    try {
                        auto parsed = parseArgstring(line);
                        if (parsed.isEmpty) continue;
                        if (parsed.commandId !in reg.commands)
                            failures ~= ctx ~ " → script-cmd:" ~ parsed.commandId;
                        else
                            ++checked;
                    } catch (Exception e) {
                        failures ~= ctx ~ " → script-parse-err:[" ~ line ~ "] " ~ e.msg;
                    }
                }
                break;

            case ActionKind.popup:
                foreach (ref pi; a.popupItems) {
                    if (pi.kind == PopupItemKind.action) {
                        checkAction(ctx ~ "/popup/" ~ pi.label, pi.action);
                    } else if (pi.kind == PopupItemKind.submenu) {
                        foreach (ref sub; pi.subItems)
                            if (sub.kind == PopupItemKind.action)
                                checkAction(ctx ~ "/submenu/" ~ pi.label ~ "/" ~ sub.label,
                                            sub.action);
                    }
                }
                break;
        }
    }

    void checkButton(string ctx, ref const(Button) btn) {
        // Disabled placeholders skip resolution — same rule as the startup validator.
        if (btn.disabled) return;
        checkAction(ctx ~ "/" ~ btn.label, btn.action);
        if (btn.ctrl.present)  checkAction(ctx ~ "/" ~ btn.label ~ "/ctrl",  btn.ctrl.action);
        if (btn.alt.present)   checkAction(ctx ~ "/" ~ btn.label ~ "/alt",   btn.alt.action);
        if (btn.shift.present) checkAction(ctx ~ "/" ~ btn.label ~ "/shift", btn.shift.action);
    }

    // Walk side panels via allButtons helper (flattens group/standalone items).
    foreach (ref p; panels) {
        auto btns = allButtons(p);
        foreach (ref btn; btns)
            checkButton(p.title, btn);
    }

    // Walk statusline groups directly (no allButtons wrapper needed — flat lists).
    foreach (ref grp; statusGroups)
        foreach (ref btn; grp.buttons)
            checkButton("<statusline>/" ~ grp.title, btn);

    writefln("button_actions: %d action ids verified", checked);

    if (failures.length > 0) {
        writeln("FAIL — unresolved ids:");
        foreach (f; failures)
            writeln("  ", f);
        assert(false, to!string(failures.length) ~ " button action(s) not in registry");
    }

    // Registry-name integrity: every registered command's factory().name()
    // must itself resolve back to SOME registered command key (not
    // necessarily the SAME key it was registered under — alias keys like
    // file.open / file.import.* / file.export.* deliberately share one
    // command class whose name() is a different, but still live, key).
    // Enumerate ALL commands and report every offender, rather than
    // asserting on the first mismatch. An "offender" is a distinct
    // drifting name() VALUE (one per underlying command class) — many
    // alias keys share the same class and therefore the same name(), so
    // they collapse into a single offender rather than being counted once
    // per alias key.
    string[][string] offendersByName;  // drifting name() -> keys registered under it
    foreach (key, nm; reg.commandNames) {
        if (nm !in reg.commands)
            offendersByName[nm] ~= key;
    }

    writefln("button_actions: %d command name() resolutions checked",
             reg.commandNames.length);

    if (offendersByName.length > 0) {
        writeln("FAIL - command name() does not resolve:");
        foreach (nm, keys; offendersByName)
            writeln("  \"", nm, "\" (keys: ", keys, ")");
        assert(false, to!string(offendersByName.length)
               ~ " command name() value(s) that do not resolve to a registered key");
    }
}
