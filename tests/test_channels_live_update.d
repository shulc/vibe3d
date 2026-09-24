// Item channel drag follows in the viewport while the button is held (tasks
// 7125/7126, item #2 of the editor bug-fix wave).
//
// THE LAW (captured, `tests/fixtures/editor_attrs_acen_laws_w17.json`, cell
// `channel_drag_live`; gap row 203): with no tool active, an LMB drag of the
// item's Position X field writes the channel once per increment, and the
// viewport redraws the item in the frame right after each increment while the
// button is still held; release adds nothing.
//
// WHY THIS FILE LAUNCHES ITS OWN EDITORS. Two harness facts, both measured:
//   * replayed mouse events reach ImGui only with `VIBE3D_TEST_VIEWPORT_WINDOWS=1`
//     (the replay sink stamps a window id only then), so the shared suite
//     instance cannot drive a panel field at all;
//   * plain `--test` renders the active cell EVERY frame and never runs the
//     interactive `DirtyKey` compare, so a pixel read there shows the moved
//     cube whether or not the key would have asked for a render — the defect
//     is invisible. `VIBE3D_TEST_DIRTY_KEY=1` keeps the production compare.
// Without the second switch every block below is green on the broken tree
// (measured: FBO hash changes per increment with the switch off, stays
// constant with it on).
//
// THE RIG: the default cube, item selection type, the item selected, no tool
// (`/api/tool/state` == {}). The observable is the RIGHT silhouette column of
// the cube on one FBO row, read through `/api/viewport/probe`: the rightmost
// item-outline pixel. One 20 px increment moves the channel by 0.02 and that
// column by 4-5 px (measured), so a frozen FBO and a live one differ by a
// whole column on every increment.
//
// ORDER (the block that must stay green on the broken tree comes first):
//   block 0 — the probe reaches: a channel write followed by a forced render
//             (camera away and back) moves the column. Green on HEAD.
//   block P — the Properties form field (the reference's gesture).
//   block C — the Channels list row (the owner's scenario; ours scrubs, the
//             reference's list cell does not — gap 203, kept).
// A shared cause reddens P and C; C's red line is read in isolation.
//
// Runner: ./run_test.d test_channels_live_update
module test_channels_live_update;

import core.sys.posix.signal : SIGKILL, SIGTERM, kill;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import http_client : getJson, postJson;
import std.array : appender;
import std.conv : to;
import std.file : exists, getcwd, mkdirRecurse, rmdirRecurse, symlink;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.net.curl : HTTP, get;
import std.path : buildPath;
import std.process : Config, Pid, spawnProcess, wait;
import std.socket : AddressFamily, InternetAddress, ProtocolType, Socket,
    SocketType;
import std.stdio : File, stdin;
import std.string : indexOf;

void main() {}

// ---------------------------------------------------------------------------
// Instance lifecycle
// ---------------------------------------------------------------------------

private struct Instance {
    ushort port;
    string root;
    string base;
    string logPath;
    Pid pid;
}

private ushort freePort() {
    auto socket = new Socket(AddressFamily.INET, SocketType.STREAM,
        ProtocolType.TCP);
    scope(exit) socket.close();
    socket.bind(new InternetAddress(InternetAddress.ADDR_ANY, 0));
    return (cast(InternetAddress)socket.localAddress).port;
}

private Instance launch(string cell) {
    Instance result;
    result.port = freePort();
    result.root = buildPath("/tmp", "vibe3d_channels_live_"
        ~ result.port.to!string ~ "_" ~ cell);
    mkdirRecurse(result.root);
    result.base = "http://127.0.0.1:" ~ result.port.to!string;
    result.logPath = buildPath(result.root, "vibe3d.log");
    const repo = getcwd();
    symlink(buildPath(repo, "config"), buildPath(result.root, "config"));
    symlink(buildPath(repo, "assets"), buildPath(result.root, "assets"));
    string[string] childEnv;
    childEnv["VIBE3D_CONFIG_DIR"] = result.root;
    childEnv["VIBE3D_TEST_VIEWPORT_WINDOWS"] = "1";
    childEnv["VIBE3D_TEST_DIRTY_KEY"] = "1";
    childEnv["VIBE3D_TEST_LAYOUT_INI"] = buildPath(result.root, "layout.ini");
    auto logFile = File(result.logPath, "wb");
    result.pid = spawnProcess([
        buildPath(repo, "vibe3d"), "--test", "--http-port",
        result.port.to!string,
    ], stdin, logFile, logFile, childEnv, Config.none, result.root);
    scope(failure) stop(result);
    foreach (_; 0 .. 240) {
        if (kill(result.pid.processID, 0) != 0) break;
        try {
            if ((cast(string)get(result.base ~ "/api/registry"))
                    .indexOf(`"layer.attr"`) >= 0)
                return result;
        } catch (Exception) {}
        Thread.sleep(25.msecs);
    }
    assert(false, "7125 " ~ cell ~ " app did not become ready; see "
        ~ result.logPath);
}

