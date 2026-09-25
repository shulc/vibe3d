// Task 6250: mesh.subpatch_toggle closes the live transform and re-arms or not.
// Revision 3 keyed that on the live action-centre mode — an INFERENCE (gap
// 171). The capture C-rearm-key (slice M3, gap 370) settled it the other way:
// the PRESET decides (`rearmAfterCommand`), a hand-set Element centre does not
// stop TransformMove re-arming. So the Element-close cells arm the element-move
// preset (`xfrm.elementMove`, no re-arm) and the origin controls the generic
// `Transform` preset (re-arms), each with the same pipe as before.

import core.thread : Thread;
import core.time : msecs;
import drag_helpers : CameraState, fetchCamera, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, sqrt, tan, PI;

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

private V3 subtract(V3 a, V3 b)
{
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
}

private double distance(V3 a, V3 b)
{
    const d = subtract(a, b);
    return sqrt(d[0]^^2 + d[1]^^2 + d[2]^^2);
}

private void settle()
{
    Thread.sleep(100.msecs);
}

private void command(string text)
{
    auto result = postJson("/api/command", text);
    assert(result["status"].str == "ok",
        "6250 command `" ~ text ~ "` failed: " ~ result.toString);
}

private void script(string text)
{
    auto result = postJson("/api/script", text);
    assert(result["status"].str == "ok",
        "6250 script `" ~ text ~ "` failed: " ~ result.toString);
}

private V3[] modelVertices()
{
    V3[] result;
    foreach (value; getJson("/api/model")["vertices"].array)
        result ~= vector(value);
    return result;
}

/// The id of the preset the last `establish` armed.
private string gPreset = "xfrm.elementMove";

