import camera_lens_control_helpers;
// Interactive drag coverage for the Polygon Extrude tool's ON-HANDLE drag.
//
// The suite already drove this tool's OFF-handle view-plane haul, but never
// the handle itself — and the
// handle is the branch that runs the per-event increment. That increment now
// takes its previous pixel from the cooked gesture and cross-checks it against
// the tool's own, so it needs a test that actually enters it.
//
// Telling the two branches apart is the whole design of this test. A press that
// MISSES the arrow silently becomes a free haul. This case therefore presses
// the published handle and verifies the normal-distance path through mesh and
// history, not merely an attribute change.
//
// The original cell reconstructs the press point from the same projected
// geometry; the session-law cells below read `/api/tool/handles` directly so
// every successive operation grabs the newly posed production handle.
//
// WHAT THIS FILE WAS MISSING (task 2690), and it is NOT the failure the two
// extrude handle pins had. Measured on this stand, THE DRAG HERE IS REAL: it
// moves twelve planes, grows the cube from 8 vertices to 12 and records one
// undo entry. The defect was the ASSERTION — `distance > 1e-3` and nothing
// else. `distance` is a tool attribute, and an attribute rises on a gesture
// whose kernel touched nothing; that is exactly how the two sibling files in
// this family shipped green over an empty drag. So a no-op regression in
// `PolyExtrudeTool.rebuildPreview` — the kernel returning 0, `built` staying
// false, `deactivate()` committing nothing — would have left this file green.
// It now asserts the two things the acceptance criterion names: the tool
// built, and a plane actually moved.
//
// `built` IS NOT AVAILABLE ON THE WIRE HERE, and that is measured rather than
// assumed: `/api/tool/state` publishes it for exactly six tools tree-wide
// (edge_extend, edge_extrude, edge_bevel, poly_bevel, edge_slice, loop_slice —
// `grep -rn '"built"' source/`), and `poly.extrude` answers `{}` even though it
// carries the flag internally. A GROWN VERTEX COUNT stands in for it and is
// strictly stronger: `built = (n != 0)` is the tool's own claim about its
// kernel's return, and the count is that claim's consequence read off the mesh.

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
enum string TOOL = "poly.extrude";
enum string W2_FIXTURE = import("fixtures/poly_extrude_w2_topology.json");

string getRaw(string path) { return cast(string) get(BASE ~ path); }


// --- the acceptance witness -------------------------------------------------
//
// EVERY CHANNEL BELOW FAILS CLOSED, which is why this file needs no separate
// positive control: each assertion is "something MOVED", so a `/api/mesh/planes`
// serving a stale copy leaves `moved` empty and goes RED, and an `/api/history`
// that stopped tracking leaves the delta at 0 and goes RED. (The frozen fixtures
// in tests/test_tool_gesture_g*.d assert "EQUAL" and "EMPTY", which a dead
// channel satisfies for free — that is why THEY open with a control.)

/// The PLANE-COMPLETE readback. `/api/model` is not a substitute: it carries no
/// marks, no set masks and no per-face material/part.
string planes() { return getRaw("/api/mesh/planes"); }
long undoLen() { return cast(long) getJson("/api/history")["undo"].array.length; }
size_t vertexCount() { return getJson("/api/model")["vertices"].array.length; }

JSONValue w2Fixture() { return parseJSON(W2_FIXTURE); }

int[] intList(JSONValue values) {
    int[] result;
    foreach (value; values.array) result ~= cast(int)value.integer;
    return result;
}

int[][] intRings(JSONValue rows) {
    int[][] result;
    foreach (row; rows.array) result ~= intList(row);
    return result;
}

int[][] endpointPairs(JSONValue rows) {
    auto result = intRings(rows);
    foreach (ref pair; result)
        if (pair.length == 2 && pair[0] > pair[1]) {
            const tmp = pair[0]; pair[0] = pair[1]; pair[1] = tmp;
        }
    return result;
}

double[][] positions(JSONValue rows) {
    double[][] result;
    foreach (row; rows.array) {
        double[] point;
        foreach (value; row.array) point ~= value.floating;
        result ~= point;
    }
    return result;
}

