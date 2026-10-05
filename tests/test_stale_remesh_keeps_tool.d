// A remesh helper works from the snapshot captured at start. If another
// command replaces that mesh before the helper finishes, consuming the stale
// result must not enter the Model-command funnel and drop the tool that is
// active at completion time.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : octal, to;
import std.file : exists, mkdirRecurse, rmdirRecurse, setAttributes, tempDir,
    write;
import std.net.curl : get;
import std.path : buildPath;
import std.process : environment, Pid, spawnProcess, thisProcessID, wait;
import std.socket : AddressFamily, InternetAddress, ProtocolType, Socket,
    SocketType;
import std.stdio : File, stdin;

import core.sys.posix.signal : kill, SIGKILL, SIGTERM;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;

void main() {}

enum string TOOL = "mesh.mirrorTool";

ushort pickFreePort() {
    auto socket = new Socket(AddressFamily.INET, SocketType.STREAM,
        ProtocolType.TCP);
    scope(exit) socket.close();
    socket.bind(new InternetAddress(InternetAddress.ADDR_ANY, cast(ushort) 0));
    return (cast(InternetAddress) socket.localAddress).port;
}

struct Instance {
    ushort port;
    string scratch;
    string logPath;
    string markerPath;
    string releasePath;
    string secondMarkerPath;
    string secondReleasePath;
    Pid pid;
    bool up;
}

bool httpProbe(string baseUrl, int tries = 100) {
    foreach (_; 0 .. tries) {
        try {
            get(baseUrl ~ "/api/camera");
            return true;
        } catch (Exception) {}
        Thread.sleep(100.msecs);
    }
    return false;
}

void writeFakeHelper(string path, string markerPath, string releasePath,
                     string secondMarkerPath, string secondReleasePath,
                     string thirdReleasePath) {
    write(path,
        "#!/bin/sh\n"
      ~ "out=\"\"\n"
      ~ "while [ $# -gt 0 ]; do\n"
      ~ "  if [ \"$1\" = \"--output\" ]; then shift; out=\"$1\"; fi\n"
      ~ "  shift\n"
      ~ "done\n"
      ~ "if [ ! -e \"" ~ markerPath ~ "\" ]; then\n"
      ~ "  : > \"" ~ markerPath ~ "\"\n"
      ~ "  while [ ! -e \"" ~ releasePath ~ "\" ]; do sleep 0.01; done\n"
      ~ "elif [ ! -e \"" ~ secondMarkerPath ~ "\" ]; then\n"
      ~ "  : > \"" ~ secondMarkerPath ~ "\"\n"
      ~ "  while [ ! -e \"" ~ secondReleasePath ~ "\" ]; do sleep 0.01; done\n"
      ~ "else\n"
      ~ "  while [ ! -e \"" ~ thirdReleasePath ~ "\" ]; do sleep 0.05; done\n"
      ~ "fi\n"
      ~ "printf 'v 0 0 0\\nv 1 0 0\\nv 1 1 0\\nv 0 1 0\\nf 1 2 3 4\\n' > \"$out\"\n"
      ~ "exit 0\n");
    setAttributes(path, octal!755);
}

Instance launchInstance() {
    Instance instance;
    instance.port = pickFreePort();
    instance.scratch = buildPath(tempDir(),
        "vibe3d_stale_remesh_test_" ~ thisProcessID.to!string ~ "_"
        ~ instance.port.to!string);
    mkdirRecurse(instance.scratch);
    instance.logPath = buildPath(instance.scratch, "vibe3d.log");
    instance.markerPath = buildPath(instance.scratch, "first-started");
    instance.releasePath = buildPath(instance.scratch, "release-first");
    instance.secondMarkerPath = buildPath(instance.scratch, "second-started");
    instance.secondReleasePath = buildPath(instance.scratch, "release-second");

    const helperPath = buildPath(instance.scratch, "fake-remesher.sh");
    const thirdReleasePath = buildPath(instance.scratch, "release-third");
    writeFakeHelper(helperPath, instance.markerPath, instance.releasePath,
        instance.secondMarkerPath, instance.secondReleasePath,
        thirdReleasePath);

    string[string] childEnv;
    childEnv["VIBE3D_AUTOREMESHER_BIN"] = helperPath;

    auto logFile = File(instance.logPath, "wb");
    instance.pid = spawnProcess([
        "./vibe3d", "--test", "--http-port", instance.port.to!string,
    ], stdin, logFile, logFile, childEnv);

    const baseUrl = "http://localhost:" ~ instance.port.to!string;
    instance.up = httpProbe(baseUrl);
    return instance;
}

void teardownInstance(ref Instance instance) {
    if (instance.pid !is null) {
        try kill(instance.pid.processID, SIGTERM); catch (Exception) {}
        bool dead;
        foreach (_; 0 .. 20) {
            Thread.sleep(50.msecs);
            if (kill(instance.pid.processID, 0) != 0) {
                dead = true;
                break;
            }
        }
        if (!dead) try kill(instance.pid.processID, SIGKILL); catch (Exception) {}
        try wait(instance.pid); catch (Exception) {}
    }
    if (instance.scratch.length && exists(instance.scratch)) {
        try rmdirRecurse(instance.scratch); catch (Exception) {}
    }
}

