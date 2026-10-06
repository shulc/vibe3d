// Task 10820: read the normal product GUI's root framebuffer after a real
// principal-ring drag. The cell FBO omits the foreground ImGui sector.
import core.exception : AssertError;
import core.thread : Thread;
import core.time : msecs;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.file : exists, getcwd, mkdirRecurse, read, rmdirRecurse;
import std.format : format;
import std.json : JSONValue;
import std.math : abs;
import std.path : buildPath;
import std.process : Config, Pid, environment, execute,
    kill, spawnProcess, tryWait, wait;
import std.socket : InternetAddress, SocketOption, SocketOptionLevel, TcpSocket;
import std.stdio : File, stdin, writefln;
import std.string : strip;

void main() {}

version (linux) {
import core.sys.posix.unistd : getpid;
private alias Rgb = int[3];
private string evidence;
private enum width = 1280, height = 960;
private struct Frame {
    ubyte[] pixels;
    Rgb at(int x, int y) const {
        assert(x >= 0 && x < width && y >= 0 && y < height,
            "sector pixel outside root framebuffer");
        auto i = (y * width + x) * 3;
        return [pixels[i], pixels[i+1], pixels[i+2]];
    }
}
private void stop(Pid pid) {
    if (pid is null) return;
    if (!tryWait(pid).terminated) {
        kill(pid);
        foreach (_; 0 .. 40) {
            if (tryWait(pid).terminated) return;
            Thread.sleep(25.msecs);
        }
        kill(pid, 9);
        wait(pid);
    }
}
private ushort allocatePort() {
    auto socket = new TcpSocket;
    scope(exit) socket.close();
    socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    auto requested = environment.get("VIBE3D_OVERLAY_GUI_PORT", "0").to!ushort;
    socket.bind(new InternetAddress("127.0.0.1", requested));
    return (cast(InternetAddress)socket.localAddress).port;
}
private Frame capture(string root, string[string] env, string name) {
    const xwd = buildPath(root, name ~ ".xwd");
    const png = buildPath(root, name ~ ".png");
    const rgb = buildPath(root, name ~ ".rgb");
    assert(execute(["xwd", "-root", "-silent", "-out", xwd], env).status == 0,
        "root framebuffer capture failed");
    assert(execute(["magick", xwd, png], env).status == 0,
        "root framebuffer PNG conversion failed");
    assert(execute(["magick", png, "-depth", "8", "rgb:" ~ rgb], env).status == 0,
        "root framebuffer RGB conversion failed");
    auto pixels = cast(ubyte[])read(rgb);
    assert(pixels.length == width * height * 3,
        "root framebuffer must contain exactly 1280x960 RGB pixels");
    return Frame(pixels);
}
private void cmd(string body) {
    auto response = postJson("/api/command", body);
    assert(response["status"].str == "ok", "sector rig command failed: " ~ response.toString);
}
private void input(string[string] env, string[] args) {
    assert(execute(["xdotool"] ~ args, env).status == 0,
        "owned GUI mouse injection failed");
    Thread.sleep(200.msecs);
}
private bool near(Rgb actual, Rgb expected, int tolerance = 3) {
    foreach (i; 0 .. 3) if (abs(actual[i] - expected[i]) > tolerance) return false;
    return true;
}
private size_t population(const ref Frame frame, int cx, int cy, int r,
                          Rgb color, int tolerance = 3) {
    size_t count;
    foreach (y; cy-r .. cy+r+1) foreach (x; cx-r .. cx+r+1)
        if (near(frame.at(x,y), color, tolerance)) ++count;
    return count;
}
private void check(string axis, string cell, scope void delegate() test,
                   ref string first) {
    auto wanted = environment.get("VIBE3D_CELL", "");
    if (wanted.length && wanted != axis ~ "-" ~ cell) return;
    try { test(); auto line = format("[sector-pixels] %s-%s PASS", axis, cell); evidence ~= line ~ "\n"; writefln("%s", line); }
    catch (AssertError failure) {
        auto line = format("[sector-pixels] %s-%s RED: %s", axis, cell, failure.msg);
        evidence ~= line ~ "\n"; writefln("%s", line);
        if (!first.length) first = failure.msg.idup;
    }
}
unittest {
    evidence = "";
    auto port = allocatePort();
    const root = buildPath(environment.get("TMPDIR", "/var/tmp"),
        "rotation-sector-gui-" ~ port.to!string ~ "-" ~ getpid().to!string);
    mkdirRecurse(root);
    const retain = environment.get("VIBE3D_OVERLAY_CAPTURE_DIR", "");
    scope(exit) rmdirRecurse(root);
    auto env = environment.toAA;
    env.remove("WAYLAND_DISPLAY");
    env["SDL_VIDEODRIVER"] = "x11";
    env["LIBGL_ALWAYS_SOFTWARE"] = "1";
    env["VIBE3D_CONFIG_DIR"] = root;
    env["XDG_CONFIG_HOME"] = root;
    auto xlog = File(buildPath(root, "xvfb.log"), "wb");
    auto displayPath = buildPath(root, "display.txt");
    auto displayFile = File(displayPath, "wb");
    auto x = spawnProcess(["Xvfb", "-displayfd", "1", "-screen", "0", "1280x960x24"],
        stdin, displayFile, xlog, env);
    const xId = x.processID;
    scope(exit) { stop(x); writefln("[sector-pixels] CLEANUP xPid=%d terminal", xId); }
    import std.file : readText;
    string display;
    foreach (_; 0 .. 120) {
        display = readText(displayPath).strip;
        if (display.length) break;
        assert(!tryWait(x).terminated, "owned Xvfb exited during startup");
        Thread.sleep(25.msecs);
    }
    assert(display.length, "owned Xvfb did not publish its display");
    env["DISPLAY"] = ":" ~ display;
    auto log = File(buildPath(root, "product.log"), "wb");
    auto app = spawnProcess([buildPath(getcwd(), "vibe3d"), "--http-port",
        port.to!string, "--window", "1280x960"], stdin, log, log, env,
        Config.none, getcwd());
    const appId = app.processID;
    scope(exit) {
        stop(app);
        auto socket = new TcpSocket;
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        socket.bind(new InternetAddress("127.0.0.1", port));
        socket.close();
        writefln("[sector-pixels] CLEANUP appPid=%d port=%d bindable", appId, port);
    }
    const savedPort = environment.get("VIBE3D_TEST_PORT", "");
    const hadPort = "VIBE3D_TEST_PORT" in environment;
    environment["VIBE3D_TEST_PORT"] = port.to!string;
    scope(exit) {
        if (hadPort) environment["VIBE3D_TEST_PORT"] = savedPort;
        else environment.remove("VIBE3D_TEST_PORT");
    }
    bool ready;
    foreach (_; 0 .. 120) {
        assert(!tryWait(app).terminated, "owned product GUI exited during startup");
        try {
            auto camera = getJson("/api/camera");
            if (camera["width"].integer > 600 && camera["height"].integer > 600) {
                ready = true; break;
            }
        } catch (Exception) {}
        Thread.sleep(25.msecs);
    }
    assert(ready, "owned product GUI did not become ready");
    auto listener = execute(["ss", "-H", "-ltnp", "sport = :" ~ port.to!string]);
    import std.string : indexOf;
    assert(listener.output.indexOf("pid=" ~ app.processID.to!string ~ ",") >= 0,
        "GUI endpoint listener is not the spawned product PID");
    writefln("[sector-pixels] OWNERS appPid=%d xPid=%d display=%s port=%d root=%s",
        app.processID, x.processID, env["DISPLAY"], port, root);
    string first;
    foreach (axis; ["X", "Z"]) {
        cmd("scene.reset"); cmd("history.clear");
        cmd("viewport.view " ~ (axis == "X" ? "Right" : "Front"));
        cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`));
        cmd("tool.set rotate on");
        Thread.sleep(300.msecs);
        auto cam = getJson("/api/camera");
        int cx = cast(int)(cam["vpX"].integer + cam["width"].integer/2);
        int cy = cast(int)(cam["vpY"].integer + cam["height"].integer/2);
        auto idle = capture(root, env, axis ~ "-idle");
        input(env, ["mousemove", (cx+120).to!string, cy.to!string]);
        input(env, ["mousedown", "1"]);
        input(env, ["mousemove", (cx+104).to!string, (cy-60).to!string]);
        auto handles = getJson("/api/tool/handles")["handles"];
        assert(handles["captured"].integer == (axis == "X" ? 10 : 12),
            "principal sector rig must capture the requested axis ring");
        auto drag = capture(root, env, axis ~ "-drag");
        // Opaque guide and quarter-alpha fill are independently captured values.
        // The active ring retains its existing 0.95 GL alpha over the grey face.
        auto fill = drag.at(cx+45, cy-15);
        // Half of the fixed haul vector lies on the terminal radial edge.
        auto edge = drag.at(cx+52, cy-30);
        const guideCount = population(drag, cx, cy, 116, [204,153,255], 0);
        const activeCount = population(drag, cx, cy, 123, [245,221,101], 0);
        size_t changed;
        foreach (y; cy-60 .. cy-2) foreach (px; cx+5 .. cx+100)
            if (drag.at(px,y) != idle.at(px,y)) ++changed;
        assert(changed >= 100, "sector drawing population must cover at least 100 interior pixels");
        auto measured = format("[sector-pixels] %s measured fill=%s guide=%d active=%d changed=%d",
            axis, fill, guideCount, activeCount, changed);
        evidence ~= measured ~ "\n"; writefln("%s", measured);
        check(axis, "fill", { assert(near(fill, [95,83,108], 0),
            format("%s sector quarter-alpha fill: expected [95, 83, 108], got %s", axis, fill)); }, first);
        check(axis, "outline", { assert(guideCount >= 20 && near(edge, [204,153,255], 0),
            format("%s sector opaque guide outline: expected >=20 purple pixels and radial edge [204, 153, 255], got %d and %s", axis, guideCount, edge)); }, first);
        check(axis, "active-ring", { assert(activeCount >= 40,
            format("%s dragged ring handleActive: expected >=40 active pixels, got %d", axis, activeCount)); }, first);
        input(env, ["mouseup", "1"]);
        cmd("tool.set rotate off");
    }
    import std.file : write;
    write(buildPath(root, "measurements.txt"), evidence);
    if (retain.length) {
        import std.file : copy, dirEntries, SpanMode;
        mkdirRecurse(retain);
        foreach (entry; dirEntries(root, SpanMode.shallow))
            if (entry.isFile) copy(entry.name, buildPath(retain, entry.name[ root.length+1 .. $]));
    }
    assert(!first.length, first);
}
}
