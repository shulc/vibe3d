// Captured transform composition law, checked from the formula rather than
// copied application output. Production-path witnesses live in the sibling
// transform, element-falloff, sampling, handle-pose, and item-parity tests.

import core.thread : Thread;
import core.time : msecs;
import drag_helpers : CameraState, buildDragLog, fetchCamera, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.file : readText;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : PI, cos, fabs, sin, sqrt, tan;

void main() {}

private double number(JSONValue value)
{
    return value.type == JSONType.integer
        ? cast(double)value.integer : value.floating;
}

private double[3] vector(JSONValue value)
{
    auto a = value.array;
    return [number(a[0]), number(a[1]), number(a[2])];
}

private double distance(double[3] a, double[3] b)
{
    return sqrt((a[0] - b[0])^^2 + (a[1] - b[1])^^2
              + (a[2] - b[2])^^2);
}

// Formula: p' = c + R*(M*S*M^T)*(p-c) + M*T. Frame columns are orthonormal;
// the Y-angle convention is x'=cos(a)x+sin(a)z, z'=-sin(a)x+cos(a)z.
private double[3] composedInFrame(double[3] point, double[3] centre,
                                  double[3] translation, double angleDegrees,
                                  double[3] scale, double[3][3] frame)
{
    immutable double a = angleDegrees * PI / 180.0;
    immutable double[3] d = [point[0] - centre[0],
                             point[1] - centre[1],
                             point[2] - centre[2]];
    double[3] scaled = [0.0, 0.0, 0.0];
    foreach (axis; 0 .. 3) {
        immutable double component = d[0]*frame[axis][0]
                                   + d[1]*frame[axis][1]
                                   + d[2]*frame[axis][2];
        foreach (k; 0 .. 3)
            scaled[k] += frame[axis][k] * scale[axis] * component;
    }
    immutable double[3] rotated = [cos(a)*scaled[0] + sin(a)*scaled[2],
                                    scaled[1],
                                   -sin(a)*scaled[0] + cos(a)*scaled[2]];
    return [centre[0] + rotated[0] + translation[0],
            centre[1] + rotated[1] + translation[1],
            centre[2] + rotated[2] + translation[2]];
}

private double[3] composed(double[3] point, double[3] centre,
                           double[3] translation, double angleDegrees,
                           double[3] scale)
{
    immutable double[3][3] world = [[1.0, 0.0, 0.0],
                                     [0.0, 1.0, 0.0],
                                     [0.0, 0.0, 1.0]];
    return composedInFrame(point, centre, translation, angleDegrees,
                           scale, world);
}

unittest // Six captured compositions obey one channel-order-independent law.
{
    const fixture = parseJSON(readText(
        "tests/fixtures/transform_handle_after_release.json"));
    auto cases = fixture["composition"].array;
    assert(cases.length == 6,
        "6207 composition witness requires all six captured cases");

    double minimumRivalSeparation = double.max;
    foreach (entry; cases) {
        const centre = vector(entry["centre"]);
        const translation = vector(entry["translation"]);
        const scale = vector(entry["scale"]);
        const angle = number(entry["rotation_y_degrees"]);
        auto points = entry["points"].array;
        auto expected = entry["expected"].array;
        assert(points.length == expected.length && points.length == 2,
            "6207 each composition cell needs two off-centre points");
        foreach (i; 0 .. points.length) {
            const point = vector(points[i]);
            assert(distance(point, centre) > 1.0,
                "6207 rotation/scale witness must stay off-centre");
            const fromLaw = composed(point, centre, translation, angle, scale);
            const captured = vector(expected[i]);
            assert(distance(fromLaw, captured) <= 1e-5,
                format("6207 captured position must equal c+R*S*(p-c)+T: %s vs %s",
                       fromLaw, captured));

            // Rival puts translation inside the linear fold.
            immutable double[3] translatedPoint = [point[0] + translation[0],
                                                   point[1] + translation[1],
                                                   point[2] + translation[2]];
            const rival = composed(translatedPoint, centre,
                                   cast(double[3])[0.0, 0.0, 0.0],
                                   angle, scale);
            const separation = distance(fromLaw, rival);
            if (separation > 1e-8 && separation < minimumRivalSeparation)
                minimumRivalSeparation = separation;
        }
    }
    assert(minimumRivalSeparation >= 0.25 - 1e-6,
        "6207 fixture must separate translation outside the linear fold");

    assert(cases[0]["expected"] == cases[2]["expected"],
        "6207 equal T/R channels must be independent of gesture order");
    assert(cases[3]["expected"] == cases[4]["expected"],
        "6207 equal T/S channels must be independent of gesture order");
}

private double[3][3] frameColumns(JSONValue value)
{
    double[3][3] result;
    foreach (i, column; value.array)
        result[i] = vector(column);
    return result;
}

