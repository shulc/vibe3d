// Task 5960 D1. This suite cell owns a separate app whose cwd is its scratch
// directory: F1 writes recording.jsonl relatively, so sharing the runner cwd
// would let parallel workers overwrite the viewport-remap witness.

import http_client : getJson, testBaseUrl;
import std.algorithm : canFind;
import std.conv      : to;
import std.datetime.stopwatch : MonoTime;
import std.file      : exists, getcwd, mkdirRecurse, readText, rmdirRecurse,
                       symlink;
import std.format    : format;
import std.json      : JSONType, JSONValue, parseJSON;
import std.net.curl  : get, HTTP;
import std.path      : buildPath;
import std.process   : Config, Pid, environment, spawnProcess, thisProcessID, wait;
import std.socket    : AddressFamily, InternetAddress, ProtocolType, Socket,
                       SocketType;
import std.stdio     : File, stdin;
import std.string    : splitLines;

import core.sys.posix.signal : kill, SIGKILL, SIGTERM;
import core.thread : Thread;
import core.time   : msecs, seconds;

void main() {}

private enum int kF1 = 1_073_741_882;
private enum int kF2 = 1_073_741_883;
private enum int kScanF1 = 58;
private enum int kScanF2 = 59;
private enum uint kLeftCtrl = 64;

private struct Instance {
    ushort port;
    string scratch;
    string logPath;
    Pid pid;
    bool ready;
}

private ushort pickFreePort()
{
    auto socket = new Socket(AddressFamily.INET, SocketType.STREAM,
        ProtocolType.TCP);
    scope(exit) socket.close();
    socket.bind(new InternetAddress(InternetAddress.ADDR_ANY, cast(ushort)0));
    return (cast(InternetAddress)socket.localAddress).port;
}

private bool httpProbe(string baseUrl, Pid pid)
{
    foreach (_; 0 .. 600) {
        if (kill(pid.processID, 0) != 0) return false;
        try {
            const body = cast(string)get(baseUrl ~ "/api/registry");
            if (body.canFind(`"scene.reset"`)
                && kill(pid.processID, 0) == 0)
                return true;
        } catch (Exception) {}
        Thread.sleep(25.msecs);
    }
    return false;
}

private Instance launchInstance()
{
    Instance instance;
    instance.port = pickFreePort();
    instance.scratch = buildPath("/tmp", "vibe3d_rejected_play_events_"
        ~ thisProcessID().to!string ~ "_" ~ instance.port.to!string);
    mkdirRecurse(instance.scratch);
    instance.logPath = buildPath(instance.scratch, "vibe3d.log");

    const repoRoot = getcwd();
    const binary = buildPath(repoRoot, "vibe3d");
    symlink(buildPath(repoRoot, "config"),
            buildPath(instance.scratch, "config"));
    symlink(buildPath(repoRoot, "assets"),
            buildPath(instance.scratch, "assets"));
    string[string] childEnv;
    childEnv["VIBE3D_CONFIG_DIR"] = instance.scratch;
    auto logFile = File(instance.logPath, "wb");
    instance.pid = spawnProcess(
        [binary, "--test", "--http-port", instance.port.to!string],
        stdin, logFile, logFile, childEnv, Config.none, instance.scratch);

    const baseUrl = "http://localhost:" ~ instance.port.to!string;
    instance.ready = httpProbe(baseUrl, instance.pid);
    return instance;
}

private void teardownInstance(ref Instance instance)
{
    if (instance.pid !is null) {
        try { kill(instance.pid.processID, SIGTERM); } catch (Exception) {}
        bool dead;
        foreach (_; 0 .. 20) {
            Thread.sleep(50.msecs);
            if (kill(instance.pid.processID, 0) != 0) {
                dead = true;
                break;
            }
        }
        if (!dead) try { kill(instance.pid.processID, SIGKILL); }
                   catch (Exception) {}
        try { wait(instance.pid); } catch (Exception) {}
    }
    if (instance.scratch.length && exists(instance.scratch))
        try { rmdirRecurse(instance.scratch); } catch (Exception) {}
}

