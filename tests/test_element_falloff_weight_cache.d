// Element falloff samples its per-vertex run weights at pick or re-grade and
// reuses that sample through later gestures and value replay in the same run.

import core.thread : Thread;
import core.time : msecs;
import drag_helpers : CameraState, fetchCamera, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.file : readText;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : PI, abs, cos, sqrt, sin, tan;

void main() {}

private alias V3 = double[3];

private double number(JSONValue value)
{
    return value.type == JSONType.integer
        ? cast(double)value.integer : value.floating;
}

private V3 vector(JSONValue value)
{
    auto a = value.array;
    return [number(a[0]), number(a[1]), number(a[2])];
}

private V3 add(V3 a, V3 b)
{
    return [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
}

private V3 subtract(V3 a, V3 b)
{
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
}

private V3 scale(V3 value, double factor)
{
    return [value[0] * factor, value[1] * factor, value[2] * factor];
}

private V3 lerp(V3 a, V3 b, double weight)
{
    return add(a, scale(subtract(b, a), weight));
}

private double distance(V3 a, V3 b)
{
    const d = subtract(a, b);
    return sqrt(d[0]*d[0] + d[1]*d[1] + d[2]*d[2]);
}

private void command(string text)
{
    auto result = postJson("/api/command", text);
    assert(result["status"].str == "ok",
        "command `" ~ text ~ "` failed: " ~ result.toString);
}

private void script(string text)
{
    auto result = postJson("/api/script", text);
    assert(result["status"].str == "ok",
        "script `" ~ text ~ "` failed: " ~ result.toString);
}

private JSONValue cacheFixture()
{
    return parseJSON(readText(
        "tests/fixtures/transform_handle_after_release.json"))
        ["element_weight_cache"];
}

private double[] fixtureWeights(string key)
{
    double[] result;
    foreach (value; cacheFixture()[key].array)
        result ~= number(value);
    return result;
}

private void assertWeightedTranslation(string cell, const(V3)[] base,
        const(double)[] weights, V3 translation)
{
    const observed = modelVertices();
    assert(observed.length == base.length && weights.length == base.length,
        "6207 " ~ cell ~ " fixture cardinality mismatch");
    foreach (i; 0 .. base.length) {
        const expected = add(base[i], scale(translation, weights[i]));
        assert(distance(observed[i], expected) <= 2e-5,
            format("6207 %s cached translation v%s: observed=%s expected=%s",
                   cell, i, observed[i], expected));
    }
}

private V3 fullUniformFold(V3 point, V3 centre, V3 translation,
                           double factor, double angleDegrees)
{
    const d = scale(subtract(point, centre), factor);
    immutable double angle = angleDegrees * PI / 180.0;
    const rotated = cast(V3)[cos(angle)*d[0] + sin(angle)*d[2],
                              d[1],
                             -sin(angle)*d[0] + cos(angle)*d[2]];
    return add(add(centre, rotated), translation);
}

private void assertWeightedFold(string cell, const(V3)[] base,
        const(double)[] weights, V3 centre, V3 translation,
        double factor, double angleDegrees)
{
    const observed = modelVertices();
    foreach (i; 0 .. base.length) {
        const full = fullUniformFold(base[i], centre, translation,
                                     factor, angleDegrees);
        const expected = lerp(base[i], full, weights[i]);
        assert(distance(observed[i], expected) <= 3e-5,
            format("6207 %s shared T/R/S cache v%s: observed=%s expected=%s",
                   cell, i, observed[i], expected));
    }
}

private void settle()
{
    Thread.sleep(180.msecs);
}

private string viewportLine(CameraState camera)
{
    return format(
        `{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        camera.vpX, camera.vpY, camera.width, camera.height);
}

private double[2] topPixel(JSONValue camera, V3 point)
{
    immutable double halfHeight = number(camera["distance"]) * tan(PI / 8.0);
    immutable double aspect = number(camera["width"]) / number(camera["height"]);
    immutable double ndcX = (point[0] - number(camera["focus"]["x"]))
                          / (halfHeight * aspect);
    immutable double ndcY = -(point[2] - number(camera["focus"]["z"]))
                          / halfHeight;
    return [(ndcX * 0.5 + 0.5) * number(camera["width"])
                                      + number(camera["vpX"]),
            (1.0 - (ndcY * 0.5 + 0.5)) * number(camera["height"])
                                      + number(camera["vpY"])];
}

private void hover(CameraState camera, int x, int y)
{
    string log = viewportLine(camera);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            30 + i*20, x, y);
    playAndWait(log);
    settle();
}

private void dragAt(CameraState camera, int x, int y, int dx, int steps = 16)
{
    hover(camera, x, y);
    playAndWait(viewportLine(camera) ~ format(
        `{"t":30,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y));
    settle();
    haulHeld(camera, x, y, dx, 0, steps);
}

private void haulHeld(CameraState camera, int x, int y, int dx, int dy,
                      int steps = 16)
{
    string motion = viewportLine(camera);
    int previousX = x;
    int previousY = y;
    foreach (i; 1 .. steps + 1) {
        immutable int nextX = x + cast(int)(cast(double)dx * i / steps + 0.5);
        immutable int nextY = y + cast(int)(cast(double)dy * i / steps + 0.5);
        motion ~= format(
            `{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            60 + i*25, nextX, nextY,
            nextX - previousX, nextY - previousY);
        previousX = nextX;
        previousY = nextY;
    }
    playAndWait(motion);
    settle();
    playAndWait(viewportLine(camera) ~ format(
        `{"t":30,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x + dx, y + dy));
    settle();
}

private double[2] handlePartScreen(int wanted)
{
    const handles = getJson("/api/tool/handles")["handles"];
    foreach (part; handles["parts"].array) {
        if (part["part"].integer != wanted
                || part["screen"].type == JSONType.null_)
            continue;
        auto screen = part["screen"].array;
        return [number(screen[0]), number(screen[1])];
    }
    assert(false, format("6207 required handle part %s is absent: %s",
                         wanted, handles));
}

private void dragArrow(CameraState camera, int dx)
{
    const part = handlePartScreen(0);
    const centre = handlePartScreen(3);
    immutable double length = sqrt((part[0] - centre[0])^^2
                                 + (part[1] - centre[1])^^2);
    immutable int sx = cast(int)(dx * (part[0] - centre[0]) / length + 0.5);
    immutable int sy = cast(int)(dx * (part[1] - centre[1]) / length + 0.5);
    assert(sy >= -1 && sy <= 1, "6207 Top-view X arrow must stay horizontal");
    dragAt(camera, cast(int)(part[0] + 0.5), cast(int)(part[1] + 0.5), sx, 8);
}

private V3[] modelVertices()
{
    V3[] result;
    foreach (value; getJson("/api/model")["vertices"].array)
        result ~= vector(value);
    return result;
}

private JSONValue transformEval()
{
    return getJson("/api/toolpipe/eval")["transform"];
}

private double falloffDistance()
{
    foreach (stage; getJson("/api/toolpipe")["stages"].array)
        if (stage["task"].str == "WGHT")
            return stage["attrs"]["dist"].str.to!double;
    assert(false, "6207 Element falloff stage is absent");
}

private V3 worldTranslation(JSONValue transform)
{
    const local = vector(transform["translate"]);
    V3 result = [0.0, 0.0, 0.0];
    foreach (axis, key; ["runFrameRight", "runFrameUp", "runFrameFwd"])
        result = add(result, scale(vector(transform[key]), local[axis]));
    return result;
}

private double[] measuredWeights(const(V3)[] base, const(V3)[] observed,
                                 V3 translation)
{
    immutable double denom = translation[0]^^2
                           + translation[1]^^2
                           + translation[2]^^2;
    assert(denom > 1e-4, "6207 C19 weight measurement needs a live translation");
    double[] result;
    foreach (i; 0 .. observed.length) {
        const delta = subtract(observed[i], base[i]);
        result ~= (delta[0]*translation[0]
                 + delta[1]*translation[1]
                 + delta[2]*translation[2]) / denom;
    }
    return result;
}

private void undo(CameraState camera)
{
    playAndWait(viewportLine(camera)
        ~ `{"t":30,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
        ~ `{"t":60,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n");
    foreach (_; 0 .. 4) settle();
}

private V3[] establish()
{
    postJson("/api/command", commandBody("scene.reset"));
    command("tool.pipe.attr snap enabled false");
    command("tool.pipe.attr symmetry enabled false");
    postJson("/api/command", commandBody("scene.loadMesh",
        `{"vertices":[[-1.2,0,-1.2],[0,0,-1.2],[1.2,0,-1.2],[-1.2,0,0],[0,0,0],[1.2,0,0],[-1.2,0,1.2],[0,0,1.2],[1.2,0,1.2]],"faces":[[0,3,4,1],[1,4,5,2],[3,6,7,4],[4,7,8,5]]}`));
    command("viewport.view Top");
    postJson("/api/camera", `{"distance":6,"focus":{"x":0,"y":0,"z":0}}`);
    command("tool.set xfrm.elementMove on");
    command("tool.pipe.attr falloff mode vertex");
    command("tool.pipe.attr falloff dist 2");
    settle();
    return modelVertices();
}

private void initialDrag(CameraState camera, const(V3)[] original)
{
    const pick = topPixel(getJson("/api/camera"), original[6]);
    dragAt(camera, cast(int)(pick[0] + 0.5), cast(int)(pick[1] + 0.5), 55);
}

private void emptyRestart(CameraState camera)
{
    const pixel = topPixel(getJson("/api/camera"), [1.5, 0.0, -1.5]);
    immutable int x = cast(int)(pixel[0] + 0.5);
    immutable int y = cast(int)(pixel[1] + 0.5);
    hover(camera, x, y);
    playAndWait(viewportLine(camera) ~ format(
        `{"t":30,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y));
    settle();
    assert(getJson("/api/tool/state")["dragAxis"].integer == -1,
        "6207 W6 empty-space DOWN must not arm a transform drag");
    playAndWait(viewportLine(camera) ~ format(
        `{"t":30,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y));
    settle();
}

unittest // W0/W1: the pick sample survives a second gizmo gesture.
{
    const original = establish();
    const camera = fetchCamera();
    const weights = fixtureWeights("pick_weights");
    initialDrag(camera, original);
    assertWeightedTranslation("W0", original, weights,
                              worldTranslation(transformEval()));
    dragArrow(camera, 13);
    assertWeightedTranslation("W1", original, weights,
                              worldTranslation(transformEval()));
    command("tool.set xfrm.elementMove off");
}

unittest // W2: numeric TX replays from the pick sample.
{
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    script("tool.attr xfrm.elementMove TX 0.8");
    settle();
    const transform = transformEval();
    assert(number(transform["translate"].array[0]) == 0.8,
        "6207 W2 numeric TX must reach the published channel");
    assertWeightedTranslation("W2", original, fixtureWeights("pick_weights"),
                              worldTranslation(transform));
    command("tool.set xfrm.elementMove off");
}

unittest // W3/W4: a range edit samples once on the deformed mesh.
{
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    command("tool.pipe.attr falloff dist 1.5");
    settle();
    const weights = fixtureWeights("regrade_weights");
    assertWeightedTranslation("W3", original, weights,
                              worldTranslation(transformEval()));
    dragArrow(camera, 13);
    assertWeightedTranslation("W4", original, weights,
                              worldTranslation(transformEval()));
    command("tool.set xfrm.elementMove off");
}

unittest // C2/W5: undo restores the pick weights, not live-position weights.
{
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    command("tool.pipe.attr falloff dist 1.5");
    settle();
    undo(camera);
    assert(falloffDistance() == 2.0,
        "6207 W5 undo must restore the pick-time range");
    dragArrow(camera, 13);
    const transform = transformEval();
    assertWeightedTranslation("W5 undo", original,
                              fixtureWeights("pick_weights"),
                              worldTranslation(transform));
    command("tool.set xfrm.elementMove off");
}

unittest // C6/W6: empty-space restart keeps T live and every weight zero.
{
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    const committed = modelVertices();
    emptyRestart(camera);
    dragArrow(camera, 40);
    assert(distance(worldTranslation(transformEval()), [0.0, 0.0, 0.0]) > 0.3,
        "6207 W6 handle/T must still move after the empty restart");
    const observed = modelVertices();
    assert(committed.length == 9,
        "6207 W6 control fixture must contain exactly nine vertices");
    assert(observed.length == 9,
        "6207 W6 empty-cache result must contain exactly nine vertices");
    foreach (i; 0 .. committed.length)
        assert(distance(observed[i], committed[i]) <= 1e-5,
            format("6207 W6 no element means zero cached weight at v%s", i));
    command("tool.set xfrm.elementMove off");
}

unittest // O4s/W7: value replay and Scale share the re-grade cache.
{
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    command("tool.pipe.attr falloff dist 3");
    settle();
    script("tool.attr xfrm.elementMove TX 0.8");
    script("tool.attr xfrm.elementMove S true");
    script("tool.attr xfrm.elementMove SX 1.5");
    script("tool.attr xfrm.elementMove SY 1.5");
    script("tool.attr xfrm.elementMove SZ 1.5");
    settle();
    const transform = transformEval();
    const factors = vector(transform["scale"]);
    assert(distance(factors, [1.5, 1.5, 1.5]) <= 1e-6,
        "6207 W7 numeric scale must reach all three channels");
    assertWeightedFold("W7", original, fixtureWeights("bank_weights"),
        original[6], worldTranslation(transform), factors[0], 0.0);
    command("tool.set xfrm.elementMove off");
}

unittest // O4r/W8: Rotate uses the same re-grade weight as T and S.
{
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    command("tool.pipe.attr falloff dist 3");
    settle();
    script("tool.attr xfrm.elementMove R true");
    script("tool.attr xfrm.elementMove RY -30");
    settle();
    const transform = transformEval();
    immutable double angle = number(transform["rotate"].array[1]);
    assert(angle < -20.0, "6207 W8 numeric RY must reach the rotate bank");
    assertWeightedFold("W8", original, fixtureWeights("bank_weights"),
        original[6], worldTranslation(transform), 1.0, angle);
    command("tool.set xfrm.elementMove off");
}

unittest // W9: without a re-grade, combined TS/TR use pick-time weights.
{
    auto original = establish();
    auto camera = fetchCamera();
    initialDrag(camera, original);
    script("tool.attr xfrm.elementMove S true");
    script("tool.attr xfrm.elementMove SX 1.5");
    script("tool.attr xfrm.elementMove SY 1.5");
    script("tool.attr xfrm.elementMove SZ 1.5");
    settle();
    auto transform = transformEval();
    assertWeightedFold("W9 TS", original, fixtureWeights("pick_weights"),
        original[6], worldTranslation(transform), 1.5, 0.0);
    command("tool.set xfrm.elementMove off");

    original = establish();
    camera = fetchCamera();
    initialDrag(camera, original);
    script("tool.attr xfrm.elementMove R true");
    script("tool.attr xfrm.elementMove RY -30");
    settle();
    transform = transformEval();
    immutable double angle = number(transform["rotate"].array[1]);
    assertWeightedFold("W9 TR", original, fixtureWeights("pick_weights"),
        original[6], worldTranslation(transform), 1.0, angle);
    command("tool.set xfrm.elementMove off");
}

unittest // W6s: the empty-cache gate suppresses driver and symmetry mirror.
{
    const original = establish();
    const camera = fetchCamera();
    command("tool.pipe.attr symmetry enabled true");
    initialDrag(camera, original);
    const committed = modelVertices();
    emptyRestart(camera);
    dragArrow(camera, 40);
    assert(distance(worldTranslation(transformEval()), [0.0, 0.0, 0.0]) > 0.3,
        "6207 W6s symmetry run must still advance the transform channel");
    const observed = modelVertices();
    assert(observed.length == committed.length && observed.length == 9,
        "6207 W6s symmetry fixture/result cardinality changed");
    foreach (i; 0 .. observed.length)
        assert(distance(observed[i], committed[i]) <= 1e-5,
            format("6207 W6s empty cache must suppress mirrored vertex v%s", i));
    command("tool.set xfrm.elementMove off");
}

unittest // W6d: undo -> tool drop -> re-arm starts with a fresh cache.
{
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    emptyRestart(camera);
    dragArrow(camera, 40);
    undo(camera);
    command("tool.set xfrm.elementMove off");
    command("tool.set xfrm.elementMove on");
    settle();
    const before = modelVertices();
    dragArrow(camera, 20);
    const after = modelVertices();
    assert(before.length == 9 && after.length == 9,
        "6207 W6d fresh-cache witness must retain the nine-vertex rig");
    bool moved;
    foreach (i; 0 .. after.length)
        moved = moved || distance(after[i], before[i]) > 1e-4;
    assert(moved,
        "6207 W6d undo -> tool drop -> re-drag reused an empty cache");
    assert(!readText("source/tools/transform/xfrm_transform.d")
                .canFind("elementWeightResetSkips_"),
        "6207 W6d residual reset-skip escape hatch survived");
    command("tool.set xfrm.elementMove off");
}

unittest // C19: an empty cache is repopulated from the current mesh at re-pick.
{
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    script("tool.attr xfrm.elementMove TX 0.5");
    settle();
    const consolidated = modelVertices();
    assert(distance(consolidated[6], [-0.7, 0.0, 1.2]) <= 2e-5,
        "6207 C19 setup must move v6 to the captured re-pick position");

    emptyRestart(camera);
    dragArrow(camera, -100);
    const zeroControl = modelVertices();
    assert(zeroControl.length == 9 && zeroControl.length == consolidated.length,
        "6207 C19 population floor requires exactly nine measured weights");
    foreach (i; 0 .. zeroControl.length)
        assert(distance(zeroControl[i], consolidated[i]) == 0.0,
            format("6207 C19 empty-control haul moved v%s", i));

    const repick = topPixel(getJson("/api/camera"), zeroControl[6]);
    immutable int x = cast(int)(repick[0] + 0.5);
    immutable int y = cast(int)(repick[1] + 0.5);
    hover(camera, x, y);
    playAndWait(viewportLine(camera) ~ format(
        `{"t":30,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y));
    settle();
    const pressed = getJson("/api/toolpipe/eval");
    assert(distance(vector(pressed["actionCenter"]["center"]), zeroControl[6]) <= 2e-5,
        "6207 C19 re-pick must store v6's current position as its centre");
    assert(distance(worldTranslation(pressed["transform"]), [0.0, 0.0, 0.0]) <= 1e-6,
        "6207 C19 re-pick press must restart at T=0");
    haulHeld(camera, x, y, 80, 24, 18);

    auto translation = worldTranslation(transformEval());
    auto weights = measuredWeights(zeroControl, modelVertices(), translation);
    assert(weights.length == 9,
        "6207 C19 re-pick must populate one weight for every rig vertex");
    assert(abs(weights[6] - 1.0) <= 2e-5,
        format("6207 C19 re-pick weight v6: got %.6f want 1.000000", weights[6]));
    assert(abs(weights[7] - 0.55) <= 2e-5 && abs(weights[8] - 0.05) <= 2e-5,
        format("6207 C19 discriminators v7/v8: got %.6f/%.6f want 0.550000/0.050000",
               weights[7], weights[8]));
    assert(weights[8] > 0.0,
        "6207 C19 v8 was outside the first range and must move after re-pick");
    assert(abs(weights[3] - 0.381534) <= 2e-5,
        format("6207 C19 re-pick weight v3: got %.6f want 0.381534", weights[3]));
    assert(abs(weights[4] - 0.285548) <= 2e-5,
        format("6207 C19 re-pick weight v4: got %.6f want 0.285548", weights[4]));
    assert(abs(falloffDistance() - 2.0) <= 1e-6,
        "6207 C19 empty press must retain the Element falloff range");

    dragArrow(camera, 20);
    translation = worldTranslation(transformEval());
    weights = measuredWeights(zeroControl, modelVertices(), translation);
    assert(abs(weights[6] - 1.0) <= 2e-5
        && abs(weights[7] - 0.55) <= 2e-5
        && abs(weights[3] - 0.381534) <= 2e-5
        && abs(weights[4] - 0.285548) <= 2e-5
        && abs(weights[8] - 0.05) <= 2e-5,
        "6207 C19 continuing haul must retain the re-pick weight profile");
    command("tool.set xfrm.elementMove off");
}
