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

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

alias baseUrl = testBaseUrl;


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

unittest { // scene.reset {"empty":true} → an EMPTY scene, not the default cube
    // TASK 4062 — the semantic-merge cell, and it exists because the failure it
    // pins is a SILENT WRONG ANSWER. `scene.reset`'s `empty` flag used to reach
    // the command through a hand-written arm in the HTTP dispatcher; delete
    // that arm and the same request still answers `status:ok` — and leaves the
    // default cube standing. Every `{"empty":true}` caller in this suite
    // (fixture_helpers, the ACEN rigs, the primitive tests) asserts only the
    // status, so not one of them can see it.
    //
    // ORDER: the argument-less reset sits ABOVE the empty one. An `empty` slot
    // that swallowed EVERY reset reddens there; one that never binds reddens
    // below. One run buys both halves.
    post(baseUrl ~ "/api/command", commandBody("scene.reset"));
    assert(modelVertexCount() == 8,
        "an argument-less reset is still the default cube; got "
        ~ modelVertexCount().to!string);

    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/command",
        commandBody("scene.reset", `{"empty":true}`)));
    assert(r["status"].str == "ok", "reset(empty) failed: " ~ r.toString);
    assert(modelVertexCount() == 0,
        "an EXPLICIT empty reset must empty the scene; got "
        ~ modelVertexCount().to!string
        ~ " verts. 8 is the default cube — i.e. the argument was swallowed and "
        ~ "the request reported ok anyway");

    // …and the OTHER two slots still arrive, so "empty wins" is not the whole
    // of what this command reads.
    post(baseUrl ~ "/api/command",
         commandBody("scene.reset", `{"type":"grid","n":6}`));
    assert(modelVertexCount() == 49,
        "a 6-square grid is 7x7 = 49 vertices; got "
        ~ modelVertexCount().to!string
        ~ ". `type` and `n` are the two remaining declared slots, and `n` is "
        ~ "the one the `levels` alias also names");
}

unittest { // file.new on a cube → empty mesh
    post(baseUrl ~ "/api/command", commandBody("scene.reset"));
    assert(modelVertexCount() == 8, "setup: default cube should have 8 verts");

    runCmd("file.new");
    assert(modelVertexCount() == 0,
        "file.new should empty the scene; got " ~
        modelVertexCount().to!string ~ " verts");
}

unittest { // file.new is undoable (SceneReset captures pre-empty mesh)
    post(baseUrl ~ "/api/command", commandBody("scene.reset"));
    assert(modelVertexCount() == 8);

    runCmd("file.new");
    assert(modelVertexCount() == 0);

    // Undo should restore the 8-vert cube.
    auto undoResp = parseJSON(cast(string)post(baseUrl ~ "/api/command", commandBody("history.undo")));
    assert(undoResp["status"].str == "ok",
        "/api/undo after file.new failed: " ~ undoResp.toString);
    assert(modelVertexCount() == 8,
        "undo of file.new should restore 8 verts; got " ~
        modelVertexCount().to!string);
}

unittest { // history.show: command dispatch succeeds (UI toggle isn't queryable)
    post(baseUrl ~ "/api/command", commandBody("scene.reset"));
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
    post(baseUrl ~ "/api/command", commandBody("scene.reset"));
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

    post(baseUrl ~ "/api/command", commandBody("scene.reset"));
}
