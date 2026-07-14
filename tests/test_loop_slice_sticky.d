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
//   2. A transient gesture proxy (`position`, backed by positionProxy_/
//      positions_, `.transient()` in params()) does NOT persist — it reverts
//      to its declared default, proving the fix didn't overshoot and turn
//      session/gesture state into accidental sticky settings.

import std.net.curl;
import std.json;
import std.math     : fabs;
import std.conv     : to;
import std.process  : spawnProcess, wait, thisProcessID, Pid;
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
}

static ~this() {
    teardownInstance(g_inst);
}

// ---------------------------------------------------------------------------
// HTTP helpers.
// ---------------------------------------------------------------------------

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(g_inst.baseUrl ~ path, body_));
}

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(g_inst.baseUrl ~ path));
}

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
    auto r = postJson("/api/reset", "");
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
// 2. Transient gesture proxy (`position`) does NOT persist — reverts to its
//    declared default. Explicitly re-pins count=1 first so the write to
//    `position` isn't swallowed by Uniform mode's count>1 re-lay no-op
//    (scrubPosition's D3 law), keeping the transience check unambiguous.
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    cmd("tool.set mesh.loopSliceTool");
    cmd("tool.attr mesh.loopSliceTool count 1");
    cmd("tool.attr mesh.loopSliceTool position 0.2");

    auto posBeforeDrop = query("tool.attr mesh.loopSliceTool position ?");
    assert(approxEqual(posBeforeDrop.floating, 0.2),
        "sanity: position write should have taken effect before drop, got "
        ~ posBeforeDrop.toString);

    cmd("tool.set mesh.loopSliceTool off");
    cmd("tool.set mesh.loopSliceTool");

    auto pos = query("tool.attr mesh.loopSliceTool position ?");
    assert(approxEqual(pos.floating, 0.5),
        "position (transient) must NOT persist -- should be back at its "
        ~ "declared default 0.5, got " ~ pos.toString);

    auto current = query("tool.attr mesh.loopSliceTool current ?");
    assert(current.integer == 0,
        "current (transient) must NOT persist -- should be back at its "
        ~ "declared default 0, got " ~ current.toString);

    cmd("tool.set mesh.loopSliceTool off");
}
