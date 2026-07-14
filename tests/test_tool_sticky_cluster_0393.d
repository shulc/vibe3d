// Task 0393 (scope expansion) — sticky-settings persistence regression for
// the REST of the affected-tool cluster an owner audit found alongside
// LoopSlice (test_loop_slice_sticky.d covers LoopSlice itself):
//
//   RadialArrayTool  (mesh.radialArrayTool)  — count/axis/center/angle/
//                                              offset/weld, incl. a Vec3
//                                              (`center`) round-trip.
//   ReductionTool    (mesh.reduceTool)       — ratio/preserveBoundary.
//   BendTool         (xfrm.bend)             — angle/spineX/Y/Z.
//   PushTool         (xfrm.push)             — dist.
//   LinearAlignTool  (xfrm.linearAlignTool)  — mode/uniform/weight.
//   RadialAlignTool  (xfrm.radialAlignTool)  — mode/side/rotate/angle/weight.
//
// Root cause (same class of bug as LoopSlice, see
// doc/tasks/*/0393-loop-slice-settings-not-sticky.md): each tool's
// activate() (directly, or via a reinitSession() helper) hard-reset its
// param-backed setting fields to constructor defaults AFTER
// applyStickyToolDefaults() (tool_presets.d, app.d activateToolById) had
// already restored the user's last-used values onto those same fields —
// clobbering the restore on every re-activation. Bend/Push/LinearAlign/
// RadialAlign share one TransformTool subclass idiom (`super.activate();`
// then a hardcoded field reset); RadialArrayTool/ReductionTool each had
// their own inline reset. The fix in every case: stop resetting the
// setting fields in activate()/reinitSession() — the field initializers
// already supply the correct constructor default for a brand-new tool.
//
// This tier needs persistence LIVE (`prefsActive` true), which under
// `--test` requires VIBE3D_CONFIG_DIR to be set (source/app.d ~1109-1113).
// The shared run_test.d harness instance every OTHER test drives never sets
// that var, so — mirroring tests/test_tool_sticky.d and
// tests/test_loop_slice_sticky.d — this file spawns its OWN
// `./vibe3d --test --http-port <free port>` with a scratch VIBE3D_CONFIG_DIR
// and tears it down when done. Must be run from the repo root.

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
// Self-launched instance lifecycle (identical idiom to test_tool_sticky.d /
// test_loop_slice_sticky.d).
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
        "vibe3d_tool_sticky_cluster_test_" ~ thisProcessID().to!string ~ "_" ~ inst.port.to!string);
    mkdirRecurse(inst.scratch);
    inst.logPath = buildPath(inst.scratch, "vibe3d.log");

    string[string] env;
    env["VIBE3D_CONFIG_DIR"] = inst.scratch;

    string[] argv = ["./vibe3d", "--test", "--http-port", inst.port.to!string];
    auto logFile = File(inst.logPath, "wb");
    inst.pid = spawnProcess(argv, stdin, logFile, logFile, env);

    inst.up = httpProbe(inst.baseUrl);
    if (!inst.up) {
        stderr.writefln("test_tool_sticky_cluster_0393: instance on port %d failed to come up", inst.port);
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
    assert(g_inst.up, "test_tool_sticky_cluster_0393: failed to launch a "
        ~ "self-hosted vibe3d instance (run from the repo root; see "
        ~ g_inst.logPath ~ ")");
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
// 1. RadialArrayTool (mesh.radialArrayTool) — count/axis/center(Vec3)/
//    angle/offset/weld survive drop -> reactivate.
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    cmd("tool.set mesh.radialArrayTool");
    cmd("tool.attr mesh.radialArrayTool count 8");
    cmd("tool.attr mesh.radialArrayTool axis X");
    cmd("tool.attr mesh.radialArrayTool center {2,3,4}");
    cmd("tool.attr mesh.radialArrayTool angle 45");
    cmd("tool.attr mesh.radialArrayTool offset 1.5");
    cmd("tool.attr mesh.radialArrayTool weld 0.02");

    cmd("tool.set mesh.radialArrayTool off");
    cmd("tool.set mesh.radialArrayTool");

    auto count = query("tool.attr mesh.radialArrayTool count ?");
    assert(count.integer == 8, "count should persist as 8, got " ~ count.toString);

    auto axis = query("tool.attr mesh.radialArrayTool axis ?");
    assert(axis.str == "X", "axis should persist as X, got " ~ axis.toString);

    auto center = query("tool.attr mesh.radialArrayTool center ?");
    assert(center.type == JSONType.array && center.array.length == 3,
        "center should be a 3-element array, got " ~ center.toString);
    assert(approxEqual(center.array[0].floating, 2.0)
        && approxEqual(center.array[1].floating, 3.0)
        && approxEqual(center.array[2].floating, 4.0),
        "center (Vec3) should persist as (2,3,4), got " ~ center.toString);

    auto angle = query("tool.attr mesh.radialArrayTool angle ?");
    assert(approxEqual(angle.floating, 45.0), "angle should persist as 45, got " ~ angle.toString);

    auto offset = query("tool.attr mesh.radialArrayTool offset ?");
    assert(approxEqual(offset.floating, 1.5), "offset should persist as 1.5, got " ~ offset.toString);

    auto weld = query("tool.attr mesh.radialArrayTool weld ?");
    assert(approxEqual(weld.floating, 0.02), "weld should persist as 0.02, got " ~ weld.toString);

    cmd("tool.set mesh.radialArrayTool off");
}

