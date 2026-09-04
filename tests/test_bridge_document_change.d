// A document change under a LIVE tool gesture — Bridge, Radial Sweep, Magnet
// (task 2880, backlog 2760).
//
// WHAT THIS PINS. `BridgeTool.deactivate()` used to commit on `engaged &&
// valid_` alone. Both are GESTURE state; neither says anything about the MESH.
// So a document change under a live gesture — File → New, a load, a scene
// reset, an active-layer switch, all ordinary paths — left the tool believing
// a gesture was armed over a mesh that no longer existed, and it fed indices
// frozen at `activate()` into a kernel that indexes them blind. Measured
// 2026-08-28, on the shared `--test` instance:
//
//     core.exception.ArrayIndexError@source/mesh_ops/bridge.d(204):
//     index [0] is out of bounds for array of length 0
//
// It survived this long for one reason: the tool had NO interactive test at
// all until `test_bridge_tool_drag.d` was written, and this was found on that
// day, by that file's own teardown.
//
// AND IT IS NOT ONE TOOL. A census of all 35 `deactivate()` overrides under
// `source/tools/**` found three that hand FROZEN document indices to a kernel
// that indexes them blind; all three were then reproduced live, each with a
// real gesture and a real reset:
//
//   mesh.bridgeTool       ArrayIndexError@source/mesh_ops/bridge.d(204)
//   mesh.radialSweepTool  ArrayIndexError@source/mesh_ops/revolve.d(374)
//   xfrm.magnet           ArrayIndexError@source/tools/deform/magnet.d(298)
//
// Magnet's window is narrower and had to be found by driving rather than by
// reading: its mouse-UP path clears `built`, so a completed haul is safe and
// the arm is a tool-drop MID-DRAG — which is exactly what a document change
// performs. A full haul + reset does NOT reproduce it; the cells below leave
// the button down on purpose, and release it afterwards so the shared
// `--test` instance does not hand the next test a stuck button.
//
// WHY THE CUBE CELLS COME FIRST, AND IT IS THE LOAD-BEARING ORDER IN THIS FILE.
// The two cells redden by DIFFERENT MEANS. Against a gesture-only guard the
// empty-reset cell kills the process, and the runner reuses one `vibe3d --test`
// per worker across a whole slice — a process death here is not a local red,
// it is every remaining test on that worker failing and reading as "the suite
// fell apart". The cube-reset cell reddens the same defect by a plain
// ASSERTION, with no crash: the frozen loops still index a fresh 8-vertex cube
// IN RANGE, so the stale gesture builds (measured under the mutation: 16
// vertices / 16 faces and a `Bridge` undo entry, where a plain cube is 8/6 and
// the history holds only the reset). druntime stops a module at its first
// failed assert, so with that cell FIRST a mutated run reddens on the
// assertion and never reaches the crashing one. Reordering these two turns a
// local red into a worker-wide one.
//
// THE ANTI-VACUITY CONTROL. Both cells assert that something did NOT happen —
// no `Bridge` entry, geometry untouched — and "nothing happened" is exactly
// what an empty gesture produces for free. So each cell reads
// `/api/tool/state` BEFORE the reset and requires `engaged && valid`: without
// that, a haul that never engaged would satisfy every assertion below on
// broken code. The read is taken BEFORE the reset and asserted AFTER it (the
// reset is itself the tool-drop), which is `test_bridge_tool_drag.d`'s
// read → drop → assert discipline and the same reason.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.algorithm : canFind, map;
import std.array : array;
import std.conv : to;
import std.json;
import std.net.curl : get, post;

import drag_helpers;
import std.format : format;

void main() {}

alias BASE = testBaseUrl;
enum string TOOL = "mesh.bridgeTool";

/// Two coaxial unit squares — the bridge operand, shared with
/// `test_bridge_tool_drag.d`.
enum string kTwoCaps = `{
    "vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0],[0,0,1],[1,0,1],[1,1,1],[0,1,1]],
    "faces":[[0,1,2,3],[4,5,6,7]]
}`;

string getRaw(string path) { return cast(string) get(BASE ~ path); }


void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

