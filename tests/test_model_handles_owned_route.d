// Task 5950 live production-wiring witness. This test launches its own editor
// because the pre-tool stall is process configuration; it drives the actual
// model/handles providers and the command -> draw -> next bridge ordering.
import core.sys.posix.signal : kill, SIGKILL, SIGTERM;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm : canFind, sort;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : Pid, spawnProcess, tryWait, wait, thisProcessID;
import std.socket : AddressFamily, InternetAddress, ProtocolType, Socket,
    SocketType, TcpSocket;
import std.stdio : File, stdin;
import std.string : indexOf;

void main() {}

private struct Reply {
    string code;
    string headers;
    string body_;
}

private Reply request(ushort port, string method, string path, string body_) {
    auto socket = new TcpSocket();
    scope(exit) socket.close();
    try socket.connect(new InternetAddress("127.0.0.1", port));
    catch (Exception) return Reply("connect-refused", "", "");

    string wire = method ~ " " ~ path ~ " HTTP/1.1\r\nHost: localhost\r\n"
                ~ "Connection: close\r\n";
    if (body_.length)
        wire ~= "Content-Type: application/json\r\nContent-Length: "
              ~ body_.length.to!string ~ "\r\n";
    wire ~= "\r\n" ~ body_;
    try {
        socket.send(cast(const(void)[]) wire);
        char[16_384] buf;
        string response;
        for (;;) {
            auto n = socket.receive(buf[]);
            if (n <= 0) break;
            response ~= buf[0 .. n].idup;
            if (response.length > 4 * 1024 * 1024) break;
        }
        if (response.length == 0) return Reply("empty-reply", "", "");
        immutable firstSpace = response.indexOf(' ');
        immutable split = response.indexOf("\r\n\r\n");
        return Reply(
            firstSpace >= 0 && response.length >= firstSpace + 4
                ? response[firstSpace + 1 .. firstSpace + 4].idup : "???",
            split >= 0 ? response[0 .. split + 2].idup : "",
            split >= 0 ? response[split + 4 .. $].idup : "");
    } catch (Exception e) {
        return Reply("io-error", "", e.msg);
    }
}

private ushort pickFreePort() {
    auto socket = new Socket(AddressFamily.INET, SocketType.STREAM,
                             ProtocolType.TCP);
    scope(exit) socket.close();
    socket.bind(new InternetAddress(InternetAddress.ADDR_ANY, cast(ushort) 0));
    return (cast(InternetAddress) socket.localAddress).port;
}

private string logTail(string path) {
    try {
        auto text = readText(path);
        return text.length > 4000 ? text[$ - 4000 .. $] : text;
    } catch (Exception e) {
        return "(log unreadable: " ~ e.msg ~ ")";
    }
}

private void stopOwned(Pid pid) {
    if (pid is null) return;
    try kill(pid.processID, SIGTERM); catch (Exception) {}
    foreach (_; 0 .. 40) {
        auto status = tryWait(pid);
        if (status.terminated) return;
        Thread.sleep(25.msecs);
    }
    try kill(pid.processID, SIGKILL); catch (Exception) {}
    try wait(pid); catch (Exception) {}
}

private void removeScratch(string path) {
    if (!exists(path)) return;
    try rmdirRecurse(path);
    catch (Exception) {}
}

private JSONValue json200(Reply reply, string context) {
    assert(reply.code == "200",
        context ~ " status changed to " ~ reply.code ~ ": " ~ reply.body_);
    assert(reply.headers.canFind("Content-Type: application/json\r\n"),
        context ~ " lost application/json: " ~ reply.headers);
    return parseJSON(reply.body_);
}

private int[] partIds(JSONValue response, string context) {
    auto handles = response["handles"];
    assert(handles.type != JSONType.null_,
        context ~ " returned null handles");
    int[] ids;
    foreach (part; handles["parts"].array)
        ids ~= cast(int) part["part"].integer;
    ids.sort();
    return ids;
}