unittest // Captured auto and element cells share the action-frame formula.
{
    const data = parseJSON(readText(
        "tests/fixtures/transform_handle_after_release.json"))["scale_axis_law"];
    foreach (mode; ["element", "auto"]) {
        const entry = data[mode];
        const centre = vector(entry["centre"]);
        const frame = frameColumns(entry["frame_columns"]);
        const scale = vector(data["scale"]);
        const angle = number(data["rotation_y_degrees"]);
        auto points = entry["points"].array;
        auto expected = entry["expected"].array;
        assert(points.length == 4 && expected.length == points.length,
            "6207 scale-axis fixture needs four off-centre vertices");
        foreach (i; 0 .. points.length) {
            const point = vector(points[i]);
            assert(distance(point, centre) > 1.0,
                "6207 scale-axis witness must stay off-centre");
            const fromLaw = composedInFrame(point, centre, [0.0, 0.0, 0.0],
                                             angle, scale, frame);
            assert(distance(fromLaw, vector(expected[i])) <= 1e-5,
                "6207 fixture must equal c+R*(M*S*M^T)*(p-c)");
        }
    }
}

private void command(string text)
{
    auto result = postJson("/api/command", text);
    assert(result["status"].str == "ok",
        "command `" ~ text ~ "` failed: " ~ result.toString);
}

private void settle()
{
    Thread.sleep(180.msecs);
}

private string viewportLine(CameraState camera)
{
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        camera.vpX, camera.vpY, camera.width, camera.height);
}

private double[2] topPixel(JSONValue camera, double[3] point)
{
    immutable double halfHeight = number(camera["distance"]) * tan(PI / 8.0);
    immutable double aspect = number(camera["width"]) / number(camera["height"]);
    immutable double dx = point[0] - number(camera["focus"]["x"]);
    immutable double dz = point[2] - number(camera["focus"]["z"]);
    immutable double ndcX = dx / (halfHeight * aspect);
    immutable double ndcY = -dz / halfHeight;
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
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            50.0 + i * 20.0, x, y);
    playAndWait(log);
    settle();
}

