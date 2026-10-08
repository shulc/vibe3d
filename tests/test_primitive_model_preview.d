// Primitive candidates replace the complete primary model without changing
// source planes until release (20261670; doc/tasks/evidence/20261670-primitive-model-preview/plan.md).
module test_primitive_model_preview;

import http_client : getJson, postJson, frameFence, quiesce;
import http_command_helpers : commandBody;
import drag_helpers : Vec3, fetchCamera, viewportFromCamera, projectToWindow,
    buildDragLog, buildDragDownLog, buildDragMotionLog, buildDragUpLog, playAndWait;
import viewport_lattice_helpers : fillLattice, erodedFillIndices, kFillNX, kFillNY, latticePoint;
import std.exception : enforce, collectException;
import std.array : join;
import std.format : format;
import std.json : JSONValue, JSONType, parseJSON;
import std.math : abs, isFinite;
import std.stdio : writeln, writefln;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : getcwd, tempDir, exists, mkdirRecurse, rmdirRecurse, symlink;
import std.path : buildPath;
import std.process : Config, Pid, environment, spawnProcess, tryWait, kill, thisProcessID;
import std.socket : Socket, AddressFamily, SocketType, ProtocolType, InternetAddress,
    SocketOptionLevel, SocketOption;
import std.stdio : File, stdin;

private enum kPopulation = kFillNX * kFillNY;
private enum kInteriorFloor = 20;
private enum kSourceFloor = 20;
private enum string kSource = `{"vertices":[
    [-2.5,-0.65,-0.65],[-1.15,-0.65,-0.65],[-1.0,0.75,-0.65],[-2.3,0.55,-0.65],
    [-2.5,-0.65,0.65],[-1.15,-0.65,0.65],[-1.0,0.75,0.65],[-2.3,0.55,0.65]],
    "faces":[[3,2,1,0],[4,5,6,7],[0,1,5,4],[1,2,6,5],[2,3,7,6],[3,0,4,7]]}`;