unittest {
    immutable port = pickFreePort();
    immutable scratch = buildPath("/tmp", "vibe3d_model_handles_owned_"
        ~ thisProcessID().to!string ~ "_" ~ port.to!string);
    mkdirRecurse(scratch);
    immutable logPath = buildPath(scratch, "vibe3d.log");

    string[string] env;
    env["VIBE3D_CONFIG_DIR"] = scratch;
    env["VIBE3D_STALL_PRE_TOOL_TICK_MS"] = "1000";
    auto logFile = File(logPath, "wb");
    auto pid = spawnProcess(
        ["./vibe3d", "--test", "--http-port", port.to!string],
        stdin, logFile, logFile, env);
    scope(exit) {
        stopOwned(pid);
        removeScratch(scratch);
    }

    bool ready;
    auto readyWatch = StopWatch(AutoStart.yes);
    while (readyWatch.peek.total!"msecs" < 60_000) {
        auto probe = request(port, "GET", "/api/registry", "");
        if (probe.code == "200" && probe.body_.canFind(`"file.save"`)) {
            ready = true;
            break;
        }
        Thread.sleep(20.msecs);
    }
    assert(ready,
        "5950 live floor: owned editor did not expose its populated registry\n"
        ~ logTail(logPath));

    auto layer0First = json200(
        request(port, "GET", "/api/model?layer=0", ""),
        "5950 live model layer 0 first");
    assert(layer0First["vertexCount"].integer == 8,
        "5950 live model floor: bootstrap layer must have eight vertices");
    auto add = json200(request(port, "POST", "/api/script", "layer.add name:B"),
                       "5950 live layer add");
    assert(add["status"].str == "ok",
        "5950 live layer add refused: " ~ add.toString());
    auto layer1 = json200(request(port, "GET", "/api/model?layer=1", ""),
                          "5950 live model layer 1");
    auto layer0Again = json200(
        request(port, "GET", "/api/model?layer=0", ""),
        "5950 live model layer 0 again");
    auto primary = json200(request(port, "GET", "/api/model", ""),
                           "5950 live model primary");
    assert(layer1["vertexCount"].integer == 0
        && layer0Again["vertexCount"].integer == 8
        && primary["vertexCount"].integer == 0,
        "5950 live model routing: layer query or live primary was not preserved");

    auto absentHandles = request(port, "GET", "/api/tool/handles", "");
    json200(absentHandles, "5950 live absent handles");
    assert(absentHandles.body_ == `{"handles":null}`,
        "5950 live absent handles body changed: " ~ absentHandles.body_);

    auto moveArm = json200(request(port, "POST", "/api/script", "tool.set move"),
                           "5950 live move arm");
    assert(moveArm["status"].str == "ok",
        "5950 live move arm refused: " ~ moveArm.toString());
    auto moveParts = partIds(json200(
        request(port, "GET", "/api/tool/handles", ""),
        "5950 live move handles"), "5950 live move handles");
    assert(moveParts.length > 0,
        "5950 live move handles floor: registry must be populated after draw");

    auto watch = StopWatch(AutoStart.yes);
    auto rotateArm = json200(
        request(port, "POST", "/api/script", "tool.set rotate"),
        "5950 live rotate arm");
    assert(rotateArm["status"].str == "ok",
        "5950 live rotate arm refused: " ~ rotateArm.toString());
    auto rotateReply = request(port, "GET", "/api/tool/handles", "");
    immutable elapsedMs = watch.peek.total!"msecs";
    auto rotateParts = partIds(json200(rotateReply,
        "5950 live rotate handles"), "5950 live rotate handles");
    assert(rotateParts.length > 0 && rotateParts != moveParts,
        "5950 live phase: rotate GET did not observe the distinct registry "
        ~ "built by its first draw");
    assert(elapsedMs >= 1000,
        "5950 live phase floor: rotate arm + GET missed the 1000 ms floor; "
        ~ "elapsed ms=" ~ elapsedMs.to!string);
}
