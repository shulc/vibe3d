// Interactive drag coverage for the Vertex Bevel tool's handle drag.
//
// tests/test_vertex_bevel_tool.d drives this tool entirely through `tool.attr`
// + `tool.doApply`; nothing in the suite had ever entered its MOTION path. That
// path runs a per-event pixel increment which now takes its previous pixel from
// the cooked gesture and cross-checks it against the tool's own, so it needs a
// test that reaches it.
//
// Two details make this one different from the extrude pins:
//
//   * There is no off-handle fallback branch — a press that misses the arrow is
//     simply not consumed and no drag begins. So `inset` moving away from zero
//     is by itself proof that the press hit the handle and the increment ran.
//   * The press hit-test reads `queryMouse()`, not the event's own pixel, and
//     the override behind `queryMouse` is only updated on MOTION events. A drag
//     log that opens with the button-down would hit-test against a stale
//     cursor, so a hover motion is played first and given a frame to land.

import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "mesh.vertexBevel";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double queryInset() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " inset ?");
    assert(r["status"].str == "ok", "query inset failed: " ~ r.toString);
    return r["value"].floating;
}

// VIEWPORT + a single hover motion, so the cursor override the press
// hit-test reads is pointing at the handle before the button goes down.
string buildHoverLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
        ~ "\n" ~
        `{"t":30.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
        ~ "\n",
        vpX, vpY, vpW, vpH, x, y);
}

unittest { // dragging the inset arrow moves `inset` off zero
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    // v6 = (0.5,0.5,0.5): its three adjacent faces average to the (1,1,1)
    // diagonal, which is the inset axis the arrow is drawn along.
    r = postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(200));

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 anchor = Vec3(0.5f, 0.5f, 0.5f);
    enum float T = 0.57735027f;
    Vec3 axis   = Vec3(T, T, T);
    float arm   = gizmoSize(anchor, vp);
    Vec3 press  = anchor + axis * (arm * 0.6f);

    float ax, ay, tx, ty, px, py;
    assert(projectToWindow(anchor, vp, ax, ay), "anchor projects behind camera");
    assert(projectToWindow(anchor + axis, vp, tx, ty),
        "anchor + axis projects behind camera");
    assert(projectToWindow(press, vp, px, py), "shaft mid-point is off-camera");
    double dx = tx - ax, dy = ty - ay;
    double len = (dx * dx + dy * dy) ^^ 0.5;
    assert(len > 1e-6, "the inset axis projects to a point");

    int x0 = cast(int) px, y0 = cast(int) py;
    playAndWait(buildHoverLog(cam.vpX, cam.vpY, cam.width, cam.height, x0, y0), BASE);
    Thread.sleep(dur!"msecs"(150));

    int x1 = cast(int)(px + dx / len * 80.0);
    int y1 = cast(int)(py + dy / len * 80.0);

    // Task 1903 Stage E4 — the DRAG-FRAME half of the seam, read around the
    // playback. Every motion event re-runs the whole chamfer through
    // `rebuildPreview`, so this is the only cell in the suite that exercises
    // the tool's per-frame batch (`tests/test_vertex_bevel_tool.d` reaches
    // `applyHeadless` only). NAME THE CALLER KIND before quoting a bus counter
    // (E2 memo m6): a tool's drag frames are NOT inside the commands' global
    // delivery batch, which is exactly why the counters below can say
    // something here.
    auto cBefore = parseJSON(cast(string) get(BASE ~ "/api/changes"));

    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 16), BASE);
    Thread.sleep(dur!"msecs"(120));

    double after = queryInset();
    assert(abs(after) > 1e-3,
        "dragging the inset arrow should have moved inset off zero — this "
        ~ "tool consumes nothing when the press misses the handle, so a zero "
        ~ "here means the drag never began. Got " ~ after.to!string);

    // …and the anti-vacuity for the counters is that same assertion: a drag
    // that never began rebuilds no preview and moves no counter, so the three
    // zeroes below only mean something after it has passed.
    auto cAfter = parseJSON(cast(string) get(BASE ~ "/api/changes"));
    immutable long unbatched = cAfter["unbatchedGeometryCommits"].integer
                             - cBefore["unbatchedGeometryCommits"].integer;
    assert(unbatched == 0,
        "the vertex-bevel drag made " ~ unbatched.to!string ~ " UNBATCHED "
        ~ "geometry commit(s) across 16 preview frames. Task 1903 Stage E4 gave "
        ~ "`rebuildPreview` an UNRECORDED MeshEditBatch per frame, so each "
        ~ "frame's internal commits defer and stamp once at close(). Measured "
        ~ "with the deferral disabled: +112 across this drag, i.e. seven per "
        ~ "frame — the per-frame figure is what makes this cell different in "
        ~ "kind from the headless one (plan §3.2 L2, §9).");
    immutable long opLog = cAfter["opLogEntriesRecorded"].integer
                         - cBefore["opLogEntriesRecorded"].integer;
    assert(opLog == 0,
        "the vertex-bevel drag recorded " ~ opLog.to!string ~ " op-log entr(ies) "
        ~ "across its preview frames. Plan §9 is explicit that the interactive "
        ~ "preview path must stay UNRECORDED: a recording batch opened per drag "
        ~ "frame builds and throws away a full op-log at 60 Hz. Switching "
        ~ "`rebuildPreview`'s constructor from `MeshEditBatch.unrecorded` to "
        ~ "`MeshEditBatch` is the mutation this reddens under "
        ~ "(task 1903 Stage E4).");
    assert(cAfter["batchLeaks"].integer - cBefore["batchLeaks"].integer == 0,
        "a MeshEditBatch leaked its frame during the vertex-bevel drag. On a "
        ~ "per-frame batch a leak is not a one-off: the module-level frame is "
        ~ "never popped, so every later commit on this mesh defers forever and "
        ~ "the app silently stops publishing (plan §2.2c).");

    cmd("tool.set " ~ TOOL ~ " off");
}
