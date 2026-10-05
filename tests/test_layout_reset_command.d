module test_layout_reset_command;

import core.sys.posix.signal : SIGKILL, SIGTERM, kill;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import http_client : postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.file : exists, getcwd, mkdirRecurse, readText, rmdirRecurse, symlink;
import std.json : JSONValue;
import std.net.curl : get;
import std.process : Config, Pid, spawnProcess, wait;
import std.socket : AddressFamily, InternetAddress, ProtocolType, Socket,
    SocketType;
import std.stdio : File, stdin;
import std.string : indexOf;

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

private Instance launch() {
    Instance result;
    result.port = freePort();
    result.root = "/tmp/vibe3d_layout_reset_6245_" ~ result.port.to!string;
    mkdirRecurse(result.root);
    result.base = "http://127.0.0.1:" ~ result.port.to!string;
    result.iniPath = result.root ~ "/layout.ini";
    result.logPath = result.root ~ "/vibe3d.log";
    const repo = getcwd();
    symlink(repo ~ "/config", result.root ~ "/config");
    symlink(repo ~ "/assets", result.root ~ "/assets");
    string[string] childEnv;
    childEnv["VIBE3D_CONFIG_DIR"] = result.root;
    childEnv["VIBE3D_TEST_VIEWPORT_WINDOWS"] = "1";
    childEnv["VIBE3D_TEST_LAYOUT_INI"] = result.iniPath;
    auto logFile = File(result.logPath, "wb");
    result.pid = spawnProcess([
        repo ~ "/vibe3d", "--test", "--http-port", result.port.to!string,
    ], stdin, logFile, logFile, childEnv, Config.none, result.root);
    scope(failure) stop(result);
    foreach (_; 0 .. 240) {
        if (kill(result.pid.processID, 0) != 0) break;
        try {
            if ((cast(string)get(result.base ~ "/api/registry"))
                    .indexOf(`"layout.reset"`) >= 0)
                return result;
        } catch (Exception) {}
        Thread.sleep(25.msecs);
    }
    assert(false, "6245 layout.reset app did not become ready; see "
        ~ result.logPath);
    return result;
}

private string windowSection(string ini, string name) {
    const marker = "[Window][" ~ name ~ "]\n";
    const start = ini.indexOf(marker);
    if (start < 0) return "";
    const end = ini.indexOf("\n[", start + marker.length);
    return end < 0 ? ini[start .. $] : ini[start .. end];
}

private string waitViewportDock(Instance instance, bool docked, string row) {
    const deadline = MonoTime.currTime + 8.seconds;
    while (MonoTime.currTime < deadline) {
        if (exists(instance.iniPath)) {
            const ini = readText(instance.iniPath);
            const section = windowSection(ini, "ViewportHost");
            if (section.length
                && (section.indexOf("DockId=") >= 0) == docked)
                return section;
        }
        Thread.sleep(25.msecs);
    }
    assert(false, "6245 " ~ row
        ~ " did not reach the expected ViewportHost dock state");
    return "";
}

private JSONValue postCommand(Instance instance, string id,
                              string params = null) {
    return postJson("/api/command", commandBody(id, params), instance.base);
}

unittest {
    auto instance = launch();
    scope(exit) stop(instance);

    const seeded = waitViewportDock(instance, true, "initial seed");
    assert(seeded.indexOf("DockId=") >= 0,
        "6245 layout.reset floor: full seed did not dock ViewportHost");

    auto changed = postCommand(instance, "viewport.layout", `"Quad"`);
    assert(changed["status"].str == "ok",
        "6245 layout.reset fixture could not rebuild the test dock tree");
    const beforeReset = waitViewportDock(instance, false, "pre-reset rebuild");
    assert(beforeReset.indexOf("DockId=") < 0,
        "6245 layout.reset floor: viewport.layout did not change the dock tree");

    auto reset = postCommand(instance, "layout.reset");
    assert(reset["status"].str == "ok",
        "6245 F4d suite: layout.reset command failed");
    const afterReset = waitViewportDock(instance, true, "fallback reseed");
    assert(afterReset.indexOf("DockId=") >= 0,
        "6245 F4d suite: layout.reset did not re-dock ViewportHost");
}
