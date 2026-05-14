// Action-Center widget test (Stage B5 of doc/test_coverage_plan.md).
//
// The Action-Center button in the status bar opens a popup whose items
// each dispatch a single `actr.<mode>` command (see config/statusline.yaml
// "Action Center" entry). Driving the actual ImGui button + popup click
// from event-log is brittle — ImGui assigns pixel positions at runtime
// from label widths, popup item heights, etc. — so this test exercises
// the COMMAND each popup item invokes, which is what the click ultimately
// runs.
//
// What this pins:
//   • all nine actr.<mode> presets are registered and resolve through
//     the dispatcher
//   • each preset flips BOTH the ACEN mode and the AXIS mode atomically
//     (the preset's purpose vs the granular `tool.pipe.attr <stage> mode`
//     form)
//   • the mode names round-trip through getAttrs

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

JSONValue getJson(string path) {
    return parseJSON(cast(string)get("http://localhost:8080" ~ path));
}

JSONValue postScript(string script) {
    auto r = parseJSON(cast(string)post("http://localhost:8080/api/script", script));
    assert(r["status"].str == "ok",
        "/api/script reported error: " ~ r.toString);
    return r;
}

string stageAttr(string taskCode, string key) {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == taskCode) return st["attrs"][key].str;
    }
    assert(false, "stage " ~ taskCode ~ " not found");
}

unittest { // every actr.<mode> preset flips ACEN + AXIS together
    // Each row: preset name → (expected ACEN mode, expected AXIS mode).
    // Mirrors the (preset, acen, axis) tuples in source/app.d:760.
    struct Case { string preset; string acen; string axis; }
    immutable Case[] cases = [
        Case("auto",       "auto",       "auto"),
        Case("select",     "select",     "select"),
        Case("selectauto", "selectauto", "selectauto"),
        Case("element",    "element",    "element"),
        Case("local",      "local",      "local"),
        Case("origin",     "origin",     "world"),    // axis at origin → world
        Case("screen",     "screen",     "screen"),
        Case("border",     "border",     "select"),
        Case("none",       "none",       "none"),
    ];

    // Reset once so every case starts from a clean toolpipe (each
    // preset is independent; the loop just walks them in order).
    post("http://localhost:8080/api/reset", "");

    foreach (c; cases) {
        postScript("actr." ~ c.preset);
        string acen = stageAttr("ACEN", "mode");
        string axis = stageAttr("AXIS", "mode");
        assert(acen == c.acen,
            "actr." ~ c.preset ~ " left ACEN.mode=" ~ acen ~
            "; expected " ~ c.acen);
        assert(axis == c.axis,
            "actr." ~ c.preset ~ " left AXIS.mode=" ~ axis ~
            "; expected " ~ c.axis);
    }
}

unittest { // explicit sanity: switching back through actr.auto leaves state correct
    post("http://localhost:8080/api/reset", "");
    // Walk to a non-default mode then back — confirms the preset overwrites
    // prior state and isn't sticky on either stage.
    postScript("actr.local");
    assert(stageAttr("ACEN", "mode") == "local",
        "actr.local should set ACEN=local");
    postScript("actr.auto");
    assert(stageAttr("ACEN", "mode") == "auto",
        "actr.auto after actr.local should land ACEN=auto, got " ~
        stageAttr("ACEN", "mode"));
    assert(stageAttr("AXIS", "mode") == "auto",
        "actr.auto after actr.local should land AXIS=auto, got " ~
        stageAttr("AXIS", "mode"));
}
