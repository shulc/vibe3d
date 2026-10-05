// Attribute-level RMB gesture laws shared by the falloff kinds.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.json : parseJSON, JSONType;
import std.math : fabs;
import std.net.curl : get, post;
import std.string : split;
import core.thread : Thread;
import core.time : msecs;

import drag_helpers : CameraState, buildDragLog, fetchCamera, playAndWait;

void main() {}

alias BASE = testBaseUrl;

void cmd(string line) {
    auto response = postJson("/api/command", line);
    assert(response["status"].str == "ok",
        "command failed: " ~ line ~ " => " ~ response.toString);
}

string[string] falloffAttrs() {
    foreach (stage; getJson("/api/toolpipe")["stages"].array) {
        if (stage["task"].str != "WGHT") continue;
        string[string] attrs;
        foreach (name, value; stage["attrs"].object)
            attrs[name] = value.str;
        return attrs;
    }
    assert(false, "WGHT stage missing from /api/toolpipe");
}

float[3] vec3(string value) {
    auto parts = value.split(",");
    assert(parts.length == 3, "invalid Vec3 attribute: " ~ value);
    return [parts[0].to!float, parts[1].to!float, parts[2].to!float];
}

float[3] sub(float[3] a, float[3] b) {
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
}

bool near(float a, float b, float eps = 1e-4f) {
    return fabs(a - b) <= eps;
}

bool near3(float[3] a, float[3] b, float eps = 1e-4f) {
    foreach (axis; 0 .. 3)
        if (!near(a[axis], b[axis], eps)) return false;
    return true;
}

string viewportEvent(CameraState camera) {
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        camera.vpX, camera.vpY, camera.width, camera.height);
}

void playSegment(string log) {
    auto response = post(BASE ~ "/api/play-events", log);
    auto parsed = parseJSON(cast(string)response);
    assert(parsed["status"].str == "success",
        "play-events failed: " ~ cast(string)response);
    foreach (_; 0 .. 200) {
        auto status = parseJSON(cast(string)get(BASE ~ "/api/play-events/status"));
        if (status["finished"].type == JSONType.true_) return;
        Thread.sleep(50.msecs);
    }
    assert(false, "play-events did not finish within 10 seconds");
}

void pressOnly(CameraState camera, int x, int y) {
    playSegment(viewportEvent(camera) ~ format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        x, y));
}

void releaseOnly(CameraState camera, int x, int y) {
    playSegment(viewportEvent(camera) ~ format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        x, y));
}

void resetAsymmetricRig() {
    auto reset = postJson("/api/command",
        commandBody("scene.reset", `{"empty":true}`));
    assert(reset["status"].str == "ok", "empty reset failed");
    cmd("select.typeFrom vertex");
    cmd("prim.cube cenX:3 cenY:2 cenZ:-1 sizeX:4 sizeY:1 sizeZ:0.5 "
        ~ "segmentsX:2 segmentsY:2 segmentsZ:2 radius:0");

    auto verts = getJson("/api/model")["vertices"].array;
    assert(verts.length != 0, "asymmetric RMB rig contains no vertices");
    float[3] lo;
    float[3] hi;
    foreach (axis; 0 .. 3) {
        lo[axis] = cast(float)verts[0].array[axis].floating;
        hi[axis] = lo[axis];
    }
    foreach (vertex; verts) foreach (axis; 0 .. 3) {
        float value = cast(float)vertex.array[axis].floating;
        if (value < lo[axis]) lo[axis] = value;
        if (value > hi[axis]) hi[axis] = value;
    }
    const float[3] extents =
        [hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]];
    assert(near3(extents, [4.0f, 1.0f, 0.5f]),
        format("A control rig must retain three distinct extents 4/1/0.5; got %s",
               extents));

    cmd("tool.set move");
    auto pipe = getJson("/api/toolpipe");
    bool foundWork;
    foreach (stage; pipe["stages"].array) {
        if (stage["task"].str == "WORK") {
            foundWork = true;
            assert(stage["attrs"]["mode"].str == "auto",
                "A control rig must use the default construction plane");
            break;
        }
    }
    assert(foundWork, "A control rig must contain the WORK stage");

    post(BASE ~ "/api/camera",
        `{"azimuth":0.5,"elevation":0.4,"distance":5.0,`
        ~ `"focus":{"x":3.0,"y":2.0,"z":-1.0}}`);
    Thread.sleep(100.msecs);
}

float[3] pointDelta(string kind, CameraState camera,
                    int x0, int y0, int x1, int y1) {
    cmd("tool.pipe.attr falloff type " ~ kind);
    playAndWait(buildDragLog(camera.vpX, camera.vpY,
                             camera.width, camera.height,
                             x0, y0, x1, y1, 2, 0, 3));
    auto attrs = falloffAttrs();
    if (kind == "linear")
        return sub(vec3(attrs["start"]), vec3(attrs["end"]));
    return vec3(attrs["size"]);
}

unittest { // A: press without motion collapses every point-placement size term
    resetAsymmetricRig();
    auto camera = fetchCamera();
    int cx = camera.vpX + camera.width / 2;
    int cy = camera.vpY + camera.height / 2;

    foreach (kind; ["linear", "radial", "cylinder"]) {
        cmd("tool.pipe.attr falloff type " ~ kind);
        if (kind == "linear") {
            cmd(`tool.pipe.attr falloff start "8,9,10"`);
            cmd(`tool.pipe.attr falloff end "-3,-4,-5"`);
        } else {
            cmd(`tool.pipe.attr falloff center "8,9,10"`);
            cmd(`tool.pipe.attr falloff size "4,5,6"`);
        }

        pressOnly(camera, cx, cy);
        auto attrs = falloffAttrs();
        if (kind == "linear") {
            auto start = vec3(attrs["start"]);
            auto end = vec3(attrs["end"]);
            assert(near3(start, end),
                "A anchor mutation: press without motion must collapse both "
                ~ "linear handles at the cursor anchor");
        } else {
            auto size = vec3(attrs["size"]);
            assert(near3(size, [0.0f, 0.0f, 0.0f]),
                "A anchor mutation: press without motion must zero the "
                ~ kind ~ " size term");
        }
        releaseOnly(camera, cx, cy);
    }
}