private string activeTool;
private int[4] replayViewport;
// Replay remaps against the complete editor viewport, even in SplitH. Keep
// every positioned log explicit so a previous per-cell header cannot persist.
void playViewportLog(string log) {
    import std.string : indexOf;
    auto newline = log.indexOf('\n');
    if (newline >= 0 && log[0 .. newline].indexOf("VIEWPORT") >= 0)
        log = log[newline+1 .. $];
    playAndWait(format(`{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        replayViewport[0], replayViewport[1], replayViewport[2], replayViewport[3]) ~ log);
}

private struct PixelInstance { ushort port; string root; Pid pid; }
private PixelInstance launchPixelInstance() {
    auto socket = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
    socket.bind(new InternetAddress(InternetAddress.ADDR_ANY, 0));
    PixelInstance child; child.port = (cast(InternetAddress)socket.localAddress).port; socket.close();
    enforce(child.port != 8080, "private child needs an ephemeral port");
    child.root = buildPath(tempDir(), format("vibe3d-primitive-pixels-%d-%d", thisProcessID(), child.port));
    enforce(!exists(child.root), "private child scratch path already exists");
    mkdirRecurse(child.root); scope(failure) stopPixelInstance(child);
    auto repo = getcwd();
    symlink(buildPath(repo, "config"), buildPath(child.root, "config"));
    symlink(buildPath(repo, "assets"), buildPath(child.root, "assets"));
    auto childEnv = environment.toAA();
    childEnv["VIBE3D_CONFIG_DIR"] = child.root; childEnv["VIBE3D_TEST_DIRTY_KEY"] = "1";
    childEnv["LIBGL_ALWAYS_SOFTWARE"] = "1";
    childEnv["VIBE3D_TEST_LAYOUT_INI"] = buildPath(child.root, "layout.ini");
    auto log = File(buildPath(child.root, "editor.log"), "wb");
    child.pid = spawnProcess([buildPath(repo, "vibe3d"), "--test", "--viewport", "1024x544", "--http-port", child.port.to!string],
        stdin, log, log, childEnv, Config.none, child.root);
    const deadline = MonoTime.currTime + 6.seconds;
    while (MonoTime.currTime < deadline && !tryWait(child.pid).terminated) {
        try {
            auto ready = getJson("/api/camera", "http://127.0.0.1:" ~ child.port.to!string);
            if (number(ready["width"]) > 64) return child;
        } catch (Exception) {}
        Thread.sleep(25.msecs);
    }
    enforce(false, "private dirty-key pixel editor did not become ready");
    return child;
}
private void stopPixelInstance(ref PixelInstance child) {
    scope(exit) if (child.root.length && exists(child.root)) rmdirRecurse(child.root);
    if (child.pid !is null) {
        if (!tryWait(child.pid).terminated) {
            kill(child.pid);
            auto deadline = MonoTime.currTime + 1.seconds;
            while (!tryWait(child.pid).terminated && MonoTime.currTime < deadline) Thread.sleep(25.msecs);
            if (!tryWait(child.pid).terminated) kill(child.pid, 9);
        }
        auto deadline = MonoTime.currTime + 2.seconds;
        while (!tryWait(child.pid).terminated && MonoTime.currTime < deadline) Thread.sleep(25.msecs);
        enforce(tryWait(child.pid).terminated, "private pixel editor PID survived teardown");
        child.pid = null;
    }
    if (child.port) {
        auto socket = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
        scope(exit) socket.close();
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
        socket.bind(new InternetAddress(InternetAddress.ADDR_ANY, child.port));
        socket.listen(1);
    }
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    enforce(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ line ~ " => " ~ r.toString);
}
void command(string id, string args = "{}") { cmd(commandBody(id, args)); }
void fence() { quiesce(); frameFence(null, 2); }
void style(string value, int cell = -1) {
    command("viewport.displayStyle", format(`{"value":"%s","viewport":%d}`, value, cell));
    fence();
}
void wire(string value, int cell = -1) {
    command("viewport.wireOverlay", format(`{"value":"%s","viewport":%d}`, value, cell));
    fence();
}
void cleanup() {
    if (activeTool.length) collectException(cmd("tool.set " ~ activeTool ~ " off"));
    activeTool = "";
    foreach (cell; 0 .. 4) {
        collectException(style("shaded", cell));
        collectException(wire("uniform", cell));
        collectException(command("viewport.cavity", format(`{"value":"off","viewport":%d}`, cell)));
    }
    collectException(command("viewport.layout", `{"preset":"Single"}`));
    collectException(cmd("workplane.reset"));
}
string planes() { return getJson("/api/mesh/planes").toString; }
size_t history() { return getJson("/api/history")["undo"].array.length; }

double number(JSONValue j) {
    if (j.type == JSONType.uinteger) return j.uinteger;
    if (j.type == JSONType.integer) return j.integer;
    return j.floating;
}
struct Pixel { int r, g, b; }
struct Image { int w, h; Pixel[] pixels; bool[] keep; }
// Fixed spatial exclusions come only from the registered production parts,
// never from a preview/release colour difference. Ortho makes shaft extrapolation affine.
bool[] handleMask(int w, int h, int cell) {
    auto keep = new bool[](kPopulation); keep[] = true;
    if (!activeTool.length) return keep;
    forceCellDraw(cell);
    auto j = getJson("/api/tool/handles");
    if (j["handles"].type == JSONType.null_) return keep;
    auto c = getJson(format("/api/camera?viewport=%d", cell));
    immutable originX = number(c["vpX"]), originY = number(c["vpY"]);
    auto root = j["handles"];
    auto parts = root["parts"].array;
    if (parts.length == 0) {
        enforce(number(root["drawGeneration"]) == 0, "MASK_EMPTY_REGISTRY_WITNESS: no registered draw before the first handle stage");
        return keep;
    }
    enforce(number(root["drawGeneration"]) > 0 && number(root["planeRingsDrawn"]) == 0,
        "MASK_PLANE_RING_WITNESS: submitted primitive mover rings must be disabled");
    foreach (part; parts) {
        immutable id = cast(int)number(part["part"]);
        bool recognized = activeTool == "prim.tube" ? id == 10 || (id >= 0 && id <= 2)
            : activeTool == "prim.cube" ? (id >= 0 && id <= 3) || (id >= 10 && id <= 13) || id == 20 || id == 21
            : (id >= 0 && id <= 5) || (id >= 10 && id <= 13);
        enforce(recognized, "MASK_REGISTERED_PART_WITNESS: unknown primitive handle part");
        if (part["visible"].boolean) {
            enforce(part["screen"].type != JSONType.null_, "MASK_VISIBLE_ANCHOR_WITNESS: visible part has no projected anchor");
        }
        if (part["screen"].type != JSONType.null_) {
            enforce(part["screen"].array.length == 2
                && isFinite(number(part["screen"].array[0])) && isFinite(number(part["screen"].array[1])),
                "MASK_FINITE_ANCHOR_WITNESS: malformed registered handle anchor");
        }
    }
    double[2] centre; bool found;
    immutable centrePart = activeTool == "prim.tube" ? 10 : 13;
    foreach (part; parts) {
        if (!part["visible"].boolean || part["screen"].type == JSONType.null_) continue;
        if (cast(int)number(part["part"]) == centrePart) {
            centre = [number(part["screen"].array[0])-originX, number(part["screen"].array[1])-originY];
            found = true;
        }
    }
    foreach (part; parts) {
        if (!part["visible"].boolean || part["screen"].type == JSONType.null_) continue;
        immutable id = cast(int)number(part["part"]);
        double[2] a = [number(part["screen"].array[0])-originX,
            number(part["screen"].array[1])-originY];
        immutable arrow = activeTool == "prim.tube" ? id >= 0 && id <= 2 : id >= 10 && id <= 12;
        auto end = a;
        if (arrow) {
            enforce(found, "MASK_FINITE_CENTRE_WITNESS: visible arrow needs its finite centre");
            end = [centre[0]+(a[0]-centre[0])/0.76, centre[1]+(a[1]-centre[1])/0.76];
        }
        foreach (i; 0 .. kPopulation) {
            auto p = latticePoint(w, h, i);
            double dx = p[0]-a[0], dy = p[1]-a[1];
            bool excluded = dx*dx+dy*dy <= 16*16;
            if (arrow && found) {
                double vx = end[0]-centre[0], vy = end[1]-centre[1];
                double length2 = vx*vx+vy*vy;
                double t = length2 > 0 ? ((p[0]-centre[0])*vx+(p[1]-centre[1])*vy)/length2 : 0;
                if (t < 0) t = 0;
                if (t > 1) t = 1;
                dx = p[0]-centre[0]-t*vx; dy = p[1]-centre[1]-t*vy;
                excluded = excluded || dx*dx+dy*dy <= 16*16;
            }
            if (excluded) keep[i] = false;
        }
    }
    return keep;
}
void forceCellDraw(int cell) {
    auto path = format("/api/camera?viewport=%d", cell);
    auto before = getJson(path);
    auto moved = JSONValue.emptyObject; moved["distance"] = JSONValue(number(before["distance"])+0.03125);
    enforce(postJson(path, moved.toString)["status"].str == "ok", "target-cell camera dirty write");
    frameFence(null, 2);
    auto restored = JSONValue.emptyObject; restored["distance"] = before["distance"];
    enforce(postJson(path, restored.toString)["status"].str == "ok", "target-cell camera restoration");
    frameFence(null, 2);
    enforce(getJson(path) == before, "TARGET_CELL_CAMERA_RESTORATION: focal/projection/orientation changed");
}
void activateCell(int cell) {
    if (cast(int)number(getJson("/api/viewport/display")["activeId"]) == cell) return;
    auto c = getJson(format("/api/camera?viewport=%d", cell));
    playViewportLog(format(`{"t":0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
        ~ "\n", cast(int)number(c["vpX"])+24, cast(int)number(c["vpY"])+cast(int)number(c["height"])-24));
    fence();
    enforce(cast(int)number(getJson("/api/viewport/display")["activeId"]) == cell,
        "MASK_CELL_OWNER_WITNESS: registered handles must be read under the probed cell");
}
Image probe(string points = "", int cell = 0) {
    activateCell(cell);
    auto j = getJson(format("/api/viewport/probe?cell=%d", cell)
        ~ (points.length ? "&points=" ~ points : ""));
    enforce(j["renders"].boolean, "production probe must read a rendered cell");
    Image a; a.w = cast(int)number(j["w"]); a.h = cast(int)number(j["h"]);
    enforce(a.w >= 360 && a.h >= 300, "PIXEL_LATTICE_ENVELOPE: fixed lattice must fit the rendered cell");
    if (number(getJson("/api/viewport/display")["cellCount"]) == 2)
        enforce(a.w >= 512, "SPLIT_CELL_ENVELOPE: private 1024-wide child must provide 512-wide cells");
    foreach (p; j["points"].array) {
        enforce("error" !in p, "invalid probe sample: " ~ p.toString);
        a.pixels ~= Pixel(cast(int)number(p["r"]), cast(int)number(p["g"]), cast(int)number(p["b"]));
    }
    if (points.length) a.keep = handleMask(a.w, a.h, cell);
    return a;
}
bool same(Pixel a, Pixel b) {
    return abs(a.r-b.r) <= 2 && abs(a.g-b.g) <= 2 && abs(a.b-b.b) <= 2;
}
size_t differences(in Image a, in Image b) {
    enforce(a.w == b.w && a.h == b.h && a.pixels.length == kPopulation
        && b.pixels.length == kPopulation, "comparison needs the fixed 3000-sample population");
    size_t n;
    size_t population;
    foreach (i, p; a.pixels) if (a.keep[i] && b.keep[i]) {
        ++population;
        if (!same(p, b.pixels[i])) ++n;
    }
    enforce(population >= 2000, "fixed overlay mask must retain at least 2000 lattice samples");
    return n;
}
struct GPixel { long id, flags, nx, ny; }
GPixel[] gbuffer(string points, int cell) {
    auto j = getJson(format("/api/viewport/probe?cell=%d&buffer=gbuf&points=", cell) ~ points);
    enforce("error" !in j && j["renders"].boolean, "independent G-buffer must be rendered and allocated");
    GPixel[] result;
    foreach (p; j["points"].array) {
        enforce("error" !in p && p["gbuf"].array.length == 6, "G-buffer texel population");
        auto a = p["gbuf"].array;
        result ~= GPixel(cast(long)number(a[2]), cast(long)number(a[3]),
            cast(long)number(a[4]), cast(long)number(a[5]));
    }
    enforce(result.length == kPopulation, "independent G-buffer population must be 3000");
    return result;
}
bool normalSame(in GPixel a, in GPixel b) { return a.nx == b.nx && a.ny == b.ny; }
bool geometrySame(in GPixel a, in GPixel b) {
    if (a.id == 0 && b.id == 0) return true;
    return a.id == b.id && a.flags == b.flags && normalSame(a, b);
}
struct Surface { Image color; Image wireColor; bool[] fill; size_t[] interior; GPixel[] geometry; }
bool[] unionMask(in Image[] images) {
    auto keep = new bool[](kPopulation); keep[] = true;
    foreach (a; images) {
        enforce(a.keep.length == kPopulation, "mask needs all 3000 fixed lattice points");
        foreach (i; 0 .. kPopulation) keep[i] = keep[i] && a.keep[i];
    }
    size_t population;
    foreach (p; keep) if (p) ++population;
    enforce(population >= 2000, "MASK_FIXED_POPULATION: exclusions must leave at least 2000 samples");
    return keep;
}
Surface frozen(Surface s, in bool[] keep) {
    s.color.keep = keep.dup; s.wireColor.keep = keep.dup;
    bool[] cleanFill;
    foreach (i, p; s.color.pixels)
        cleanFill ~= keep[i] && s.fill[i] && !same(p, s.wireColor.pixels[i]);
    s.interior = erodedFillIndices(cleanFill);
    return s;
}
Surface surface(string points, int cell = 0) {
    style("shaded", cell); auto a = probe(points, cell);
    style("wireframe", cell); auto b = probe(points, cell);
    style("shaded", cell);
    auto geometry = gbuffer(points, cell);
    enforce(a.pixels.length == kPopulation && b.pixels.length == kPopulation,
        "fill classification needs the fixed 3000-sample lattice");
    Surface s; s.color = a; s.wireColor = b; s.geometry = geometry;
    bool[] cleanFill;
    foreach (i, p; a.pixels) {
        s.fill ~= geometry[i].id != 0;
        cleanFill ~= s.fill[i] && !same(p, b.pixels[i]) && a.keep[i] && b.keep[i];
    }
    s.interior = erodedFillIndices(cleanFill);
    return s;
}
void witness(Surface source, Surface live, bool hasSource, string label) {
    auto mask = unionMask([source.color, source.wireColor, live.color, live.wireColor]);
    source = frozen(source, mask); live = frozen(live, mask);
    size_t newGeometry, survivingGeometry;
    foreach (i; 0 .. kPopulation) {
        if (!source.fill[i] && live.fill[i]) ++newGeometry;
        if (source.fill[i] && live.fill[i] && source.geometry[i].id == live.geometry[i].id
            && source.geometry[i].flags == live.geometry[i].flags && normalSame(source.geometry[i], live.geometry[i]))
            ++survivingGeometry;
    }
    enforce(newGeometry >= 20, format("%s GBUFFER_GENERATED_POPULATION: %d new occupied samples", label, newGeometry));
    if (hasSource) enforce(survivingGeometry >= 20,
        format("%s GBUFFER_SOURCE_POPULATION: %d surviving source samples", label, survivingGeometry));
    enforce(live.interior.length >= kInteriorFloor,
        format("%s INTERIOR_POPULATION: %d eroded samples", label, live.interior.length));
    size_t generated;
    foreach (i; live.interior)
        if (!source.fill[i] && !same(live.color.pixels[i], source.color.pixels[i])) ++generated;
    enforce(generated >= kInteriorFloor,
        format("%s GENERATED_INTERIOR_WITNESS: %d new eroded fill pixels", label, generated));
    if (hasSource) {
        enforce(source.interior.length >= kSourceFloor,
            format("%s SOURCE_PREFIX_POPULATION: %d eroded source samples", label, source.interior.length));
        size_t sourcePixels;
        foreach (i; source.interior) if (live.color.keep[i]) {
            ++sourcePixels;
            enforce(live.fill[i] && same(source.color.pixels[i], live.color.pixels[i])
                && source.geometry[i].id == live.geometry[i].id
                && normalSame(source.geometry[i], live.geometry[i]),
                format("%s SOURCE_PREFIX_WITNESS: source sample %d disappeared or changed", label, i));
        }
        enforce(sourcePixels >= kSourceFloor, label ~ " SOURCE_PREFIX_MASK_POPULATION");
    }
}
void matches(Surface source, Surface live, Surface saved, bool hasSource, string label) {
    auto mask = unionMask([source.color, source.wireColor, live.color, live.wireColor, saved.color, saved.wireColor]);
    source = frozen(source, mask); live = frozen(live, mask); saved = frozen(saved, mask);
    witness(source, live, hasSource, label);
    witness(source, saved, hasSource, label ~ " RELEASED");
    enforce(live.color.w == saved.color.w && live.color.h == saved.color.h,
        label ~ " camera dimensions moved on release");
    size_t moved;
    foreach (i, f; live.fill) {
        if (f != saved.fill[i]) ++moved;
        if (f && saved.fill[i])
            enforce(live.geometry[i].id == saved.geometry[i].id
                && live.geometry[i].flags == saved.geometry[i].flags
                && normalSame(live.geometry[i], saved.geometry[i]),
                format("%s GBUFFER_NORMAL_MATCH: lattice sample %d changed", label, i));
    }
    enforce(moved == 0,
        format("%s PREVIEW_RELEASE_SILHOUETTE_MATCH: %d occupancy samples change", label, moved));
    size_t colorDifferences; size_t firstDifference;
    foreach (i; live.interior) if (!same(live.color.pixels[i], saved.color.pixels[i])) {
        if (colorDifferences++ == 0) firstDifference = i;
    }
    if (colorDifferences) {
        auto i = firstDifference;
        enforce(false, format("%s PREVIEW_RELEASE_INTERIOR_MATCH: %d samples differ, first %d at %s live=%s saved=%s", label,
            colorDifferences, i, latticePoint(live.color.w,live.color.h,i), live.color.pixels[i], saved.color.pixels[i]));
    }
}

// Invalid observer inputs and an altered unmasked colour must be refused by
// the same helpers that judge production captures (20261670 amendment).
void observerValidation() {
    import std.algorithm.searching : canFind;
    void rejects(void delegate() check, string expected) {
        auto error = collectException(check());
        enforce(error !is null && error.msg.canFind(expected),
            "OBSERVER_REJECTION_WITNESS: expected " ~ expected ~
            (error is null ? " but the invalid fixture passed" : " but got " ~ error.msg));
    }
    Surface fixture(bool occupied) {
        Surface s;
        s.color.w = s.wireColor.w = 1024; s.color.h = s.wireColor.h = 544;
        s.color.pixels = new Pixel[](kPopulation); s.wireColor.pixels = new Pixel[](kPopulation);
        s.color.keep = new bool[](kPopulation); s.color.keep[] = true;
        s.wireColor.keep = s.color.keep.dup;
        s.fill = new bool[](kPopulation); s.fill[] = occupied;
        s.geometry = new GPixel[](kPopulation);
        if (occupied) {
            s.color.pixels[] = Pixel(120, 120, 120);
            s.geometry[] = GPixel(1, 0, 32000, 32000);
        }
        return s;
    }
    auto source = fixture(false), live = fixture(true);
    matches(source, live, live, false, "OBSERVER_VALID_CONTROL");
    auto malformed = live.color; malformed.keep = new bool[](kPopulation+1); malformed.keep[] = true;
    rejects(() { unionMask([malformed]); }, "mask needs all 3000 fixed lattice points");
    auto tinyMask = live.color; tinyMask.keep = new bool[](kPopulation); tinyMask.keep[0] = true;
    rejects(() { unionMask([tinyMask]); }, "MASK_FIXED_POPULATION");
    auto tiny = fixture(false);
    tiny.fill[0] = true; tiny.geometry[0] = live.geometry[0]; tiny.color.pixels[0] = live.color.pixels[0];
    rejects(() { witness(source, tiny, false, "TINY_GENERATED"); }, "GBUFFER_GENERATED_POPULATION");
    foreach (i; 0 .. 20) {
        tiny.fill[i] = true; tiny.geometry[i] = live.geometry[i]; tiny.color.pixels[i] = live.color.pixels[i];
    }
    rejects(() { witness(source, tiny, false, "TINY_INTERIOR"); }, "INTERIOR_POPULATION");
    auto covered = fixture(true);
    foreach (i; 0 .. 20) {
        covered.fill[i] = false; covered.geometry[i] = GPixel.init; covered.color.pixels[i] = Pixel.init;
    }
    rejects(() { witness(covered, live, false, "NO_GENERATED_INTERIOR"); }, "GENERATED_INTERIOR_WITNESS");
    auto sourcePoint = fixture(false);
    sourcePoint.fill[0] = true; sourcePoint.geometry[0] = live.geometry[0]; sourcePoint.color.pixels[0] = live.color.pixels[0];
    rejects(() { witness(sourcePoint, live, true, "TINY_SOURCE_GEOMETRY"); }, "GBUFFER_SOURCE_POPULATION");
    rejects(() { witness(tiny, live, true, "TINY_SOURCE_INTERIOR"); }, "SOURCE_PREFIX_POPULATION");
    auto altered = fixture(true);
    altered.color.pixels[kFillNX+1].r += 8;
    rejects(() { matches(source, live, altered, false, "ALTERED_UNMASKED_COLOUR"); },
        "PREVIEW_RELEASE_INTERIOR_MATCH");
}

void nativeSource(bool materials) {
    import std.file : write, tempDir, exists, remove;
    import std.path : buildPath;
    import std.process : thisProcessID;
    auto m = parseJSON(kSource);
    if (materials) {
        m["surfaces"] = parseJSON(`[
            {"name":"Primitive default","baseColor":[0.9,0.08,0.05],"diffuse":1,"specular":0,"opacity":1},
            {"name":"Source blue","baseColor":[0.05,0.12,0.9],"diffuse":1,"specular":0,"opacity":1}]`);
        m["faceMaterial"] = parseJSON(`[1,1,1,1,0,1]`);
    }
    auto layer = JSONValue.emptyObject;
    layer["type"] = JSONValue("mesh"); layer["selected"] = JSONValue(true);
    layer["channels"] = parseJSON(`{"name":"Primitive source rig","visible":true}`);
    layer["mesh"] = m;
    auto scene = JSONValue.emptyObject;
    scene["formatVersion"] = JSONValue(8); scene["primaryLayer"] = JSONValue(0);
    scene["focusedItem"] = JSONValue(0); scene["layers"] = JSONValue([layer]);
    auto path = buildPath(tempDir(), format("vibe3d-primitive-preview-%d.v3d", thisProcessID()));
    write(path, scene.toString);
    scope(exit) if (exists(path)) remove(path);
    command("file.load", format(`{"path":"%s"}`, path));
    enforce(getJson("/api/model")["vertices"].array.length == 8
        && getJson("/api/model")["faces"].array.length == 6, "source geometry population must be 8/6");
    if (materials) enforce(getJson("/api/model")["surfaces"].array.length == 2,
        "material source needs exactly two surface slots");
}
void cameraWitness(string preset, bool pinned = false, int cell = 0) {
    auto c = getJson(format("/api/camera?viewport=%d", cell));
    enforce(c["projKind"].str == "Ortho" && c["viewPreset"].str == preset
        && getJson("/api/viewport/display")["cells"].array[cell]["ortho"].boolean,
        "ACTUAL_AXIS_CAMERA: preset must render orthographically");
    auto matrix = c["viewMatrix"].array;
    enforce(matrix.length == 16, "ACTUAL_AXIS_CAMERA: complete rendered view matrix");
    foreach (axis, key; ["x", "y", "z"])
        enforce(abs(number(c["eye"][key])-number(c["focus"][key])
            - number(matrix[2+axis*4])*number(c["distance"])) < 0.0001,
            "ACTUAL_AXIS_CAMERA: eye must follow the rendered back row");
    if (!pinned) {
        immutable backY = preset == "Bottom" ? -1.0 : 1.0;
        enforce(abs(number(matrix[2])) < 0.00001 && abs(number(matrix[6])-backY) < 0.00001
            && abs(number(matrix[10])) < 0.00001 && abs(number(matrix[0])-1) < 0.00001
            && abs(number(matrix[9])+(preset == "Bottom" ? -1.0 : 1.0)) < 0.00001,
            "ACTUAL_AXIS_CAMERA: reset-plane Top/Bottom rendered basis");
    }
}
void bottomCamera(bool pinned = false) {
    auto top = getJson("/api/camera")["viewMatrix"].array;
    cmd("viewport.view Bottom"); fence(); park();
    cameraWitness("Bottom", pinned);
    auto bottom = getJson("/api/camera")["viewMatrix"].array;
    foreach (axis; 0 .. 3)
        enforce(abs(number(top[2+axis*4])+number(bottom[2+axis*4])) < 0.00001,
            "BOTTOM_SIGNED_CAMERA: rendered back must oppose the preceding Top under the same plane");
}
void camera(int cell = 0, bool pinned = false) {
    activateCell(cell); cmd("viewport.view Top");
    auto r = postJson(format("/api/camera?viewport=%d", cell),
        `{"distance":8.5,"roll":0,"focus":{"x":0,"y":0,"z":0}}`);
    enforce(r["status"].str == "ok", "camera setup: " ~ r.toString);
    command("viewport.cavityParams", format(`{"screenRidge":0,"screenValley":0,"viewport":%d}`, cell));
    command("viewport.cavity", format(`{"value":"screen","viewport":%d}`, cell));
    fence(); cameraWitness("Top", pinned, cell);
}
void park() {
    immutable intendedCell = cast(int)number(getJson("/api/viewport/display")["activeId"]);
    auto c = fetchCamera();
    playViewportLog(format(`{"t":0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
        ~ "\n", c.vpX+24, c.vpY+c.height-24));
    fence();
    enforce(cast(int)number(getJson("/api/viewport/display")["activeId"]) == intendedCell,
        "PARK_CELL_OWNER_WITNESS: safe interior parking must retain the intended cell");
}
void setup(bool hasSource, bool materials = false, bool transformed = false, bool rotatedPlane = false) {
    cleanup(); command("scene.reset", `{"empty":true}`);
    if (hasSource) nativeSource(materials);
    command("mesh.select", `{"mode":"polygons","indices":[]}`);
    if (transformed) {
        cmd("layer.attr 0 pos.x 0.45"); cmd("layer.attr 0 pos.y 0.2"); cmd("layer.attr 0 rot.y 23");
    }
    if (rotatedPlane) cmd("workplane.edit cenX:0.15 cenY:0.1 cenZ:0.1 rotX:12 rotY:15 rotZ:8");
    cmd("tool.pipe.attr snap enabled false");
    camera(0, rotatedPlane); wire("none"); style("shaded"); park(); cmd("history.clear"); fence();
}
int[2] pixel(Vec3 p) {
    float x, y;
    auto vp = viewportFromCamera(fetchCamera());
    enforce(projectToWindow(p, vp, x, y), "construction point projects");
    return [cast(int)x, cast(int)y];
}
void drag(int[2] p, int dx, int dy) {
    auto c = fetchCamera();
    playViewportLog(buildDragLog(c.vpX, c.vpY, c.width, c.height, p[0], p[1], p[0]+dx, p[1]+dy, 8));
    fence();
}
void arm(string tool) {
    activeTool = tool; cmd("tool.set " ~ tool);
    if (tool == "prim.cube") {
        foreach (axis; ["X", "Y", "Z"]) cmd("tool.attr " ~ tool ~ " segments" ~ axis ~ " 1");
        cmd("tool.attr " ~ tool ~ " radius 0");
    } else if (tool == "prim.torus") {
        cmd("tool.attr " ~ tool ~ " majorSegments 24"); cmd("tool.attr " ~ tool ~ " minorSegments 12");
    } else if (tool == "prim.tube") {
        cmd("tool.attr " ~ tool ~ " segments 24"); cmd("tool.attr " ~ tool ~ " cap true");
    } else {
        if (tool == "prim.sphere") cmd("tool.attr " ~ tool ~ " method 0");
        cmd("tool.attr " ~ tool ~ " sides 24");
        cmd("tool.attr " ~ tool ~ " segments " ~ (tool == "prim.sphere" ? "24" : "1"));
        if (tool == "prim.capsule") {
            cmd("tool.attr " ~ tool ~ " endsegments 6"); cmd("tool.attr " ~ tool ~ " endsize 1");
        }
    }
    fence();
}
double attr(string name) {
    auto r = postJson("/api/command", "tool.attr " ~ activeTool ~ " " ~ name ~ " ?");
    enforce(r["status"].str == "ok", "attribute query failed");
    return number(r["value"]);
}
void setAttr(string name, double value) { cmd(format("tool.attr %s %s %.6f", activeTool, name, value)); }
void normalizeShape(bool hasSource) {
    setAttr("cenX", hasSource ? 1.15 : 0); setAttr("cenY", 0); setAttr("cenZ", 0);
    if (activeTool == "prim.torus") {
        setAttr("majorRadius", 0.8); setAttr("minorRadius", 0.22);
    } else if (activeTool == "prim.tube") {
        setAttr("outerRadius", 0.9); setAttr("innerRadius", 0.42); setAttr("height", 1.4);
    } else {
        foreach (n; ["sizeX", "sizeY", "sizeZ"]) setAttr(n, activeTool == "prim.cube" ? 1.55 : 0.8);
    }
    fence(); park();
}
void construct(string tool, bool hasSource) {
    arm(tool);
    auto p = pixel(Vec3(hasSource ? 1.15f : 0, 0, 0));
    drag(p, 90, 65);
    // Clearance from degenerate base centre handles is required by Sphere's
    // state-aware ellipse/volume branch; this is the interactive suite's rig.
    drag([p[0]-15, p[1]], 0, -75);
    if (tool == "prim.tube") drag([p[0]+30, p[1]+20], 0, 0);
    normalizeShape(hasSource);
}
void release(string sourcePlanes, JSONValue sourceModel, bool box, string label) {
    enforce(planes() == sourcePlanes, label ~ " SOURCE_PLANES_BEFORE_RELEASE: preview wrote the source");
    if (!box) enforce(history() == 0, label ~ " FAMILY_PREVIEW_HISTORY: live family edit records history");
    cmd("tool.release"); activeTool = ""; fence();
    auto saved = getJson("/api/model");
    enforce(saved["faces"].array.length > sourceModel["faces"].array.length,
        label ~ " RELEASE_POPULATION: release added no primitive faces");
    enforce(history() == 1, label ~ " RELEASE_HISTORY: release must collapse into one real mesh edit");
    foreach (i, v; sourceModel["vertices"].array)
        enforce(saved["vertices"].array[i] == v, label ~ " RELEASE_SOURCE_VERTICES: source prefix moved");
    foreach (i, f; sourceModel["faces"].array)
        enforce(saved["faces"].array[i] == f, label ~ " RELEASE_SOURCE_FACES: source prefix changed");
    enforce(planes() != sourcePlanes, label ~ " RELEASE_PLANES: release left source-only geometry");
    command("mesh.select", `{"mode":"polygons","indices":[]}`);
    park(); fence();
}
void pair(string tool, bool hasSource, bool transformed = false) {
    setup(hasSource, false, transformed); scope(exit) cleanup();
    auto dim = probe(); auto points = fillLattice(dim.w, dim.h);
    auto original = surface(points); auto before = planes(); auto model = getJson("/api/model");
    construct(tool, hasSource); auto live = surface(points);
    release(before, model, false, tool);
    matches(original, live, surface(points), hasSource, tool);
}
void sphereCell() { pair("prim.sphere", false); }
void coneCell() { pair("prim.cone", false); }
void capsuleCell() { pair("prim.capsule", true); }
void cylinderCell() { pair("prim.cylinder", true, true); }

void boxCell() {
    Image[] styleImages;
    foreach (displayStyle; ["shaded", "solid", "wireframe"]) {
        setup(true, true, false, true); scope(exit) cleanup();
        bottomCamera(true);
        auto dim = probe(); auto points = fillLattice(dim.w, dim.h);
        auto original = surface(points); auto before = planes(); auto model = getJson("/api/model");
        construct("prim.cube", true);
        auto depth = history(); auto old = attr("sizeX"); setAttr("sizeX", old + 0.2); fence();
        enforce(history() == depth+1 && planes() == before,
            "BOX_PARAMETER_HISTORY: property edit must record one live ladder step without writing source");
        auto live = surface(points); witness(original, live, true, "BOX");
        if (displayStyle == "shaded") {
            size_t red, blue;
            foreach (i; live.interior) {
                auto p = live.color.pixels[i];
                if (p.r > p.b+20) ++red;
                if (p.b > p.r+20) ++blue;
            }
            enforce(red >= 5 && blue >= 5,
                format("BOX_MATERIAL_SLOTS_WITNESS: red=%d blue=%d", red, blue));
        }
        style(displayStyle); auto liveStyle = probe(points); styleImages ~= liveStyle;
        release(before, model, true, "BOX " ~ displayStyle);
        matches(original, live, surface(points), true, "BOX " ~ displayStyle);
        style(displayStyle);
        enforce(differences(liveStyle, probe(points)) == 0,
            "BOX_STYLE_RELEASE_MATCH: " ~ displayStyle);
    }
    enforce(styleImages.length == 3, "box style population must be three fresh gestures");
    enforce(differences(styleImages[0], styleImages[1]) >= 5
        && differences(styleImages[0], styleImages[2]) >= 20,
        "BOX_STYLE_WITNESS: shaded, solid and wireframe must produce distinct positive pixels");
}

void flatCell() {
    foreach (tool; ["prim.cube", "prim.sphere", "prim.cylinder"]) {
        setup(false); scope(exit) cleanup();
        if (tool == "prim.cube" || tool == "prim.sphere") {
            // Actual Bottom faces the Sphere ellipse's -Y normal and exercises
            // Box's negative signed base winding (approved rig-amendment).
            bottomCamera();
        }
        auto dim = probe(); auto points = fillLattice(dim.w, dim.h);
        auto original = surface(points); auto before = planes(); auto model = getJson("/api/model");
        arm(tool); auto p = pixel(Vec3(0, 0, 0)); auto c = fetchCamera();
        playViewportLog(buildDragDownLog(c.vpX, c.vpY, c.width, c.height, p[0], p[1]));
        playViewportLog(buildDragMotionLog(c.vpX, c.vpY, c.width, c.height,
            p[0], p[1], p[0]+120, p[1]+90, 8)); fence();
        auto drawing = surface(points);
        witness(original, drawing, false, tool ~ " DRAWING_BASE");
        enforce(planes() == before, tool ~ " DRAWING_BASE_SOURCE: live press wrote source");
        playViewportLog(buildDragUpLog(c.vpX, c.vpY, c.width, c.height,
            p[0]+120, p[1]+90)); fence(); park();
        auto standing = surface(points);
        matches(original, drawing, standing, false, tool ~ " DRAWING_BASE_BASESET");
        release(before, model, tool == "prim.cube", tool ~ " FLAT");
        matches(original, standing, surface(points), false, tool ~ " FLAT_RELEASE");
        auto saved = getJson("/api/model");
        enforce(saved["faces"].array.length == 1,
            tool ~ " FLAT_BUILDER: final base must remain one flat polygon");
        enforce(saved["vertices"].array.length == (tool == "prim.cube" ? 4 : 24),
            tool ~ " FLAT_VERTEX_POPULATION: sphere must use the interactive ellipse builder");
    }
}

void tubeCell() {
    setup(false); scope(exit) cleanup();
    auto dim = probe(); auto points = fillLattice(dim.w, dim.h);
    auto original = surface(points); auto before = planes(); auto model = getJson("/api/model");
    arm("prim.tube"); auto p = pixel(Vec3(0, 0, 0)); drag(p, 100, 80);
    enforce(attr("outerRadius") > 0.1 && attr("height") == 0,
        "TUBE_OUTERSET_LIFECYCLE: outer stage must have radius and no height");
    auto outer = surface(points); witness(original, outer, false, "TUBE_OUTERSET");
    enforce(planes() == before && history() == 0,
        "TUBE_OUTERSET_SOURCE: noncommittable preview must preserve source/history");
    drag(p, 0, -80); drag([p[0]+30, p[1]+20], 0, 0); normalizeShape(false);
    auto live = surface(points); release(before, model, false, "TUBE");
    matches(original, live, surface(points), false, "TUBE");
}

void subpatch(bool on) {
    command("mesh.select", `{"mode":"polygons","indices":[]}`);
    cmd("mesh.subpatch_toggle"); fence();
    auto p = getJson("/api/subpatch/preview");
    enforce(p["active"].boolean == on && !p["pending"].boolean,
        "source subdivision must reach the requested settled state");
}
void torusCell() {
    setup(true); scope(exit) cleanup();
    auto dim = probe(); auto points = fillLattice(dim.w, dim.h);
    auto cage = surface(points); subpatch(true);
    auto original = surface(points);
    size_t rounded;
    foreach (i, f; cage.fill) if (f != original.fill[i]) ++rounded;
    enforce(rounded >= 20, format("TORUS_SOURCE_LIMIT_WITNESS: %d cage/limit occupancy differences", rounded));
    cmd("history.clear"); auto before = planes(); auto model = getJson("/api/model");
    construct("prim.torus", true); auto first = surface(points);
    witness(original, first, true, "TORUS_FIRST");
    auto key = getJson("/api/viewport/display")["cells"].array[0]["toolPreviewKey"];
    setAttr("minorRadius", 0.36); fence();
    enforce(getJson("/api/viewport/display")["cells"].array[0]["toolPreviewKey"] != key,
        "TORUS_PARAMETER_UPLOAD_WITNESS: shape edit did not change uploaded candidate");
    auto live = surface(points);
    size_t changedGeometry;
    foreach (i; 0 .. kPopulation) if (!geometrySame(first.geometry[i], live.geometry[i])) ++changedGeometry;
    enforce(changedGeometry >= 20,
        format("TORUS_PARAMETER_GBUFFER_WITNESS: %d occupied/normal samples change", changedGeometry));
    enforce(differences(first.color, live.color) >= 20,
        "TORUS_PARAMETER_PIXEL_WITNESS: changed thickness shows stale candidate/cache");
    release(before, model, false, "TORUS_LIMIT");
    matches(original, live, surface(points), true, "TORUS_LIMIT");
}

void multiCell() {
    setup(false); scope(exit) cleanup();
    command("viewport.layout", `{"preset":"SplitH"}`); fence();
    foreach (cell; 0 .. 2) {
        camera(cell); wire("none", cell);
    }
    auto before = planes(); auto model = getJson("/api/model");
    string[2] points; Surface[2] original, live;
    foreach (cell; 0 .. 2) {
        auto dim = probe("", cell); points[cell] = fillLattice(dim.w, dim.h);
        original[cell] = surface(points[cell], cell);
    }
    construct("prim.cylinder", false);
    foreach (cell; 0 .. 2) live[cell] = surface(points[cell], cell);
    style("shaded", 0); style("wireframe", 1);
    auto plans = getJson("/api/viewport/display")["cells"].array;
    enforce(plans.length == 2 && plans[0]["plan"]["active"]["drawFaces"].boolean
        && !plans[1]["plan"]["active"]["drawFaces"].boolean,
        "CYLINDER_TWO_CELL_PLAN_WITNESS: live cells need independent filled/line plans");
    Image[2] styled;
    foreach (cell; 0 .. 2) styled[cell] = probe(points[cell], cell);
    enforce(differences(styled[0], styled[1]) >= 20,
        "CYLINDER_TWO_CELL_PIXEL_WITNESS: different plans must produce different positive pixels");
    release(before, model, false, "CYLINDER_TWO_CELL");
    foreach (cell; 0 .. 2) {
        enforce(differences(styled[cell], probe(points[cell], cell)) == 0,
            format("CYLINDER_TWO_CELL_RELEASE_MATCH: cell %d changes under its own plan", cell));
        matches(original[cell], live[cell], surface(points[cell], cell), false,
            format("CYLINDER_CELL_%d", cell));
    }
}

void cancelCell() {
    setup(true); scope(exit) cleanup();
    auto dim = probe(); auto points = fillLattice(dim.w, dim.h);
    auto original = surface(points); auto before = planes();
    construct("prim.capsule", true); auto live = surface(points);
    witness(original, live, true, "CANCEL_CAPSULE");
    auto c = fetchCamera();
    playViewportLog(`{"t":50,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
        ~ `{"t":60,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n");
    fence(); park();
    enforce(planes() == before && history() == 0, "CANCEL_SOURCE_HISTORY: cancel changed authoritative state");
    auto cancelled = surface(points);
    foreach (i; 0 .. kPopulation)
        enforce(geometrySame(original.geometry[i], cancelled.geometry[i]), "CANCEL_GBUFFER_RESTORATION_MATCH");
    enforce(original.interior.length >= kSourceFloor,
        "CANCEL_SOURCE_POPULATION: restoration needs visible source geometry");
    enforce(differences(original.color, cancelled.color) == 0,
        "CANCEL_RESTORATION_MATCH: cancelled candidate remains displayed");
    cmd("tool.release"); activeTool = ""; fence();
    enforce(planes() == before && history() == 0, "CANCEL_DROP_SOURCE: dropping cancelled edit committed geometry");
    auto dropped = surface(points);
    foreach (i; 0 .. kPopulation)
        enforce(geometrySame(original.geometry[i], dropped.geometry[i]), "CANCEL_DROP_GBUFFER_RESTORATION_MATCH");
    enforce(differences(original.color, dropped.color) == 0,
        "CANCEL_DROP_RESTORATION_MATCH: dropping idle tool changes restored pixels");
}

int main() {
    import liveness_gate : scenario;
    import std.process : environment;
    const bool hadPort = ("VIBE3D_TEST_PORT" in environment.toAA()) !is null;
    const priorPort = environment.get("VIBE3D_TEST_PORT", "");
    const priorTool = activeTool;
    auto child = launchPixelInstance();
    scope(exit) {
        if (hadPort) environment["VIBE3D_TEST_PORT"] = priorPort;
        else environment.remove("VIBE3D_TEST_PORT");
        activeTool = priorTool;
    }
    scope(exit) stopPixelInstance(child);
    environment["VIBE3D_TEST_PORT"] = child.port.to!string;
    scope(exit) cleanup();
    fence();
    auto fullViewport = fetchCamera();
    const priorReplayViewport = replayViewport; scope(exit) replayViewport = priorReplayViewport;
    replayViewport = [fullViewport.vpX, fullViewport.vpY, fullViewport.width, fullViewport.height];
    auto idleBefore = getJson("/api/frames/counts")["totals"];
    frameFence(null, 4);
    auto idleAfter = getJson("/api/frames/counts")["totals"];
    enforce(number(idleAfter["cellsConsidered"])-number(idleBefore["cellsConsidered"]) >= 4
        && number(idleAfter["cellsRendered"])-number(idleBefore["cellsRendered"])
            < number(idleAfter["cellsConsidered"])-number(idleBefore["cellsConsidered"]),
        "PRIVATE_DIRTY_KEY_WITNESS: child must skip settled cell renders");
    bool snapEnabled;
    foreach (st; getJson("/api/toolpipe")["stages"].array)
        if (st["task"].str == "SNAP") snapEnabled = st["attrs"]["enabled"].str == "true";
    scope(exit) collectException(cmd("tool.pipe.attr snap enabled " ~ (snapEnabled ? "true" : "false")));
    auto filter = environment.get("VIBE3D_CELL", "");
    int passed, failed; string[] errors;
    void run(void function() fn, string id) {
        if (filter.length && filter != id) return;
        scenario(id);
        try { observerValidation(); fn(); ++passed; }
        catch (Exception e) { ++failed; errors ~= id ~ " — " ~ e.msg; }
    }
    run(&boxCell, "box"); run(&cylinderCell, "cylinder"); run(&sphereCell, "sphere");
    run(&coneCell, "cone"); run(&capsuleCell, "capsule"); run(&torusCell, "torus");
    run(&tubeCell, "tube"); run(&flatCell, "flat"); run(&multiCell, "multi"); run(&cancelCell, "cancel");
    enforce(passed+failed == (filter.length ? 1 : 10),
        "SCENARIO_POPULATION: selected pixel filter must execute exactly one scenario, or all ten");
    if (errors.length) writeln("FAIL: ", errors.join(" | "));
    cleanup(); writefln("%d passed, %d failed", passed, failed);
    return failed ? 1 : 0;
}
