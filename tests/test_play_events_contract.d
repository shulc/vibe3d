// Task 5960 D2 production contract. Every cell launches its own app in a
// scratch cwd because recording.jsonl is relative and is the delivery oracle.

import core.sys.posix.signal : SIGKILL, SIGTERM, kill;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import http_command_helpers : commandBody;
import http_client;
import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, getcwd, mkdirRecurse, readText, rmdirRecurse, symlink;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.net.curl : HTTP, get, post;
import std.path : buildPath;
import std.process : Config, Pid, environment, spawnProcess, wait,
    thisProcessID;
import std.socket : AddressFamily, InternetAddress, ProtocolType, Socket,
    SocketType;
import std.stdio : File, stdin;
import std.string : splitLines;

void main() {}

private enum int kF1 = 1_073_741_882;
private enum int kF2 = 1_073_741_883;
private enum int kScanF1 = 58;
private enum int kScanF2 = 59;

private struct Instance {
    ushort port;
    string root;
    string base;
    string logPath;
    Pid pid;
}

private ushort pickFreePort() {
    auto socket = new Socket(AddressFamily.INET, SocketType.STREAM,
        ProtocolType.TCP);
    scope(exit) socket.close();
    socket.bind(new InternetAddress(InternetAddress.ADDR_ANY, cast(ushort) 0));
    return (cast(InternetAddress) socket.localAddress).port;
}

private Instance launch(string cell) {
    Instance instance;
    instance.port = pickFreePort();
    instance.root = buildPath("/tmp", "vibe3d_playback_contract_"
        ~ thisProcessID().to!string ~ "_" ~ instance.port.to!string ~ "_" ~ cell);
    mkdirRecurse(instance.root);
    instance.logPath = buildPath(instance.root, "vibe3d.log");
    instance.base = "http://127.0.0.1:" ~ instance.port.to!string;
    immutable repo = getcwd();
    symlink(buildPath(repo, "config"), buildPath(instance.root, "config"));
    symlink(buildPath(repo, "assets"), buildPath(instance.root, "assets"));
    string[string] childEnv;
    childEnv["VIBE3D_CONFIG_DIR"] = instance.root;
    auto logFile = File(instance.logPath, "wb");
    instance.pid = spawnProcess(
        [buildPath(repo, "vibe3d"), "--test", "--http-port",
         instance.port.to!string],
        stdin, logFile, logFile, childEnv, Config.none, instance.root);
    foreach (_; 0 .. 2400) {
        if (kill(instance.pid.processID, 0) != 0) break;
        try {
            auto registry = cast(string) get(instance.base ~ "/api/registry");
            if (registry.canFind(`"scene.reset"`)
                && kill(instance.pid.processID, 0) == 0)
                return instance;
        } catch (Exception) {}
        Thread.sleep(25.msecs);
    }
    assert(false, cell ~ " isolated app did not become ready; see "
        ~ instance.logPath);
    return instance;
}

private void stop(ref Instance instance) {
    if (instance.pid !is null) {
        try { kill(instance.pid.processID, SIGTERM); } catch (Exception) {}
        foreach (_; 0 .. 40) {
            if (kill(instance.pid.processID, 0) != 0) break;
            Thread.sleep(25.msecs);
        }
        if (kill(instance.pid.processID, 0) == 0)
            try { kill(instance.pid.processID, SIGKILL); } catch (Exception) {}
        try { wait(instance.pid); } catch (Exception) {}
    }
    if (instance.root.length && exists(instance.root))
        try { rmdirRecurse(instance.root); } catch (Exception) {}
}

private struct HttpReply { int code; string body_; }

private HttpReply sendPost(string url, string data,
                           string contentType = "application/json") {
    HttpReply reply;
    auto http = HTTP();
    http.method = HTTP.Method.post;
    http.url = url;
    http.setPostData(data, contentType);
    http.onReceive = (ubyte[] bytes) {
        reply.body_ ~= cast(string) bytes;
        return bytes.length;
    };
    http.onReceiveStatusLine = (HTTP.StatusLine line) {
        reply.code = line.code;
    };
    http.perform();
    return reply;
}

private JSONValue readJson(Instance instance, string path) {
    return http_client.getJson(path, instance.base);
}

private JSONValue postOkJson(Instance instance, string path, string data) {
    return http_client.postJson(path, data, instance.base);
}

private size_t field(JSONValue value, string key) {
    auto v = value[key];
    return v.type == JSONType.uinteger
        ? cast(size_t)v.uinteger : cast(size_t)v.integer;
}

private JSONValue waitFinished(Instance instance, size_t total,
                               size_t motions, string cell,
                               Duration budget = 8.seconds) {
    immutable deadline = MonoTime.currTime + budget;
    while (MonoTime.currTime < deadline) {
        auto status = readJson(instance, "/api/play-events/status");
        if (status["finished"].type == JSONType.true_) {
            assert(field(status, "total") == total
                && field(status, "remaining") == 0
                && field(status, "immediateMotions") == motions,
                cell ~ " playback population changed: " ~ status.toString());
            return status;
        }
        Thread.sleep(10.msecs);
    }
    assert(false, cell ~ " playback timed out");
    return JSONValue.init;
}

