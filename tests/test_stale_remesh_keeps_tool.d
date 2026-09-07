// A remesh helper works from the snapshot captured at start. If another
// command replaces that mesh before the helper finishes, consuming the stale
// result must not enter the Model-command funnel and drop the tool that is
// active at completion time.

import http_client : postJson;
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
import core.time : MonoTime, msecs, seconds;

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
    string releasePath;
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
                     string secondReleasePath) {
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
      ~ "else\n"
      ~ "  while [ ! -e \"" ~ secondReleasePath ~ "\" ]; do sleep 0.05; done\n"
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
    instance.releasePath = buildPath(instance.scratch, "release-first");

    const helperPath = buildPath(instance.scratch, "fake-remesher.sh");
    const markerPath = buildPath(instance.scratch, "first-started");
    const secondReleasePath = buildPath(instance.scratch, "release-second");
    writeFakeHelper(helperPath, markerPath, instance.releasePath,
        secondReleasePath);

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

static this() {
    g_instance = launchInstance();
    assert(g_instance.up,
        "failed to launch the isolated remesh test instance; see "
        ~ g_instance.logPath);
    environment["VIBE3D_TEST_PORT"] = g_instance.port.to!string;
}

static ~this() {
    teardownInstance(g_instance);
}

unittest {
    auto response = postJson("/api/command", commandBody("scene.reset"));
    assert(response["status"].str == "ok", response.toString);

    response = postJson("/api/command", "mesh.remesh.start");
    assert(response["status"].str == "ok", response.toString);

    // Replace the captured mesh, then arm the tool before allowing the helper
    // to finish. This fixes the ordering instead of racing the helper.
    response = postJson("/api/command", commandBody("scene.reset"));
    assert(response["status"].str == "ok", response.toString);
    response = postJson("/api/command",
        `{"id":"tool.reset","params":{"_positional":["` ~ TOOL ~ `"]}}`);
    assert(response["status"].str == "ok", response.toString);
    write(g_instance.releasePath, "");

    // RemeshStart refuses while the first job is live. Its first success is
    // the observable proof that the stale completion was consumed. The fake
    // helper deliberately holds this second job so it cannot race the check.
    bool completed;
    const deadline = MonoTime.currTime + 10.seconds;
    while (!completed && MonoTime.currTime < deadline) {
        response = postJson("/api/command", "mesh.remesh.start");
        completed = response["status"].str == "ok";
        if (!completed) Thread.sleep(10.msecs);
    }
    assert(completed,
        "the stale remesh result was not consumed within the 10-second budget");

    response = postJson("/api/command",
        `{"id":"tool.attr","params":{"_positional":["` ~ TOOL
        ~ `","mergeVerts","false"]}}`);
    assert(response["status"].str == "ok",
        "stale remesh landing dropped the active tool: " ~ response.toString);
}