bool positionsMatch(const double[][] got, const double[][] want) {
    if (got.length != want.length) return false;
    foreach (i; 0 .. got.length) {
        if (got[i].length != want[i].length) return false;
        foreach (j; 0 .. got[i].length)
            if (abs(got[i][j] - want[i][j]) > 1e-6) return false;
    }
    return true;
}

void expectW2Mesh(string checkpoint, bool comparePositions) {
    auto want = w2Fixture()["checkpoints"][checkpoint];
    auto got = getJson("/api/model");
    auto sel = getJson("/api/selection");

    // Population floors make the exact comparisons below non-vacuous.
    assert(got["vertices"].array.length > 8 && got["faces"].array.length > 4
        && got["edges"].array.length > 11,
        checkpoint ~ ": W2 exact mesh channels are unexpectedly empty");
    if (comparePositions) {
        const gotPositions = positions(got["vertices"]),
              wantPositions = positions(want["positions"]);
        assert(positionsMatch(gotPositions, wantPositions),
            checkpoint ~ ": full positions differ from accepted raw");
    }
    const gotFaces = intRings(got["faces"]), wantFaces = intRings(want["faces"]);
    assert(gotFaces == wantFaces, format(
        "%s: ordered face rings differ from accepted raw: got %s, want %s",
        checkpoint, gotFaces, wantFaces));
    const gotEdges = endpointPairs(got["edges"]),
          wantEdges = endpointPairs(want["edges"]);
    assert(gotEdges == wantEdges, format(
        "%s: ordered edges differ from accepted raw: got %s, want %s",
        checkpoint, gotEdges, wantEdges));
    assert(intList(sel["selectedVertices"]) ==
               intList(want["selected"]["vertices"]),
        checkpoint ~ ": selected vertices differ from accepted raw");
    assert(intList(sel["selectedEdges"]) == intList(want["selected"]["edges"]),
        checkpoint ~ ": selected edges differ from accepted raw");
    assert(intList(sel["selectedFaces"]) ==
               intList(want["selected"]["polygons"]),
        checkpoint ~ ": selected polygons differ from accepted raw");
}

void expectW2Positions(string checkpoint) {
    auto got = getJson("/api/model");
    auto want = w2Fixture()["checkpoints"][checkpoint];
    assert(got["vertices"].array.length > 8,
        checkpoint ~ ": W2 position population is unexpectedly empty");
    assert(positionsMatch(positions(got["vertices"]), positions(want["positions"])),
        checkpoint ~ ": full positions differ from accepted raw");
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double queryDistance() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " distance ?");
    assert(r["status"].str == "ok", "query distance failed: " ~ r.toString);
    return r["value"].floating;
}

double queryShiftX() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " shiftX ?");
    assert(r["status"].str == "ok", "query shiftX failed: " ~ r.toString);
    return r["value"].floating;
}

double queryShiftY() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " shiftY ?");
    assert(r["status"].str == "ok", "query shiftY failed: " ~ r.toString);
    return r["value"].floating;
}

void navigate(bool undo) {
    const mod = undo ? 64 : 65;
    playAndWaitLensControl(format(
        `{"t":50,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":%s,"repeat":0}` ~ "\n"
      ~ `{"t":60,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":%s,"repeat":0}` ~ "\n",
        mod, mod), BASE);
}

void handlePx(out int x, out int y) {
    auto h = getJson("/api/tool/handles")["handles"];
    assert(h.type != JSONType.null_, "poly.extrude publishes no handle arbiter");
    foreach (p; h["parts"].array) {
        if (cast(int)p["part"].integer != 0) continue;
        assert(p["screen"].type != JSONType.null_, "Polygon extrude handle is off-camera");
        x = cast(int)p["screen"].array[0].floating;
        y = cast(int)p["screen"].array[1].floating;
        return;
    }
    assert(false, "Polygon extrude handle part 0 is absent");
}

void settle() {
    import core.thread : Thread;
    import core.time : dur;
    Thread.sleep(dur!"msecs"(180));
}