__gshared Instance g_instance;

shared static this() {
    g_instance = launchInstance();
    assert(g_instance.up,
        "failed to launch the isolated remesh test instance; see "
        ~ g_instance.logPath);
    environment["VIBE3D_TEST_PORT"] = g_instance.port.to!string;
}

shared static ~this() {
    teardownInstance(g_instance);
}

void waitForMarker(string markerPath, Duration timeout) {
    const deadline = MonoTime.currTime + timeout;
    while (!exists(markerPath) && MonoTime.currTime < deadline)
        Thread.sleep(10.msecs);
}

unittest {
    auto response = postJson("/api/command", commandBody("scene.reset"));
    assert(response["status"].str == "ok", response.toString);

    response = postJson("/api/command", "mesh.remesh.start");
    assert(response["status"].str == "ok", response.toString);
    waitForMarker(g_instance.markerPath, 2.seconds);
    assert(exists(g_instance.markerPath),
        "the fresh remesh helper did not start within the 2-second budget");

    response = postJson("/api/command",
        `{"id":"tool.reset","params":{"_positional":["` ~ TOOL ~ `"]}}`);
    assert(response["status"].str == "ok", response.toString);
    response = postJson("/api/command",
        `{"id":"tool.attr","params":{"_positional":["` ~ TOOL
        ~ `","mergeVerts","false"]}}`);
    assert(response["status"].str == "ok",
        "the fresh-result control could not engage the mirror tool: "
        ~ response.toString);
    response = postJson("/api/command",
        "tool.attr " ~ TOOL ~ " mergeVerts ?");
    assert(response["status"].str == "ok",
        "the fresh-result control must arm the mirror tool: " ~ response.toString);
    write(g_instance.releasePath, "");

    // Positive control: an unchanged source must accept the helper's quad.
    // Keep this before the stale-result arm so a `sourceMatches => false`
    // mutation proves acceptance without hiding the rejection assertions.
    bool applied;
    auto deadline = MonoTime.currTime + 10.seconds;
    while (!applied && MonoTime.currTime < deadline) {
        auto model = getJson("/api/model");
        applied = model["vertices"].array.length == 4;
        if (!applied) Thread.sleep(10.msecs);
    }
    assert(applied,
        "a fresh remesh result was not applied within the 10-second budget");
    auto model = getJson("/api/model");
    assert(model["vertices"].array.length == 4,
        "a fresh remesh result must produce the helper's four-vertex quad");
    assert(model["faces"].array.length == 1,
        "a fresh remesh result must produce the helper's one-face quad");

    response = postJson("/api/command", commandBody("scene.reset"));
    assert(response["status"].str == "ok", response.toString);
    response = postJson("/api/command", "mesh.remesh.start");
    assert(response["status"].str == "ok", response.toString);
    const markerPath = g_instance.secondMarkerPath;
    waitForMarker(markerPath, 2.seconds);
    assert(exists(markerPath),
        "the stale remesh helper did not start within the 2-second budget");

    // Replace the captured mesh, then arm the tool before allowing the helper
    // to finish. This fixes the ordering instead of racing the helper.
    response = postJson("/api/command", commandBody("scene.reset"));
    assert(response["status"].str == "ok", response.toString);
    response = postJson("/api/command",
        `{"id":"tool.reset","params":{"_positional":["` ~ TOOL ~ `"]}}`);
    assert(response["status"].str == "ok", response.toString);
    response = postJson("/api/command",
        `{"id":"tool.attr","params":{"_positional":["` ~ TOOL
        ~ `","mergeVerts","false"]}}`);
    assert(response["status"].str == "ok",
        "the stale-result arm could not engage the mirror tool: "
        ~ response.toString);
    response = postJson("/api/command",
        "tool.attr " ~ TOOL ~ " mergeVerts ?");
    assert(response["status"].str == "ok",
        "the stale-result arm must have a live mirror tool: " ~ response.toString);
    write(g_instance.secondReleasePath, "");

    // RemeshStart refuses while the first job is live. Its first success is
    // the observable proof that the stale completion was consumed. The fake
    // helper deliberately holds this second job so it cannot race the check.
    bool completed;
    deadline = MonoTime.currTime + 10.seconds;
    while (!completed && MonoTime.currTime < deadline) {
        response = postJson("/api/command", "mesh.remesh.start");
        completed = response["status"].str == "ok";
        if (!completed) Thread.sleep(10.msecs);
    }
    assert(completed,
        "the stale remesh result was not consumed within the 10-second budget");

    model = getJson("/api/model");
    assert(model["vertices"].array.length == 8,
        "discarding a stale remesh result must leave the cube's eight vertices");
    assert(model["faces"].array.length == 6,
        "discarding a stale remesh result must leave the cube's six faces");

    response = postJson("/api/command",
        `{"id":"tool.attr","params":{"_positional":["` ~ TOOL
        ~ `","mergeVerts","false"]}}`);
    assert(response["status"].str == "ok",
        "stale remesh landing dropped the active tool: " ~ response.toString);
}
