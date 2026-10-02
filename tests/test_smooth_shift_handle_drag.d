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
// release pushes one undo entry. The defect was the ASSERTION:
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

double queryShift(string tool) {
    auto r = postJson("/api/command", "tool.attr " ~ tool ~ " shift ?");
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

// Rows the cell leaves above the arm: the three hauls (the field write was
// undone). Measured 3 on this stand, task 8290.
enum long UNDO_DELTA = 3;

void key(int mod) {
    import core.thread : Thread;
    import core.time   : dur;
    playAndWait(format(
        `{"t":0.000,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":%d,"repeat":0}`, mod), BASE);
    Thread.sleep(dur!"msecs"(150));
}

void uiCmd(string line) {
    auto r = postJson("/api/command?origin=ui", line);
    assert(r["status"].str == "ok", "UI-door '" ~ line ~ "' failed: " ~ r.toString);
}

/// An interactive (panel-origin) value write, one discrete step.
void field(string tool, double v) {
    auto r = postJson("/api/script?interactive=true",
        "tool.attr " ~ tool ~ " shift " ~ format("%.9g", v));
    assert(r["status"].str == "ok", "field write failed: " ~ r.toString);
}

/// Haul the offset arrow 80 px up from wherever it is drawn now.
void haul(CameraState cam) {
    import core.thread : Thread;
    import core.time   : dur;
    double sx, sy;
    bool found;
    fetchHandlePart(0, sx, sy, found, BASE);
    assert(found, "Smooth Shift/Thicken lost its offset handle");
    const x = cast(int) sx, y = cast(int) sy;
    playAndWait(buildHoverLog(cam.vpX, cam.vpY, cam.width, cam.height, x, y), BASE);
    Thread.sleep(dur!"msecs"(150));
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x, y, x, y - 80, 16), BASE);
    Thread.sleep(dur!"msecs"(120));
}

void dragCell(string tool, bool thicken) { // both IDs share SmoothShiftTool
    // NO PRE-DISARM, DELIBERATELY (task 3130). `/api/reset` cancels and DROPS the
    // active tool BEFORE it replaces the geometry, so a gesture left standing by
    // an earlier stand — or by an earlier RED run of this one — cannot commit
    // into the scene this stand is about to read. The explicit
    // `tool.set <tool> off` that used to stand here (task 2900) was a workaround
    // for the opposite order. Removing it is not tidying: it makes this stand a
    // WITNESS for that guarantee instead of a file that hides its loss.
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    // Face 4 is the cube's +Y face: centroid (0,0.5,0), normal +Y — so the
    // offset arrow is drawn straight up the world Y axis.
    r = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    uiCmd("tool.set " ~ tool ~ " on");

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

    double after = queryShift(tool);
    assert(abs(after) > 1e-3,
        "dragging the offset arrow should have moved shift off zero — this "
        ~ "tool consumes nothing when the press misses the handle, so a zero "
        ~ "here means the drag never began. Tool " ~ tool ~ ", got " ~ after.to!string);
    // Task 8290: the haul is the SUM of its per-step increments. 80 px along an
    // axis that projects to `len` px per unit is ~80/len units; the old
    // `base + last increment` form gave one step's worth (1/16 of that).
    immutable double expected = 80.0 / len;
    assert(abs(after - expected) < 0.25 * expected,
        "an 80 px haul must move shift by ~" ~ expected.to!string
        ~ " (80 px at " ~ len.to!string ~ " px/unit); got " ~ after.to!string
        ~ " for " ~ tool);

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

    // Task 8290 (captured, private fixture smooth_shift_panel_edit.json): the
    // arm is the UI door, so the first haul's record carries the activation —
    // its Ctrl+Z disarms, and the redo RE-ARMS on the completed mesh (cell F).
    key(64);
    assert(vertexCount() == v0 && faceCount() == f0,
        "Smooth Shift first undo must restore the pre-gesture topology");
    key(65);
    assert(vertexCount() == v1 && faceCount() == f1,
        "Smooth Shift redo must restore the completed topology");
    // KNOWN DIVERGENCE, OURS (not the reference's value): both ids restore the recorded
    // Shift here, while the reference's redo of the re-arming UI pair reads the arm's
    // attributes (law 4; fixture `thicken_direct_ui/s06_R.attrs` ref [s01], ours [s02, s04];
    // `smooth_direct_ui/s06_R.attrs` the same). Topology-redo S4 flips this expectation for
    // BOTH ids; Thicken's former reset matched it only by its own special case (gone, 8950).
    assert(abs(queryShift(tool) - after) < 1e-6,
        "redo must restore the captured Shift amount for this exact ID");

    // After a re-arm the next haul starts from zero and STACKS one layer.
    haul(cam);
    const size_t v2 = vertexCount(), f2 = faceCount();
    const double secondShift = queryShift(tool);
    assert(v2 > v1 && f2 > f1,
        "the first haul after a re-arm must build from the completed topology");
    assert(abs(secondShift) > 1e-3 && abs(secondShift) < abs(after) * 1.5,
        "the first haul after a re-arm must start Shift from zero, got "
        ~ secondShift.to!string);
    immutable string layerTwo = planes();

    // Inside the live operation every later step re-evaluates THAT layer: a
    // haul continues from the current Shift (cell CTL) — right after the
    // re-arm haul, with no history step between them.
    haul(cam);
    const double thirdShift = queryShift(tool);
    assert(vertexCount() == v2 && faceCount() == f2,
        "a later haul in the same operation must re-evaluate its layer, not "
        ~ "stack another: " ~ vertexCount().to!string ~ " vertices, expected "
        ~ v2.to!string);
    assert(abs(thirdShift) > abs(secondShift) + 1e-3,
        "a later haul must continue from the current Shift " ~ secondShift.to!string
        ~ ", got " ~ thirdShift.to!string);
    key(64);
    assert(vertexCount() == v2 && abs(queryShift(tool) - secondShift) < 1e-6,
        "undo of the continuing haul restores the re-arm haul's layer and Shift");
    key(64);
    assert(vertexCount() == v1 && faceCount() == f1,
        "undo of second Smooth Shift/Thicken step restores the first step");
    assert(abs(queryShift(tool)) < 1e-6,
        "undo of second gesture restores its zero Shift start");
    key(65);
    key(65);
    assert(vertexCount() == v2 && faceCount() == f2
        && abs(queryShift(tool) - thirdShift) < 1e-6,
        "redo of both steps restores the continued layer and its Shift");
    // ... and a field write sets the ABSOLUTE value on the same layer (cell A).
    field(tool, secondShift);
    assert(vertexCount() == v2 && faceCount() == f2,
        "a field write after a haul must re-evaluate the layer, not stack one");
    assert(planeDiff(layerTwo, planes()).length == 0,
        "a field write of the layer's own earlier Shift must reproduce that "
        ~ "layer exactly — it moved planes " ~ planeDiff(layerTwo, planes()).to!string);
    key(64);
    assert(abs(queryShift(tool) - thirdShift) < 1e-6 && vertexCount() == v2,
        "undo of the field write must restore the haul's Shift on the same layer");

    cmd("tool.set " ~ tool ~ " off");
    Thread.sleep(dur!"msecs"(300));

    // ...half two: a PLANE actually moved, and release recorded it.
    auto moved = planeDiff(planesBefore, planes());
    assert(moved.canFind("vertices") && moved.canFind("counts"),
        "the gesture and its release moved planes " ~ moved.to!string
        ~ " — `vertices` and `counts` are not both among them, so the mesh is "
        ~ "byte-identical to what it was before the drag. A tool attribute can "
        ~ "hold any value over that");
    immutable long undoDelta = undoLen() - u0;
    assert(undoDelta == UNDO_DELTA,
        "the gestures recorded " ~ undoDelta.to!string ~ " undo entr(ies), "
        ~ "expected exactly " ~ UNDO_DELTA.to!string);
}