private __gshared Instance g_instance;

shared static this()
{
    g_instance = launchInstance();
    assert(g_instance.ready,
        "S1 isolated app did not become ready; see " ~ g_instance.logPath);
    environment["VIBE3D_TEST_PORT"] = g_instance.port.to!string;
}

shared static ~this()
{
    teardownInstance(g_instance);
}

private struct Reply {
    int code;
    string body_;
}

private Reply postAllowing400(string body_)
{
    Reply reply;
    auto http = HTTP();
    http.method = HTTP.Method.post;
    http.url = testBaseUrl() ~ "/api/play-events";
    http.setPostData(body_, "text/plain");
    http.onReceive = (ubyte[] data) {
        reply.body_ ~= cast(string)data;
        return data.length;
    };
    http.onReceiveStatusLine = (HTTP.StatusLine line) {
        reply.code = line.code;
    };
    http.perform();
    return reply;
}

private size_t field(JSONValue status, string name)
{
    return cast(size_t)status[name].integer;
}

private uint currentMods()
{
    return cast(uint)getJson("/api/buttons/availability")["mods"].integer;
}

private JSONValue waitForProgress()
{
    const deadline = MonoTime.currTime + 2.seconds;
    JSONValue status;
    while (MonoTime.currTime < deadline) {
        status = getJson("/api/play-events/status");
        if (status["finished"].type == JSONType.false_
            && field(status, "total") == 7
            && field(status, "immediateMotions") >= 1
            && field(status, "remaining") >= 1)
            return status;
        Thread.sleep(10.msecs);
    }
    assert(false, "S1 population floor: long playback never reached a running "
        ~ "state after at least one of its three motions");
    return status;
}

private JSONValue waitFinished(size_t total, size_t motions, string cell)
{
    const deadline = MonoTime.currTime + 5.seconds;
    JSONValue status;
    while (MonoTime.currTime < deadline) {
        status = getJson("/api/play-events/status");
        if (status["finished"].type == JSONType.true_) {
            assert(field(status, "total") == total
                && field(status, "remaining") == 0
                && field(status, "immediateMotions") == motions,
                cell ~ ": finished with the wrong event population: "
                ~ status.toString);
            return status;
        }
        Thread.sleep(10.msecs);
    }
    assert(false, cell ~ ": playback did not finish within five seconds");
    return status;
}

private void assertRejectedWithoutEffect(string cell, string body_)
{
    // WHEN: snapshot immediately before and after the rejected POST while the
    // seven-event playback is still active. Only monotonic progress may differ.
    const before = getJson("/api/play-events/status");
    assert(before["finished"].type == JSONType.false_
        && field(before, "total") == 7 && field(before, "remaining") >= 1,
        cell ~ " precondition: expected the populated long playback to be running");
    assert(currentMods() == kLeftCtrl,
        cell ~ " precondition: the populated playback must hold Ctrl");

    const reply = postAllowing400(body_);
    assert(reply.code == 400,
        cell ~ ": rejected body must answer HTTP 400, got " ~ reply.code.to!string);
    const after = getJson("/api/play-events/status");
    assert(after["finished"].type == JSONType.false_
        && field(after, "total") == 7 && field(after, "remaining") >= 1
        && field(after, "remaining") <= field(before, "remaining")
        && field(after, "immediateMotions") >= field(before, "immediateMotions"),
        cell ~ ": 400 changed playback state beyond ordinary progress: before="
        ~ before.toString ~ " after=" ~ after.toString);
    assert(currentMods() == kLeftCtrl,
        cell ~ ": rejected load changed the active playback's Ctrl modifier");
}