void setupPoly() {
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok");
    cmd("workplane.reset");
    auto rig = w2Fixture()["rig"];
    r = postJson("/api/command", commandBody("scene.loadMesh",
        `{"vertices":` ~ rig["vertices"].toString ~
        `,"faces":` ~ rig["faces"].toString ~ `}`));
    assert(r["status"].str == "ok", "W2 Polygon open rig failed to load");
    cmd("history.clear");
    r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"polygons","indices":[0]}`));
    assert(r["status"].str == "ok");
    // The HTTP camera fixes fovY at 45 degrees. This distance is the exact
    // equivalent focus-plane scale for the captured 0.0031848573644 units/px
    // in its 1144x966 viewport; module coverage also pins the original eye
    // and projection separately.
    r = postJson("/api/camera",
        `{"azimuth":-2.530727415391778,"elevation":0.43633231299858255,`
        ~ `"distance":4.64218897796836,"roll":0,"width":1144,"height":966,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok");
    r = postJson("/api/command?origin=ui", "tool.set " ~ TOOL ~ " on");
    assert(r["status"].str == "ok" || r["status"].str == "success");
    settle();
}

void dragHandle(int dx, int steps = 12, int mod = 0, int button = 1) {
    int x, y; handlePx(x, y);
    auto cam = fetchCamera(BASE);
    playAndWaitLensControl(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y, x + dx, y, steps, mod, cast(ubyte)button), BASE);
    settle();
}

void freePx(out int x, out int y) {
    auto cam = fetchCamera(BASE);
    x = cam.vpX + 896;
    y = cam.vpY + 246;
}

void dragFree(int dx, int dy, int steps = 12, int mod = 0, int button = 1,
        int pressX = 896, int pressY = 246) {
    auto cam = fetchCamera(BASE);
    const int x = cam.vpX + pressX, y = cam.vpY + pressY;
    playAndWaitLensControl(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y, x + dx, y + dy, steps, mod, cast(ubyte)button), BASE);
    settle();
}

void tapHandle(int button, int mod = 0) {
    dragHandle(0, 1, mod, button);
}

