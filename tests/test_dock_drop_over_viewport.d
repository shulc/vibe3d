module test_dock_drop_over_viewport;

import core.sys.posix.signal : SIGKILL, SIGTERM, kill;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.algorithm : count;
import std.conv : to;
import std.file : exists, getcwd, mkdirRecurse, readText, rmdirRecurse, symlink;
import std.json : JSONType, JSONValue;
import std.net.curl : HTTP, get;
import std.path : buildPath;
import std.process : Config, Pid, spawnProcess, wait;
import std.socket : AddressFamily, InternetAddress, ProtocolType, Socket,
    SocketType;
import std.stdio : File, stdin;
import std.string : indexOf, splitLines, startsWith;

void main() {}

private struct Instance {
    ushort port;
    string root;
    string base;
    string iniPath;
    string logPath;
    Pid pid;
}

private ushort freePort() {
    auto socket = new Socket(AddressFamily.INET, SocketType.STREAM,
        ProtocolType.TCP);
    scope(exit) socket.close();
    socket.bind(new InternetAddress(InternetAddress.ADDR_ANY, 0));
    return (cast(InternetAddress)socket.localAddress).port;
}

private Instance launch(string cell) {
    Instance result;
    result.port = freePort();
    result.root = buildPath("/tmp", "vibe3d_dock_6245_"
        ~ result.port.to!string ~ "_" ~ cell);
    mkdirRecurse(result.root);
    result.base = "http://127.0.0.1:" ~ result.port.to!string;
    result.iniPath = buildPath(result.root, "layout.ini");
    result.logPath = buildPath(result.root, "vibe3d.log");
    const repo = getcwd();
    symlink(buildPath(repo, "config"), buildPath(result.root, "config"));
    symlink(buildPath(repo, "assets"), buildPath(result.root, "assets"));
    string[string] childEnv;
    childEnv["VIBE3D_CONFIG_DIR"] = result.root;
    childEnv["VIBE3D_TEST_VIEWPORT_WINDOWS"] = "1";
    childEnv["VIBE3D_TEST_LAYOUT_INI"] = result.iniPath;
    auto logFile = File(result.logPath, "wb");
    result.pid = spawnProcess([
        buildPath(repo, "vibe3d"), "--test", "--http-port",
        result.port.to!string,
    ], stdin, logFile, logFile, childEnv, Config.none, result.root);
    foreach (_; 0 .. 240) {
        if (kill(result.pid.processID, 0) != 0) break;
        try {
            if ((cast(string)get(result.base ~ "/api/registry"))
                    .indexOf(`"layout.reset"`) >= 0)
                return result;
        } catch (Exception) {}
        Thread.sleep(25.msecs);
    }
    assert(false, "6245 " ~ cell ~ " app did not become ready; see "
        ~ result.logPath);
    return result;
}

private void stop(ref Instance instance) {
    if (instance.pid !is null) {
        try kill(instance.pid.processID, SIGTERM); catch (Exception) {}
        foreach (_; 0 .. 40) {
            if (kill(instance.pid.processID, 0) != 0) break;
            Thread.sleep(25.msecs);
        }
        if (kill(instance.pid.processID, 0) == 0)
            try kill(instance.pid.processID, SIGKILL); catch (Exception) {}
        try wait(instance.pid); catch (Exception) {}
    }
    if (instance.root.length && exists(instance.root))
        try rmdirRecurse(instance.root); catch (Exception) {}
}

private JSONValue getJsonAt(Instance instance, string path) {
    return getJson(path, instance.base);
}

private JSONValue postJsonAt(Instance instance, string path, string body) {
    return postJson(path, body, instance.base);
}

private void postEvents(Instance instance, string events) {
    auto http = HTTP();
    string reply;
    http.onReceive = (ubyte[] data) {
        reply ~= cast(string)data;
        return data.length;
    };
    http.postData = events;
    http.addRequestHeader("Content-Type", "text/plain");
    http.url = instance.base ~ "/api/play-events";
    http.perform();
    assert(reply.indexOf(`"status":"success"`) >= 0,
        "6245 play-events rejected the populated gesture: " ~ reply);
}

private size_t number(JSONValue object, string key) {
    const value = object[key];
    return value.type == JSONType.uinteger
        ? cast(size_t)value.uinteger : cast(size_t)value.integer;
}

private JSONValue waitFinished(Instance instance, size_t total, string row) {
    const deadline = MonoTime.currTime + 5.seconds;
    while (MonoTime.currTime < deadline) {
        const status = getJsonAt(instance, "/api/play-events/status");
        if (status["finished"].type == JSONType.true_) {
            assert(number(status, "remaining") == 0
                && number(status, "total") == total,
                "6245 " ~ row ~ " playback population: " ~ status.toString);
            return status;
        }
        Thread.sleep(10.msecs);
    }
    assert(false, "6245 " ~ row ~ " playback timed out");
    return JSONValue.init;
}

