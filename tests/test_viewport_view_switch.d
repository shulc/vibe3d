// Task 0214 — a per-cell view-preset switch (top/front/perspective/...) must
// be a pure camera-only mutation: it must NOT reset the current geometry
// selection and must NOT drop the active tool.
//
// Background: the per-cell view-selector combo drawn inside each `Viewport##k`
// window (source/app.d, "Per-cell view-selector dropdown") was found to leak
// its own click into scene picking while its dropdown popup was open, because
// the full-cell `##vpHit` hit-surface kept reporting itself hovered
// (`ImGuiHoveredFlags.AllowWhenBlockedByPopup`) even while the popup floated
// on top of it. That leak (fixed by removing the flag, source/app.d ~9483)
// is interactive-only — `--test` never builds the `Viewport##k` windows, so
// there is no popup and no click to leak in this harness. What IS reachable
// headlessly, and what this test locks down, is the *contract* the fix
// depends on: the view-preset mutation itself (`viewport.view <preset>` —
// the exact camera.viewPreset/projKind/dirty write the combo's onChange
// performs, source/app.d "viewport.view <preset>" branch, task 0171) is and
// must remain a pure camera-only side effect. This guards against a future
// change wiring a reset/re-seed into that path, which would defeat the
// gate fix's premise (that the *only* problem was the leaked click, not the
// view-change mutation itself).
//
// `viewport.view` is the pre-existing, unguarded, HTTP-reachable command
// (task 0171, already exercised by test_ortho_view.d / test_viewport_multi.d)
// that performs the identical field-level mutation as the per-cell combo's
// onChange — so it is used directly here instead of adding a redundant
// test-only wrapper command.

import std.net.curl;
import std.json;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}

void runCmd(string line) {
    auto j = postJson("/api/command", line);
    assert(j["status"].str == "ok" || j["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ j.toString);
}

// Read back a live tool attr via the forms-engine `?` query idiom
// (mirrors tests/test_tool_undo_coordination.d's attrQueryOk). ToolAttrCommand
// validates toolId against the active tool and throws on a mismatch
// (source/commands/tool/attr.d), so this doubles as an "is toolId still the
// active tool" probe — a real tool-drop would flip this to false.
bool attrQueryOk(string toolId, string name) {
    auto r = postJson("/api/command", "tool.attr " ~ toolId ~ " " ~ name ~ " ?");
    return r["status"].str == "ok";
}

unittest { // view-preset switch preserves selection, no active tool
    postJson("/api/reset", "{}");
    runCmd("prim.cube");

    auto selResp = postJson("/api/select", `{"mode":"vertices","indices":[0,2,5]}`);
    assert(selResp["status"].str == "ok", "select failed: " ~ selResp.toString);

    auto before = getJson("/api/selection");
    assert(before["selectedVertices"].array.length == 3,
        "expected 3 selected vertices before view switch: " ~ before.toString);

    foreach (preset; ["Top", "Front", "Right", "Perspective"]) {
        runCmd("viewport.view " ~ preset);
        auto after = getJson("/api/selection");
        assert(after == before,
            "selection changed after viewport.view " ~ preset ~
            ": before=" ~ before.toString ~ " after=" ~ after.toString);
    }
}

unittest { // view-preset switch preserves selection AND the active tool
    postJson("/api/reset", "{}");
    runCmd("prim.cube");

    auto selResp = postJson("/api/select", `{"mode":"vertices","indices":[1,3,6]}`);
    assert(selResp["status"].str == "ok", "select failed: " ~ selResp.toString);

    runCmd("tool.set move on");
    assert(attrQueryOk("move", "TX"),
        "move tool should be active right after tool.set move on");

    auto before = getJson("/api/selection");
    assert(before["selectedVertices"].array.length == 3,
        "expected 3 selected vertices before view switch: " ~ before.toString);

    foreach (preset; ["Top", "Front", "Perspective"]) {
        runCmd("viewport.view " ~ preset);

        assert(attrQueryOk("move", "TX"),
            "active tool 'move' dropped after viewport.view " ~ preset);

        auto after = getJson("/api/selection");
        assert(after == before,
            "selection changed after viewport.view " ~ preset ~
            " (tool active): before=" ~ before.toString ~
            " after=" ~ after.toString);
    }
}

unittest { // view-preset switch preserves an EMPTY selection + active tool
    // (the whole-mesh / no-selection mode of a transform tool)
    postJson("/api/reset", "{}");
    runCmd("prim.cube");

    auto selResp = postJson("/api/select", `{"mode":"vertices","indices":[]}`);
    assert(selResp["status"].str == "ok", "select failed: " ~ selResp.toString);

    runCmd("tool.set move on");
    assert(attrQueryOk("move", "TX"),
        "move tool should be active right after tool.set move on");

    runCmd("viewport.view Top");
    assert(attrQueryOk("move", "TX"),
        "active tool 'move' dropped after viewport.view Top (empty selection)");

    auto after = getJson("/api/selection");
    assert(after["selectedVertices"].array.length == 0,
        "empty selection should stay empty after viewport.view: " ~ after.toString);
}