private string keyEvent(double t, int sym, int scan) {
    return format(
        `{"t":%.1f,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":0,"repeat":0}`,
        t, sym, scan);
}

unittest { // S1: finished is a production-sink delivery barrier
    auto instance = launch("s1");
    scope(exit) stop(instance);
    const log = keyEvent(0, kF1, kScanF1) ~ "\n"
        ~ `{"t":0,"type":"SDL_MOUSEMOTION","x":101,"y":102,"xrel":3,"yrel":4,"state":0,"mod":0}` ~ "\n"
        ~ `{"t":0,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":103,"y":104,"clicks":1,"mod":0}` ~ "\n"
        ~ `{"t":0,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":103,"y":104,"clicks":1,"mod":0}` ~ "\n"
        ~ keyEvent(0, 97, 4) ~ "\n"
        ~ `{"t":0,"type":"SDL_EVENT","sdl_type":32769}` ~ "\n"
        ~ keyEvent(0, kF2, kScanF2);
    auto accepted = sendPost(instance.base ~ "/api/play-events", log, "text/plain");
    assert(accepted.code == 200,
        "S1 populated mixed log was not accepted: " ~ accepted.body_);
    auto reply = parseJSON(accepted.body_);
    auto done = waitFinished(instance, 7, 1, "S1");
    assert(field(done, "generation") == field(reply, "generation"),
        "S1 status identity changed before completion");
    immutable recording = buildPath(instance.root, "recording.jsonl");
    assert(exists(recording),
        "S1 production sink did not create recording.jsonl");
    string[] types;
    foreach (line; readText(recording).splitLines()) {
        auto event = parseJSON(line);
        if (event["type"].str != "VIEWPORT") types ~= event["type"].str;
    }
    assert(types.length == 5,
        "S1 production recorder population must be five non-control events");
    assert(types == ["SDL_MOUSEMOTION", "SDL_MOUSEBUTTONDOWN",
                     "SDL_MOUSEBUTTONUP", "SDL_KEYDOWN", "SDL_EVENT"],
        "S1 production sink lost or reordered a mixed event: " ~ types.to!string);
}

unittest { // S2: first status belongs to the POST generation
    auto instance = launch("s2");
    scope(exit) stop(instance);
    foreach (round; 0 .. 50) {
        auto accepted = sendPost(instance.base ~ "/api/play-events",
            format(`{"t":0,"type":"SDL_MOUSEMOTION","x":%d,"y":2,"xrel":0,"yrel":0,"state":0,"mod":0}`,
                   round), "text/plain");
        assert(accepted.code == 200,
            "S2 populated round was not accepted: " ~ accepted.body_);
        auto reply = parseJSON(accepted.body_);
        auto first = readJson(instance, "/api/play-events/status");
        assert(field(first, "generation") == field(reply, "generation"),
            "S2 first status generation differed from the POST reply");
    }
}

private string replacementALog() {
    string result = keyEvent(0, kF1, kScanF1) ~ "\n";
    foreach (i; 0 .. 20)
        result ~= format(
            `{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":11,"xrel":1,"yrel":0,"state":0,"mod":0}` ~ "\n",
            50 + i * 100, i);
    return result;
}

private string replacementBLog() {
    string result;
    foreach (i; 0 .. 2000)
        result ~= format(
            `{"t":0,"type":"SDL_MOUSEMOTION","x":%d,"y":22,"xrel":1,"yrel":0,"state":0,"mod":0}` ~ "\n",
            i);
    return result ~ keyEvent(0, kF2, kScanF2);
}

