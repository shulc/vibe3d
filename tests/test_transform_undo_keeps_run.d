// A transform history step inside the current run rewrites that run; it does
// not end it.  These cells exercise the keyboard undo/redo chokepoint so the
// tool's resyncSession path runs after each history hook.

import core.thread : Thread;
import core.time : msecs;
import drag_helpers : CameraState, fetchCamera, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.file : readText;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : PI, sqrt, tan;

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

private double distance(V3 a, V3 b)
{
    const d = subtract(a, b);
    return sqrt(d[0]*d[0] + d[1]*d[1] + d[2]*d[2]);
}

private double distance2(double[2] a, double[2] b)
{
    return sqrt((a[0] - b[0])^^2 + (a[1] - b[1])^^2);
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

private JSONValue fixture()
{
    return parseJSON(readText(
        "tests/fixtures/transform_handle_after_release.json"))["undo_redo"];
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
    string motion = viewportLine(camera);
    int previous = x;
    foreach (i; 1 .. steps + 1) {
        immutable int next = x + cast(int)(cast(double)dx * i / steps + 0.5);
        motion ~= format(
            `{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":0,"state":1,"mod":0}` ~ "\n",
            60 + i*25, next, y, next - previous);
        previous = next;
    }
    playAndWait(motion);
    settle();
    playAndWait(viewportLine(camera) ~ format(
        `{"t":30,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x + dx, y));
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
    dragAt(camera, cast(int)(part[0] + 0.5),
           cast(int)(part[1] + 0.5), sx, 8);
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

private V3 worldTranslation(JSONValue transform)
{
    const local = vector(transform["translate"]);
    V3 result = [0.0, 0.0, 0.0];
    foreach (axis, key; ["runFrameRight", "runFrameUp", "runFrameFwd"])
        result = add(result, scale(vector(transform[key]), local[axis]));
    return result;
}

private void navigate(CameraState camera, bool undo)
{
    immutable int mod = undo ? 64 : 65;
    playAndWait(viewportLine(camera)
        ~ format(`{"t":30,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":%d,"repeat":0}` ~ "\n", mod)
        ~ format(`{"t":60,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":%d,"repeat":0}` ~ "\n", mod));
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

private void initialDrag(CameraState camera, const(V3)[] original, int dx = 55)
{
    const pick = topPixel(getJson("/api/camera"), original[6]);
    dragAt(camera, cast(int)(pick[0] + 0.5), cast(int)(pick[1] + 0.5), dx);
}

private void assertFixtureVertices(string cell, string key, double tolerance = 0.004)
{
    const observed = modelVertices();
    const expected = fixture()[key].array;
    assert(observed.length == expected.length,
        "6207 " ~ cell ~ " fixture cardinality mismatch");
    foreach (i; 0 .. observed.length)
        assert(distance(observed[i], vector(expected[i])) <= tolerance,
            format("6207 %s v%s: observed=%s expected=%s",
                   cell, i, observed[i], vector(expected[i])));
}

private void assertLivePose(string cell, string translationKey, string vertexKey)
{
    const transform = transformEval();
    const expectedTranslation = vector(fixture()[translationKey]);
    assert(distance(worldTranslation(transform), expectedTranslation) <= 0.004,
        format("6207 %s run T: observed=%s expected=%s",
               cell, worldTranslation(transform), expectedTranslation));
    assertFixtureVertices(cell, vertexKey);
    assert(transform["runFrameValid"].type == JSONType.true_,
        "6207 " ~ cell ~ " must keep the frozen run frame live");
    assert(distance(modelVertices()[6],
                    add(vector(fixture()["undo_expected"].array[6]),
                        subtract(expectedTranslation,
                                 vector(fixture()["undo_translation"])))) <= 0.004,
        "6207 " ~ cell ~ " handle anchor vertex must stay at c+M*T");
    assert(distance2(handlePartScreen(3),
                     topPixel(getJson("/api/camera"), modelVertices()[6])) <= 1.5,
        "6207 " ~ cell ~ " published handle must stay on the anchor vertex");
}

unittest // K1/K2: undo rewrites the live run; the next arrow continues it.
{
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    dragArrow(camera, 13);
    assert(number(transformEval()["translate"].array[0]) > 0.55,
        "6207 K1 setup must land two gestures before undo");
    navigate(camera, true);
    assertLivePose("K1 undo", "undo_translation", "undo_expected");
    dragArrow(camera, 13);
    assertLivePose("K2 continuation", "continued_translation", "continued_expected");
    command("tool.set xfrm.elementMove off");
}

unittest // K3/C4b: redo rewrites the same run and continuation remains absolute.
{
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    dragArrow(camera, 13);
    assert(number(transformEval()["translate"].array[0]) > 0.55,
        "6207 K3 setup must land two gestures before undo/redo");
    navigate(camera, true);
    navigate(camera, false);
    assertLivePose("K3 redo", "continued_translation", "continued_expected");
    dragArrow(camera, 13);
    assertLivePose("K3 redo continuation", "redo_continued_translation",
                      "redo_continued_expected");
    command("tool.set xfrm.elementMove off");
}

unittest // K4/C8: numeric replay after undo uses the preserved pick weights.
{
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    dragArrow(camera, 13);
    assert(number(transformEval()["translate"].array[0]) > 0.55,
        "6207 K4 setup must land two gestures before undo/value replay");
    navigate(camera, true);
    script("tool.attr xfrm.elementMove TX 0.8");
    settle();
    assertLivePose("K4 numeric after undo", "numeric_translation", "numeric_expected");
    command("tool.set xfrm.elementMove off");
}

unittest // K5/U3: popping an older serial is a boundary, never a stale continuation.
{
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original, 130);
    const priorRun = modelVertices();
    assert(distance(priorRun[6], original[6]) > 0.5,
        "6207 K5 setup must establish the earlier run");
    const repick = topPixel(getJson("/api/camera"), priorRun[6]);
    dragAt(camera, cast(int)(repick[0] + 0.5),
           cast(int)(repick[1] + 0.5), 13, 8);
    navigate(camera, true);
    navigate(camera, true);
    assert(transformEval()["runFrameValid"].type == JSONType.false_,
        "6207 K5 undo into an older run serial must reset the current run");
    dragArrow(camera, 13);
    const observed = modelVertices()[6];
    const freshTransform = transformEval();
    assert(freshTransform["runFrameValid"].type == JSONType.true_,
        "6207 K5 post-boundary gesture must establish a fresh run");
    assert(distance(observed,
                    add(original[6], worldTranslation(freshTransform))) <= 0.004,
        "6207 K5 post-boundary gesture must start from the restored baseline");
    assert(distance(observed, original[6]) > 0.02,
        "6207 K5 fresh post-boundary gesture must move the restored vertex");
    assert(distance(observed, priorRun[6]) > 0.5,
        "6207 K5 must not continue from the stale newer-run baseline");
    command("tool.set xfrm.elementMove off");
}