unittest // S1 WHAT: rejected garbage/empty loads have zero production side effects
{
    // WHEN: A is a seven-event, three-motion playback with a known remap. Its
    // one-second gaps keep both 400 probes between the first and second motion.
    const longLog =
        `{"t":0,"type":"VIEWPORT","vpX":0,"vpY":0,"vpW":1300,"vpH":1088,"fovY":0.785398}` ~ "\n" ~
        format(`{"t":0,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":0,"repeat":0}`,
               kF1, kScanF1) ~ "\n" ~
        format(`{"t":25,"type":"SDL_MOUSEMOTION","x":300,"y":200,"xrel":1,"yrel":1,"state":0,"mod":%d}`,
               kLeftCtrl) ~ "\n" ~
        format(`{"t":1000,"type":"SDL_MOUSEMOTION","x":310,"y":210,"xrel":1,"yrel":1,"state":0,"mod":%d}`,
               kLeftCtrl) ~ "\n" ~
        format(`{"t":2000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":320,"y":220,"clicks":1,"mod":%d}`,
               kLeftCtrl) ~ "\n" ~
        format(`{"t":2100,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":320,"y":220,"clicks":1,"mod":%d}`,
               kLeftCtrl) ~ "\n" ~
        format(`{"t":2800,"type":"SDL_MOUSEMOTION","x":330,"y":230,"xrel":1,"yrel":1,"state":0,"mod":%d}`,
               kLeftCtrl) ~ "\n" ~
        format(`{"t":3000,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":0,"repeat":0}`,
               kF2, kScanF2);

    const accepted = postAllowing400(longLog);
    assert(accepted.code == 200,
        "S1 population floor: seven-event long playback was not accepted");
    const running = waitForProgress();
    assert(field(running, "total") == 7
        && field(running, "immediateMotions") >= 1,
        "S1 population floor: expected seven events and at least one delivered motion");

    const viewportGarbage = "not json\n"
        ~ `{"t":0,"type":"VIEWPORT","vpX":0,"vpY":0,"vpW":100,"vpH":100,"fovY":0.785398}`;
    assertRejectedWithoutEffect("S1 garbage", viewportGarbage);
    assertRejectedWithoutEffect("S1 empty", "");

    // WHEN: the original playback reaches its own F2. This proves both 400s
    // preserved its tail and that no modifier was leaked at completion.
    waitFinished(7, 3, "S1 original playback");
    assert(currentMods() == 0,
        "S1 original playback completion left a modifier held");

    // WHEN: a later valid three-event log omits VIEWPORT. It must inherit A's
    // 1300x1088 remap, deliver exactly one Ctrl motion, close F2, and release Ctrl.
    const laterLog =
        format(`{"t":0,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":0,"repeat":0}`,
               kF1, kScanF1) ~ "\n" ~
        format(`{"t":25,"type":"SDL_MOUSEMOTION","x":300,"y":200,"xrel":4,"yrel":2,"state":0,"mod":%d}`,
               kLeftCtrl) ~ "\n" ~
        format(`{"t":50,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":0,"repeat":0}`,
               kF2, kScanF2);
    assert(postAllowing400(laterLog).code == 200,
        "S1 later-valid population floor: three-event log was not accepted");
    waitFinished(3, 1, "S1 later valid playback");
    assert(currentMods() == 0,
        "S1 later valid playback did not release its borrowed Ctrl modifier");

    const recordingPath = buildPath(g_instance.scratch, "recording.jsonl");
    assert(exists(recordingPath),
        "S1 viewport witness: later F1/F2 produced no recording.jsonl");
    size_t motions;
    int recordedX, recordedY;
    foreach (line; readText(recordingPath).splitLines()) {
        const event = parseJSON(line);
        if (event["type"].str != "SDL_MOUSEMOTION") continue;
        ++motions;
        recordedX = cast(int)event["x"].integer;
        recordedY = cast(int)event["y"].integer;
    }
    assert(motions == 1,
        "S1 viewport population floor: later recording must contain exactly one motion");
    assert(recordedX == 300 && recordedY == 128,
        format("S1 rejected VIEWPORT changed inherited remap: recorded (%d,%d)",
               recordedX, recordedY));
}