private void click(CameraState camera, int x, int y)
{
    hover(camera, x, y);
    const log = viewportLine(camera)
        ~ format(`{"t":30.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
                 x, y)
        ~ format(`{"t":60.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
                 x, y);
    playAndWait(log);
    settle();
}

private double[3][] modelVertices()
{
    double[3][] result;
    foreach (value; getJson("/api/model")["vertices"].array)
        result ~= vector(value);
    return result;
}

private void establishRig(string mode)
{
    postJson("/api/command", commandBody("scene.reset"));
    command("tool.pipe.attr snap enabled false");
    command("tool.pipe.attr falloff type none");
    command("tool.pipe.attr symmetry enabled false");
    postJson("/api/command", commandBody("scene.loadMesh",
        `{"vertices":[[-1.2,0,-1.2],[0,0,-1.2],[1.2,0,-1.2],[-1.2,0,0],[0,0,0],[1.2,0,0],[-1.2,0,1.2],[0,0,1.2],[1.2,0,1.2]],"faces":[[0,3,4,1],[1,4,5,2],[3,6,7,4],[4,7,8,5]]}`));
    command("viewport.view Top");
    postJson("/api/camera", `{"distance":6.0,"focus":{"x":0,"y":0,"z":0}}`);
    const selection = mode == "element"
        ? `{"mode":"polygons","indices":[3]}`
        : `{"mode":"vertices","indices":[4,5,7,8]}`;
    postJson("/api/command", commandBody("mesh.select", selection));
    command("tool.set Transform on");
    settle();
}

private void runGestureScaleCell(string mode)
{
    const fixture = parseJSON(readText(
        "tests/fixtures/transform_handle_after_release.json"))["scale_axis_law"];
    const entry = fixture[mode];
    const capturedFrame = frameColumns(entry["frame_columns"]);
    establishRig(mode);
    command("actr." ~ mode);
    settle();

    auto cameraJson = getJson("/api/camera");
    auto camera = fetchCamera();
    if (mode == "element") {
        command("tool.pipe.attr falloff type element");
        const p = topPixel(cameraJson, [-1.2, 0.0, 1.2]);
        click(camera, cast(int)(p[0] + 0.5), cast(int)(p[1] + 0.5));
        command("tool.pipe.attr falloff type none");
    } else {
        const centre = vector(entry["centre"]);
        const p = topPixel(cameraJson, centre);
        click(camera, cast(int)(p[0] + 0.5), cast(int)(p[1] + 0.5));
    }
    settle();

    const before = modelVertices();
    const rigCentre = mode == "element"
        ? before[6] : vector(getJson("/api/toolpipe/eval")["actionCenter"]["center"]);
    immutable double centreTolerance = mode == "auto" ? 0.005 : 1e-5;
    assert(distance(rigCentre, vector(entry["centre"])) <= centreTolerance,
        format("6207 G-RS %s centre must come from the rig: %s vs %s",
               mode, rigCentre, vector(entry["centre"])));

    const centrePx = topPixel(getJson("/api/camera"), rigCentre);
    immutable double ringStart = PI / 4.0;
    immutable int x0 = cast(int)(centrePx[0] + 132.0*cos(ringStart) + 0.5);
    immutable int y0 = cast(int)(centrePx[1] + 132.0*sin(ringStart) + 0.5);
    hover(camera, x0, y0);
    const hovered = getJson("/api/tool/handles")["handles"];
    assert(hovered["hot"].integer == 13,
        "6207 G-RS " ~ mode ~ " must grab the view ring: " ~ hovered.toString);
    immutable double arc = number(fixture["rotation_y_degrees"]) * PI / 180.0;
    immutable int x1 = cast(int)(centrePx[0] + 132.0*cos(ringStart + arc) + 0.5);
    immutable int y1 = cast(int)(centrePx[1] + 132.0*sin(ringStart + arc) + 0.5);
    playAndWait(buildDragLog(camera.vpX, camera.vpY, camera.width, camera.height,
                             x0, y0, x1, y1, 20));
    settle();

    auto transform = getJson("/api/toolpipe/eval")["transform"];
    const angle = number(transform["rotate"].array[1]);
    assert(fabs(angle) > 5.0 && fabs(fabs(angle) - 30.0) > 5.0
        && fabs(fabs(angle) - 90.0) > 5.0,
        "6207 G-RS ring angle must mix the scaled axis without a 30/90 special case");
    double[3][3] runFrame;
    foreach (axis, key; ["runFrameRight", "runFrameUp", "runFrameFwd"])
        runFrame[axis] = vector(transform[key]);
    if (mode == "auto") {
        foreach (axis; 0 .. 3)
            assert(distance(runFrame[axis], capturedFrame[axis]) <= 1e-5,
                "6207 G-RS auto must use the captured world frame");
    } else {
        assert(distance(runFrame[0], [1.0, 0.0, 0.0]) > 0.5,
            "6207 G-RS element needs a non-world action frame");
    }

    command("tool.attr Transform SX 2.0");
    settle();
    const after = modelVertices();
    const scale = vector(fixture["scale"]);
    immutable int[] selected = [4, 5, 7, 8];
    double rivalSeparation = 0.0;
    foreach (vi; selected) {
        const expected = composedInFrame(before[vi], rigCentre,
            [0.0, 0.0, 0.0], angle, scale, runFrame);
        const rotatedFirst = composed(before[vi], rigCentre,
            [0.0, 0.0, 0.0], angle, [1.0, 1.0, 1.0]);
        const rival = composedInFrame(rotatedFirst, rigCentre,
            [0.0, 0.0, 0.0], 0.0, scale, runFrame);
        rivalSeparation = rivalSeparation > distance(expected, rival)
            ? rivalSeparation : distance(expected, rival);
        assert(distance(after[vi], expected) <= 1e-5,
            "6207 G-RS " ~ mode ~ " must apply c+R*(M*S*M^T)*(p-c)");
    }
    assert(rivalSeparation >= 0.3,
        "6207 G-RS " ~ mode ~ " must separate R*S from S*R");
    command("tool.set Transform off");
}

unittest // G-RS element: ring then non-uniform action-frame scale.
{
    runGestureScaleCell("element");
}

unittest // G-RS auto: held rotation outranks the settled world frame.
{
    runGestureScaleCell("auto");
}

unittest // Item C16 uses the same formula and S does not scale T.
{
    const fixture = parseJSON(readText(
        "tests/fixtures/transform_handle_after_release.json"));
    auto entry = fixture["item_translate_then_scale"];
    const point = vector(entry["point"]);
    const centre = vector(entry["centre"]);
    const translation = vector(entry["translation"]);
    const scale = vector(entry["scale"]);
    const expected = vector(entry["expected_position"]);
    const handle = vector(entry["expected_handle"]);
    const fromLaw = composed(point, centre, translation, 0, scale);
    assert(distance(fromLaw, expected) <= 1e-5,
        "6207 item position must equal c+S*(p-c)+T");
    immutable double[3] scaleTranslationRival = [
        centre[0] + scale[0]*(point[0]-centre[0]+translation[0]),
        centre[1] + scale[1]*(point[1]-centre[1]+translation[1]),
        centre[2] + scale[2]*(point[2]-centre[2]+translation[2])];
    assert(distance(fromLaw, scaleTranslationRival) >= 0.2,
        "6207 item fixture must distinguish scaled translation");
    assert(distance(handle, [centre[0]+translation[0],
                             centre[1]+translation[1],
                             centre[2]+translation[2]]) <= 1e-5,
        "6207 item handle must equal c+T");
}
