// Frame-phase witnesses (task 4620).
//
// These cells run in the same order as the production frame edges they pin:
// synthetic event dispatch -> resolved scene hover -> scene FBO pixels ->
// composed ImGui pixels.  Each assertion reads a VALUE produced by the phase,
// never its call count.  The composed-frame probe reads GL_BACK in plain
// --test mode, where the app deliberately does not present; it therefore pins
// UI submission but makes no claim about SDL_GL_SwapWindow.
module test_frame_phase_witness;

import core.thread : Thread;
import core.time : dur;
import drag_helpers : Vec3, fetchCamera, playAndWait, projectToWindow,
                      viewportFromCamera;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;

void main() {}

void settle(int ms = 250) {
    Thread.sleep(dur!"msecs"(ms));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ line ~ " -> " ~ r.toString);
}

void resetKnownView() {
    cmd(commandBody("scene.reset", "{}"));
    cmd("viewport.layout Single");
    cmd("viewport.view Perspective");
    cmd("select.typeFrom vertex");
    settle();
}

struct Px {
    int x, y, r, g, b, a;
}

struct Probe {
    int w, h;
    bool renders;
    string hash;
    Px[] points;
}

Probe probe(string query) {
    auto j = getJson("/api/viewport/probe?" ~ query);
    assert("error" !in j, "pixel probe failed: " ~ j.toString);
    Probe p;
    p.w = cast(int)j["w"].integer;
    p.h = cast(int)j["h"].integer;
    p.renders = j["renders"].type == JSONType.TRUE;
    if ("hash" in j) p.hash = j["hash"].str;
    foreach (v; j["points"].array) {
        assert("error" !in v, "pixel point failed: " ~ v.toString);
        p.points ~= Px(cast(int)v["x"].integer, cast(int)v["y"].integer,
                       cast(int)v["r"].integer, cast(int)v["g"].integer,
                       cast(int)v["b"].integer, cast(int)v["a"].integer);
    }
    return p;
}

bool nearClear(Px p) {
    import std.math : abs;
    return abs(p.r - 92) <= 2 && abs(p.g - 102) <= 2
        && abs(p.b - 107) <= 2;
}

bool sameRgb(Px a, Px b) {
    return a.r == b.r && a.g == b.g && a.b == b.b;
}

string lattice(int x0, int y0, int x1, int y1, int step) {
    string result;
    for (int y = y0; y <= y1; y += step) {
        for (int x = x0; x <= x1; x += step) {
            if (result.length) result ~= ";";
            result ~= x.to!string ~ "," ~ y.to!string;
        }
    }
    return result;
}

void cleanupPanelWitness() {
    try cmd("ui.toolProperties hide"); catch (Exception) {}
    try cmd("tool.set move off"); catch (Exception) {}
}