/// A haul that is deliberately left MID-DRAG: hover, press, move, and NO
/// mouse-up. `buildDragLog` always closes with one, and Magnet's mouse-up
/// clears `built`, so a closed haul cannot arm the window this file drives.
/// The leading hover + 180 ms gap gives the render loop its frames to run
/// `pickVertices()` before the button goes down (the same reason
/// `test_magnet_drag.d`'s own builder has it).
string buildOpenHaulLog(int vpX, int vpY, int vpW, int vpH,
                        int hx, int hy, int x1, int y1, int steps = 12) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
        ~ `"fovY":0.785398}` ~ "\n", vpX, vpY, vpW, vpH);
    log ~= format(
        `{"t":20.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,`
        ~ `"yrel":0,"state":0,"mod":0}` ~ "\n", hx, hy);
    log ~= format(
        `{"t":200.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,`
        ~ `"clicks":1,"mod":0}` ~ "\n", hx, hy);
    int lx = hx, ly = hy;
    foreach (i; 1 .. steps + 1) {
        int x = hx + (x1 - hx) * i / steps;
        int y = hy + (y1 - hy) * i / steps;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,`
            ~ `"yrel":%d,"state":1,"mod":0}` ~ "\n",
            200.0 + i * 50.0, x, y, x - lx, y - ly);
        lx = x; ly = y;
    }
    return log;
}

/// Release the button the open haul left down, so the next test on this
/// shared worker does not inherit it.
void releaseButton(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    playAndWait(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
        ~ `"fovY":0.785398}` ~ "\n"
        ~ `{"t":20.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,`
        ~ `"clicks":1,"mod":0}` ~ "\n", vpX, vpY, vpW, vpH, x, y), BASE);
}

string[] undoLabels() {
    string[] out_;
    foreach (e; getJson("/api/history")["undo"].array) out_ ~= e["label"].str;
    return out_;
}

/// Load the two caps, select them, activate Bridge and haul 60 px — the
/// gesture `test_bridge_tool_drag.d` proves builds a bridge on a drop. Returns
/// the tool's own engagement claim, read while the tool is still live.
JSONValue armBridgeHaul() {
    import core.thread : Thread;
    import core.time   : dur;

    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset(empty) failed: " ~ r.toString);
    r = postJson("/api/command", commandBody("scene.loadMesh", kTwoCaps));
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);
    // `/api/load-mesh` RESETS THE CAMERA — frame AFTER the load, never before.
    r = postJson("/api/camera",
        `{"azimuth":0.6,"elevation":0.5,"distance":5.0,`
        ~ `"focus":{"x":0.5,"y":0.5,"z":0.5}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    r = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0,1]}`));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("history.clear");
    cmd("tool.set " ~ TOOL ~ " on");
    Thread.sleep(dur!"msecs"(250));

    auto cam = fetchCamera(BASE);
    immutable int cx = cam.vpX + cam.width  / 2;
    immutable int cy = cam.vpY + cam.height / 2;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cx, cy, cx + 60, cy, 12), BASE);
    Thread.sleep(dur!"msecs"(120));

    return getJson("/api/tool/state");
}


/// Load the two caps and frame them. Every cell in this file arms over this
/// stand and never over a plain cube, and that is a MEASURED requirement, not
/// housekeeping: `SessionMeshKey`'s three terms are the address, the
/// `topologyVersion` and the two counts, and a reset from an untouched cube TO
/// a cube reproduces all three exactly — same surviving `Layer`, same
/// deterministic construction, same 8/6. A radial-sweep cell built that way
/// went green on the fix and red on nothing (measured: 100 vertices / 101
/// faces, i.e. the guard never fired), which is the residual documented on
/// `SessionMeshKey` showing up as a cell that cannot come out differently.
/// Two caps are 8 vertices / 2 FACES, so the count term separates them from
/// the cube the reset installs.
void loadCapsStand() {
    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset(empty) failed: " ~ r.toString);
    r = postJson("/api/command", commandBody("scene.loadMesh", kTwoCaps));
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);
    // `/api/load-mesh` RESETS THE CAMERA — frame AFTER the load, never before.
    r = postJson("/api/camera",
        `{"azimuth":0.6,"elevation":0.5,"distance":5.0,`
        ~ `"focus":{"x":0.5,"y":0.5,"z":0.5}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
}