unittest {
    dragCell("mesh.smoothShiftTool", false);
    dragCell("mesh.thickenTool", true);
}

// Task 8290 cell B (captured): before the first haul engages the operation, a
// field write changes the attribute only — no geometry — and the engaging haul
// starts Offset from zero, discarding the typed value.
unittest {
    foreach (tool; ["mesh.smoothShiftTool", "mesh.thickenTool"]) {
        auto r = postJson("/api/command", commandBody("scene.reset"));
        assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
        r = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
        assert(r["status"].str == "ok", "select failed: " ~ r.toString);
        uiCmd("tool.set " ~ tool ~ " on");
        immutable string before = planes();
        field(tool, 5.0);
        assert(abs(queryShift(tool) - 5.0) < 1e-6, "the field write did not land on " ~ tool);
        assert(planeDiff(before, planes()).length == 0,
            "an unengaged field write must not build geometry; " ~ tool ~ " moved "
            ~ planeDiff(before, planes()).to!string);
        haul(fetchCamera(BASE));
        const s = queryShift(tool);
        assert(abs(s) > 1e-3 && abs(s) < 1.0,
            "the engaging haul must start Offset from zero, not the typed 5.0; "
            ~ tool ~ " got " ~ s.to!string);
        cmd("tool.set " ~ tool ~ " off");
    }
}

// Task 8290 cell F (captured): the redo that RE-ARMS the tool makes the redone
// mesh the operation's base, so the first field write after it stacks one
// layer at the typed value — no haul in between — and a later haul starts a new
// layer on top of it, its Offset from zero (C6-1 s07: restart, shift 0.009 on s02
// and on s07 alike; topology-redo S3, task 8950).
unittest {
    foreach (tool; ["mesh.smoothShiftTool", "mesh.thickenTool"]) {
        auto r = postJson("/api/command", commandBody("scene.reset"));
        assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
        cmd("history.clear");
        r = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
        assert(r["status"].str == "ok", "select failed: " ~ r.toString);
        uiCmd("tool.set " ~ tool ~ " on");
        auto cam = fetchCamera(BASE);
        const size_t v0 = vertexCount();
        haul(cam);
        const size_t v1 = vertexCount();
        key(64);
        key(65);
        assert(vertexCount() == v1, "F rig: the re-arm redo lost the first layer on " ~ tool);
        immutable string redone = planes();
        field(tool, 0.3);
        const size_t v2 = vertexCount();
        assert(v2 > v1,
            "the first field write after a re-arm must stack one layer; " ~ tool
            ~ " has " ~ v2.to!string ~ " vertices, the redone mesh " ~ v1.to!string);
        assert(planeDiff(redone, planes()).canFind("vertices"),
            "the stacked layer did not move any vertex on " ~ tool);
        haul(cam);
        const s = queryShift(tool);
        assert(vertexCount() == v2 + (v1 - v0),
            "a haul after the field write starts a new layer on top of it; " ~ tool
            ~ " has " ~ vertexCount().to!string ~ ", the field-write mesh " ~ v2.to!string
            ~ " and one layer " ~ (v1 - v0).to!string);
        assert(s < 0.3 - 1e-3,
            "the haul that starts the new layer starts its Offset from zero, not the typed 0.3; "
            ~ tool ~ " got " ~ s.to!string);
        cmd("tool.set " ~ tool ~ " off");
    }
}
