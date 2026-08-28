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
//
// WHAT THIS FILE WAS MISSING (task 2690), and it is NOT the failure the two
// extrude handle pins had. Measured on this stand, THE DRAG HERE IS REAL: it
// moves thirteen planes, grows the cube from 8 vertices to 10 and records one
// undo entry. The defect was the ASSERTION — `abs(inset) > 1e-3` and three bus
// counters that must read ZERO. An attribute rises on a gesture whose kernel
// touched nothing (that is exactly how the two sibling files in this family
// shipped green over an empty drag), and THREE ZEROES ARE THE THING AN EMPTY
// GESTURE PRODUCES BEST: a drag that rebuilt no preview makes no unbatched
// commit, records no op-log entry and leaks no frame. So a no-op regression in
// `rebuildPreview` would have left every assertion in this file green, and the
// counter block would have been actively misleading — it would have gone on
// reporting "the deferral holds" about frames that never ran.
//
// It now asserts the two things the acceptance criterion names — the tool
// built, and a plane actually moved — and the counter block's anti-vacuity is
// re-pointed at those instead of at `inset`.
//
// `built` IS NOT AVAILABLE ON THE WIRE HERE, and that is measured rather than
// assumed: `/api/tool/state` publishes it for exactly six tools tree-wide
// (edge_extend, edge_extrude, edge_bevel, poly_bevel, edge_slice, loop_slice —
// `grep -rn '"built"' source/`), and `mesh.vertexBevel` answers `{}` even
// though it carries the flag internally. A GROWN VERTEX COUNT stands in for it
// and is strictly stronger: `built = (n != 0)` is the tool's own claim about
// its kernel's return, and the count is that claim's consequence read off the
// mesh.

import std.algorithm : canFind, sort;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "mesh.vertexBevel";

string getRaw(string path) { return cast(string) get(BASE ~ path); }
JSONValue getJson(string path) { return parseJSON(getRaw(path)); }
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

// --- the acceptance witness -------------------------------------------------
//
// THE THREE CHANNELS BELOW FAIL CLOSED, and that is exactly what the counter
// block further down does NOT do. Each assertion here is "something MOVED", so
// a `/api/mesh/planes` serving a stale copy leaves `moved` empty and goes RED,
// and an `/api/history` that stopped tracking leaves the delta at 0 and goes
// RED. That is what lets them serve as the anti-vacuity for the three zeroes.

/// The PLANE-COMPLETE readback. `/api/model` is not a substitute: it carries no
/// marks, no set masks and no per-face material/part.
string planes() { return getRaw("/api/mesh/planes"); }
long undoLen() { return cast(long) getJson("/api/history")["undo"].array.length; }
size_t vertexCount() { return getJson("/api/model")["vertices"].array.length; }

string[] planeDiff(string aText, string bText) {
    auto a = parseJSON(aText);
    auto b = parseJSON(bText);
    bool[string] keys;
    foreach (k, _; a.objectNoRef) keys[k] = true;
    foreach (k, _; b.objectNoRef) keys[k] = true;
    string[] names;
    foreach (k, _; keys) if (k != "provenance") names ~= k;
    names.sort();
    string[] diff;
    foreach (k; names) {
        auto pa = k in a.objectNoRef;
        auto pb = k in b.objectNoRef;
        if (pa is null || pb is null) { diff ~= k; continue; }
        if (pa.toString() != pb.toString()) diff ~= k;
    }
    return diff;
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

    // The framing is PART OF THE GESTURE: the press point is derived from the
    // arm at the live camera, so the camera is pinned rather than inherited.
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(250));

    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t v0           = vertexCount();

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

    // THE CHECK THIS FILE DID NOT HAVE, and the anti-vacuity the three zeroes
    // below actually need: a drag that rebuilt no preview moves no counter, so
    // `0 == 0` is what an empty gesture produces best. `inset` alone could not
    // carry that weight — it rises whether or not the kernel emitted a vertex.
    immutable size_t v1 = vertexCount();
    assert(v1 > v0,
        "the drag added no vertex (still " ~ v0.to!string ~ ") while inset "
        ~ "reads " ~ after.to!string ~ ". `rebuildPreview` sets `built` from "
        ~ "its kernel's return, so a kernel that touched nothing leaves the "
        ~ "attribute exactly where this test used to stop looking — AND makes "
        ~ "every one of the three counter zeroes below true for free");
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
    Thread.sleep(dur!"msecs"(250));

    // …and a PLANE actually moved, with the drop recording it.
    auto moved = planeDiff(planesBefore, planes());
    assert(moved.canFind("vertices") && moved.canFind("counts"),
        "the gesture and its drop moved planes " ~ moved.to!string
        ~ " — `vertices` and `counts` are not both among them, so the mesh is "
        ~ "byte-identical to what it was before the drag");
    assert(undoLen() - u0 == 1,
        "the drop recorded " ~ (undoLen() - u0).to!string ~ " undo entr(ies), "
        ~ "expected exactly 1 — `deactivate()` commits only when the tool "
        ~ "built, so 0 here means the whole gesture was a no-op");
}