unittest { // A: all three kinds retain the full 3-D cursor-point difference
    resetAsymmetricRig();
    auto camera = fetchCamera();
    int cx = camera.vpX + camera.width / 2;
    int cy = camera.vpY + camera.height / 2;

    auto linear = pointDelta("linear", camera, cx, cy, cx, cy + 60);
    auto radial = pointDelta("radial", camera, cx, cy, cx, cy + 60);
    auto cylinder = pointDelta("cylinder", camera, cx, cy, cx, cy + 60);

    assert(fabs(linear[1]) > 0.05f,
        format("A projection mutation: +Y drag must retain a non-zero second "
             ~ "component; got linear delta %s", linear));
    assert(near3(radial, linear, 2e-3f) &&
           near3(cylinder, linear, 2e-3f),
        format("A discipline: linear/radial/cylinder must receive the same "
             ~ "unprojected point difference; linear=%s radial=%s cylinder=%s",
               linear, radial, cylinder));
}

float screenSize() {
    return falloffAttrs()["screenSize"].to!float;
}

int selectionSteps() {
    return falloffAttrs()["steps"].to!int;
}

unittest { // B: both absolute hauls floor at one after a -60 px drag
    postJson("/api/command", commandBody("scene.reset"));
    cmd("tool.set move");
    auto camera = fetchCamera();
    int cx = camera.vpX + camera.width / 2;
    int cy = camera.vpY + camera.height / 2;

    cmd("tool.pipe.attr falloff type screen");
    cmd("tool.pipe.attr falloff screenSize 20");
    playAndWait(buildDragLog(camera.vpX, camera.vpY,
                             camera.width, camera.height,
                             cx, cy, cx - 60, cy, 3, 0, 3));
    assert(near(screenSize(), 1.0f),
        format("B floor mutation: screen -60 px must floor at one, got %g",
               screenSize()));

    cmd("tool.pipe.attr falloff type selection");
    cmd("tool.pipe.attr falloff steps 20");
    playAndWait(buildDragLog(camera.vpX, camera.vpY,
                             camera.width, camera.height,
                             cx, cy, cx - 60, cy, 3, 0, 3));
    assert(selectionSteps() == 1,
        format("B floor mutation: selection -60 px must floor at one, got %d",
               selectionSteps()));
}

unittest { // B: vertical motion changes neither absolute haul
    postJson("/api/command", commandBody("scene.reset"));
    cmd("tool.set move");
    auto camera = fetchCamera();
    int cx = camera.vpX + camera.width / 2;
    int cy = camera.vpY + camera.height / 2;

    cmd("tool.pipe.attr falloff type screen");
    cmd("tool.pipe.attr falloff screenSize 20");
    playAndWait(buildDragLog(camera.vpX, camera.vpY,
                             camera.width, camera.height,
                             cx, cy, cx, cy + 60, 3, 0, 3));
    assert(near(screenSize(), 20.0f),
        format("B vertical mutation: +Y must not change screen size; got %g",
               screenSize()));

    cmd("tool.pipe.attr falloff type selection");
    cmd("tool.pipe.attr falloff steps 20");
    playAndWait(buildDragLog(camera.vpX, camera.vpY,
                             camera.width, camera.height,
                             cx, cy, cx, cy + 60, 3, 0, 3));
    assert(selectionSteps() == 20,
        format("B vertical mutation: +Y must not change selection steps; got %d",
               selectionSteps()));
}

string elementDragLog(CameraState camera, int x0, int y0,
                      const(int)[] xs) {
    string log = viewportEvent(camera) ~ format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x0, y0);
    int previous = x0;
    foreach (i, x; xs) {
        log ~= format(
            `{"t":%d.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":0,"state":4,"mod":0}` ~ "\n",
            100 + cast(int)i * 50, x, y0, x - previous);
        previous = x;
    }
    log ~= format(
        `{"t":%d.000,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        100 + cast(int)xs.length * 50,
        xs.length ? xs[$ - 1] : x0, y0);
    return log;
}

float runElementPath(const(int)[] offsets) {
    postJson("/api/command", commandBody("scene.reset"));
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0,0,0\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    auto camera = fetchCamera();
    int cx = camera.vpX + camera.width / 2;
    int cy = camera.vpY + camera.height / 2;
    int[] xs;
    foreach (offset; offsets) xs ~= cx + offset;
    playSegment(elementDragLog(camera, cx, cy, xs));
    return falloffAttrs()["dist"].to!float;
}

unittest { // C: two tracker increments equal one motion to the same endpoint
    float oneMotion = runElementPath([80]);
    float twoMotions = runElementPath([30, 80]);
    assert(oneMotion > 0.5f,
        format("C premise: +80 px must grow element distance; got %g",
               oneMotion));
    assert(near(twoMotions, oneMotion, 2e-4f),
        format("C absolute mutation: incremental tracker must accumulate two "
             ~ "successive motions to the same endpoint; one=%g two=%g",
               oneMotion, twoMotions));

    float floor = runElementPath([-300]);
    assert(near(floor, 0.0f),
        format("C floor: a sufficiently negative haul must reach zero; got %g",
               floor));
}