unittest { // S3 preservation: production sink keeps B ordered and single-delivered; U5 witnesses the former double delivery
    auto instance = launch("s3");
    scope(exit) stop(instance);
    foreach (round; 0 .. 20) {
        auto a = sendPost(instance.base ~ "/api/play-events",
                         replacementALog(), "text/plain");
        assert(a.code == 200, "S3 A was not accepted: " ~ a.body_);
        immutable progressDeadline = MonoTime.currTime + 2.seconds;
        size_t aDelivered;
        while (MonoTime.currTime < progressDeadline) {
            auto state = readJson(instance, "/api/play-events/status");
            aDelivered = field(state, "immediateMotions");
            if (aDelivered >= 1 && state["finished"].type == JSONType.false_)
                break;
            Thread.sleep(5.msecs);
        }
        assert(aDelivered >= 1,
            "S3 population floor: A delivered no motion before replacement");
        auto b = sendPost(instance.base ~ "/api/play-events",
                         replacementBLog(), "text/plain");
        assert(b.code == 200, "S3 B was not accepted: " ~ b.body_);
        auto bReply = parseJSON(b.body_);
        assert(field(bReply, "replaced") != 0,
            "S3 B did not report an active replaced generation");
        waitFinished(instance, 2001, 2000, "S3", 12.seconds);

        immutable recording = buildPath(instance.root, "recording.jsonl");
        assert(exists(recording),
            "S3 production-sink recorder witness is missing");
        size_t seenA, seenB;
        int expectedB;
        bool bStarted;
        foreach (line; readText(recording).splitLines()) {
            auto event = parseJSON(line);
            if (event["type"].str != "SDL_MOUSEMOTION") continue;
            immutable y = cast(int)event["y"].integer;
            if (y == 11) {
                assert(!bStarted, "S3 delivered an A event after B began");
                ++seenA;
            } else if (y == 22) {
                bStarted = true;
                immutable x = cast(int)event["x"].integer;
                assert(x == expectedB,
                    format("S3 B order/duplication changed at %d: got %d",
                           expectedB, x));
                ++expectedB;
                ++seenB;
            }
        }
        assert(seenA >= 1,
            "S3 recorder floor: no A event preceded B");
        assert(seenB == 2000 && expectedB == 2000,
            format("S3 production-sink recorder saw %d/2000 B events", seenB));
    }
}

private string stripScene() {
    string vertices = "[";
    foreach (i; 0 .. 7) {
        immutable double x = -1.5 + 0.5 * i;
        if (i) vertices ~= ",";
        vertices ~= format("[%.4f,-0.25,0.0],[%.4f,0.25,0.0]", x, x);
    }
    vertices ~= ",[0.10,-0.15,-1.0],[0.50,-0.15,-1.0],[0.30,0.15,-1.0]]";
    string faces = "[";
    foreach (i; 0 .. 6) {
        if (i) faces ~= ",";
        faces ~= format("[%d,%d,%d,%d]", 2*i, 2*i + 2, 2*i + 3, 2*i + 1);
    }
    return `{"vertices":` ~ vertices ~ `,"faces":` ~ faces ~ `,[14,15,16]]}`;
}

private void command(Instance instance, string body_) {
    auto reply = postOkJson(instance, "/api/command", body_);
    assert(reply["status"].str == "ok",
        "S6 setup command failed: " ~ reply.toString());
}

private void releaseHold(ref Instance instance) nothrow {
    try {
        postOkJson(instance, "/api/subpatch/hold",
                 `{"ms":0,"ceilingMs":15000}`);
    } catch (Exception) {}
}

unittest { // S6 preservation: hold gates delivery, not owned load acceptance
    auto instance = launch("s6");
    scope(exit) stop(instance);
    command(instance, commandBody("scene.reset"));
    command(instance, commandBody("scene.loadMesh", stripScene()));
    command(instance, "select.typeFrom polygon");
    command(instance, commandBody("mesh.select",
        `{"mode":"polygons","indices":[0,1,2,3,4,5,6]}`));
    command(instance, commandBody("mesh.subpatch_toggle"));
    command(instance, commandBody("mesh.select",
        `{"mode":"polygons","indices":[]}`));
    foreach (_; 0 .. 1500) {
        if (readJson(instance, "/api/subpatch/preview")["pending"].type
            == JSONType.false_) break;
        Thread.sleep(20.msecs);
    }
    auto held = postOkJson(instance, "/api/subpatch/hold",
                         `{"ms":6000,"ceilingMs":15000}`);
    assert(held["status"].str == "ok", "S6 hold did not arm");
    scope(exit) releaseHold(instance);
    command(instance, commandBody("mesh.select",
        `{"mode":"polygons","indices":[0,2,4]}`));
    command(instance, commandBody("mesh.hide"));
    assert(readJson(instance, "/api/subpatch/preview")["pending"].type
        == JSONType.true_, "S6 population floor: no held preview build");

    string log;
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":1,"yrel":1,"state":0,"mod":0}` ~ "\n",
            100 + i * 300, 50 + i, 60 + i);
    immutable postedAt = MonoTime.currTime;
    auto accepted = sendPost(instance.base ~ "/api/play-events", log, "text/plain");
    immutable postMs = (MonoTime.currTime - postedAt).total!"msecs";
    assert(accepted.code == 200 && postMs < 5000,
        format("S6 hold blocked owned acceptance for %dms: %s", postMs,
               accepted.body_));
    auto during = readJson(instance, "/api/play-events/status");
    assert(during["finished"].type == JSONType.false_
        && field(during, "total") == 5
        && field(during, "remaining") == 5
        && field(during, "immediateMotions") == 0,
        "S6 hold delivered input before the build landed: " ~ during.toString());
    // Natural release still preserves one due-event burst, but this cell does
    // not test burst cardinality: status exposes only the completed aggregate.
    auto done = waitFinished(instance, 5, 5, "S6", 12.seconds);
    assert(field(done, "generation")
        == field(parseJSON(accepted.body_), "generation"),
        "S6 accepted generation changed across the hold");
}
