// Sticky tool-option persistence (Stage A + C) and the CommandWrapper
// activation-deform regression (Stage CW) — self-launched, isolated tier.
//
// A + C need persistence LIVE (`prefsActive` true), which under `--test`
// requires VIBE3D_CONFIG_DIR to be set (source/app.d ~1109-1113). The shared
// run_test.d harness instance that every OTHER test drives never sets that
// var (deliberately — see doc/tool_settings_persist_plan.md "Risks &
// Dependencies" #4), so this tier spawns its OWN
// `./vibe3d --test --http-port <free port>` with a scratch VIBE3D_CONFIG_DIR,
// drives it directly over its own port, and tears it down when done. Must be
// run from the repo root (same assumption run_test.d itself makes for its
// `./vibe3d` launches).
//
// Coverage:
//   1. Base/direct tool (mesh.sliceTool): a genuine setting (snapAngle)
//      survives drop -> reactivate (A); a transient param (startX, the drawn
//      cut-line geometry) does NOT (C) -- it reverts to its declared default.
//   2. The Stage CW regression this whole tier exists to prove: reactivating
//      a CommandWrapper deformer (edge.slide) must NOT re-run its deform
//      purely from the mechanical sticky restore. `edge.slide` is used
//      (rather than xfrm.smooth/jitter/quantize) because those three have a
//      config/forms/*.yaml entry and are therefore rendered by FormsPanel,
//      which only calls Tool.evaluate() as a side effect of an actual
//      `tool.attr` write (commands/tool/attr.d) -- never merely because the
//      Tool Properties panel is open. `edge.slide` has no form, so it is
//      still rendered by the legacy schema panel (property_panel.d), whose
//      `drawProvider` calls `t.evaluate()` UNCONDITIONALLY every frame the
//      panel is open (property_panel.d:72) -- the exact site the Stage CW
//      root-cause cites. That is the only path that can turn a stale
//      `paramsDirty` left over from a restore-fired `onParamChanged` into an
//      observable extra deform without any further user action, so it is the
//      mechanistically correct exemplar for a settle-only repro.

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
// Self-launched instance lifecycle
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
        "vibe3d_sticky_test_" ~ thisProcessID().to!string ~ "_" ~ inst.port.to!string);
    mkdirRecurse(inst.scratch);
    inst.logPath = buildPath(inst.scratch, "vibe3d.log");

    string[string] env;
    env["VIBE3D_CONFIG_DIR"] = inst.scratch;

    string[] argv = ["./vibe3d", "--test", "--http-port", inst.port.to!string];
    auto logFile = File(inst.logPath, "wb");
    inst.pid = spawnProcess(argv, stdin, logFile, logFile, env);

    inst.up = httpProbe(inst.baseUrl);
    if (!inst.up) {
        stderr.writefln("test_tool_sticky: instance on port %d failed to come up", inst.port);
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

// One self-launched instance for the whole tier (module ctor/dtor bracket
// every unittest in this file -- both run before/after user main() under
// -unittest, same as the unittests themselves).
__gshared Instance g_inst;

static this() {
    g_inst = launchInstance();
    assert(g_inst.up, "test_tool_sticky: failed to launch a self-hosted "
        ~ "vibe3d instance (run from the repo root; see " ~ g_inst.logPath ~ ")");
}

static ~this() {
    teardownInstance(g_inst);
}

// ---------------------------------------------------------------------------
// HTTP helpers -- identical idioms to the shared-harness tests, just bound to
// this file's self-launched instance instead of the module-level baseUrl.
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

struct V3 { double x, y, z; }

V3[] dumpVerts() {
    V3[] out_;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        out_ ~= V3(a[0].floating, a[1].floating, a[2].floating);
    }
    return out_;
}

bool vertsEqual(const V3[] a, const V3[] b, double eps = 1e-6) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length)
        if (!approxEqual(a[i].x, b[i].x, eps) || !approxEqual(a[i].y, b[i].y, eps)
            || !approxEqual(a[i].z, b[i].z, eps))
            return false;
    return true;
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

void selectEdges(long[] indices) {
    cmd("select.typeFrom edge");
    string arr = "[";
    foreach (i, idx; indices) { if (i) arr ~= ","; arr ~= idx.to!string; }
    arr ~= "]";
    auto j = postJson("/api/select", `{"mode":"edges","indices":` ~ arr ~ `}`);
    assert(j["status"].str == "ok", "edge select failed: " ~ j.toString);
}

// ---------------------------------------------------------------------------
// 1. A + C: a base/direct tool's genuine setting survives drop -> reactivate;
//    a transient (gesture-geometry) param does not.
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    cmd("tool.set mesh.sliceTool");
    // A genuine setting.
    cmd("tool.attr mesh.sliceTool snapAngle 30");
    // A transient (gesture) param -- the drawn cut-line start point.
    cmd("tool.attr mesh.sliceTool startX 7");

    // Drop -- captures sticky for BOTH (capture doesn't know intent; it's the
    // schema flag on the param that decides what's excluded).
    cmd("tool.set mesh.sliceTool off");

    // Reactivate -- restore should bring back snapAngle=30 (A) but leave
    // startX at its declared default -1 (C: excluded from capture, so
    // there's nothing to restore).
    cmd("tool.set mesh.sliceTool");

    auto snap = query("tool.attr mesh.sliceTool snapAngle ?");
    assert(approxEqual(snap.floating, 30.0),
        "A: snapAngle should persist across drop->reactivate as 30, got "
        ~ snap.toString);

    auto sx = query("tool.attr mesh.sliceTool startX ?");
    assert(approxEqual(sx.floating, -1.0),
        "C: transient startX must NOT persist -- should be back at its "
        ~ "declared default -1, got " ~ sx.toString);

    cmd("tool.set mesh.sliceTool off");
}

// ---------------------------------------------------------------------------
// 2. Stage CW regression: reactivating edge.slide (a CommandWrapper
//    deformer) must not re-run its deform purely from the sticky restore.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    selectEdges([0]);

    cmd("tool.set edge.slide");
    cmd("tool.attr edge.slide t 0.3");   // a genuine, real edit -> real slide
    auto v1 = dumpVerts();               // post-slide state -- the only
                                          // legitimate mutation in this test
    cmd("tool.set edge.slide off");      // commits it; captures sticky (t=0.3)

    auto undoAfterFirstDrop = undoCount();

    // Reactivate -- restore fires onParamChanged("t") with the SAME sticky
    // value BEFORE activate()/reinitSession() runs. Without the Stage CW fix
    // this leaves paramsDirty=true, which the property panel's UNCONDITIONAL
    // per-frame evaluate() (property_panel.d:72) would consume on the next
    // drawn frame -- re-running the slide a second time purely from having
    // reactivated the tool, with no further user action.
    cmd("tool.set edge.slide");

    // Open the Tool Properties panel (hidden by default under --test) and let
    // a few real frames render so evaluate() gets a chance to run.
    cmd("ui.toolProperties show");
    Thread.sleep(300.msecs);

    cmd("tool.set edge.slide off");

    auto vFinal = dumpVerts();
    assert(vertsEqual(v1, vFinal),
        "Stage CW: reactivate->drop must not move any vertex beyond the "
        ~ "legitimate first slide (v1) -- an extra deform crept in");

    auto undoFinal = undoCount();
    assert(undoFinal == undoAfterFirstDrop,
        "Stage CW: reactivate->drop must record NO undo entry (undo depth "
        ~ "was " ~ undoAfterFirstDrop.to!string ~ ", now " ~ undoFinal.to!string
        ~ ")");
}
