// Topology pen — attribute availability by mode, the panel half (wave plan
// 8640 slice 8690, M-I / D16; law L16). The pen's `paramEnabled` answers the
// mode test (Strength only in Smoothing, Range / Quads Only only in Fill) and
// the Tool Properties form greys the row: a disabled row takes no input and
// dispatches nothing. The write-door refusal is tests/test_topopen_attr_availability.d.
//
// (1) Population, per mode, over the pen's own `params()` (no hard-coded
//     list): the disabled set in every one of the eight modes.
// (2) The shipped form's Strength row, drawn by the shipped `FormsPanel` with
//     the pen as provider: in Smoothing a Tab reaches it and a typed value
//     dispatches one interactive `tool.attr` (positive half FIRST); in Move
//     the Tab reaches nothing and nothing is dispatched.
// Fast loop: tools/local/ut-standalone.sh tests/unit/ui/topology_pen_attr_availability_test.d
module tests.unit.ui.topology_pen_attr_availability_test;

import std.algorithm : canFind, sort;
import std.array : array;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : buildNormalizedPath, buildPath, dirName;

import d_imgui.imgui_h : ImGuiKey;
import forms : Form, loadForms;
import forms_render : FormsPanel;
import params : injectParamsInto, wireTagForValue;
import tests.unit.ui.headless_panel : HeadlessPanel, openPanel;
import tools.edit.topology_pen.tool : TopologyPenTool;

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
                                             "..", "..", "..");

private void setMode(TopologyPenTool pen, string mode) {
    auto pj = parseJSON(`{"mode":"` ~ mode ~ `"}`);
    injectParamsInto(pen.params(), pj);
    // The write landed (the mode test reads the field the Param binds).
    foreach (ref p; pen.params())
        if (p.name == "mode")
            assert(wireTagForValue(p.intEnumValues, *p.iptr) == mode,
                   "8690 rig: the pen's mode did not become " ~ mode);
}

private string[] disabledParams(TopologyPenTool pen, out size_t visited) {
    string[] off;
    visited = 0;
    foreach (ref p; pen.params()) {
        ++visited;
        if (!pen.paramEnabled(p.name)) off ~= p.name;
    }
    return off.sort.array;
}

unittest { // (1) the disabled set per mode
    auto pen = new TopologyPenTool();
    static immutable string[2][8] modes = [
        ["move",      "quadOnly,range,smoothStrength"],
        ["duplicate", "quadOnly,range,smoothStrength"],
        ["remove",    "quadOnly,range,smoothStrength"],
        ["split",     "quadOnly,range,smoothStrength"],
        ["addLoop",   "quadOnly,range,smoothStrength"],
        ["point",     "quadOnly,range,smoothStrength"],
        ["fill",      "smoothStrength"],
        ["smooth",    "quadOnly,range"],
    ];
    size_t cells;
    foreach (m; modes) {
        setMode(pen, m[0]);
        size_t visited;
        const off = disabledParams(pen, visited);
        import std.array : join;
        assert(visited == 18, format("8690 population: the pen publishes %s params, measured 18 "
                                     ~ "(12 + the S7a operation context)",
                                     visited));
        assert(off.join(",") == m[1],
               format("8690 availability: mode %s disables %s, expected [%s]", m[0], off, m[1]));
        ++cells;
    }
    assert(cells == 8, "8690 population: the mode table did not run all eight modes");
}

unittest { // (2) the shipped form greys the Strength row outside Smoothing
    auto forms = loadForms(repoRoot.buildPath("config", "forms", "topology_pen.yaml"));
    Form strength;
    size_t found;
    foreach (ref f; forms) {
        if (f.id != "topopen.main") continue;
        foreach (ref r; f.rows)
            if (r.command == "tool.attr mesh.topoPen smoothStrength ?") {
                strength = f;
                strength.rows = [r];
                ++found;
            }
    }
    assert(found == 1, format("8690 panel rig: the shipped form has %s Strength rows", found));

    auto pen = new TopologyPenTool();
    auto panel = new FormsPanel;
    string[] sent;
    auto ui = openPanel(() {
        panel.draw(strength, pen, null,
                   (string id, string json) { sent ~= id ~ " " ~ json; },
                   "mesh.topoPen");
    });
    scope(exit) ui.close();

    void tabAndType(string value) {
        ui.frame();
        ui.keyDown(cast(int) ImGuiKey.Tab);
        ui.frame();
        ui.keyUp(cast(int) ImGuiKey.Tab);
        ui.frame();
        ui.typeText(value);
        ui.keyDown(cast(int) ImGuiKey.Enter);
        ui.frame();
        ui.keyUp(cast(int) ImGuiKey.Enter);
        ui.frame();
        ui.frame();
    }

    // Positive half: Smoothing enables the row; the Tab lands on it and the
    // typed value goes out as one interactive tool.attr on smoothStrength.
    setMode(pen, "smooth");
    assert(pen.paramEnabled("smoothStrength"), "8690 panel rig: Strength disabled in Smoothing");
    tabAndType("2");
    assert(sent.length >= 1 && sent[$ - 1].canFind("tool.attr")
           && sent[$ - 1].canFind("smoothStrength"),
           format("8690 panel: the enabled Strength row dispatched %s", sent));

    // Negative half: Move greys the row; the same gesture reaches nothing.
    setMode(pen, "move");
    const before = sent.length;
    tabAndType("3");
    assert(sent.length == before,
           format("8690 panel: the greyed Strength row in Move dispatched %s", sent[before .. $]));
}