private void stop(ref Instance instance) {
    if (instance.pid !is null) {
        try kill(instance.pid.processID, SIGTERM); catch (Exception) {}
        foreach (_; 0 .. 40) {
            if (kill(instance.pid.processID, 0) != 0) break;
            Thread.sleep(25.msecs);
        }
        if (kill(instance.pid.processID, 0) == 0)
            try kill(instance.pid.processID, SIGKILL); catch (Exception) {}
        try wait(instance.pid); catch (Exception) {}
        instance.pid = null;
    }
    if (instance.root.length && exists(instance.root))
        try rmdirRecurse(instance.root); catch (Exception) {}
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

private void command(Instance instance, string line) {
    auto r = postJson("/api/command", line, instance.base);
    assert(r["status"].str == "ok",
        "7125 command `" ~ line ~ "` failed: " ~ r.toString);
}

private double channel(Instance instance, string attr) {
    auto r = postJson("/api/command", "layer.attr 0 " ~ attr ~ " ?",
        instance.base);
    assert(r["status"].str == "ok", "7125 query " ~ attr ~ ": " ~ r.toString);
    const v = r["value"];
    return v.type == JSONType.float_ ? v.floating
         : v.type == JSONType.integer ? cast(double)v.integer
         : cast(double)v.uinteger;
}

private size_t number(JSONValue object, string key) {
    const value = object[key];
    return value.type == JSONType.uinteger
        ? cast(size_t)value.uinteger : cast(size_t)value.integer;
}

private void play(Instance instance, string[] events) {
    auto body_ = appender!string();
    foreach (i, e; events) {
        if (i) body_.put("\n");
        body_.put(format(`{"t":%d,`, i * 30));
        body_.put(e[1 .. $]);
    }
    auto http = HTTP();
    string reply;
    http.onReceive = (ubyte[] data) {
        reply ~= cast(string)data;
        return data.length;
    };
    http.postData = body_.data;
    http.addRequestHeader("Content-Type", "text/plain");
    http.url = instance.base ~ "/api/play-events";
    http.perform();
    assert(reply.indexOf(`"status":"success"`) >= 0,
        "7125 play-events rejected the gesture: " ~ reply);
    const deadline = MonoTime.currTime + 5.seconds;
    while (MonoTime.currTime < deadline) {
        const status = getJson("/api/play-events/status", instance.base);
        if (status["finished"].type == JSONType.true_) {
            assert(number(status, "remaining") == 0
                && number(status, "total") == events.length,
                "7125 playback population: " ~ status.toString);
            return;
        }
        Thread.sleep(10.msecs);
    }
    assert(false, "7125 playback timed out");
}

private string motion(int x, int y, int state) {
    return format(`{"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,`
        ~ `"state":%d,"mod":0}`, x, y, state);
}

private string button(string type, int x, int y) {
    return format(`{"type":"%s","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        type, x, y);
}

// FBO row the silhouette is read on (the cube's mid height in the default
// perspective camera, 609x584 cell under the seeded layout).
private enum int kRow = 300;

/// Rightmost item-outline pixel on `kRow`, or -1 when the row shows none.
private int rightSilhouette(Instance instance) {
    auto pts = appender!string();
    foreach (x; 0 .. 609) {
        if (x) pts.put(";");
        pts.put(format("%d,%d", x, kRow));
    }
    const j = getJson("/api/viewport/probe?points=" ~ pts.data, instance.base);
    assert("points" in j, "7125 probe answered no points: " ~ j.toString);
    int right = -1;
    foreach (p; j["points"].array) {
        const r = number(p, "r"), b = number(p, "b");
        if (r > 200 && b < 90) {                 // the item outline (orange)
            const x = cast(int)number(p, "x");
            if (x > right) right = x;
        }
    }
    return right;
}

/// Poll until the column differs from `from` or the deadline passes. The
/// probe reads the last COMPLETED frame and the write lands in the frame
/// that processes the event, so the answer is at least one frame behind.
private int columnAfter(Instance instance, int from) {
    const deadline = MonoTime.currTime + 2.seconds;
    int now = rightSilhouette(instance);
    while (now == from && MonoTime.currTime < deadline) {
        Thread.sleep(20.msecs);
        now = rightSilhouette(instance);
    }
    return now;
}

private void rig(Instance instance, string panel) {
    command(instance, "select.typeFrom item");
    command(instance, panel);
    const sel = getJson("/api/selection", instance.base);
    assert(sel["selType"].str == "item"
        && sel["items"].array.length == 1
        && sel["items"].array[0]["selected"].type == JSONType.true_,
        "7125 rig floor: one selected item under the item type: "
        ~ sel.toString);
    const tool = getJson("/api/tool/state", instance.base);
    assert(tool.type == JSONType.object && tool.object.length == 0,
        "7125 rig floor: no active tool, got " ~ tool.toString);
    assert(channel(instance, "pos.x") == 0.0,
        "7125 rig floor: Position X starts at 0");
    Thread.sleep(300.msecs);
    // The opt-in took effect: over idle frames the cell is CONSIDERED every
    // frame and rendered only when its key moves. Plain `--test` renders
    // every considered cell, and under it every block here is green on the
    // broken tree, so this floor is what keeps the witness armed.
    const a = getJson("/api/frames/counts", instance.base)["totals"];
    Thread.sleep(300.msecs);
    const b = getJson("/api/frames/counts", instance.base)["totals"];
    const considered = number(b, "cellsConsidered") - number(a, "cellsConsidered");
    const rendered = number(b, "cellsRendered") - number(a, "cellsRendered");
    assert(considered >= 3 && rendered < considered, format(
        "7125 rig floor: the DirtyKey compare is not live (idle frames: "
        ~ "%d considered, %d rendered): VIBE3D_TEST_DIRTY_KEY did not take, "
        ~ "or a key term moves on every frame",
        considered, rendered));
}

/// Drag the field at (x0, y0) by `steps` increments of 20 px, asserting
/// after each increment and before release that the channel grew and the
/// viewport followed. `label` names the surface in the red line.
/// Returns the silhouette column before the drag, for the undo cell.
private int dragFollows(Instance instance, int x0, int y0, string label) {
    enum int steps = 10;
    int column = rightSilhouette(instance);
    const startColumn = column;
    assert(column > 0, "7125 " ~ label ~ " floor: the item outline is on row "
        ~ kRow.to!string);
    play(instance, [motion(x0, y0, 0), motion(x0, y0, 0),
                    button("SDL_MOUSEBUTTONDOWN", x0, y0)]);
    double value = channel(instance, "pos.x");
    int x = x0;
    foreach (k; 1 .. steps + 1) {
        x += 20;
        play(instance, [motion(x, y0, 1)]);
        const next = channel(instance, "pos.x");
        assert(next > value + 1e-4, format(
            "7125 %s floor: increment %d did not write the channel "
            ~ "(pos.x %.4f -> %.4f) — the drag missed the field",
            label, k, value, next));
        value = next;
        const moved = columnAfter(instance, column);
        assert(moved > column, format(
            "viewport did not follow the channel drag (%s): increment %d, "
            ~ "pos.x %.4f, right silhouette column stayed %d (was %d)",
            label, k, value, moved, column));
        column = moved;
    }
    play(instance, [button("SDL_MOUSEBUTTONUP", x, y0)]);
    Thread.sleep(200.msecs);
    assert(rightSilhouette(instance) == column, format(
        "7125 %s: release changed the view (law: release adds nothing)",
        label));
    assert(value > 0.19 && value < 0.21, format(
        "7125 %s floor: ten increments of 0.02 should reach 0.2, got %.4f",
        label, value));
    return startColumn;
}

// ---------------------------------------------------------------------------
// Block 0 — the probe reaches a shifted cube when a render is forced.
// ---------------------------------------------------------------------------
unittest {
    auto instance = launch("control");
    scope(exit) stop(instance);
    rig(instance, "ui.layerList show");
    const before = rightSilhouette(instance);
    assert(before > 0, "7125 control floor: outline on the probe row");
    command(instance, "layer.attr 0 pos.x 0.1");
    // Force a render through a key term the defect does not touch: the
    // camera, away and back to the same pose.
    const cam = getJson("/api/camera", instance.base);
    const az = cam["azimuth"].floating;
    postJson("/api/camera", format(`{"azimuth":%.6f}`, az + 0.1),
        instance.base);
    Thread.sleep(150.msecs);
    postJson("/api/camera", format(`{"azimuth":%.6f}`, az), instance.base);
    const after = columnAfter(instance, before);
    assert(after > before + 10, format(
        "7125 control: a forced render must show the 0.1 shift on row %d "
        ~ "(column %d -> %d)", kRow, before, after));
}

// ---------------------------------------------------------------------------
// Block P — the Properties form's Position X field (Items panel).
// ---------------------------------------------------------------------------
unittest {
    auto instance = launch("properties");
    scope(exit) stop(instance);
    rig(instance, "ui.layerList show");
    const startColumn = dragFollows(instance, 715, 135, "properties slider");
    // Undo with no tool: the revert is the only publication that can dirty
    // the cell, so the view must return to the pre-drag column on its own.
    const dragged = rightSilhouette(instance);
    assert(dragged > startColumn, "7125 undo floor: the drag moved the view");
    command(instance, "history.undo");
    assert(channel(instance, "pos.x") == 0.0,
        "7125 undo floor: one undo reverts the coalesced drag to pos.x 0");
    const undone = columnAfter(instance, dragged);
    assert(undone == startColumn, format(
        "viewport did not follow the undo of the channel drag: right "
        ~ "silhouette column %d, expected the pre-drag %d (dragged %d)",
        undone, startColumn, dragged));
}

// ---------------------------------------------------------------------------
// Block C — the Channels list row for Position X.
// ---------------------------------------------------------------------------
unittest {
    auto instance = launch("channels");
    scope(exit) stop(instance);
    rig(instance, "ui.channels show");
    cast(void)dragFollows(instance, 715, 128, "channels row");
}