private V3[] establish(bool elementFalloff = true, bool startSubpatch = false,
                       bool createMorph = false, string preset = "xfrm.elementMove")
{
    gPreset = preset;
    postJson("/api/command", commandBody("scene.reset"));
    command("tool.pipe.attr snap enabled false");
    command("tool.pipe.attr symmetry enabled false");
    postJson("/api/command", commandBody("scene.loadMesh",
        `{"vertices":[[-1.2,0,-1.2],[0,0,-1.2],[1.2,0,-1.2],[-1.2,0,0],[0,0,0],[1.2,0,0],[-1.2,0,1.2],[0,0,1.2],[1.2,0,1.2]],"faces":[[0,3,4,1],[1,4,5,2],[3,6,7,4],[4,7,8,5]]}`));
    if (!elementFalloff) command("select.element vertex set 6");
    if (startSubpatch) command("mesh.subpatch_toggle");
    if (createMorph) command("mesh.morph.create name:f1 kind:relative");
    command("viewport.view Top");
    postJson("/api/camera", `{"distance":6,"focus":{"x":0,"y":0,"z":0}}`);
    command("tool.set " ~ gPreset ~ " on");
    command("tool.pipe.attr actionCenter mode element");
    if (!elementFalloff) command("tool.pipe.attr falloff type none");
    if (elementFalloff) {
        command("tool.pipe.attr falloff type element");
        command("tool.pipe.attr falloff mode vertex");
        command("tool.pipe.attr falloff dist 2");
    }
    settle();
    return modelVertices();
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

private void haulHeld(CameraState camera, int x, int y, int dx, int dy,
                      int steps = 12)
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

private void dragAt(CameraState camera, int x, int y, int dx)
{
    hover(camera, x, y);
    playAndWait(viewportLine(camera) ~ format(
        `{"t":30,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y));
    settle();
    haulHeld(camera, x, y, dx, 0);
}

private void pressAt(CameraState camera, int x, int y)
{
    hover(camera, x, y);
    playAndWait(viewportLine(camera) ~ format(
        `{"t":30,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y));
    settle();
}

private void releaseAt(CameraState camera, int x, int y)
{
    playAndWait(viewportLine(camera) ~ format(
        `{"t":30,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y));
    settle();
}

private void initialDrag(CameraState camera, const(V3)[] original)
{
    const pick = topPixel(getJson("/api/camera"), original[6]);
    dragAt(camera, cast(int)(pick[0] + 0.5), cast(int)(pick[1] + 0.5), 55);
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
    assert(false, format("6250 required handle part %s is absent: %s",
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
    assert(abs(sy) <= 1, "6250 Top-view X arrow must stay horizontal");
    dragAt(camera, cast(int)(part[0] + 0.5), cast(int)(part[1] + 0.5), sx);
}

private double[] measuredWeights(const(V3)[] base, const(V3)[] observed,
                                 V3 translation)
{
    immutable double denom = translation[0]^^2
                           + translation[1]^^2
                           + translation[2]^^2;
    assert(denom > 1e-4, "6250 N4 weight measurement needs a live translation");
    double[] result;
    foreach (i; 0 .. observed.length) {
        const delta = subtract(observed[i], base[i]);
        result ~= (delta[0]*translation[0]
                 + delta[1]*translation[1]
                 + delta[2]*translation[2]) / denom;
    }
    return result;
}

private bool allSubpatch()
{
    auto flags = getJson("/api/model")["isSubpatch"].array;
    if (flags.length != 4) return false;
    foreach (flag; flags)
        if (flag.type != JSONType.true_) return false;
    return true;
}

private JSONValue[] undoRows()
{
    return getJson("/api/history")["undo"].array;
}

private string actionCenterMode()
{
    foreach (stage; getJson("/api/toolpipe")["stages"].array)
        if (stage["task"].str == "ACEN") return stage["attrs"]["mode"].str;
    assert(false, "6250 population: active toolpipe has no ACEN stage");
}

private string weightType()
{
    foreach (stage; getJson("/api/toolpipe")["stages"].array)
        if (stage["task"].str == "WGHT") return stage["attrs"]["type"].str;
    assert(false, "6250 population: active toolpipe has no WGHT stage");
}

private bool selectionEmpty()
{
    const selection = getJson("/api/selection");
    return selection["selectedVertices"].array.length == 0
        && selection["selectedEdges"].array.length == 0
        && selection["selectedFaces"].array.length == 0;
}

unittest { // N1 — at-rest handle/T/run state after two complete gestures.
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    dragArrow(camera, 18);
    const beforeState = getJson("/api/tool/state");
    const beforeEval = getJson("/api/toolpipe/eval");
    const beforeMesh = modelVertices();
    const pin = vector(beforeEval["actionCenter"]["center"]);
    const handle = vector(beforeState["pivot"]);
    const translation = vector(beforeEval["transform"]["translate"]);
    assert(beforeState["runOpen"].boolean
        && distance(translation, [0.0, 0.0, 0.0]) > 0.2,
        "6250 N1 population: two settled gestures must leave a live nonzero run");

    command("mesh.subpatch_toggle");
    settle();
    const afterState = getJson("/api/tool/state");
    const afterEval = getJson("/api/toolpipe/eval");
    assert(allSubpatch(), "6250 N1 control: toggle did not reach all four faces");
    assert(modelVertices() == beforeMesh,
        "6250 N1 control: toggle changed the consolidated cage positions");
    assert(distance(vector(afterEval["actionCenter"]["center"]), pin) <= 1e-6,
        "6250 N1 control: Element pin moved during the toggle");
    assert(distance(vector(afterState["pivot"]), handle) <= 1e-6,
        "6250 N1 control: retained at-rest handle state moved while closed");
    assert(!afterState["runOpen"].boolean,
        "6250 N1 control: consolidated Element run remained open");
    assert(distance(vector(afterEval["transform"]["translate"]), translation) <= 1e-6,
        "6250 N1: Element toggle zeroed T instead of retaining it");
    assert(!afterState["sessionOpen"].boolean,
        "6250 N1: Element toggle re-armed the session unconditionally");
    command("tool.set " ~ gPreset ~ " off");
}

private struct AtRestGesture {
    int x, y;
    bool initialSubpatch;
    bool subpatch;
    string actionMode;
    JSONValue state;
    JSONValue eval;
    V3 vertex;
    JSONValue[] rows;
}

private AtRestGesture runAtRestGesture(bool toggle, bool originArm = false,
                                       bool collectRows = false,
                                       bool startSubpatch = false)
{
    const original = establish(true, startSubpatch, false,
                               originArm ? "Transform" : "xfrm.elementMove");
    const initialSubpatch = allSubpatch();
    assert(initialSubpatch == startSubpatch,
        "6250 population: requested initial subpatch state was not established");
    if (originArm) command("tool.pipe.attr actionCenter mode origin");
    const camera = fetchCamera();
    initialDrag(camera, original);
    const before = modelVertices();
    const pixel = topPixel(getJson("/api/camera"), before[6]);
    immutable int x = cast(int)(pixel[0] + 0.5);
    immutable int y = cast(int)(pixel[1] + 0.5);
    size_t beforeRows;
    if (toggle) {
        command("mesh.subpatch_toggle");
        settle();
        beforeRows = undoRows().length;
    }
    dragAt(camera, x, y, 80);
    auto vertices = modelVertices();
    AtRestGesture result;
    result.x = x;
    result.y = y;
    result.initialSubpatch = initialSubpatch;
    result.subpatch = allSubpatch();
    result.actionMode = actionCenterMode();
    result.state = getJson("/api/tool/state");
    result.eval = getJson("/api/toolpipe/eval");
    result.vertex = vertices[6];
    if (collectRows) {
        dragArrow(camera, 80);
        dragArrow(camera, 80);
        result.rows = undoRows()[beforeRows .. $].dup;
    }
    command("tool.set " ~ gPreset ~ " off");
    return result;
}

unittest { // N1b — a post-toggle gesture settles like the no-toggle control.
    const control = runAtRestGesture(false);
    const toggled = runAtRestGesture(true, false, true);
    assert(!control.subpatch && toggled.subpatch,
        "6250 N1b population: toggle and no-toggle arms were not separated");
    assert(control.x == toggled.x && control.y == toggled.y,
        "6250 N1b population: control and toggle must press identical pixels");
    const controlT = vector(control.eval["transform"]["translate"]);
    const toggledT = vector(toggled.eval["transform"]["translate"]);
    const controlDrift = distance(vector(control.state["pivot"]), control.vertex);
    const toggledDrift = distance(vector(toggled.state["pivot"]), toggled.vertex);
    assert(control.state["runOpen"].boolean
        && control.state["runFrame"]["valid"].boolean
        && distance(controlT, [0.0, 0.0, 0.0]) > 0.05
        && controlDrift <= 1e-3,
        format("6250 N1b control: no-toggle gesture was not live at rest; "
             ~ "T=%s valid=%s runOpen=%s drift=%.4f",
               controlT, control.state["runFrame"]["valid"],
               control.state["runOpen"], controlDrift));
    assert(toggled.state["runOpen"].boolean
        && toggled.state["runFrame"]["valid"].boolean
        && distance(toggledT, [0.0, 0.0, 0.0]) > 0.05
        && toggledDrift <= 1e-3,
        format("6250 N1b: post-toggle gesture lost its live at-rest run; "
             ~ "T=%s valid=%s runOpen=%s drift=%.4f "
             ~ "(control T=%s drift=%.4f)",
               toggledT, toggled.state["runFrame"]["valid"],
               toggled.state["runOpen"], toggledDrift,
               controlT, controlDrift));
    const added = toggled.rows;
    assert(added.length == 3,
        format("6250 N1c population: three gestures added %s rows", added.length));
    const runId = added[0]["runId"].integer;
    assert(runId != 0, "6250 N1c: post-toggle gestures lost their run id");
    foreach (i, row; added) {
        assert(row["command"].str == "mesh.vertex_edit"
            && row["inSession"].boolean && row["runId"].integer == runId,
            format("6250 N1c: gesture %s is not in the shared open run: %s", i, row));
    }
    const originToggled = runAtRestGesture(true, true, true);
    assert(originToggled.actionMode == "origin",
        "6250 N1b origin population: origin arm was not selected");
    const originT = vector(originToggled.eval["transform"]["translate"]);
    assert(originToggled.state["runOpen"].boolean
        && originToggled.state["runFrame"]["valid"].boolean
        && distance(originT, [0.0, 0.0, 0.0]) > 0.05,
        format("6250 N1b origin: post-toggle gesture lost its live at-rest run; "
             ~ "T=%s valid=%s runOpen=%s",
               originT, originToggled.state["runFrame"]["valid"],
               originToggled.state["runOpen"]));
    assert(originToggled.rows.length == 3,
        format("6250 N1b origin population: three gestures added %s rows",
               originToggled.rows.length));
    const originRunId = originToggled.rows[0]["runId"].integer;
    assert(originRunId != 0,
        "6250 N1b origin: post-toggle gestures lost their run id");
    foreach (i, row; originToggled.rows) {
        assert(row["command"].str == "mesh.vertex_edit"
            && row["inSession"].boolean && row["runId"].integer == originRunId,
            format("6250 N1b origin: gesture %s is not in the shared open run: %s",
                   i, row));
    }
}

unittest { // N1d — a real +1 UiState mesh mutation is not our deferred settle.
    establish(true, false, true, "Transform");
    command("tool.pipe.attr actionCenter mode origin");
    command("tool.pipe.attr falloff type none");
    assert(selectionEmpty(),
        "6250 N1d population: foreign publication needs an empty selection hash");
    const camera = fetchCamera();
    dragArrow(camera, 55);
    const before = getJson("/api/tool/state");
    const beforeT = vector(getJson("/api/toolpipe/eval")["transform"]["translate"]);
    assert(before["runOpen"].boolean && before["runFrame"]["valid"].boolean
        && distance(beforeT, [0.0, 0.0, 0.0]) > 0.2,
        "6250 N1d population: origin gesture did not arm a live nonzero run");

    auto foreign = postJson("/api/command",
        commandBody("mesh.morph.select", `{"name":""}`));
    assert(foreign["status"].str == "ok",
        "6250 N1d population: morph-target clear did not publish MapsDisplay");
    settle();
    assert(selectionEmpty(),
        "6250 N1d population: foreign MapsDisplay publication changed selection hash");
    const after = getJson("/api/tool/state");
    const afterT = vector(getJson("/api/toolpipe/eval")["transform"]["translate"]);
    assert(after["tool"].str == "xfrm",
        "6250 N1d control: UiState morph-target clear dropped the transform");
    assert(!after["runOpen"].boolean && !after["runFrame"]["valid"].boolean
        && distance(afterT, [0.0, 0.0, 0.0]) <= 1e-6,
        format("6250 N1d: foreign +1 mesh mutation was swallowed as own settle; "
             ~ "T=%s valid=%s runOpen=%s",
               afterT, after["runFrame"]["valid"], after["runOpen"]));
    command("tool.set " ~ gPreset ~ " off");
}

unittest { // N1f — after the real settle, the next +1 still is foreign.
    establish(true, true, true, "Transform");
    command("tool.pipe.attr actionCenter mode origin");
    command("tool.pipe.attr falloff type none");
    assert(allSubpatch() && selectionEmpty(),
        "6250 N1f population: live subpatch arm must keep an empty selection");
    const camera = fetchCamera();
    dragArrow(camera, 55);
    const before = getJson("/api/tool/state");
    const beforeT = vector(getJson("/api/toolpipe/eval")["transform"]["translate"]);
    assert(before["runOpen"].boolean && before["runFrame"]["valid"].boolean
        && distance(beforeT, [0.0, 0.0, 0.0]) > 0.2,
        "6250 N1f population: settled subpatch gesture did not retain its run");

    auto foreign = postJson("/api/command",
        commandBody("mesh.morph.select", `{"name":""}`));
    assert(foreign["status"].str == "ok",
        "6250 N1f population: morph-target clear did not publish MapsDisplay");
    settle();
    const after = getJson("/api/tool/state");
    const afterT = vector(getJson("/api/toolpipe/eval")["transform"]["translate"]);
    assert(after["tool"].str == "xfrm" && allSubpatch() && selectionEmpty(),
        "6250 N1f control: foreign publication changed the tool/subpatch/selection stand");
    assert(!after["runOpen"].boolean && !after["runFrame"]["valid"].boolean
        && distance(afterT, [0.0, 0.0, 0.0]) <= 1e-6,
        format("6250 N1f: post-settle foreign +1 mutation was swallowed; "
             ~ "T=%s valid=%s runOpen=%s",
               afterT, after["runFrame"]["valid"], after["runOpen"]));
    command("tool.set " ~ gPreset ~ " off");
}

unittest { // N1e — reopening after a subpatch-off boundary stamps that mesh.
    const toggledOff = runAtRestGesture(true, false, false, true);
    const translation = vector(toggledOff.eval["transform"]["translate"]);
    const drift = distance(vector(toggledOff.state["pivot"]), toggledOff.vertex);
    assert(toggledOff.initialSubpatch && !toggledOff.subpatch,
        "6250 N1e population: the command did not toggle subpatch off");
    assert(toggledOff.state["runOpen"].boolean
        && toggledOff.state["runFrame"]["valid"].boolean
        && distance(translation, [0.0, 0.0, 0.0]) > 0.05
        && drift <= 1e-3,
        format("6250 N1e: subpatch-off reopen lost its live at-rest run; "
             ~ "T=%s valid=%s runOpen=%s drift=%.4f",
               translation, toggledOff.state["runFrame"]["valid"],
               toggledOff.state["runOpen"], drift));
}

unittest { // N2 — no handle is published while the Element session is closed.
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    const stalePart = handlePartScreen(0);
    const stalePin = vector(getJson("/api/toolpipe/eval")["actionCenter"]["center"]);
    assert(!getJson("/api/tool/state")["editOpen"].boolean,
        "6250 N2 population: completed gesture must close its edit before toggle");
    command("mesh.subpatch_toggle");
    settle();
    const closedState = getJson("/api/tool/state");
    assert(allSubpatch() && closedState["tool"].str == "xfrm",
        "6250 N2 control: toggle must apply while the transform stays selected");
    assert(!closedState["sessionOpen"].boolean,
        "6250 N2 control: Element session did not close");
    const handles = getJson("/api/tool/handles")["handles"];
    assert(handles.type == JSONType.object && handles["parts"].array.length == 0,
        "6250 N2: closed session published transform handle parts: " ~ handles.toString);
    immutable int x = cast(int)(stalePart[0] + 0.5);
    immutable int y = cast(int)(stalePart[1] + 0.5);
    assert(x == 490 && y == 431,
        format("6250 N2b population: stale part-0 pixel moved to (%s,%s)", x, y));
    pressAt(camera, x, y);
    const reopenedState = getJson("/api/tool/state");
    const pin = vector(getJson("/api/toolpipe/eval")["actionCenter"]["center"]);
    assert(reopenedState["sessionOpen"].boolean,
        "6250 N2b control: physical press did not reopen the closed session");
    assert(reopenedState["activeBank"].str == "none"
        && reopenedState["dragAxis"].integer == -1 && !reopenedState["dragging"].boolean
        && distance(pin, stalePin) <= 1e-6,
        format("6250 N2b: press at hidden part 0 (%s,%s) grabbed stale geometry; "
             ~ "bank=%s axis=%s dragging=%s pin=%s stale=%s",
               x, y, reopenedState["activeBank"], reopenedState["dragAxis"], reopenedState["dragging"],
               pin, stalePin));
    releaseAt(camera, x, y);
    command("tool.set " ~ gPreset ~ " off");
}

unittest { // N2c — pipe writes and the test opener cannot clear the latch.
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    command("mesh.subpatch_toggle");
    command("tool.pipe.attr actionCenter mode origin");
    command("tool.beginSession");
    settle();
    const closed = getJson("/api/tool/state");
    const handles = getJson("/api/tool/handles")["handles"];
    assert(!closed["sessionOpen"].boolean && !closed["editOpen"].boolean,
        "6250 N2c: non-physical writes reopened the closed session");
    assert(handles.type == JSONType.object && handles["parts"].array.length == 0,
        "6250 N2c: non-physical writes republished closed-session handles");
    const pixel = topPixel(getJson("/api/camera"), modelVertices()[7]);
    immutable int x = cast(int)(pixel[0] + 0.5);
    immutable int y = cast(int)(pixel[1] + 0.5);
    pressAt(camera, x, y);
    assert(getJson("/api/tool/state")["sessionOpen"].boolean,
        "6250 N2c: physical press did not clear the closed-session latch");
    releaseAt(camera, x, y);
    command("tool.set " ~ gPreset ~ " off");
}

unittest { // N2d — the close branch is the preset's, whatever its falloff (C-rearm-key).
    const original = establish(false);
    assert(weightType() != "element",
        "6250 N2d population: the arm kept Element falloff after `falloff type none`");
    const pin = vector(getJson("/api/toolpipe/eval")["actionCenter"]["center"]);
    assert(distance(pin, original[6]) <= 2e-5,
        format("6250 N2d population: ACEN-only selected-element pick was %s", pin));
    command("tool.beginSession");
    command("tool.attr " ~ gPreset ~ " TX 0.5");
    assert(getJson("/api/tool/state")["editOpen"].boolean
        && distance(modelVertices()[6], original[6]) > 0.1,
        "6250 N2d population: ACEN-only pending edit did not open and move");
    command("mesh.subpatch_toggle");
    settle();
    const state = getJson("/api/tool/state");
    const handles = getJson("/api/tool/handles")["handles"];
    assert(!state["sessionOpen"].boolean
        && handles.type == JSONType.object && handles["parts"].array.length == 0,
        "6250 N2d: the no-re-arm preset without Element falloff missed the close branch");
    command("tool.set " ~ gPreset ~ " off");
}

unittest { // N3 — frozen pin plus an accepted, inert numeric edit.
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    const pin = vector(getJson("/api/toolpipe/eval")["actionCenter"]["center"]);
    command("mesh.subpatch_toggle");
    settle();
    const consolidated = modelVertices();
    script("tool.attr " ~ gPreset ~ " TX 1.0");
    settle();
    const state = getJson("/api/tool/state");
    const eval = getJson("/api/toolpipe/eval");
    assert(distance(vector(eval["actionCenter"]["center"]), pin) <= 1e-6,
        "6250 N3 control: inert numeric write advanced the frozen pin");
    assert(number(eval["transform"]["translate"].array[0]) == 1.0,
        "6250 N3 control: accepted numeric value was not retained");
    assert(!state["editOpen"].boolean && !state["sessionOpen"].boolean,
        "6250 N3 control: numeric write reopened the closed session");
    assert(modelVertices() == consolidated,
        "6250 N3: post-toggle numeric write moved a vertex");
    command("tool.set " ~ gPreset ~ " off");
}

unittest { // N4 — next press re-picks/re-grades the consolidated mesh.
    const original = establish();
    const camera = fetchCamera();
    initialDrag(camera, original);
    script("tool.attr " ~ gPreset ~ " TX 0.5");
    settle();
    command("mesh.subpatch_toggle");
    settle();
    const consolidated = modelVertices();
    assert(!getJson("/api/tool/state")["sessionOpen"].boolean,
        "6250 N4 population: toggle must close the Element session");

    const pixel = topPixel(getJson("/api/camera"), consolidated[7]);
    immutable int x = cast(int)(pixel[0] + 0.5);
    immutable int y = cast(int)(pixel[1] + 0.5);
    hover(camera, x, y);
    playAndWait(viewportLine(camera) ~ format(
        `{"t":30,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y));
    settle();
    const pressed = getJson("/api/toolpipe/eval");
    const pressedState = getJson("/api/tool/state");
    assert(distance(vector(pressed["actionCenter"]["center"]), consolidated[7]) <= 2e-5,
        "6250 N4 control: next press did not store the clicked vertex's current position");
    assert(distance(vector(pressed["transform"]["translate"]), [0.0, 0.0, 0.0]) <= 1e-6,
        "6250 N4 control: next press did not reset T to zero");
    assert(pressedState["sessionOpen"].boolean && pressedState["editOpen"].boolean,
        "6250 N4 control: next press did not reopen the edit session");

    haulHeld(camera, x, y, 80, 24, 18);
    const moved = modelVertices();
    // The picked vertex is the anchor-ring member and therefore has weight 1;
    // its observed displacement is the applied world translation itself.
    const translation = subtract(moved[7], consolidated[7]);
    const observed = measuredWeights(consolidated, moved, translation);
    assert(observed.length == consolidated.length && observed.length == 9,
        "6250 N4 population: falloff measurement lost a rig vertex");
    foreach (i; 0 .. observed.length) {
        const d = distance(consolidated[i], consolidated[7]);
        const expected = d >= 2.0 ? 0.0 : 1.0 - d / 2.0;
        assert(abs(observed[i] - expected) <= 3e-5,
            format("6250 N4: consolidated-mesh falloff weight v%s got %.6f want %.6f",
                   i, observed[i], expected));
    }
    command("tool.set " ~ gPreset ~ " off");
}