unittest {
    foreach(controlLens;[defaultLensControl,explicitLensControl]) { // a purely horizontal drag on the arrow moves `distance`
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    // Face 3 is the cube's +X face: centroid (0.5,0,0), averaged normal +X.
    r = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[3]}`));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    // The framing is PART OF THE GESTURE: the press point is derived from the
    // arm at the live camera, so the camera is pinned rather than inherited.
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    // Settle so a draw() frame has built the gizmo frame the press hit-tests
    // against. The shaft runs from anchor + axis*(arm/6) to anchor + axis*arm
    // with arm = gizmoSize(anchor, vp) — the same 90 px target the running
    // gizmo uses — so 0.6*arm lands mid-shaft.
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(200));

    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t v0           = vertexCount();

    applyLensControl(controlLens,BASE);
    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 anchor = Vec3(0.5f, 0.0f, 0.0f);
    Vec3 axis   = Vec3(1.0f, 0.0f, 0.0f);
    float arm   = gizmoSize(anchor, vp);
    Vec3 press  = anchor + axis * (arm * 0.6f);

    float ax, ay, tx, ty, px, py;
    assert(projectToWindow(anchor, vp, ax, ay), "anchor projects behind camera");
    assert(projectToWindow(anchor + axis, vp, tx, ty),
        "anchor + X projects behind camera");
    assert(projectToWindow(press, vp, px, py), "shaft mid-point is off-camera");
    double sdx = tx - ax;
    assert(abs(sdx) > 20.0,
        "the extrude axis must project with a real horizontal component for "
        ~ "this test to separate the two branches, got " ~ sdx.to!string);

    // Purely horizontal, in whichever direction grows the projection.
    int x0 = cast(int) px, y0 = cast(int) py;
    int x1 = x0 + (sdx > 0 ? 80 : -80);
    playAndWaitLensControl(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y0, 16), BASE);
    Thread.sleep(dur!"msecs"(120));

    double after = queryDistance();
    assert(after > 1e-3,
        "a horizontal drag on the extrude arrow should have driven distance "
        ~ "positive — a press that missed the arrow would have fallen into "
        ~ "the free branch, which reads only vertical travel and would have "
        ~ "left it at 0. Got " ~ after.to!string);

    // THE CHECK THIS FILE DID NOT HAVE, half one: the kernel emitted geometry.
    // This stands in for `built`, which this tool does not put on the wire.
    immutable size_t v1 = vertexCount();
    assert(v1 > v0,
        "the drag added no vertex (still " ~ v0.to!string ~ ") while distance "
        ~ "reads " ~ after.to!string ~ ". `rebuildPreview` sets `built` from "
        ~ "its kernel's return and `deactivate()` commits only when built, so "
        ~ "a kernel that touched nothing leaves the attribute exactly where "
        ~ "this test used to stop looking");

    cmd("tool.set " ~ TOOL ~ " off");
    Thread.sleep(dur!"msecs"(250));

    // ...and half two: a PLANE actually moved, and the drop recorded it.
    auto moved = planeDiff(planesBefore, planes());
    assert(moved.canFind("vertices") && moved.canFind("counts"),
        "the gesture and its drop moved planes " ~ moved.to!string
        ~ " — `vertices` and `counts` are not both among them, so the mesh is "
        ~ "byte-identical to what it was before the drag. A tool attribute can "
        ~ "hold any value over that");
    assert(undoLen() - u0 == 1,
        "the drop recorded " ~ (undoLen() - u0).to!string ~ " undo entr(ies), "
        ~ "expected exactly 1 — `deactivate()` commits only when the tool "
        ~ "built, so 0 here means the whole gesture was a no-op");

    }
    applyLensControl(defaultLensControl);
}

unittest { // Polygon first group is one activation+topology navigation step.
    setupPoly();
    const initial = planes();
    const u0 = undoLen();
    dragFree(40, -30);
    const first = planes();
    assert(vertexCount() == 12 && first != initial && undoLen() == u0 + 1,
        "Polygon g1 did not create its 12v history row");

    navigate(true);
    assert(vertexCount() == 8 && planes() == initial && undoLen() == u0 - 1,
        "one Polygon Undo must remove g1 and its activation");
    navigate(false);
    assert(vertexCount() == 12 && planes() != initial && undoLen() == u0 + 1
        && abs(queryDistance()) < 1e-6 && abs(queryShiftX()) < 1e-6
        && abs(queryShiftY()) < 1e-6,
        "one Polygon Redo must restore 12v with default attributes");
    const replayed = planes();

    dragHandle(60);
    const second = planes();
    assert(vertexCount() == 16 && second != replayed && undoLen() == u0 + 2,
        "selected-face drag after Polygon first-group redo did not create 16v");
    navigate(true);
    assert(vertexCount() == 12 && planes() == replayed,
        "Polygon continuation undo did not restore the 12v replay image");
    navigate(false);
    assert(vertexCount() == 16 && planes() == second,
        "Polygon continuation redo did not restore the 16v image");
}

unittest { // Main ladder: g1, Middle clone and Shift reset are distinct rows.
    setupPoly();
    const u0 = undoLen();
    dragFree(40, -30);
    const g1 = planes();
    assert(vertexCount() == 12 && undoLen() == u0 + 1,
        "Polygon main g1 missing");
    expectW2Mesh("main_g1", false);
    tapHandle(2);
    const middle = planes();
    assert(vertexCount() == 16 && middle != g1 && undoLen() == u0 + 2,
        "Polygon Middle did not append a 16v operation row");
    expectW2Mesh("main_middle", false);
    dragFree(35, -25, 12, 3, 1, 896, 386);
    const shifted = planes();
    assert(vertexCount() == 20 && shifted != middle && undoLen() == u0 + 3,
        "Polygon Shift did not append a reset 20v operation row");
    expectW2Mesh("main_shift", false);

    cmd("tool.set move on");
    assert(undoLen() == u0 + 4, "switch added a cumulative Polygon carrier");
    navigate(true);
    assert(planes() == shifted && undoLen() == u0 + 3,
        "outside z1 did not remove Move alone");
    navigate(true);
    assert(planes() == middle && vertexCount() == 16,
        "outside z2 did not remove Shift alone");
    navigate(true);
    assert(planes() == g1 && vertexCount() == 12,
        "outside z3 did not remove Middle alone");
    navigate(true);
    assert(vertexCount() == 8 && undoLen() == u0 - 1,
        "outside z4 did not remove Polygon g1 with its activation");
}

unittest { // Zero tap and zero Middle create 12v then 16v at zero attrs.
    setupPoly();
    const initial = planes();
    const u0 = undoLen();
    tapHandle(1);
    const zero = planes();
    assert(abs(queryDistance()) < 1e-6 && abs(queryShiftX()) < 1e-6
        && abs(queryShiftY()) < 1e-6 && vertexCount() == 12
        && zero != initial && undoLen() == u0 + 1,
        "zero Polygon tap did not create its coincident 12v topology row");
    expectW2Mesh("zero", true);
    tapHandle(2);
    const middle = planes();
    assert(abs(queryDistance()) < 1e-6 && abs(queryShiftX()) < 1e-6
        && abs(queryShiftY()) < 1e-6 && vertexCount() == 16
        && middle != zero && undoLen() == u0 + 2,
        "zero Polygon Middle did not create its coincident 16v row");
    expectW2Mesh("middle", true);
    navigate(true);
    assert(planes() == zero && vertexCount() == 12,
        "zero Middle undo did not restore 12v");
    navigate(false);
    assert(planes() == middle && vertexCount() == 16,
        "zero Middle redo did not restore 16v");
}

unittest { // Plain second drag stays on one topology and replaces redo branch.
    setupPoly();
    const u0 = undoLen();
    dragFree(40, -30);
    const first = planes();
    dragHandle(35);
    const oldSecond = planes();
    assert(vertexCount() == 12 && oldSecond != first && undoLen() == u0 + 2,
        "plain Polygon second drag did not append a position row");
    navigate(true);
    assert(planes() == first && undoLen() == u0 + 1,
        "plain second-drag undo did not restore g1");
    dragHandle(-55);
    const branch = planes();
    assert(vertexCount() == 12 && branch != first && branch != oldSecond
        && undoLen() == u0 + 2,
        "new Polygon drag after Undo did not replace the redo branch");
    navigate(true);
    assert(planes() == first, "replacement branch undo did not restore g1");
    navigate(false);
    assert(planes() == branch, "replacement branch redo restored the old branch");
}

unittest { // Interactive parameter is a row; recording command adds only itself.
    setupPoly();
    const u0 = undoLen();
    dragFree(40, -30);
    const first = planes();
    auto p = postJson("/api/script?interactive=true",
        "tool.attr poly.extrude shiftX 0.2\n");
    assert(p["status"].str == "ok" || p["status"].str == "success");
    const param = planes();
    assert(param != first && vertexCount() == 12 && undoLen() == u0 + 2,
        "interactive Polygon shift did not append its preview row");
    navigate(true);
    assert(planes() == first, "interactive shift undo lost g1");
    navigate(false);
    assert(planes() == param && abs(queryShiftX() - 0.2) < 1e-5,
        "interactive shift redo lost its exact mesh/attr image");

    tapHandle(2);
    const middle = planes();
    assert(vertexCount() == 16 && undoLen() == u0 + 3,
        "recording-command fixture lacks the Middle row");
    auto r = postJson("/api/command?origin=ui", "mesh.flip");
    assert(r["status"].str == "ok" || r["status"].str == "success");
    assert(undoLen() == u0 + 4,
        "recording command close added a cumulative Polygon row");
    navigate(true);
    assert(planes() == middle && undoLen() == u0 + 3,
        "recording-command z1 did not remove the command alone");
    navigate(true);
    assert(planes() == param && undoLen() == u0 + 2,
        "recording-command z2 did not remove Middle alone");
}

unittest { // Param image -> closed redo -> fresh dormant attr-only adjustment.
    setupPoly();
    const u0 = undoLen();
    dragFree(40, -30);
    const g1 = planes();
    auto p = postJson("/api/script?interactive=true",
        "tool.attr poly.extrude shiftX 0.2\n");
    assert(p["status"].str == "ok" || p["status"].str == "success");
    const param = planes();
    assert(param != g1 && abs(queryShiftX() - 0.2) < 1e-5
        && abs(queryShiftY() - 0.07) < 1e-5
        && undoLen() == u0 + 2,
        "param-fresh rig did not record its exact parameter image and attrs");
    expectW2Mesh("main_g1", false);

    auto close = postJson("/api/command?origin=ui", "tool.set move on");
    assert(close["status"].str == "ok" || close["status"].str == "success");
    assert(planes() == param && undoLen() == u0 + 3,
        "param-fresh close changed the parameter basis or added a carrier");
    navigate(true);
    const zPlanes = planes();
    const zDepth = undoLen();
    const zShiftX = queryShiftX(), zShiftY = queryShiftY();
    assert(zPlanes == param && zDepth == u0 + 2
        && abs(zShiftX - 0.2) < 1e-5 && abs(zShiftY - 0.07) < 1e-5,
        format("param-fresh closed Undo lost mesh=%s, shift=(%s,%s) or depth=%s/%s",
            zPlanes == param, zShiftX, zShiftY, zDepth, u0 + 2));
    navigate(false);
    assert(planes() == param && undoLen() == u0 + 3,
        "param-fresh r1 lost the parameter image or Move row");

    auto r = postJson("/api/command?origin=ui", "tool.set " ~ TOOL ~ " on");
    assert(r["status"].str == "ok" || r["status"].str == "success");
    const fresh = undoLen();
    auto st = getJson("/api/tool/state");
    const freshShiftX = queryShiftX(), freshShiftY = queryShiftY();
    assert(planes() == param && abs(freshShiftX - 0.2) < 1e-5
        && abs(freshShiftY - 0.07) < 1e-5
        && st["session"]["dormant"].type == JSONType.true_
        && st["session"]["live"].type == JSONType.false_, format(
        "param-fresh arm did not retain attrs/basis: mesh=%s shift=(%s,%s) dormant=%s live=%s",
        planes() == param, freshShiftX, freshShiftY,
        st["session"]["dormant"].toString, st["session"]["live"].toString));

    int x, y; freePx(x, y);
    auto cam = fetchCamera(BASE);
    playAndWaitLensControl(buildDragDownLog(cam.vpX, cam.vpY, cam.width, cam.height, x, y), BASE);
    playAndWaitLensControl(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y, x + 37, y - 34, 12), BASE);
    st = getJson("/api/tool/state");
    const dragShiftX = queryShiftX(), dragShiftY = queryShiftY();
    assert(planes() == param && abs(dragShiftX + 0.100) < 1e-5
        && abs(dragShiftY - 0.080) < 1e-5
        && undoLen() == fresh && st["session"]["live"].type == JSONType.false_,
        format("param-fresh dormant drag lost basis/attrs: mesh=%s shift=(%s,%s)",
            planes() == param, dragShiftX, dragShiftY));
    playAndWaitLensControl(buildDragUpLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x + 37, y - 34), BASE);
    auto h = getJson("/api/history");
    assert(planes() == param && undoLen() == fresh + 1
        && h["undo"].array[$ - 1]["command"].str == "tool.topology_adjustment",
        "param-fresh dormant drop did not append exactly its attr history row");

    navigate(true);
    assert(planes() == param && undoLen() == fresh - 1,
        "param-fresh dormant Undo changed the frozen basis or row pairing");
    // Expectation (task 9080, S6; the door law, CAP `dormant2_inset_ui/s13_R`,
    // `inset_dormant_ui/s11_R`): the redo of the UI arm brings its attribute-only row back
    // in the same step (was: the bare activation, the row left in redo). Law 4, generic
    // (task 9020 item A; not a Poly Extrude capture): the re-created instance takes its
    // drop seed — the shift it held with its own adjustment undone, never the drag's.
    // Task 9270 (S6r, model §R12 M-init): the dormant press ACTIVATED the instance, so the
    // adjustment's before-image is the activation reset (shifts 0), not the arm's
    // (0.2, 0.07) — CAP `vmerge_dormant_ui/s11_R` (the seed is the reset image, 0.001).
    navigate(false);
    st = getJson("/api/tool/state");
    h = getJson("/api/history");
    assert(planes() == param && undoLen() == fresh + 1
        && abs(queryShiftX()) < 1e-6 && abs(queryShiftY()) < 1e-6
        && st["session"]["dormant"].type == JSONType.true_
        && h["redo"].array.length == 0
        && h["undo"].array[$ - 1]["command"].str == "tool.topology_adjustment",
        format("param-fresh dormant Redo lost the seed (shift %s,%s; the reset 0,0, not the arm's %s,%s), basis, "
            ~ "or did not bring its adjustment back with the arm (undo %s, redo %s)",
            queryShiftX(), queryShiftY(), freshShiftX, freshShiftY, undoLen(),
            h["redo"].array.length));
}

unittest { // Polygon -> Edge undo/redo never gives a fresh Edge Polygon attrs.
    setupPoly();
    dragFree(40, -30);
    const polygonImage = planes();
    const polygonDepth = undoLen();
    const polygonShiftX = queryShiftX();
    const polygonShiftY = queryShiftY();
    assert(abs(polygonShiftX) > 1e-5 || abs(polygonShiftY) > 1e-5,
        "mixed topology-tool rig did not produce a non-default Polygon attr image");

    auto edge = postJson("/api/command?origin=ui", "tool.set edge.extrude on");
    assert(edge["status"].str == "ok" || edge["status"].str == "success",
        "mixed topology-tool rig could not activate Edge Extrude");
    // The UI arm writes the activation and Edge Extrude's begin row, one undo step
    // (task 9210, S5b; model §1.1, CAP ebevel_row_ui s06_Z).
    assert(undoLen() == polygonDepth + 2,
        "Edge activation and its begin row did not stand as one UI step above Polygon");

    navigate(true);
    assert(planes() == polygonImage && undoLen() == polygonDepth,
        "undoing Edge activation changed Polygon's history-owned mesh image");
    assert(abs(queryShiftX() - polygonShiftX) < 1e-6
        && abs(queryShiftY() - polygonShiftY) < 1e-6,
        "undoing Edge activation did not restore Polygon's session-owned attrs");

    navigate(false);
    assert(planes() == polygonImage && undoLen() == polygonDepth + 2,
        "redoing Edge activation changed Polygon's history-owned mesh image");
    edge = postJson("/api/command?origin=ui", "tool.set edge.extrude on");
    assert(edge["status"].str == "ok" || edge["status"].str == "success",
        "fresh Edge arm after its closed redo did not return through /api/command");
    auto st = getJson("/api/tool/state");
    assert(st["session"]["dormant"].type == JSONType.false_,
        "fresh Edge arm inherited Polygon's closed-redo dormant ownership");
}

unittest { // Unwinding a closed redo makes the next Polygon arm topology-live.
    setupPoly();
    const initial = planes();
    const u0 = undoLen();
    dragFree(40, -30);
    assert(vertexCount() == 12 && undoLen() == u0 + 1,
        "closed-redo unwind rig did not create Polygon topology");

    auto edge = postJson("/api/command?origin=ui", "tool.set edge.extrude on");
    assert(edge["status"].str == "ok" || edge["status"].str == "success",
        "closed-redo unwind rig could not arm Edge Extrude");
    navigate(true);    // Edge activation -> Polygon.
    navigate(false);   // Edge activation redo marks its closed Polygon predecessor.
    navigate(true);    // Unwind the Edge row that sourced that marker.
    navigate(true);    // Unwind Polygon topology + activation.
    assert(planes() == initial && vertexCount() == 8 && undoLen() == u0 - 1,
        "closed-redo unwind rig did not restore the base Polygon mesh");

    auto polygon = postJson("/api/command?origin=ui", "tool.set " ~ TOOL ~ " on");
    assert(polygon["status"].str == "ok" || polygon["status"].str == "success",
        "fresh Polygon arm after closed-redo unwind was refused");
    const fresh = undoLen();
    dragFree(40, -30);
    auto st = getJson("/api/tool/state");
    assert(vertexCount() == 12 && planes() != initial && undoLen() == fresh + 1
        && st["session"]["dormant"].type == JSONType.false_,
        "fresh Polygon drag after source-row unwind stayed dormant and created no topology");
}

unittest { // Prepared switch closes a held drag once, without a cumulative row.
    setupPoly();
    const initial = planes();
    const u0 = undoLen();
    int x, y; handlePx(x, y);
    auto cam = fetchCamera(BASE);
    playAndWaitLensControl(buildDragDownLog(cam.vpX, cam.vpY, cam.width, cam.height, x, y), BASE);
    playAndWaitLensControl(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y, x + 80, y, 12), BASE);
    const preview = planes();
    assert(preview != initial && vertexCount() == 12,
        "held Polygon drag did not build a preview");
    cmd("tool.set move on");
    assert(planes() == preview && undoLen() == u0 + 2,
        "prepared switch lost the pending Polygon image or duplicated a row");
    playAndWaitLensControl(buildDragUpLog(cam.vpX, cam.vpY, cam.width, cam.height, x + 80, y), BASE);
    navigate(true);
    navigate(true);
    assert(planes() == initial && vertexCount() == 8 && undoLen() == u0 - 1,
        "prepared close row did not round-trip with its activation");
}

unittest { // Full closed redo makes a fresh Polygon arm dormant and attr-only.
    setupPoly();
    const u0 = undoLen();
    dragHandle(80);
    const first = planes();
    cmd("tool.set move on");
    navigate(true);   // Move activation
    navigate(true);   // Polygon first row + activation
    navigate(false);
    navigate(false);
    assert(planes() == first && vertexCount() == 12 && undoLen() == u0 + 2,
        "full closed redo did not restore Polygon image and Move row");
    auto r = postJson("/api/command?origin=ui", "tool.set " ~ TOOL ~ " on");
    assert(r["status"].str == "ok" || r["status"].str == "success");
    const freshImage = planes();
    const fresh = undoLen();
    const armDist = queryDistance(), armShiftX = queryShiftX(), armShiftY = queryShiftY();
    int x, y; handlePx(x, y);
    auto cam = fetchCamera(BASE);
    playAndWaitLensControl(buildDragDownLog(cam.vpX, cam.vpY, cam.width, cam.height, x, y), BASE);
    playAndWaitLensControl(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y, x + 60, y, 12), BASE);
    auto st = getJson("/api/tool/state");
    assert(planes() == freshImage && undoLen() == fresh
        && st["session"]["live"].type == JSONType.false_,
        "dormant Polygon held drag armed or previewed topology");
    playAndWaitLensControl(buildDragUpLog(cam.vpX, cam.vpY, cam.width, cam.height, x + 60, y), BASE);
    auto h = getJson("/api/history");
    assert(planes() == freshImage && undoLen() == fresh + 1
        && h["undo"].array[$ - 1]["command"].str == "tool.topology_adjustment",
        "dormant Polygon drag must append one attr-only row with exact mesh/selection");
    navigate(true);
    assert(planes() == freshImage && undoLen() == fresh - 1,
        "dormant Polygon z1 did not remove adjustment and activation");
    // Expectation (task 9080, S6; the door law, CAP `dormant2_inset_ui/s13_R`): the UI
    // activation's redo brings its adjustment back in the same step (was: bare). Law 4,
    // generic (task 9020 item A; not a Poly Extrude capture): the re-created instance takes
    // its drop seed — its own adjustment undone. Task 9270 (S6r, model §R12 M-init): the
    // dormant press activated the instance, so that before-image is the activation reset
    // (distance and shifts 0), not the arm's sticky values — CAP `vmerge_dormant_ui/s11_R`
    // (the seed is the reset image, 0.001).
    navigate(false);
    st = getJson("/api/tool/state");
    assert(planes() == freshImage && undoLen() == fresh + 1
        && st["session"]["dormant"].type == JSONType.true_
        && abs(queryDistance()) < 1e-6 && abs(queryShiftX()) < 1e-6
        && abs(queryShiftY()) < 1e-6,
        format("dormant Polygon r1 did not restore the activation, its adjustment and its seed: distance %s "
            ~ "shift (%s,%s), the reset 0 (0,0) — the arm's %s (%s,%s)", queryDistance(), queryShiftX(),
            queryShiftY(), armDist, armShiftX, armShiftY));
}
