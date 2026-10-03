// Task 0393 — Loop Slice sticky-settings persistence regression.
//
// Root cause (see doc/tasks/backlog/0393-loop-slice-settings-not-sticky.md /
// done/): `LoopSliceTool.activate()` called `reinitSession()`, which
// hard-reset every SETTING field (count_/mode_/edit_/selectNew_/
// sliceSelected_/keepQuads_/sliceNgon_/sliceSplit_/sliceCaps_/gap_/
// curvature_/curveTension_/profile_/depth_/reverseX_/reverseY_/aspect_) back
// to its constructor default, AFTER `applyStickyToolDefaults()`
// (tool_presets.d, invoked from app.d `activateToolById`) had already
// restored the user's last-used values onto those same fields — silently
// clobbering the restore on every single re-activation. `length_`/
// `sliderX_`/`sliderY_` (HUD geometry) were the only fields reinitSession
// never touched, and they were the only ones that DID survive drop ->
// reactivate — which is what gave the bug away.
//
// This tier needs persistence LIVE (`prefsActive` true), which under
// `--test` requires VIBE3D_CONFIG_DIR to be set (source/app.d ~1109-1113).
// The shared run_test.d harness instance every OTHER test drives never sets
// that var (see tests/test_tool_sticky.d, doc/tool_settings_persist_plan.md
// "Risks & Dependencies" #4), so — mirroring test_tool_sticky.d — this file
// spawns its OWN `./vibe3d --test --http-port <free port>` with a scratch
// VIBE3D_CONFIG_DIR, drives it directly over its own port, and tears it down
// when done. Must be run from the repo root (same assumption run_test.d
// itself makes for its `./vibe3d` launches).
//
// Coverage:
//   1. Settings (count/caps/gap/mode) survive drop -> reactivate.
//   2. The slice positions DO persist (task 9330, captured 2026-10-03,
//      toolcard `loop_slice_position_memory` Q2/Q3): the whole list survives
//      drop -> reactivate, only `current` resets to 0 — and the next cut
//      lands at the remembered position, not at 0.5.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math     : fabs;
import std.conv     : to;
import std.process  : spawnProcess, wait, thisProcessID, Pid, environment;
import std.socket   : Socket, AddressFamily, SocketType, ProtocolType, InternetAddress;
import std.file     : mkdirRecurse, rmdirRecurse, exists;
import std.path     : buildPath;
import std.stdio    : File, stdin, stderr;

import core.thread            : Thread;
import core.time              : msecs;
import core.sys.posix.signal  : kill, SIGTERM, SIGKILL;

void main() {}

// ---------------------------------------------------------------------------
// Self-launched instance lifecycle (identical idiom to test_tool_sticky.d).
// ---------------------------------------------------------------------------

ushort pickFreePort() {
    auto sock = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
    scope(exit) sock.close();
    sock.bind(new InternetAddress(InternetAddress.ADDR_ANY, cast(ushort)0));
    return (cast(InternetAddress)sock.localAddress).port;
}

struct Instance {
    ushort  port;
    string  baseUrl;
    string  scratch;
    string  logPath;
    Pid     pid;
    bool    up;
}

bool httpProbe(string baseUrl, int tries = 100) {
    for (int i = 0; i < tries; ++i) {
        try {
            get(baseUrl ~ "/api/camera");
            return true;
        } catch (Exception) {}
        Thread.sleep(100.msecs);
    }
    return false;
}

Instance launchInstance() {
    Instance inst;
    inst.port    = pickFreePort();
    inst.baseUrl = "http://localhost:" ~ inst.port.to!string;
    inst.scratch = buildPath("/tmp",
        "vibe3d_loop_slice_sticky_test_" ~ thisProcessID().to!string ~ "_" ~ inst.port.to!string);
    mkdirRecurse(inst.scratch);
    inst.logPath = buildPath(inst.scratch, "vibe3d.log");

    string[string] env;
    env["VIBE3D_CONFIG_DIR"] = inst.scratch;

    string[] argv = ["./vibe3d", "--test", "--http-port", inst.port.to!string];
    auto logFile = File(inst.logPath, "wb");
    inst.pid = spawnProcess(argv, stdin, logFile, logFile, env);

    inst.up = httpProbe(inst.baseUrl);
    if (!inst.up) {
        stderr.writefln("test_loop_slice_sticky: instance on port %d failed to come up", inst.port);
        try { stderr.writeln(readLogTail(inst.logPath)); } catch (Exception) {}
    }
    return inst;
}