private string windowSection(string ini, string name) {
    const marker = "[Window][" ~ name ~ "]\n";
    const start = ini.indexOf(marker);
    if (start < 0) return "";
    const end = ini.indexOf("\n[", start + marker.length);
    return end < 0 ? ini[start .. $] : ini[start .. end];
}

private string posLine(string section) {
    foreach (line; section.splitLines)
        if (line.startsWith("Pos=")) return line;
    return "";
}

private string dockLine(string section) {
    foreach (line; section.splitLines)
        if (line.startsWith("DockId=")) return line;
    return "";
}

private string waitIni(Instance instance, string windowName,
                       bool delegate(string) ready, string row) {
    const deadline = MonoTime.currTime + 8.seconds;
    while (MonoTime.currTime < deadline) {
        if (exists(instance.iniPath)) {
            const ini = readText(instance.iniPath);
            const section = windowSection(ini, windowName);
            if (section.length && ready(section)) return ini;
        }
        Thread.sleep(25.msecs);
    }
    assert(false, "6245 " ~ row ~ " ini did not reach the expected state");
    return "";
}

private void show(Instance instance, string id) {
    auto result = postJsonAt(instance, "/api/command", commandBody(id));
    assert(result["status"].str == "ok",
        "6245 could not show " ~ id ~ ": " ~ result.toString);
}