unittest { // event delivery: observe the shortcut's camera-state effect
    resetKnownView();
    auto before = getJson("/api/camera?viewport=0");
    assert(before["viewPreset"].str == "Perspective",
        "event witness precondition: camera is not Perspective");

    auto cam = fetchCamera();
    string log = format(
        `{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height)
      ~ `{"t":1,"type":"SDL_KEYDOWN","sym":1073741913,"scan":89,"mod":0,"repeat":0}` ~ "\n"
      ~ `{"t":11,"type":"SDL_KEYUP","sym":1073741913,"scan":89,"mod":0,"repeat":0}` ~ "\n";
    playAndWait(log);
    settle();

    auto after = getJson("/api/camera?viewport=0");
    assert(after["viewPreset"].str == "Top"
        && after["projKind"].str == "Ortho",
        "frame events phase did not deliver the synthetic KP1 shortcut: "
        ~ after.toString);
}

unittest { // picking/hover: observe the resolved hovered vertex
    resetKnownView();
    auto cam = fetchCamera();
    auto vp = viewportFromCamera(cam);
    auto model = getJson("/api/model");

    int nearest = -1;
    float nearestD2 = float.max;
    int px, py;
    foreach (i, v; model["vertices"].array) {
        auto a = v.array;
        Vec3 w = Vec3(cast(float)a[0].floating,
                      cast(float)a[1].floating,
                      cast(float)a[2].floating);
        Vec3 d = w - cam.eye;
        float d2 = d.x*d.x + d.y*d.y + d.z*d.z;
        float sx, sy;
        if (d2 >= nearestD2 || !projectToWindow(w, vp, sx, sy)) continue;
        nearest = cast(int)i;
        nearestD2 = d2;
        px = cast(int)sx;
        py = cast(int)sy;
    }
    assert(nearest >= 0, "hover witness has no projectable foreground vertex");

    string log = format(
        `{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height)
      ~ format(
        `{"t":1,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
        px, py);
    playAndWait(log);
    settle();

    auto hover = getJson("/api/toolpipe/eval")["hover"];
    assert(cast(int)hover["vertex"].integer == nearest,
        format("frame picking/hover phase resolved vertex %d, expected %d "
               ~ "at (%d,%d)", cast(int)hover["vertex"].integer,
               nearest, px, py));
}

unittest { // scene draw: non-black population, then background + model pixels
    resetKnownView();
    auto dims = probe("cell=0&hash=1");
    assert(dims.renders && dims.w > 100 && dims.h > 100
        && dims.hash.length == 16,
        "scene witness has no rendered framebuffer: " ~ dims.hash);

    auto broad = probe("cell=0&points="
        ~ lattice(4, 4, dims.w - 5, dims.h - 5,
                  (dims.w < dims.h ? dims.w : dims.h) / 8));
    int nonBlack;
    foreach (p; broad.points)
        if (p.r != 0 || p.g != 0 || p.b != 0) ++nonBlack;
    // Population floor FIRST: an untouched all-zero FBO otherwise satisfies
    // every later "this pixel is absent" assertion vacuously.
    assert(nonBlack >= 40,
        format("frame scene phase left a degenerate black framebuffer: only "
               ~ "%d/%d broad samples are non-black",
               nonBlack, broad.points.length));

    auto corner = probe("cell=0&points=4,4").points[0];
    assert(nearClear(corner),
        format("frame scene phase did not publish the clear background: "
               ~ "corner is (%d,%d,%d)", corner.r, corner.g, corner.b));

    string interior;
    foreach (iy; 0 .. 6) foreach (ix; 0 .. 6) {
        if (interior.length) interior ~= ";";
        interior ~= (cast(int)(dims.w * (0.42 + 0.16 * ix / 5.0))).to!string
                 ~ ","
                 ~ (cast(int)(dims.h * (0.43 + 0.17 * iy / 5.0))).to!string;
    }
    auto fill = probe("cell=0&points=" ~ interior);
    int covered;
    foreach (p; fill.points) if (!nearClear(p)) ++covered;
    assert(covered >= 33,
        format("frame scene phase did not draw the model: only %d/%d "
               ~ "interior samples differ from the clear colour",
               covered, fill.points.length));
}

unittest { // panel draw: compare composed pixels with the panel hidden/shown
    resetKnownView();
    scope(exit) cleanupPanelWitness();
    cmd("tool.set move");
    cmd("ui.toolProperties hide");
    settle();

    auto dims = probe("target=frame&hash=1");
    assert(dims.renders && dims.w >= 430 && dims.h >= 550
        && dims.hash.length == 16,
        "panel witness has no composed default framebuffer: " ~ dims.hash);

    auto whole = probe("target=frame&points="
        ~ lattice(5, 5, dims.w - 6, dims.h - 6,
                  (dims.w < dims.h ? dims.w : dims.h) / 7));
    int distinct = whole.points.length ? 1 : 0;
    foreach (i; 1 .. whole.points.length)
        if (!sameRgb(whole.points[i], whole.points[0])) ++distinct;
    // Population floor FIRST: a blank composed target would make a hidden
    // panel and a panel whose draw vanished byte-identical for the wrong reason.
    assert(whole.points.length >= 40 && distinct >= 4,
        format("composed frame is degenerate before the panel check: "
               ~ "%d samples, %d differ from the first colour",
               whole.points.length, distinct));

    immutable string panelGrid = lattice(166, 16, 414, 524, 16);
    auto hidden = probe("target=frame&points=" ~ panelGrid);
    cmd("ui.toolProperties show");
    settle();
    auto shown = probe("target=frame&points=" ~ panelGrid);
    assert(hidden.points.length == shown.points.length
        && hidden.points.length >= 400,
        "panel pixel lattice was not populated in both states");

    int changed;
    foreach (i; 0 .. hidden.points.length)
        if (!sameRgb(hidden.points[i], shown.points[i])) ++changed;
    assert(changed >= 100,
        format("frame panel phase changed only %d/%d Tool Properties pixels "
               ~ "between hidden and shown states",
               changed, hidden.points.length));
}
