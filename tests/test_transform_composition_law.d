// Captured transform composition law, checked from the formula rather than
// copied application output. The gesture cells below drive the production
// tool and derive their centre, frame, translation, and expectations from the
// authored rig before comparing any law residual.

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

private double[3] add(double[3] a, double[3] b)
{
    return [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
}

private double[3] subtract(double[3] a, double[3] b)
{
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
}

private double[3] scale(double[3] v, double s)
{
    return [v[0] * s, v[1] * s, v[2] * s];
}

private double dot(double[3] a, double[3] b)
{
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}

private double[3] cross(double[3] a, double[3] b)
{
    return [a[1]*b[2] - a[2]*b[1],
            a[2]*b[0] - a[0]*b[2],
            a[0]*b[1] - a[1]*b[0]];
}

private double[3] normalized(double[3] v)
{
    immutable double length = sqrt(dot(v, v));
    assert(length > 1e-9, "6207 rig axis must be non-zero");
    return scale(v, 1.0 / length);
}

private double angleXZ(double[3] a, double[3] b)
{
    immutable double la = sqrt(a[0]*a[0] + a[2]*a[2]);
    immutable double lb = sqrt(b[0]*b[0] + b[2]*b[2]);
    assert(la > 1e-6 && lb > 1e-6,
        "6207 direction witness needs non-zero XZ vectors");
    immutable double cosine = (a[0]*b[0] + a[2]*b[2]) / (la*lb);
    immutable double clamped = cosine < -1.0 ? -1.0 : cosine > 1.0 ? 1.0 : cosine;
    import std.math : acos;
    return acos(clamped) * 180.0 / PI;
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

private string indexList(const(int)[] indices)
{
    string result = "[";
    foreach (i, value; indices)
        result ~= (i ? "," : "") ~ format("%s", value);
    return result ~ "]";
}

private double[3][] establishVertexRig(const(int)[] selection)
{
    postJson("/api/command", commandBody("scene.reset"));
    command("tool.pipe.attr snap enabled false");
    command("tool.pipe.attr falloff type none");
    command("tool.pipe.attr symmetry enabled false");
    postJson("/api/command", commandBody("scene.loadMesh",
        `{"vertices":[[-1.2,0,-1.2],[0,0,-1.2],[1.2,0,-1.2],[-1.2,0,0],[0,0,0],[1.2,0,0],[-1.2,0,1.2],[0,0,1.2],[1.2,0,1.2]],"faces":[[0,3,4,1],[1,4,5,2],[3,6,7,4],[4,7,8,5]]}`));
    command("viewport.view Top");
    postJson("/api/camera", `{"distance":6.0,"focus":{"x":0,"y":0,"z":0}}`);
    postJson("/api/command", commandBody("mesh.select",
        `{"mode":"vertices","indices":` ~ indexList(selection) ~ `}`));
    command("tool.set Transform on");
    settle();
    return modelVertices();
}

private JSONValue transformEval()
{
    return getJson("/api/toolpipe/eval")["transform"];
}

private double[3][3] runFrame(JSONValue transform)
{
    double[3][3] result;
    foreach (axis, key; ["runFrameRight", "runFrameUp", "runFrameFwd"])
        result[axis] = vector(transform[key]);
    return result;
}

private double[3] worldTranslation(JSONValue transform,
                                   double[3][3] frame)
{
    const t = vector(transform["translate"]);
    double[3] result = [0.0, 0.0, 0.0];
    foreach (axis; 0 .. 3)
        result = add(result, scale(frame[axis], t[axis]));
    return result;
}

private void assertFrozenRigFrame(JSONValue transform, double[3] centre,
                                  double[3][3] frame, string cell)
{
    assert(transform["runFrameValid"].type == JSONType.true_,
        "6207 " ~ cell ~ " must publish a valid frozen run frame");
    assert(distance(vector(transform["runFrameOrigin"]), centre) <= 1e-5,
        "6207 " ~ cell ~ " runFrameOrigin must equal the centre computed from the rig");
    const actual = runFrame(transform);
    foreach (axis; 0 .. 3)
        assert(distance(actual[axis], frame[axis]) <= 1e-5,
            format("6207 %s run-frame axis %s must come from the rig: %s vs %s",
                   cell, axis, actual[axis], frame[axis]));
}

private void dragViewRing(CameraState camera, double deltaDegrees = -20.0)
{
    const centre = vector(transformEval()["gizmoCenter"]);
    const centrePx = topPixel(getJson("/api/camera"), centre);
    double start;
    int radius;
    bool found;
    foreach (candidateAngle; [0.0, PI/2.0, PI, 3.0*PI/2.0, PI/4.0, 3.0*PI/4.0]) {
        foreach (candidateRadius; [132, 128, 136, 120, 144, 112, 152]) {
            immutable int x = cast(int)(centrePx[0]
                + candidateRadius*cos(candidateAngle) + 0.5);
            immutable int y = cast(int)(centrePx[1]
                + candidateRadius*sin(candidateAngle) + 0.5);
            hover(camera, x, y);
            if (getJson("/api/tool/handles")["handles"]["hot"].integer != 13)
                continue;
            start = candidateAngle;
            radius = candidateRadius;
            found = true;
            break;
        }
        if (found)
            break;
    }
    assert(found, "6207 gesture cell must find an unobstructed view-ring point");
    immutable int x0 = cast(int)(centrePx[0] + radius*cos(start) + 0.5);
    immutable int y0 = cast(int)(centrePx[1] + radius*sin(start) + 0.5);
    immutable double finish = start + deltaDegrees * PI / 180.0;
    immutable int x1 = cast(int)(centrePx[0] + radius*cos(finish) + 0.5);
    immutable int y1 = cast(int)(centrePx[1] + radius*sin(finish) + 0.5);
    playAndWait(buildDragLog(camera.vpX, camera.vpY, camera.width, camera.height,
                             x0, y0, x1, y1, 20));
    settle();
}

private double[2] handlePartScreen(int wanted)
{
    const handles = getJson("/api/tool/handles")["handles"];
    foreach (part; handles["parts"].array) {
        if (part["part"].integer != wanted
                || part["screen"].type == JSONType.null_)
            continue;
        const screen = part["screen"].array;
        return [number(screen[0]), number(screen[1])];
    }
    assert(false, format("6207 required handle part %s is absent: %s",
                         wanted, handles));
}

private struct ArrowObservation
{
    double[3][] before;
    double[3][] after;
    double[3] handleMid;
    double[3] handleAfter;
    double[3] arrowWorld;
}

private ArrowObservation dragMoveArrow(CameraState camera, int dx = 55)
{
    ArrowObservation result;
    result.before = modelVertices();
    const part = handlePartScreen(0);
    const centre = vector(transformEval()["gizmoCenter"]);
    const centrePx = topPixel(getJson("/api/camera"), centre);
    const screenDirection = normalized(
        [part[0] - centrePx[0], 0.0, part[1] - centrePx[1]]);
    result.arrowWorld = screenDirection;
    immutable int x0 = cast(int)(part[0] + 0.5);
    immutable int y0 = cast(int)(part[1] + 0.5);
    hover(camera, x0, y0);
    playAndWait(viewportLine(camera)
        ~ format(`{"t":30.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
                 x0, y0));
    settle();
    const state = getJson("/api/tool/state");
    assert(state["activeBank"].str == "move" && state["dragAxis"].integer == 0,
        "6207 gesture cell must grab move axis 0: " ~ state.toString);

    string motion = viewportLine(camera);
    int previousX = x0;
    foreach (i; 1 .. 17) {
        immutable int x = x0 + cast(int)(cast(double)dx * i / 16.0 + 0.5);
        motion ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":0,"state":1,"mod":0}` ~ "\n",
            50.0 + i*30.0, x, y0, x - previousX);
        previousX = x;
    }
    playAndWait(motion);
    settle();
    result.handleMid = vector(transformEval()["gizmoCenter"]);
    playAndWait(viewportLine(camera)
        ~ format(`{"t":30.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
                 x0 + dx, y0));
    settle();
    result.after = modelVertices();
    result.handleAfter = vector(transformEval()["gizmoCenter"]);
    return result;
}

private double[3][3] frameForCell(string mode, const(double[3])[] base)
{
    const gridRight = normalized(subtract(base[1], base[0]));
    const gridFwd = normalized(subtract(base[3], base[0]));
    if (mode == "local") {
        const localUp = scale(gridFwd, -1.0);
        return [gridRight, localUp, cross(gridRight, localUp)];
    }
    if (mode != "select")
        return [gridRight, cross(gridFwd, gridRight), gridFwd];
    const along = normalized(subtract(base[5], base[1]));
    immutable double[3] up = [0.0, 1.0, 0.0];
    return [along, up, cross(along, up)];
}

private void assertIdleHandle(double[3] expected, string cell)
{
    assert(distance(vector(transformEval()["gizmoCenter"]), expected) <= 1e-5,
        "6207 " ~ cell ~ " handle must equal c+M*T after release");
    Thread.sleep(1000.msecs);
    assert(distance(vector(transformEval()["gizmoCenter"]), expected) <= 1e-5,
        "6207 " ~ cell ~ " handle must remain at c+M*T after idle");
}

private void runRotateThenMoveCell(string mode)
{
    immutable int[] selection = mode == "local" ? [0, 3, 5, 8] : [1, 5];
    const base = establishVertexRig(selection);
    command("actr." ~ mode);
    settle();
    const camera = fetchCamera();
    if (mode == "element") {
        command("tool.pipe.attr falloff type element");
        const pixel = topPixel(getJson("/api/camera"), base[6]);
        click(camera, cast(int)(pixel[0] + 0.5), cast(int)(pixel[1] + 0.5));
        command("tool.pipe.attr falloff type none");
        settle();
    }

    double[3] rigCentre;
    if (mode == "element") rigCentre = base[6];
    else if (mode == "origin") rigCentre = [0.0, 0.0, 0.0];
    else if (mode == "local") rigCentre = scale(add(base[0], base[3]), 0.5);
    else rigCentre = scale(add(base[1], base[5]), 0.5);
    const rigFrame = frameForCell(mode, base);
    dragViewRing(camera);
    const afterRing = transformEval();
    immutable double angle = number(afterRing["rotate"].array[1]);
    assert(fabs(angle) > 10.0,
        "6207 " ~ mode ~ " RTg cell needs a real held rotation");
    const drag = dragMoveArrow(camera);
    const transform = transformEval();

    // These are deliberately the first semantic assertions after the gesture:
    // a self-consistent but re-frozen answer must fail before any residual that
    // consumes the answer's own centre or frame.
    assertFrozenRigFrame(transform, rigCentre, rigFrame, mode ~ " RTg");
    const translation = worldTranslation(transform, rigFrame);
    assert(sqrt(translation[0]*translation[0] + translation[2]*translation[2]) > 0.2,
        "6207 RTg translation must be visible and not parallel to the Y rotation axis");
    if (mode != "origin")
        assert(sqrt(dot(rigCentre, rigCentre)) > 0.5,
            "6207 non-origin RTg rig must have c != 0");

    double rivalSeparation = 0.0;
    foreach (vi; selection) {
        double[3] expected;
        if (mode == "local") {
            expected = add(base[vi], translation);
        } else {
            expected = composed(base[vi], rigCentre, translation, angle,
                                [1.0, 1.0, 1.0]);
            const rival = composed(add(base[vi], translation), rigCentre,
                                   [0.0, 0.0, 0.0], angle,
                                   [1.0, 1.0, 1.0]);
            rivalSeparation = rivalSeparation > distance(expected, rival)
                ? rivalSeparation : distance(expected, rival);
        }
        assert(distance(drag.after[vi], expected) <= 1e-5,
            format("6207 G %s RTg must apply the rig-centred fold at v%s: %s vs %s",
                   mode, vi, drag.after[vi], expected));
    }
    if (mode != "local")
        assert(rivalSeparation >= 0.1,
            "6207 RTg rig must separate translation outside the held rotation");

    const expectedHandle = add(rigCentre, translation);
    assert(distance(drag.handleAfter, expectedHandle) <= 1e-5,
        "6207 H " ~ mode ~ " RTg must release at c+M*T");
    if (mode == "select") {
        const geometryDelta = subtract(drag.after[selection[0]], drag.before[selection[0]]);
        assert(angleXZ(geometryDelta, drag.arrowWorld) <= 1.5,
            "6207 G select RTg geometry must follow the drawn arrow");
        assert(distance(drag.handleMid, drag.handleAfter) <= 1e-4,
            "6207 G select RTg handle must not jump on release");
    }
    assertIdleHandle(expectedHandle, mode ~ " RTg");

    const beforeRegrade = modelVertices();
    command("tool.pipe.attr snap enabled true");
    settle();
    const afterRegrade = modelVertices();
    foreach (vi; selection)
        assert(distance(beforeRegrade[vi], afterRegrade[vi]) <= 1e-5,
            "6207 G " ~ mode ~ " RTg re-grade must preserve the held affine");
    command("tool.set Transform off");
}

unittest // G/H: Element RTg uses the picked rig centre and keeps its affine.
{
    runRotateThenMoveCell("element");
}

unittest // G/H: Origin RTg keeps translation outside held rotation.
{
    runRotateThenMoveCell("origin");
}

unittest // G/H: A placed Auto centre is captured before the T/R gestures.
{
    const base = establishVertexRig([1, 5]);
    command("actr.auto");
    settle();
    const camera = fetchCamera();
    const placedPoint = cast(double[3])[-1.5, 0.0, 1.5];
    const pixel = topPixel(getJson("/api/camera"), placedPoint);
    click(camera, cast(int)(pixel[0] + 0.5), cast(int)(pixel[1] + 0.5));
    const rigCentre = vector(getJson("/api/toolpipe/eval")["actionCenter"]["center"]);
    assert(distance(rigCentre, placedPoint) <= 0.005,
        "6207 auto-placement must establish an off-centre rig point before the run");
    const rigFrame = frameForCell("auto", base);
    const drag = dragMoveArrow(camera);
    dragViewRing(camera);
    const transform = transformEval();
    assertFrozenRigFrame(transform, rigCentre, rigFrame, "auto-placed TR");
    const translation = worldTranslation(transform, rigFrame);
    immutable double angle = number(transform["rotate"].array[1]);
    assert(fabs(angle) > 10.0 && fabs(translation[0]) > 0.2,
        "6207 auto-placed TR must keep non-parallel T and R terms");
    foreach (vi; [1, 5]) {
        const expected = composed(base[vi], rigCentre, translation, angle,
                                  [1.0, 1.0, 1.0]);
        assert(distance(modelVertices()[vi], expected) <= 1e-5,
            "6207 G auto-placed TR must use the centre captured before the run");
    }
    const expectedHandle = add(rigCentre, translation);
    assert(distance(drag.handleAfter, expectedHandle) <= 1e-5,
        "6207 H auto-placed TR must release at c+M*T");
    assertIdleHandle(expectedHandle, "auto-placed TR");
    command("tool.set Transform off");
}

unittest // G/H: Select RTg follows its drawn frame without a release jump.
{
    runRotateThenMoveCell("select");
}

unittest // G/H: Local RTg samples cluster pivots from the frozen baseline.
{
    runRotateThenMoveCell("local");
}

unittest // X: Local rebake freezes the handle at the translated cluster centre.
{
    const base = establishVertexRig([0, 3, 5, 8]);
    command("actr.local");
    settle();
    const camera = fetchCamera();
    const drag = dragMoveArrow(camera);
    const rebakeSource = drag.after;
    const rigCentre = scale(add(rebakeSource[0], rebakeSource[3]), 0.5);
    dragViewRing(camera);
    const transform = transformEval();
    assertFrozenRigFrame(transform, rigCentre,
                         frameForCell("local", rebakeSource), "local rebake X");
    assert(distance(vector(transform["gizmoCenter"]), rigCentre) <= 1e-5,
        "6207 X local rebake handle must equal the cluster centre from the rig");
    assert(distance(rigCentre, scale(add(base[0], base[3]), 0.5)) > 0.4,
        "6207 X local rebake rig must visibly move its cluster centre");
    command("tool.set Transform off");
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