private enum controlLog =
    `{"t":0,"type":"SDL_MOUSEMOTION","x":80,"y":69,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
    `{"t":80,"type":"SDL_MOUSEMOTION","x":80,"y":69,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
    `{"t":160,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":80,"y":69,"clicks":1,"mod":0}` ~ "\n" ~
    `{"t":240,"type":"SDL_MOUSEMOTION","x":125,"y":85,"xrel":45,"yrel":16,"state":1,"mod":0}` ~ "\n" ~
    `{"t":320,"type":"SDL_MOUSEMOTION","x":170,"y":100,"xrel":45,"yrel":15,"state":1,"mod":0}` ~ "\n" ~
    `{"t":400,"type":"SDL_MOUSEMOTION","x":215,"y":115,"xrel":45,"yrel":15,"state":1,"mod":0}` ~ "\n" ~
    `{"t":480,"type":"SDL_MOUSEMOTION","x":260,"y":130,"xrel":45,"yrel":15,"state":1,"mod":0}` ~ "\n" ~
    `{"t":560,"type":"SDL_MOUSEMOTION","x":300,"y":140,"xrel":40,"yrel":10,"state":1,"mod":0}` ~ "\n" ~
    `{"t":640,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":300,"y":140,"clicks":1,"mod":0}`;

private enum viewportEdgeLog =
    `{"t":0,"type":"SDL_MOUSEMOTION","x":80,"y":69,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
    `{"t":80,"type":"SDL_MOUSEMOTION","x":80,"y":69,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
    `{"t":160,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":80,"y":69,"clicks":1,"mod":0}` ~ "\n" ~
    `{"t":240,"type":"SDL_MOUSEMOTION","x":110,"y":95,"xrel":30,"yrel":26,"state":1,"mod":0}` ~ "\n" ~
    `{"t":320,"type":"SDL_MOUSEMOTION","x":140,"y":120,"xrel":30,"yrel":25,"state":1,"mod":0}` ~ "\n" ~
    `{"t":400,"type":"SDL_MOUSEMOTION","x":170,"y":145,"xrel":30,"yrel":25,"state":1,"mod":0}` ~ "\n" ~
    `{"t":480,"type":"SDL_MOUSEMOTION","x":200,"y":170,"xrel":30,"yrel":25,"state":1,"mod":0}` ~ "\n" ~
    `{"t":560,"type":"SDL_MOUSEMOTION","x":230,"y":195,"xrel":30,"yrel":25,"state":1,"mod":0}` ~ "\n" ~
    `{"t":640,"type":"SDL_MOUSEMOTION","x":275,"y":220,"xrel":45,"yrel":25,"state":1,"mod":0}` ~ "\n" ~
    `{"t":720,"type":"SDL_MOUSEMOTION","x":320,"y":240,"xrel":45,"yrel":20,"state":1,"mod":0}` ~ "\n" ~
    `{"t":800,"type":"SDL_MOUSEMOTION","x":360,"y":250,"xrel":40,"yrel":10,"state":1,"mod":0}` ~ "\n" ~
    `{"t":880,"type":"SDL_MOUSEMOTION","x":400,"y":254,"xrel":40,"yrel":4,"state":1,"mod":0}` ~ "\n" ~
    `{"t":960,"type":"SDL_MOUSEMOTION","x":400,"y":254,"xrel":0,"yrel":0,"state":1,"mod":0}` ~ "\n" ~
    `{"t":1040,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":400,"y":254,"clicks":1,"mod":0}`;

private enum viewportCenterLog =
    `{"t":0,"type":"SDL_MOUSEMOTION","x":80,"y":69,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
    `{"t":80,"type":"SDL_MOUSEMOTION","x":80,"y":69,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
    `{"t":160,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":80,"y":69,"clicks":1,"mod":0}` ~ "\n" ~
    `{"t":240,"type":"SDL_MOUSEMOTION","x":120,"y":95,"xrel":40,"yrel":26,"state":1,"mod":0}` ~ "\n" ~
    `{"t":320,"type":"SDL_MOUSEMOTION","x":160,"y":120,"xrel":40,"yrel":25,"state":1,"mod":0}` ~ "\n" ~
    `{"t":400,"type":"SDL_MOUSEMOTION","x":200,"y":145,"xrel":40,"yrel":25,"state":1,"mod":0}` ~ "\n" ~
    `{"t":480,"type":"SDL_MOUSEMOTION","x":240,"y":170,"xrel":40,"yrel":25,"state":1,"mod":0}` ~ "\n" ~
    `{"t":560,"type":"SDL_MOUSEMOTION","x":280,"y":200,"xrel":40,"yrel":30,"state":1,"mod":0}` ~ "\n" ~
    `{"t":640,"type":"SDL_MOUSEMOTION","x":320,"y":230,"xrel":40,"yrel":30,"state":1,"mod":0}` ~ "\n" ~
    `{"t":720,"type":"SDL_MOUSEMOTION","x":360,"y":265,"xrel":40,"yrel":35,"state":1,"mod":0}` ~ "\n" ~
    `{"t":800,"type":"SDL_MOUSEMOTION","x":400,"y":300,"xrel":40,"yrel":35,"state":1,"mod":0}` ~ "\n" ~
    `{"t":880,"type":"SDL_MOUSEMOTION","x":400,"y":300,"xrel":0,"yrel":0,"state":1,"mod":0}` ~ "\n" ~
    `{"t":960,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":400,"y":300,"clicks":1,"mod":0}`;

unittest { // F4g': production opt-in, with the positive rows before refusal
    {
        auto instance = launch("control");
        scope(exit) stop(instance);
        show(instance, "ui.about");
        show(instance, "history.show");
        const beforeIni = waitIni(instance, "About",
            section => posLine(section).length != 0, "row 1 before");
        const before = windowSection(beforeIni, "About");
        assert(before.indexOf("DockId=") < 0,
            "6245 F4g row 1 floor: About was not initially floating");
        postEvents(instance, controlLog);
        waitFinished(instance, 9, "F4g row 1");
        const afterIni = waitIni(instance, "About",
            section => section.indexOf("DockId=") >= 0, "row 1 after");
        const after = windowSection(afterIni, "About");
        assert(posLine(after) != posLine(before),
            "6245 F4g row 1 control: panel position did not change");
    }
    {
        auto instance = launch("edge");
        scope(exit) stop(instance);
        show(instance, "ui.about");
        const beforeIni = waitIni(instance, "About",
            section => posLine(section).length != 0, "row 2 before");
        assert(beforeIni.count("DockNode ") >= 8,
            "6245 F4g row 2 population: seeded ini has fewer than eight dock nodes");
        postEvents(instance, viewportEdgeLog);
        waitFinished(instance, 14, "F4g row 2");
        const afterIni = waitIni(instance, "About",
            section => section.indexOf("DockId=") >= 0, "row 2 after");
        const about = windowSection(afterIni, "About");
        const viewport = windowSection(afterIni, "ViewportHost");
        assert(afterIni.count("DockNode ") >= 10,
            "6245 F4g row 2 population: edge split has fewer than ten dock nodes");
        assert(dockLine(about).length != 0
            && dockLine(viewport).length != 0
            && dockLine(about) != dockLine(viewport),
            "6245 F4g row 2 edge: panel did not split beside ViewportHost");
    }
    {
        auto instance = launch("centre");
        scope(exit) stop(instance);
        show(instance, "ui.about");
        const beforeIni = waitIni(instance, "About",
            section => posLine(section).length != 0, "row 3 before");
        const before = windowSection(beforeIni, "About");
        postEvents(instance, viewportCenterLog);
        const status = waitFinished(instance, 13, "F4g row 3");
        assert(status["finished"].type == JSONType.true_
            && number(status, "remaining") == 0
            && number(status, "total") == 13,
            "6245 F4g row 3 own playback floor failed");
        const afterIni = waitIni(instance, "About",
            section => posLine(section) != posLine(before), "row 3 after");
        const after = windowSection(afterIni, "About");
        assert(posLine(after) != posLine(before),
            "6245 F4g row 3 floor: drag did not move the panel");
        assert(after.indexOf("DockId=") < 0,
            "6245 F4g row 3 centre: panel merged into ViewportHost");
    }
}
