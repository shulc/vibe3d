// Task 5940: the production `/api/tool/state` route is served by an owned
// main-thread request. This self-hosted cell widens the arm-to-update seam and
// drives the real registration, command, refire and drop wiring.
module test_tool_state_owned_route;

import core.sys.posix.signal : kill, SIGKILL, SIGTERM;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import http_client : sharedGetJson = getJson;
import std.algorithm : canFind;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.exception : collectException;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.process : Pid, spawnProcess, thisProcessID, tryWait, wait;
import std.socket : AddressFamily, InternetAddress, ProtocolType, Socket,
    SocketOption, SocketOptionLevel, SocketType, TcpSocket;
import std.stdio : File, stdin;
import std.string : indexOf;

void main() {}

private struct Reply {
    string code;
    string body;
}

private Reply request(ushort port, string method, string path, string body) {
    auto socket = new TcpSocket();
    scope(exit) socket.close();
    socket.connect(new InternetAddress("127.0.0.1", port));
    socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO,
                     10.seconds);
    string wire = method ~ " " ~ path ~ " HTTP/1.1\r\n"
                ~ "Host: 127.0.0.1\r\nConnection: close\r\n";
    if (body.length)
        wire ~= "Content-Type: application/json\r\nContent-Length: "
              ~ body.length.to!string ~ "\r\n";
    wire ~= "\r\n" ~ body;
    socket.send(cast(const(void)[])wire);
    char[16384] buffer;
    string response;
    for (;;) {
        auto n = socket.receive(buffer[]);
        if (n <= 0) break;
        response ~= buffer[0 .. n].idup;
    }
    immutable firstSpace = response.indexOf(' ');
    immutable split = response.indexOf("\r\n\r\n");
    assert(firstSpace >= 0 && split >= 0,
        "5940 live HTTP response is malformed: " ~ response);
    return Reply(response[firstSpace + 1 .. firstSpace + 4].idup,
                 response[split + 4 .. $].idup);
}

private ushort pickFreePort() {
    auto socket = new Socket(AddressFamily.INET, SocketType.STREAM,
                             ProtocolType.TCP);
    scope(exit) socket.close();
    socket.bind(new InternetAddress(InternetAddress.ADDR_ANY, cast(ushort)0));
    return (cast(InternetAddress)socket.localAddress).port;
}

private void stopOwned(Pid pid) {
    try kill(pid.processID, SIGTERM); catch (Exception) {}
    foreach (_; 0 .. 200) {
        if (tryWait(pid).terminated) return;
        Thread.sleep(25.msecs);
    }
    try kill(pid.processID, SIGKILL); catch (Exception) {}
    try wait(pid); catch (Exception) {}
}

private JSONValue command(ushort port, string line,
                          string path = "/api/command") {
    auto reply = request(port, "POST", path, line);
    assert(reply.code == "200",
        "5940 live command HTTP status " ~ reply.code ~ ": " ~ reply.body);
    auto result = parseJSON(reply.body);
    assert(result["status"].str == "ok",
        "5940 live command failed: " ~ line ~ " -> " ~ reply.body);
    return result;
}

private JSONValue fetchJson(ushort port, string path) {
    return sharedGetJson(path, "http://localhost:" ~ port.to!string);
}

private double number(JSONValue value) {
    import std.json : JSONType;
    return value.type == JSONType.integer
        ? cast(double)value.integer : value.floating;
}

private double pivotX(JSONValue state) {
    return number(state["pivot"].array[0]);
}