string readLogTail(string path) {
    import std.file : readText;
    auto txt = readText(path);
    return txt.length > 4000 ? txt[$ - 4000 .. $] : txt;
}

void teardownInstance(ref Instance inst) {
    if (inst.pid is null) return;
    try { kill(inst.pid.processID, SIGTERM); } catch (Exception) {}
    bool dead;
    for (int i = 0; i < 20; ++i) {
        Thread.sleep(50.msecs);
        if (kill(inst.pid.processID, 0) != 0) { dead = true; break; }
    }
    if (!dead) try { kill(inst.pid.processID, SIGKILL); } catch (Exception) {}
    try { wait(inst.pid); } catch (Exception) {}
    if (inst.scratch.length && exists(inst.scratch)) {
        try { rmdirRecurse(inst.scratch); } catch (Exception) {}
    }
}

__gshared Instance g_inst;

static this() {
    g_inst = launchInstance();
    assert(g_inst.up, "test_loop_slice_sticky: failed to launch a self-hosted "
        ~ "vibe3d instance (run from the repo root; see " ~ g_inst.logPath ~ ")");
    environment["VIBE3D_TEST_PORT"] = g_inst.port.to!string;
}

static ~this() {
    teardownInstance(g_inst);
}

// ---------------------------------------------------------------------------
// Shared HTTP helpers read the self-launched instance's port set above.
// ---------------------------------------------------------------------------


bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: "
        ~ r.toString);
}

JSONValue query(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "query '" ~ line ~ "' failed: " ~ r.toString);
    assert("value" in r,
        "query '" ~ line ~ "' returned no value field: " ~ r.toString);
    return r["value"];
}

void resetCube() {
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

// ---------------------------------------------------------------------------
// 1. Settings survive drop -> reactivate.
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    cmd("tool.set mesh.loopSliceTool");
    // Non-default settings (constructor defaults: count=1, caps=true,
    // gap=0, mode=uniform — see field initializers in loop_slice_tool.d).
    cmd("tool.attr mesh.loopSliceTool count 4");
    cmd("tool.attr mesh.loopSliceTool caps false");
    cmd("tool.attr mesh.loopSliceTool gap 0.3");
    cmd("tool.attr mesh.loopSliceTool mode symmetry");

    // Clean drop -- captures sticky (captureStickyToolDefaults, app.d).
    cmd("tool.set mesh.loopSliceTool off");

    // Reactivate -- applyStickyToolDefaults restores BEFORE activate()
    // (app.d activateToolById); reinitSession() must not clobber it back to
    // the constructor defaults (the 0393 bug).
    cmd("tool.set mesh.loopSliceTool");

    auto count = query("tool.attr mesh.loopSliceTool count ?");
    assert(count.integer == 4,
        "count should persist across drop->reactivate as 4, got " ~ count.toString);

    auto caps = query("tool.attr mesh.loopSliceTool caps ?");
    assert(caps.boolean == false,
        "caps should persist across drop->reactivate as false, got " ~ caps.toString);

    auto gap = query("tool.attr mesh.loopSliceTool gap ?");
    assert(approxEqual(gap.floating, 0.3),
        "gap should persist across drop->reactivate as 0.3, got " ~ gap.toString);

    auto mode = query("tool.attr mesh.loopSliceTool mode ?");
    assert(mode.str == "symmetry",
        "mode should persist across drop->reactivate as symmetry, got " ~ mode.toString);

    // positions_ must stay CONSISTENT with the restored count_ — a real cut
    // right now must actually produce 4 slices, not silently fall back to 1
    // (the invariant reinitSession's old `positions_ = [0.5f]` hard-reset
    // would have broken once count_ stopped being reset alongside it).
    auto state = getJson("/api/tool/state");
    assert(state["positions"].array.length == 4,
        "positions[] should have grown to match the restored count=4, got "
        ~ state.toString);

    cmd("tool.set mesh.loopSliceTool off");
}