// ---------------------------------------------------------------------------
// 2. ReductionTool (mesh.reduceTool) — ratio/preserveBoundary survive
//    drop -> reactivate.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("select.typeFrom polygon");

    cmd("tool.set mesh.reduceTool");
    cmd("tool.attr mesh.reduceTool ratio 0.25");
    cmd("tool.attr mesh.reduceTool preserveBoundary false");

    cmd("tool.set mesh.reduceTool off");
    cmd("tool.set mesh.reduceTool");

    auto ratio = query("tool.attr mesh.reduceTool ratio ?");
    assert(approxEqual(ratio.floating, 0.25), "ratio should persist as 0.25, got " ~ ratio.toString);

    auto pb = query("tool.attr mesh.reduceTool preserveBoundary ?");
    assert(pb.boolean == false, "preserveBoundary should persist as false, got " ~ pb.toString);

    cmd("tool.set mesh.reduceTool off");
}

// ---------------------------------------------------------------------------
// 3. BendTool (xfrm.bend) — angle/spineX/Y/Z survive drop -> reactivate.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("select.typeFrom polygon");

    cmd("tool.set xfrm.bend");
    cmd("tool.attr xfrm.bend angle 30");
    cmd("tool.attr xfrm.bend spineX 0");
    cmd("tool.attr xfrm.bend spineY 1");
    cmd("tool.attr xfrm.bend spineZ 0");

    cmd("tool.set xfrm.bend off");
    cmd("tool.set xfrm.bend");

    auto angle = query("tool.attr xfrm.bend angle ?");
    assert(approxEqual(angle.floating, 30.0), "angle should persist as 30, got " ~ angle.toString);

    auto sx = query("tool.attr xfrm.bend spineX ?");
    auto sy = query("tool.attr xfrm.bend spineY ?");
    auto sz = query("tool.attr xfrm.bend spineZ ?");
    assert(approxEqual(sx.floating, 0.0) && approxEqual(sy.floating, 1.0) && approxEqual(sz.floating, 0.0),
        "spine should persist as (0,1,0), got (" ~ sx.toString ~ "," ~ sy.toString ~ "," ~ sz.toString ~ ")");

    cmd("tool.set xfrm.bend off");
}

// ---------------------------------------------------------------------------
// 4. PushTool (xfrm.push) — dist survives drop -> reactivate.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("select.typeFrom polygon");

    cmd("tool.set xfrm.push");
    cmd("tool.attr xfrm.push dist 0.75");

    cmd("tool.set xfrm.push off");
    cmd("tool.set xfrm.push");

    auto dist = query("tool.attr xfrm.push dist ?");
    assert(approxEqual(dist.floating, 0.75), "dist should persist as 0.75, got " ~ dist.toString);

    cmd("tool.set xfrm.push off");
}

// ---------------------------------------------------------------------------
// 5. LinearAlignTool (xfrm.linearAlignTool) — mode/uniform/weight survive
//    drop -> reactivate.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("select.typeFrom edge");

    cmd("tool.set xfrm.linearAlignTool");
    cmd("tool.attr xfrm.linearAlignTool mode curve");
    cmd("tool.attr xfrm.linearAlignTool uniform true");
    cmd("tool.attr xfrm.linearAlignTool weight 0.4");

    cmd("tool.set xfrm.linearAlignTool off");
    cmd("tool.set xfrm.linearAlignTool");

    auto mode = query("tool.attr xfrm.linearAlignTool mode ?");
    assert(mode.str == "curve", "mode should persist as curve, got " ~ mode.toString);

    auto uniform = query("tool.attr xfrm.linearAlignTool uniform ?");
    assert(uniform.boolean == true, "uniform should persist as true, got " ~ uniform.toString);

    auto weight = query("tool.attr xfrm.linearAlignTool weight ?");
    assert(approxEqual(weight.floating, 0.4), "weight should persist as 0.4, got " ~ weight.toString);

    cmd("tool.set xfrm.linearAlignTool off");
}

// ---------------------------------------------------------------------------
// 6. RadialAlignTool (xfrm.radialAlignTool) — mode/side/rotate/angle/weight
//    survive drop -> reactivate.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("select.typeFrom edge");

    cmd("tool.set xfrm.radialAlignTool");
    cmd("tool.attr xfrm.radialAlignTool mode nside");
    cmd("tool.attr xfrm.radialAlignTool side 6");
    cmd("tool.attr xfrm.radialAlignTool rotate 15");
    cmd("tool.attr xfrm.radialAlignTool angle 20");
    cmd("tool.attr xfrm.radialAlignTool weight 0.6");

    cmd("tool.set xfrm.radialAlignTool off");
    cmd("tool.set xfrm.radialAlignTool");

    auto mode = query("tool.attr xfrm.radialAlignTool mode ?");
    assert(mode.str == "nside", "mode should persist as nside, got " ~ mode.toString);

    auto side = query("tool.attr xfrm.radialAlignTool side ?");
    assert(side.integer == 6, "side should persist as 6, got " ~ side.toString);

    auto rotate = query("tool.attr xfrm.radialAlignTool rotate ?");
    assert(approxEqual(rotate.floating, 15.0), "rotate should persist as 15, got " ~ rotate.toString);

    auto angle = query("tool.attr xfrm.radialAlignTool angle ?");
    assert(approxEqual(angle.floating, 20.0), "angle should persist as 20, got " ~ angle.toString);

    auto weight = query("tool.attr xfrm.radialAlignTool weight ?");
    assert(approxEqual(weight.floating, 0.6), "weight should persist as 0.6, got " ~ weight.toString);

    cmd("tool.set xfrm.radialAlignTool off");
}