unittest {
    immutable port = pickFreePort();
    immutable scratch = buildPath("/tmp", "vibe3d_tool_state_owned_"
        ~ thisProcessID().to!string ~ "_" ~ port.to!string);
    mkdirRecurse(scratch);
    immutable logPath = buildPath(scratch, "vibe3d.log");
    string[string] env;
    env["VIBE3D_CONFIG_DIR"] = scratch;
    env["VIBE3D_STALL_PRE_TOOL_TICK_MS"] = "400";
    auto logFile = File(logPath, "wb");
    auto pid = spawnProcess(
        ["./vibe3d", "--test", "--http-port", port.to!string],
        stdin, logFile, logFile, env);
    scope(exit) {
        stopOwned(pid);
        logFile.close();
        if (exists(scratch))
            cast(void) collectException(rmdirRecurse(scratch));
    }

    bool ready;
    string lastProbe;
    auto readiness = StopWatch(AutoStart.yes);
    while (readiness.peek.total!"msecs" < 60_000) {
        try {
            auto probe = request(port, "GET", "/api/registry", "");
            lastProbe = probe.code ~ " " ~ probe.body;
            if (probe.code == "200" && probe.body.canFind(`"file.save"`)) {
                ready = true;
                break;
            }
        } catch (Exception e) {
            lastProbe = e.msg;
        }
        Thread.sleep(20.msecs);
    }
    assert(ready, "5940 live instance was not ready: " ~ lastProbe);

    // L0: no active tool is the exact legacy empty object.
    auto idle = request(port, "GET", "/api/tool/state", "");
    assert(idle.code == "200" && idle.body == "{}",
        "5940 L0 idle route must return exact 200 {}: " ~ idle.body);

    command(port, "scene.reset");
    command(port, `{"id":"history.clear"}`);
    command(port, `{"id":"imagePlane.add","params":{"name":"Ref","projection":"front"}}`);
    command(port, "layer.attr 1 pos.x 4.0");
    command(port, "layer.attr 1 pos.y 1.5");
    command(port, "layer.attr 1 pos.z -2.0");
    command(port, "layer.attr 1 pivot.x 0.25");
    command(port, "layer.select index:0 mode:set");
    command(port, "layer.select index:1 mode:add");
    auto layers = fetchJson(port, "/api/layers")["layers"].array;
    assert(layers.length == 2 && layers[0]["primary"].boolean
        && layers[0]["selected"].boolean && layers[1]["focused"].boolean,
        "5940 live fixture requires selected mesh plus focused image plane");
    assert(fetchJson(port, "/api/selection")["selType"].str == "item",
        "5940 live fixture must be in item selection mode");

    // L1: start before POST; the arm services, then the full 400 ms seam stall
    // lies between it and the GET's later tickAll service.
    immutable armStarted = MonoTime.currTime;
    command(port, "tool.set move on");
    auto armedReply = request(port, "GET", "/api/tool/state", "");
    immutable armElapsed = MonoTime.currTime - armStarted;
    assert(armedReply.code == "200", "5940 L1 tool state did not succeed");
    auto armed = parseJSON(armedReply.body);
    auto pipe = fetchJson(port, "/api/toolpipe/eval");
    auto centre = pipe["actionCenter"]["center"].array;
    assert(number(centre[0]) != 0 || number(centre[1]) != 0
        || number(centre[2]) != 0,
        "5940 L1 population floor: action centre must differ from the origin");
    assert("tool" in armed,
        "5940 L1 production wiring must read the live active-tool slot: "
        ~ armedReply.body);
    assert(armed["tool"].str == "xfrm" && armed["subject"].str == "item"
        && number(armed["pivot"].array[0]) == number(centre[0])
        && number(armed["pivot"].array[1]) == number(centre[1])
        && number(armed["pivot"].array[2]) == number(centre[2]),
        "5940 L1 owned read must see the arm frame's updated item pivot: "
        ~ armedReply.body);
    assert(armElapsed >= 400.msecs,
        "5940 L1 timing floor: arm plus immediate read did not cross the 400 ms stall");

    // L2: the real interactive refire path publishes one fold per value batch.
    command(port, "tool.attr move TX 0.7", "/api/script?interactive=true");
    auto first = fetchJson(port, "/api/tool/state");
    assert(first["editOpen"].boolean
        && first["valueReplay"]["source"].str == "interactive"
        && first["valueReplay"]["cause"].str == "move"
        && first["valueReplay"]["channels"].array.length == 1
        && first["valueReplay"]["channels"].array[0].str == "TX"
        && first["valueReplay"]["folds"].integer == 1
        && first["runFrame"]["valid"].boolean
        && pivotX(first) > 4.949 && pivotX(first) < 4.951
        && number(first["runFrame"]["origin"].array[0]) > 4.249
        && number(first["runFrame"]["origin"].array[0]) < 4.251,
        "5940 L2 first interactive refire state changed: " ~ first.toString);

    command(port, "tool.attr move TX 1.2", "/api/script?interactive=true");
    auto second = fetchJson(port, "/api/tool/state");
    assert(second["valueReplay"]["folds"].integer == 2
        && pivotX(second) > 5.449 && pivotX(second) < 5.451
        && !(pivotX(second) > 6.149 && pivotX(second) < 6.151),
        "5940 L2 second refire must remain absolute from the run origin: "
        ~ second.toString);

    // L3: production drop clears the live slot; the next owned read is `{}`.
    command(port, "tool.set move off");
    auto dropped = request(port, "GET", "/api/tool/state", "");
    assert(dropped.code == "200" && dropped.body == "{}",
        "5940 L3 dropped tool must return exact 200 {}: " ~ dropped.body);
}