// ---------------------------------------------------------------------------
// 2. The positions list persists across drop -> reactivate; `current` resets.
//    Free mode with three NON-uniform values, so "kept" is distinguishable
//    from "reset to 0.5" and from the uniform re-lay (0.25/0.5/0.75).
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    cmd("tool.set mesh.loopSliceTool");
    cmd("tool.attr mesh.loopSliceTool mode free");
    cmd("tool.attr mesh.loopSliceTool count 3");
    immutable double[3] want = [0.1, 0.3, 0.85];
    foreach (k, v; want) {
        cmd("tool.attr mesh.loopSliceTool current " ~ k.to!string);
        cmd("tool.attr mesh.loopSliceTool position " ~ v.to!string);
    }
    auto before = getJson("/api/tool/state")["positions"].array;
    assert(before.length == 3 && approxEqual(before[0].floating, 0.1)
        && approxEqual(before[1].floating, 0.3) && approxEqual(before[2].floating, 0.85),
        "rig: the three Free positions did not land before the drop: "
        ~ before.to!string);
    assert(query("tool.attr mesh.loopSliceTool current ?").integer == 2,
        "rig: current should be 2 before the drop (else its reset is vacuous)");

    cmd("tool.set mesh.loopSliceTool off");
    cmd("tool.set mesh.loopSliceTool");

    auto after = getJson("/api/tool/state")["positions"].array;
    assert(after.length == 3, "positions list length should persist as 3, got "
        ~ after.to!string);
    foreach (k, v; want)
        assert(approxEqual(after[k].floating, v),
            "positions must persist across drop->reactivate (captured: the "
            ~ "whole list is kept), want " ~ want.to!string ~ ", got "
            ~ after.to!string);
    assert(query("tool.attr mesh.loopSliceTool current ?").integer == 0,
        "current must reset to 0 at activation (captured)");
    assert(approxEqual(query("tool.attr mesh.loopSliceTool position ?").floating, 0.1),
        "position (the proxy of positions[current]) should read 0.1");

    cmd("tool.set mesh.loopSliceTool off");
}

// ---------------------------------------------------------------------------
// 3. A single remembered position places the next cut. Count 1 at 0.2, drop,
//    reactivate, cut across cube edge 0-1 (x from -0.5 to 0.5): the new
//    vertex on that edge sits at x = -0.3 or 0.3 (direction-agnostic), never
//    at the default's x = 0.
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    cmd("tool.set mesh.loopSliceTool");
    cmd("tool.attr mesh.loopSliceTool count 1");
    cmd("tool.attr mesh.loopSliceTool position 0.2");
    cmd("tool.set mesh.loopSliceTool off");

    auto m0 = getJson("/api/model");
    int seed = -1;
    foreach (i, e; m0["edges"].array) {
        auto a = m0["vertices"].array[e.array[0].integer].array;
        auto b = m0["vertices"].array[e.array[1].integer].array;
        if (fabs(a[1].floating + 0.5) < 1e-4 && fabs(b[1].floating + 0.5) < 1e-4
            && fabs(a[2].floating + 0.5) < 1e-4 && fabs(b[2].floating + 0.5) < 1e-4)
            seed = cast(int) i;
    }
    assert(seed >= 0, "rig: cube edge y=-0.5,z=-0.5 not found");
    cmd(commandBody("mesh.select", `{"mode":"edges","indices":[` ~ seed.to!string ~ `]}`));

    cmd("tool.set mesh.loopSliceTool");
    cmd("tool.doApply");
    auto m1 = getJson("/api/model");
    assert(m1["vertexCount"].integer == 12, "rig: one loop should add 4 vertices, got "
        ~ m1["vertexCount"].toString);
    int onEdge = 0;
    foreach (v; m1["vertices"].array) {
        auto c = v.array;
        if (fabs(c[1].floating + 0.5) > 1e-4 || fabs(c[2].floating + 0.5) > 1e-4) continue;
        if (fabs(fabs(c[0].floating) - 0.5) < 1e-4) continue;   // the edge's own ends
        ++onEdge;
        assert(fabs(fabs(c[0].floating) - 0.3) < 1e-4,
            "the cut after reactivation must land at the remembered 0.2 "
            ~ "(x = +-0.3), got x = " ~ c[0].toString);
    }
    assert(onEdge == 1, "population: expected exactly one new vertex on the seed "
        ~ "edge, got " ~ onEdge.to!string);

    cmd("tool.set mesh.loopSliceTool off");
}
