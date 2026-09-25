// The per-preset tool attribute cache survives an editor restart (slice M5b;
// owner answer "Model, Q2": keep it between restarts, as the reference keeps
// it in its saved config; gap row 307, verdict C-M5-save).
//
// The law on our side: the cache is a section of the prefs document, written
// at a clean shutdown and read at startup, both behind `prefsActive` — which
// under `--test` needs VIBE3D_CONFIG_DIR. The shared suite instance never sets
// it, so this file launches its own instances (same idiom as
// tests/test_tool_sticky.d) and signals them down with SIGTERM, which reaches
// the editor as an ordinary quit on a clean document.
//
// Cells, in one order so a single run buys every half: the control (a fresh
// config directory reads the default range) is asserted ABOVE the needle (a
// restarted instance on the saved directory reads the typed range).

import http_client : getJson, postJson;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse;
import std.format : format;
import std.json : JSONValue;
import std.math : abs;
import std.path : buildPath;
import std.process : Pid, spawnProcess, thisProcessID, tryWait, wait;
import std.socket : AddressFamily, InternetAddress, ProtocolType, Socket, SocketType;
import std.stdio : File, stdin, stderr;
import std.algorithm.searching : canFind;

import core.sys.posix.signal : SIGKILL, SIGTERM, kill;
import core.thread : Thread;
import core.time : msecs;

void main() {}

private enum double kTyped = 0.37;

private ushort freePort() {
    auto sock = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
    scope(exit) sock.close();
    sock.bind(new InternetAddress(InternetAddress.ADDR_ANY, cast(ushort) 0));
    return (cast(InternetAddress) sock.localAddress).port;
}

private struct Instance {
    string baseUrl;
    Pid pid;
    string logPath;
}

private Instance launch(string configDir, string tag) {
    Instance inst;
    const port = freePort();
    inst.baseUrl = "http://localhost:" ~ port.to!string;
    inst.logPath = buildPath(configDir, "vibe3d_" ~ tag ~ ".log");
    string[string] env;
    env["VIBE3D_CONFIG_DIR"] = configDir;
    auto log = File(inst.logPath, "wb");
    inst.pid = spawnProcess(["./vibe3d", "--test", "--http-port", port.to!string],
                            stdin, log, log, env);
    foreach (i; 0 .. 150) {
        try {
            getJson("/api/camera", inst.baseUrl);
            return inst;
        } catch (Exception) {}
        Thread.sleep(100.msecs);
    }
    kill(inst.pid.processID, SIGKILL);
    wait(inst.pid);
    assert(false, tag ~ ": the instance did not come up; see " ~ inst.logPath);
}

/// SIGTERM and wait for a clean exit; true when it exited on its own.
private bool quit(ref Instance inst) {
    try kill(inst.pid.processID, SIGTERM); catch (Exception) {}
    foreach (i; 0 .. 150) {
        auto r = tryWait(inst.pid);
        if (r.terminated) return true;
        Thread.sleep(100.msecs);
    }
    kill(inst.pid.processID, SIGKILL);
    wait(inst.pid);
    return false;
}

private void command(ref Instance inst, string text) {
    auto r = postJson("/api/command", text, inst.baseUrl);
    assert(r["status"].str == "ok", "command `" ~ text ~ "` failed: " ~ r.toString);
}

private double elementRange(ref Instance inst) {
    command(inst, "tool.set xfrm.elementMove on");
    Thread.sleep(150.msecs);
    foreach (stage; getJson("/api/toolpipe", inst.baseUrl)["stages"].array)
        if (stage["task"].str == "WGHT") {
            assert(stage["attrs"]["type"].str == "element",
                "floor: Element Move armed without the element falloff");
            return stage["attrs"]["dist"].str.to!double;
        }
    assert(false, "falloff stage (WGHT) is absent from /api/toolpipe");
}

unittest {
    const root = buildPath("/tmp", format("vibe3d_m5b_restart_%d", thisProcessID()));
    const saved = buildPath(root, "saved");
    const fresh = buildPath(root, "fresh");
    mkdirRecurse(saved);
    mkdirRecurse(fresh);
    scope(exit) if (exists(root)) rmdirRecurse(root);

    // Session 1: type the range, drop the tool, quit cleanly.
    auto first = launch(saved, "first");
    immutable double initial = elementRange(first);
    assert(abs(initial - kTyped) > 1e-3,
        format("floor: a fresh config already reads the typed range (%s)", initial));
    command(first, format("tool.pipe.attr falloff dist %g", kTyped));
    command(first, "tool.set xfrm.elementMove off");
    assert(quit(first), "floor: the first instance did not exit on SIGTERM");
    const prefsPath = buildPath(saved, "prefs.json");
    assert(exists(prefsPath) && readText(prefsPath).canFind(`"toolAttrCache"`),
        "floor: the clean exit wrote no tool attribute cache section to prefs.json");

    // Control: a fresh config directory reads the default.
    auto control = launch(fresh, "control");
    immutable double defaultRange = elementRange(control);
    quit(control);
    assert(abs(defaultRange - kTyped) > 1e-3,
        format("control: a fresh config directory read the typed range (%s)", defaultRange));

    // Session 2 on the saved directory: the typed range is recalled.
    auto second = launch(saved, "second");
    immutable double recalled = elementRange(second);
    quit(second);
    assert(abs(recalled - kTyped) <= 1e-6,
        format("the tool attribute cache did not survive a restart: range %s, typed %s",
               recalled, kTyped));
}