/// Arm Radial Sweep on one cap and engage it with a panel attr write
/// (`onParamChanged` sets `engaged`, the same bit a haul sets).
void armRadialSweep() {
    import core.thread : Thread;
    import core.time   : dur;

    loadCapsStand();
    auto r = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0]}`));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);
    cmd("history.clear");
    cmd("tool.set mesh.radialSweepTool on");
    Thread.sleep(dur!"msecs"(300));
    cmd("tool.attr mesh.radialSweepTool count 6");
    Thread.sleep(dur!"msecs"(200));
}

/// Grab cap vertex 6 (1,1,1) and haul it 60 px, leaving the button DOWN.
/// Returns the grab pixel so the caller can release it. `moved` is the arm
/// witness: Magnet sets `built` only when `applyMagnet` actually displaced
/// something, so a vertex that did not move means this cell drives nothing.
void armOpenMagnetHaul(out int hx, out int hy, out int vpX, out int vpY,
                       out int vpW, out int vpH, out bool moved) {
    import core.thread : Thread;
    import core.time   : dur;
    import std.math    : abs;

    loadCapsStand();
    cmd("select.typeFrom vertex");
    cmd("history.clear");
    cmd("tool.set xfrm.magnet on");
    Thread.sleep(dur!"msecs"(300));

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    float sx, sy;
    immutable bool visible = projectToWindow(Vec3(1.0f, 1.0f, 1.0f), vp, sx, sy);
    assert(visible, "cap vertex 6 (1,1,1) must be visible from this camera");
    vpX = cam.vpX; vpY = cam.vpY; vpW = cam.width; vpH = cam.height;
    hx = cast(int) sx; hy = cast(int) sy;

    playAndWait(buildOpenHaulLog(vpX, vpY, vpW, vpH, hx, hy, hx + 60, hy, 12),
                BASE);
    Thread.sleep(dur!"msecs"(150));

    auto v6 = getJson("/api/model")["vertices"].array[6].array;
    moved = abs(v6[0].floating - 1.0) > 1e-3;
}

string vacuousMsg(string what) {
    return "the gesture never armed, so this cell asserts that nothing "
        ~ "happened over a tool that was doing nothing — it would be green on "
        ~ "broken code. " ~ what;
}

// ===========================================================================
// THE CUBE CELLS — every one of these reddens by ASSERTION, never by a crash,
// and they ALL come before the empty cells for that reason.
// ===========================================================================

unittest { // Bridge: a reset TO A PRIMITIVE under an armed haul
    import core.thread : Thread;
    import core.time   : dur;

    auto st = armBridgeHaul();

    // The reset is itself the tool-drop: `SceneReset.applyImpl` overwrites
    // `*mesh` IN PLACE and only then fires `onResetTool()` → `setActiveTool
    // (null)` → `deactivate()`. So no engaged tool is left standing behind an
    // assert raised after this line.
    auto r = postJson("/api/reset?type=cube", "");
    assert(r["status"].str == "ok", "reset(cube) failed: " ~ r.toString);
    Thread.sleep(dur!"msecs"(250));

    assert(st["valid"].type == JSONType.true_ && st["engaged"].type == JSONType.true_,
        vacuousMsg("the 60 px haul left the tool unengaged or the selection "
                   ~ "invalid: " ~ st.toString));

    auto model = getJson("/api/model");
    immutable long nv = model["vertexCount"].integer;
    immutable long nf = model["faceCount"].integer;
    assert(nv == 8 && nf == 6,
        "the scene reset replaced the document with a cube while a bridge "
        ~ "gesture was armed, and the drop built into it: the fresh cube "
        ~ "carries " ~ nv.to!string ~ " vertices / " ~ nf.to!string
        ~ " faces instead of 8/6. `deactivate()` committed a gesture whose "
        ~ "frozen loops belong to the PREVIOUS document — they still index "
        ~ "this one in range, which is why this reads as built geometry "
        ~ "rather than as the crash the empty-reset cell below produces");

    // EXACT equality, not `!canFind`: the reset's own entry is the positive
    // control that `/api/history` is answering at all, so a dead channel
    // cannot satisfy this the way an absence check would.
    auto labels = undoLabels();
    assert(labels == ["Reset to cube"],
        "history after the document change is " ~ labels.to!string
        ~ ", expected exactly [\"Reset to cube\"] — a gesture armed over a "
        ~ "document that has since been replaced must not reach "
        ~ "`commitBridgeEdit`");
}

unittest { // Radial Sweep: a reset TO A PRIMITIVE under an engaged session
    import core.thread : Thread;
    import core.time   : dur;

    armRadialSweep();

    auto r = postJson("/api/reset?type=cube", "");
    assert(r["status"].str == "ok", "reset(cube) failed: " ~ r.toString);
    Thread.sleep(dur!"msecs"(250));

    auto model = getJson("/api/model");
    immutable long nv = model["vertexCount"].integer;
    immutable long nf = model["faceCount"].integer;
    assert(nv == 8 && nf == 6,
        "the scene reset replaced the document with a cube while a radial "
        ~ "sweep session was engaged, and the drop revolved into it: the "
        ~ "fresh cube carries " ~ nv.to!string ~ " vertices / "
        ~ nf.to!string ~ " faces instead of 8/6. The frozen `profile_` vertex "
        ~ "ids belong to the PREVIOUS document and still index this one in "
        ~ "range");

    auto labels = undoLabels();
    assert(labels == ["Reset to cube"],
        "history after the document change is " ~ labels.to!string
        ~ ", expected exactly [\"Reset to cube\"]");
}

