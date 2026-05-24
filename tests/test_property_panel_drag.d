// Property-panel slider-drag behaviour test
// (Stage E3 of doc/test_coverage_plan.md).
//
// Driving the actual ImGui slider via synthesized SDL events would
// require pixel-perfect knowledge of the slider's runtime position
// (it drifts with the panel's docked width, font metrics, and the
// active tool's widget order). That's an ImGui-render-pipeline test,
// not a behaviour test.
//
// What the property panel slider achieves at the *behaviour* level —
// many intermediate parameter applications coalesce into ONE history
// entry — is the same beginEdit / commitEdit batching that MoveTool's
// gizmo drag uses (Phase 7.5h in source/tools/move.d). Testing the
// drag's history coalescing pins exactly the same code path; the
// pixel-level slider mechanics are out of scope until ImGui pixel
// positions become a stable test surface.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

long undoCount() {
    auto j = getJson("/api/history");
    return j["undo"].array.length;
}

string topUndoCommand() {
    auto undo = getJson("/api/history")["undo"].array;
    return undo.length == 0 ? "" : undo[$ - 1]["command"].str;
}

// Drain the undo stack so subsequent count-delta assertions aren't
// affected by command_history's 50-entry cap (which pins length=50 once
// reached, making `before == after` even for genuine new entries when
// a long suite has filled the buffer).
void drainHistory() {
    foreach (_; 0 .. 100) {
        if (undoCount() == 0) return;
        postJson("/api/undo", "");
    }
}

unittest { // a 20-step move-tool drag produces ONE undo entry
    // Setup mirrors test_tool_move_drag.d so the pin is on the same
    // code path: select v6, activate Move, drag X-arrow.
    postJson("/api/reset", "");
    drainHistory();   // start from a known-empty undo stack
    auto sel = postJson("/api/select",
        `{"mode":"vertices","indices":[6]}`);
    assert(sel["status"].str == "ok", "select failed");
    auto setResp = postJson("/api/script", "tool.set move");
    assert(setResp["status"].str == "ok", "tool.set move failed");

    long stackBefore = undoCount();

    // Compute the X-arrow pixel positions and drive a 20-step drag.
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 pivot = Vec3(0.5f, 0.5f, 0.5f);
    float size = gizmoSize(pivot, vp);
    Vec3 arrowStart = Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z);
    Vec3 arrowEnd   = Vec3(pivot.x + size,         pivot.y, pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowStart, vp, sx1, sy1), "off-camera");
    assert(projectToWindow(arrowEnd,   vp, sx2, sy2), "off-camera");
    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double sdx = cast(double)(sx2 - sx1);
    double sdy = cast(double)(sy2 - sy1);
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    int x1 = x0 + cast(int)(100.0 * sdx / sLen);
    int y1 = y0 + cast(int)(100.0 * sdy / sLen);

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    // Tool deactivate closes any open edit (Phase 7.5h) — that's when
    // the drag's begin/commit pair lands on the undo stack. Without
    // tool.set off the edit stays open and undoCount looks unchanged.
    postJson("/api/script", "tool.set move off");

    long stackAfter = undoCount();
    assert(stackAfter == stackBefore + 1,
        "a single move-tool drag should produce exactly 1 history " ~
        "entry; before=" ~ stackBefore.to!string ~
        " after=" ~ stackAfter.to!string);

    // Sanity: undo of that one entry restores v6 to its pre-drag position.
    auto post6Pre = vertexPos(6);
    assert(fabs(post6Pre[0] - 0.5) > 0.05,
        "setup: v6.x must have moved away from 0.5 before testing undo");

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);

    auto post6Post = vertexPos(6);
    assert(fabs(post6Post[0] - 0.5) < 1e-4 &&
           fabs(post6Post[1] - 0.5) < 1e-4 &&
           fabs(post6Post[2] - 0.5) < 1e-4,
        "undo of the move-tool drag should restore v6 to (0.5,0.5,0.5); " ~
        "got (" ~ post6Post[0].to!string ~ "," ~
                  post6Post[1].to!string ~ "," ~
                  post6Post[2].to!string ~ ")");
}

unittest { // 2 separate move-tool drags in one tool session = 1 entry
    // Phase 7.5h: as long as the tool stays active, both drags + any
    // intermediate falloff / slider tweaks coalesce into a single
    // history entry at tool.deactivate (or selection change) time.
    postJson("/api/reset", "");
    drainHistory();   // command_history caps the undo stack at 50; drain
                      // so this test's count-delta assertion holds even
                      // when an earlier test has filled the buffer
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    postJson("/api/script", "tool.set move");
    long stackBefore = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 pivot = Vec3(0.5f, 0.5f, 0.5f);
    float size = gizmoSize(pivot, vp);
    Vec3 arrowEnd = Vec3(pivot.x + size, pivot.y, pivot.z);
    Vec3 arrowStart = Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z);
    float sx1, sy1, sx2, sy2;
    projectToWindow(arrowStart, vp, sx1, sy1);
    projectToWindow(arrowEnd,   vp, sx2, sy2);
    int xa = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int ya = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double sdx = sx2 - sx1, sdy = sy2 - sy1;
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    int xb = xa + cast(int)(60.0 * sdx / sLen);
    int yb = ya + cast(int)(60.0 * sdy / sLen);

    // Two consecutive drags with no tool deactivation in between.
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xa, ya, xb, yb, 10));
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xb, yb, xa, ya, 10));
    // Deactivate to close the edit.
    postJson("/api/script", "tool.set move off");

    long stackAfter = undoCount();
    assert(stackAfter == stackBefore + 1,
        "2 drags in one tool session should coalesce to 1 history " ~
        "entry; got " ~ (stackAfter - stackBefore).to!string ~
        " entries instead");
}
