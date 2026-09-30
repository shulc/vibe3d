// Topology Pen: a HELD Move drag is the tool's uncommitted edit (task 8660).
//
// The Move gesture writes the mesh live while the button is held and records
// its one history row only at release. Two doors reach it mid-hold, and both
// must DISCARD the drag rather than keep or record it:
//
//   * `tool.reset`  — `EditSession.discardOpenEdit` asks the tool's
//     `hasUncommittedEdit` / `cancelUncommittedEdit` BEFORE the reset re-arm;
//   * a document replace (`file.load`) — the disarm seam loops
//     `cancelUncommittedEdit` before it drops the tool (`/api/tool/disarm`
//     reports how many cancel steps it took).
//
// Base-commit outcome, measured before the hooks existed, is in the task card
// (8660): the reset left the vertex moved (cell 1 (a) red) and the load
// recorded a "Topology Move" row (cell 2 red); cell 1 (b)/(c) were already
// green there and are regression pins, not discriminators.
//
// Run via: ./run_test.d topopen_live_move_discard

import http_command_helpers : commandBody;
import topopen_place_helpers;
import drag_helpers : buildDragDownLog, buildDragMotionLog, buildDragUpLog;
import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, remove;
import std.format : format;
import std.json;
import std.math : sqrt;
import std.process : thisProcessID;

void main() {}

enum float R   = 2.0f;
enum int   LON = 96, LAT = 72;
enum string kMoveLabel = "Topology Move";

struct Rig {
    CameraState c;
    int cx, cy, nx, ny;
    double[3] pre;      // the grabbed vertex before the press
    size_t undoBefore;  // undo length before the press
}

size_t undoLen() { return getJson("/api/history")["undo"].array.length; }

string[] undoLabels() {
    string[] labels;
    foreach (e; getJson("/api/history")["undo"].array) labels ~= e["label"].str;
    return labels;
}

JSONValue toolState() { return getJson("/api/tool/state"); }

string activeToolName() {
    auto s = toolState();
    return ("tool" in s.object) ? s["tool"].str : "";
}

double dist(double[3] a, double[3] b) {
    double s = 0;
    foreach (i; 0 .. 3) s += (a[i] - b[i]) * (a[i] - b[i]);
    return sqrt(s);
}

/// Background sphere, one placed vertex on the edit layer, then a HELD Move
/// drag of it: down + motion, no up. Returns with the drag live.
Rig holdMoveDrag() {
    Rig r;
    setupSphereBg(R, LON, LAT);
    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));
    r.c = fetchCamera();
    r.cx = r.c.vpX + r.c.width / 2; r.cy = r.c.vpY + r.c.height / 2;
    r.nx = r.cx + 80;               r.ny = r.cy + 40;

    // After the reset, before the arm: every length read below is measured
    // from here, far from the history cap.
    cmd("history.clear");
    cmd("tool.set mesh.topoPen on");
    cmd("tool.attr mesh.topoPen mode point");

    postJson("/api/play-events",
        clickLog(r.c.vpX, r.c.vpY, r.c.width, r.c.height, r.cx, r.cy));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 1, "rig: the click must place one vertex");

    r.pre = readVerticesLayer(1)[0];
    r.undoBefore = undoLen();
    assert(r.undoBefore < 40, "rig: history headroom, undo length "
        ~ r.undoBefore.to!string);

    postJson("/api/play-events", buildDragDownLog(r.c.vpX, r.c.vpY,
        r.c.width, r.c.height, r.cx, r.cy));
    waitPlayerIdle();
    postJson("/api/play-events", buildDragMotionLog(r.c.vpX, r.c.vpY,
        r.c.width, r.c.height, r.cx, r.cy, r.nx, r.ny, 16));
    waitPlayerIdle();

    // Population: the drag is live — armed, dirty, and the vertex has moved.
    auto s = toolState();
    assert(s["moveArmed"].type == JSONType.true_ &&
           s["moveDirty"].type == JSONType.true_,
        "rig: the held press must arm a live, written Move: " ~ s.toString);
    const moved = dist(readVerticesLayer(1)[0], r.pre);
    assert(moved > 1e-3, "rig: the held drag must move the vertex, moved "
        ~ moved.to!string);
    assert(undoLen() == r.undoBefore, "rig: a held drag records nothing yet");
    return r;
}

// Cell 1: tool.reset during a held Move drag throws the drag away.
unittest {
    auto r = holdMoveDrag();

    cmd("tool.reset");

    // (a) the vertex is back, bit-identical to its pre-press position.
    const after = readVerticesLayer(1)[0];
    assert(after == r.pre, format(
        "tool.reset mid-drag must restore the grabbed vertex exactly: "
        ~ "pre %s, after %s", r.pre, after));
    // (b) nothing was recorded by the reset.
    assert(undoLen() == r.undoBefore, format(
        "tool.reset mid-drag must record nothing: undo %s -> %s (%s)",
        r.undoBefore, undoLen(), undoLabels()));
    // (c) the release that follows records nothing either.
    postJson("/api/play-events", buildDragUpLog(r.c.vpX, r.c.vpY,
        r.c.width, r.c.height, r.nx, r.ny));
    waitPlayerIdle();
    assert(undoLen() == r.undoBefore, format(
        "the release after a mid-drag reset must record nothing: undo %s -> %s (%s)",
        r.undoBefore, undoLen(), undoLabels()));
    assert(readVerticesLayer(1)[0] == r.pre,
        "the release after a mid-drag reset must not move the vertex");
    // (d) the reset re-armed the pen.
    assert(activeToolName() == "mesh.topoPen",
        "tool.reset must leave the pen armed: " ~ toolState().toString);
}

// Cell 2 (load-mid-drag): a document replace during a held Move drag cancels
// it through the disarm seam instead of recording it at the drop.
unittest {
    const path = format("/var/tmp/vibe3d_8660_load_seed_%d.v3d", thisProcessID);
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);
    postJson("/api/command", commandBody("scene.reset"));
    auto sv = postJson("/api/command",
        `{"id":"file.save","params":{"path":"` ~ path ~ `"}}`);
    assert(sv["status"].str == "ok" && exists(path),
        "file.save did not create the load seed: " ~ sv.toString);

    auto r = holdMoveDrag();
    const crossings0 = getJson("/api/tool/disarm")["crossings"].integer;

    auto ld = postJson("/api/command",
        `{"id":"file.load","params":{"path":"` ~ path ~ `"}}`);
    assert(ld["status"].str == "ok", "file.load failed: " ~ ld.toString);

    auto d = getJson("/api/tool/disarm");
    assert(d["crossings"].integer == crossings0 + 1 &&
           d["hadTool"].type == JSONType.true_,
        "the load must cross the disarm seam once with the pen armed: "
        ~ d.toString);
    assert(!undoLabels().canFind(kMoveLabel), format(
        "a load mid-drag must not record the held Move: %s", undoLabels()));
    assert(d["cancelSteps"].integer == 1 &&
           d["stillArmed"].type == JSONType.false_,
        "the disarm seam must cancel the held Move in one step: " ~ d.toString);
    assert(activeToolName() != "mesh.topoPen",
        "the load must disarm the pen: " ~ toolState().toString);

    const afterLoad = undoLen();
    postJson("/api/play-events", buildDragUpLog(r.c.vpX, r.c.vpY,
        r.c.width, r.c.height, r.nx, r.ny));
    waitPlayerIdle();
    assert(undoLen() == afterLoad && !undoLabels().canFind(kMoveLabel), format(
        "the release after a mid-drag load must record nothing: %s", undoLabels()));
}
