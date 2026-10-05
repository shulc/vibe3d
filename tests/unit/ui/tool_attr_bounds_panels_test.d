// The captured tool attribute bounds at the two panels (task 9492), driven
// through a headless ImGui frame: the property panel re-clamps a typed value
// its widget does not clamp (a one-sided row), and the forms panel ranges a
// tool row's drag over its row so the dispatched value stops at the max.
module tests.unit.ui.tool_attr_bounds_panels_test;

import ImGui = d_imgui;
import d_imgui.imgui_h : ImVec2;
import std.conv : to;
import std.json : parseJSON;

import command_history : CommandHistory;
import edit_session    : EditSession;
import forms           : Form, Row;
import forms_render    : FormsPanel;
import params          : Param;
import property_panel  : PropertyPanel;
import tool            : Tool;
import tests.unit.ui.headless_panel : openPanel;

private final class WidthTool : Tool {
    float width = 0.5f;
    override Param[] params() { return [Param.float_("width", "Width", &width, 0.5f)]; }
}

private final class SidesTool : Tool {
    int sides = 24;
    override Param[] params() { return [Param.int_("sides", "Sides", &sides, 24)]; }
}

/// The property panel's typed -5 into Edge Bevel's Width ([0, none]).
private float typedWidth(string toolId) {
    auto tool = new WidthTool();
    Tool active = tool;
    auto session = new EditSession(() => active, new CommandHistory(), () {});
    auto panel = new PropertyPanel();
    auto ui = openPanel(() { panel.draw(tool, session, toolId); });
    scope (exit) ui.close();
    ui.frame();
    ui.editRow(0, "-5");
    return tool.width;
}

unittest { // the panel re-clamp lands a one-sided row; no row, no clamp
    assert(typedWidth("edge.bevel") == 0.0f, "the panel left -5 below the row's min");
    assert(typedWidth("") == -5.0f, "control: with no row the typed value stands");
}

/// The value the forms panel dispatches after dragging Sphere's Sides far up.
private long draggedSides(string toolId) {
    auto tool = new SidesTool();
    Form form;
    form.showLabel = false;
    form.rows = [Row.makeControl("tool.attr prim.sphere sides ?", "Sides", "sides")];
    auto panel = new FormsPanel;
    long sent = -1;
    ImVec2 lo, hi;
    auto ui = openPanel(() {
        panel.draw(form, tool, null, (string id, string json) {
            sent = parseJSON(json)["_positional"].array[2].integer;
        }, toolId);
        lo = ImGui.GetItemRectMin();
        hi = ImGui.GetItemRectMax();
    });
    scope (exit) ui.close();
    ui.frame();
    assert(hi.x > lo.x, "the forms panel drew no Sides widget");
    const at = ImVec2((lo.x + hi.x) * 0.5f, (lo.y + hi.y) * 0.5f);
    ui.pressAt(at);
    foreach (i; 1 .. 5) ui.hoverAt(ImVec2(at.x + 10_000.0f * i, at.y));
    ui.release();
    return sent;
}

unittest { // the forms drag stops at the row's max; with no row it does not
    assert(draggedSides("prim.sphere") == 1024,
           "the forms drag passed the row's max: " ~ draggedSides("prim.sphere").to!string);
    assert(draggedSides("") > 1024, "control: with no row the drag runs past 1024");
}