unittest { // Magnet: a reset TO A PRIMITIVE with the haul still under way
    import core.thread : Thread;
    import core.time   : dur;

    int hx, hy, vpX, vpY, vpW, vpH;
    bool moved;
    armOpenMagnetHaul(hx, hy, vpX, vpY, vpW, vpH, moved);

    auto r = postJson("/api/reset?type=cube", "");
    assert(r["status"].str == "ok", "reset(cube) failed: " ~ r.toString);
    Thread.sleep(dur!"msecs"(250));
    releaseButton(vpX, vpY, vpW, vpH, hx + 60, hy);

    assert(moved,
        vacuousMsg("cap vertex 6 did not move during the haul, so "
                   ~ "`applyMagnet` displaced nothing and `built` is false"));

    // Magnet's commit records an undo entry and writes no geometry, so the
    // HISTORY is the whole observable here — hence the exact compare, whose
    // left-hand entry doubles as the channel's positive control.
    auto labels = undoLabels();
    assert(labels == ["Reset to cube"],
        "history after the document change is " ~ labels.to!string
        ~ ", expected exactly [\"Reset to cube\"] — `commitEdit` built an "
        ~ "undo AFTER-image out of `touchedIdx_`, which indexes the document "
        ~ "the reset just replaced");
}

// ===========================================================================
// THE EMPTY CELLS — the reported reproductions. Against a gesture-only guard
// each of these kills the process, so they run LAST and only ever run when
// every cell above has passed.
// ===========================================================================

unittest { // Bridge: the reported repro — reset TO EMPTY under an armed haul
    import core.thread : Thread;
    import core.time   : dur;

    auto st = armBridgeHaul();

    // Before the fix this call returns 200 and the process then dies inside
    // the deactivate it triggered, so the failure of this cell is the NEXT
    // read timing out rather than an assertion — which is exactly why the
    // cube cells run first.
    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset(empty) failed: " ~ r.toString);
    Thread.sleep(dur!"msecs"(250));

    assert(st["valid"].type == JSONType.true_ && st["engaged"].type == JSONType.true_,
        vacuousMsg("the 60 px haul left the tool unengaged or the selection "
                   ~ "invalid: " ~ st.toString));

    auto model = getJson("/api/model");
    immutable long nv = model["vertexCount"].integer;
    immutable long nf = model["faceCount"].integer;
    assert(nv == 0 && nf == 0,
        "a reset to EMPTY under an armed bridge gesture left "
        ~ nv.to!string ~ " vertices / " ~ nf.to!string ~ " faces behind");

    auto labels = undoLabels();
    assert(labels == ["Reset to empty"],
        "history after the document change is " ~ labels.to!string
        ~ ", expected exactly [\"Reset to empty\"]");
}

unittest { // Radial Sweep: reset TO EMPTY under an engaged session
    import core.thread : Thread;
    import core.time   : dur;

    armRadialSweep();

    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset(empty) failed: " ~ r.toString);
    Thread.sleep(dur!"msecs"(250));

    auto model = getJson("/api/model");
    immutable long nv = model["vertexCount"].integer;
    immutable long nf = model["faceCount"].integer;
    assert(nv == 0 && nf == 0,
        "a reset to EMPTY under an engaged radial sweep left "
        ~ nv.to!string ~ " vertices / " ~ nf.to!string ~ " faces behind");

    auto labels = undoLabels();
    assert(labels == ["Reset to empty"],
        "history after the document change is " ~ labels.to!string
        ~ ", expected exactly [\"Reset to empty\"]");
}

unittest { // Magnet: reset TO EMPTY with the haul still under way
    import core.thread : Thread;
    import core.time   : dur;

    int hx, hy, vpX, vpY, vpW, vpH;
    bool moved;
    armOpenMagnetHaul(hx, hy, vpX, vpY, vpW, vpH, moved);

    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset(empty) failed: " ~ r.toString);
    Thread.sleep(dur!"msecs"(250));
    releaseButton(vpX, vpY, vpW, vpH, hx + 60, hy);

    assert(moved,
        vacuousMsg("cap vertex 6 did not move during the haul, so "
                   ~ "`applyMagnet` displaced nothing and `built` is false"));

    auto labels = undoLabels();
    assert(labels == ["Reset to empty"],
        "history after the document change is " ~ labels.to!string
        ~ ", expected exactly [\"Reset to empty\"]");
}
