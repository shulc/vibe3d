// Interactive drag coverage for the Smooth Shift tool's handle drag.
//
// tests/test_smooth_shift.d drives this tool entirely through `tool.attr`
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
// WHAT THIS FILE WAS MISSING (task 2900). The drive here is REAL — measured on
// this stand, the drag takes the cube from 8 vertices / 6 faces to 12 / 10 and
// the drop pushes one undo entry. The defect was the ASSERTION:
// `abs(shift) > 1e-3` and nothing else. `shift` is a gizmo ATTRIBUTE the motion
// handler moves whether or not `smoothShiftFacesByMask` ever produced a face,
// so a SmoothShiftTool whose kernel touched nothing — no geometry, no record —
// left this file green. It is the FOURTH file found in this exact shape
// (`poly.extrude`, `mesh.vertexBevel` and `mesh.mirrorTool` were the others).
//
// `built` IS NOT ON THE WIRE HERE, measured rather than assumed: it is
// published for exactly six tools tree-wide (poly_bevel, edge_bevel,
// edge_extend, edge_extrude, edge_slice, loop_slice — `grep -rn '"built"'
// source/`) and `/api/tool/state` answers `{}` for `mesh.smoothShiftTool`. A
// GROWN VERTEX AND FACE COUNT stands in and is strictly stronger: `built` is
// the tool's own claim about its kernel's return, and the counts are that claim
// read off the mesh. Both planes are named because a smooth shift that inserted
// vertices without producing the side walls is a different failure from one
// that did nothing at all.
//
// EVERY CHANNEL BELOW FAILS CLOSED, so no positive control is needed: each new
// assertion is "something MOVED", and a stale `/api/mesh/planes`, a frozen
// `/api/model` or an `/api/history` that stopped tracking each leave their
// assertion RED rather than green.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.algorithm : canFind, sort;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import plane_diff_helpers;
import drag_helpers;

void main() {}

alias BASE = testBaseUrl;
enum string TOOL = "mesh.smoothShiftTool";

string getRaw(string path) { return cast(string) get(BASE ~ path); }


/// The PLANE-COMPLETE readback. `/api/model` is not a substitute: it carries no
/// marks, no set masks and no per-face material/part.
string planes() { return getRaw("/api/mesh/planes"); }
long undoLen() { return cast(long) getJson("/api/history")["undo"].array.length; }
size_t vertexCount() { return getJson("/api/model")["vertices"].array.length; }
size_t faceCount() { return getJson("/api/model")["faces"].array.length; }

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double queryShift() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " shift ?");
    assert(r["status"].str == "ok", "query shift failed: " ~ r.toString);
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

unittest { // dragging the offset arrow moves `shift` off zero
    // NO PRE-DISARM, DELIBERATELY (task 3130). `/api/reset` cancels and DROPS the
    // active tool BEFORE it replaces the geometry, so a gesture left standing by
    // an earlier stand — or by an earlier RED run of this one — cannot commit
    // into the scene this stand is about to read. The explicit
    // `tool.set <tool> off` that used to stand here (task 2900) was a workaround
    // for the opposite order. Removing it is not tidying: it makes this stand a
    // WITNESS for that guarantee instead of a file that hides its loss.
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    // Face 4 is the cube's +Y face: centroid (0,0.5,0), normal +Y — so the
    // offset arrow is drawn straight up the world Y axis.
    r = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(200));

    // Read the four channels BEFORE the gesture rather than assuming them.
    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t v0           = vertexCount();
    immutable size_t f0           = faceCount();

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 anchor = Vec3(0.0f, 0.5f, 0.0f);
    Vec3 axis   = Vec3(0.0f, 1.0f, 0.0f);
    float arm   = gizmoSize(anchor, vp);
    Vec3 press  = anchor + axis * (arm * 0.6f);

    float ax, ay, tx, ty, px, py;
    assert(projectToWindow(anchor, vp, ax, ay), "anchor projects behind camera");
    assert(projectToWindow(anchor + axis, vp, tx, ty),
        "anchor + axis projects behind camera");
    assert(projectToWindow(press, vp, px, py), "shaft mid-point is off-camera");
    double dx = tx - ax, dy = ty - ay;
    double len = (dx * dx + dy * dy) ^^ 0.5;
    assert(len > 1e-6, "the offset axis projects to a point");

    int x0 = cast(int) px, y0 = cast(int) py;
    playAndWait(buildHoverLog(cam.vpX, cam.vpY, cam.width, cam.height, x0, y0), BASE);
    Thread.sleep(dur!"msecs"(150));

    int x1 = cast(int)(px + dx / len * 80.0);
    int y1 = cast(int)(py + dy / len * 80.0);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 16), BASE);
    Thread.sleep(dur!"msecs"(120));

    double after = queryShift();
    assert(abs(after) > 1e-3,
        "dragging the offset arrow should have moved shift off zero — this "
        ~ "tool consumes nothing when the press misses the handle, so a zero "
        ~ "here means the drag never began. Got " ~ after.to!string);

    // THE CHECKS THIS FILE DID NOT HAVE, half one: the kernel emitted geometry.
    // This stands in for `built`, which this tool does not publish. Read while
    // the tool is still armed — the shift previews on the DOCUMENT mesh.
    immutable size_t v1 = vertexCount();
    immutable size_t f1 = faceCount();
    assert(v1 > v0 && f1 > f0,
        "the drag left " ~ v1.to!string ~ " vertices / " ~ f1.to!string
        ~ " faces (started at " ~ v0.to!string ~ " / " ~ f0.to!string
        ~ ", measured 12 / 10 on this stand) while shift reads "
        ~ after.to!string ~ ". `rebuildPreview` sets `built` from its kernel's "
        ~ "return and the commit runs only when built, so no growth means the "
        ~ "smooth shift produced neither the shifted face nor its side walls — "
        ~ "and the `shift` attribute above reads exactly the same in that "
        ~ "state, which is where this test used to stop looking");

    cmd("tool.set " ~ TOOL ~ " off");
    Thread.sleep(dur!"msecs"(300));

    // ...half two: a PLANE actually moved, and the drop recorded it.
    auto moved = planeDiff(planesBefore, planes());
    assert(moved.canFind("vertices") && moved.canFind("counts"),
        "the gesture and its drop moved planes " ~ moved.to!string
        ~ " — `vertices` and `counts` are not both among them, so the mesh is "
        ~ "byte-identical to what it was before the drag. A tool attribute can "
        ~ "hold any value over that");
    immutable long undoDelta = undoLen() - u0;
    assert(undoDelta == 1,
        "the gesture recorded " ~ undoDelta.to!string ~ " undo entr(ies), "
        ~ "expected exactly 1 — 0 means the whole drag was a no-op that left "
        ~ "nothing undoable behind it");
}
