// file.new + history.show command tests (Stage C2 of
// doc/test_coverage_plan.md).
//
// file.quit is intentionally skipped — it terminates the vibe3d main
// loop, which would kill the test session and break every subsequent
// test in the same worker. Test_coverage_plan.md flags this as needing
// a `--test` mode exit-suppression flag before it can be safely
// exercised. Doing that retrofit on FileQuit is a separate change and
// not in scope here.
//
// What this DOES pin:
//   • file.new wipes the scene to empty (zero verts/faces) — undo
//     restores the prior mesh
//   • history.show is registered and can be dispatched without error
//     (the panel-visibility flag itself is UI-only and not queryable
//     over HTTP — testing toggling is best done with an end-to-end UI
//     screenshot test, out of scope for the HTTP runner)

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

void runCmd(string argstring) {
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
    assert(r["status"].str == "ok",
        "/api/command \"" ~ argstring ~ "\" failed: " ~ r.toString);
}

long modelVertexCount() {
    auto j = getJson("/api/model");
    return j["vertices"].array.length;
}

JSONValue cameraJson() { return getJson("/api/camera?viewport=0"); }

void setCamera(string body_) {
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/camera", body_));
    assert(r["status"].str == "ok", "POST /api/camera failed: " ~ r.toString);
}

unittest { // file.new on a cube → empty mesh
    post(baseUrl ~ "/api/reset", "");
    assert(modelVertexCount() == 8, "setup: default cube should have 8 verts");

    runCmd("file.new");
    assert(modelVertexCount() == 0,
        "file.new should empty the scene; got " ~
        modelVertexCount().to!string ~ " verts");
}

unittest { // file.new is undoable (SceneReset captures pre-empty mesh)
    post(baseUrl ~ "/api/reset", "");
    assert(modelVertexCount() == 8);

    runCmd("file.new");
    assert(modelVertexCount() == 0);

    // Undo should restore the 8-vert cube.
    auto undoResp = parseJSON(cast(string)post(baseUrl ~ "/api/undo", ""));
    assert(undoResp["status"].str == "ok",
        "/api/undo after file.new failed: " ~ undoResp.toString);
    assert(modelVertexCount() == 8,
        "undo of file.new should restore 8 verts; got " ~
        modelVertexCount().to!string);
}

unittest { // history.show: command dispatch succeeds (UI toggle isn't queryable)
    post(baseUrl ~ "/api/reset", "");
    runCmd("history.show");
    // Idempotency: a second call toggles back. Both should succeed.
    runCmd("history.show");
    // Sanity: vertex count is untouched (history.show is a pure UI toggle).
    assert(modelVertexCount() == 8,
        "history.show shouldn't mutate the mesh; got " ~
        modelVertexCount().to!string ~ " verts");
}

unittest { // file.new resets the camera pose (task 0182 / V3)
    // file.new dispatches through the generic commandHandlerDelegate — not
    // a dedicated app-layer site — so there is no per-fire-site hook to reset
    // the viewport from. The fix wires an onViewportReset delegate into the
    // SceneReset factory (mirroring onResetTool) so every dispatch path
    // (menu, shortcut, HTTP) resets the viewport uniformly. Without it, a
    // File -> New that leaves a stale camera would ship green (this test
    // previously only asserted mesh-empty, never camera pose).
    post(baseUrl ~ "/api/reset", "");
    auto defaultCam = cameraJson();

    // Orbit/zoom/pan the camera away from the default framing.
    setCamera(`{"azimuth":1.2,"elevation":0.3,"distance":9.0,` ~
              `"focus":{"x":2.0,"y":-1.0,"z":0.5}}`);
    auto movedCam = cameraJson();
    assert(movedCam["azimuth"].floating  != defaultCam["azimuth"].floating,
        "setup: camera should have moved away from default azimuth");

    runCmd("file.new");

    auto afterCam = cameraJson();
    assert(afterCam["azimuth"].floating   == defaultCam["azimuth"].floating,
        "file.new should reset azimuth to default; got " ~ afterCam.toString);
    assert(afterCam["elevation"].floating == defaultCam["elevation"].floating,
        "file.new should reset elevation to default; got " ~ afterCam.toString);
    assert(afterCam["distance"].floating  == defaultCam["distance"].floating,
        "file.new should reset distance to default; got " ~ afterCam.toString);
    assert(afterCam["focus"]["x"].floating == defaultCam["focus"]["x"].floating &&
           afterCam["focus"]["y"].floating == defaultCam["focus"]["y"].floating &&
           afterCam["focus"]["z"].floating == defaultCam["focus"]["z"].floating,
        "file.new should reset focus to default; got " ~ afterCam.toString);

    post(baseUrl ~ "/api/reset", "");
}
