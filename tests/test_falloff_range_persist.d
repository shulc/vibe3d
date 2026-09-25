// Element Move keeps a user-typed falloff Range between applications.
//
// Captured law (fixture tests/fixtures/editor_attrs_acen_laws_w17.json,
// `element_move_range`): a Range typed while Element Move is armed survives
// two hauls, a DROP of the tool, and a re-arm with a selection of a different
// size. It is neither re-fitted to the new selection nor reset to the
// arm-time value. Both drop gestures were captured and both keep it: a switch
// to Move with the `w` key, and Escape.
//
// The two drop gestures reach DIFFERENT reset doors in our code, which is why
// each has its own block with its own reset and rig (a shared rig would let
// the first block's state leak into the second):
//   * `w` arms Move through the prepared-arm door, whose pipe install clears
//     the falloff config (`FalloffStage.installPreparedTransientReset`);
//   * Escape drops the tool (`dropActiveTool` -> `resetTransientPipeStages`
//     -> `FalloffStage.resetTransient`), and the re-arm then runs the
//     prepared-arm install as well.
// So a fix at the install door alone turns W green and leaves E red, and a
// fix at `resetTransient` alone leaves BOTH red (measured on mutant copies).
//
// Rig: a 4x4 quad grid in XZ, spacing 0.5, facing +Y, top view. The two
// picked vertices are selected; the re-arm selection is the seven boundary
// vertices of one edge row plus its two neighbours (box 2.0 x 0.5). A re-fit
// to that selection would give 1.0, which is also our config default, so the
// needle separates "kept" from both rivals but not the rivals from each other.
//
// Every gesture is real input through /api/play-events: the hauls are mouse
// drags, the drops are the `w` and Escape keys, and the re-arm is the `t`
// key (the Element Move shortcut). Only the rig itself (mesh, view, the
// initial arm, the typed Range and the re-arm selection) is set through
// commands.
//
// Order inside each block: every floor first (probe reaches the value, the
// hauls moved the picked vertex, the drop dropped, the selection is seven,
// the re-arm armed Element Move), then the one needle.

import core.thread : Thread;
import core.time : msecs;
import drag_helpers : CameraState, fetchCamera, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : PI, abs, tan;

void main() {}

private alias V3 = double[3];

private enum double kTypedRange = 0.37;
private enum int kPickA = 6;    // (-0.5, 0, -0.5)
private enum int kPickB = 18;   // ( 0.5, 0,  0.5)
private enum int kIdle = 12;    // ( 0,   0,  0  ) — not selected
private immutable int[] kRearmSelection = [0, 1, 2, 3, 4, 5, 9];

private enum int kSymT = 116;
private enum int kSymW = 119;
private enum int kSymEscape = 27;

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

private double number(JSONValue value)
{
    return value.type == JSONType.integer ? cast(double)value.integer
         : value.type == JSONType.uinteger ? cast(double)value.uinteger
         : value.floating;
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

private V3[] modelVertices()
{
    V3[] result;
    foreach (value; getJson("/api/model")["vertices"].array) {
        auto a = value.array;
        result ~= [number(a[0]), number(a[1]), number(a[2])];
    }
    return result;
}

private string[string] falloffAttrs()
{
    foreach (stage; getJson("/api/toolpipe")["stages"].array)
        if (stage["task"].str == "WGHT") {
            string[string] result;
            foreach (key, value; stage["attrs"].object) result[key] = value.str;
            return result;
        }
    assert(false, "falloff stage (WGHT) is absent from /api/toolpipe");
}

private double falloffRange()
{
    auto attrs = falloffAttrs();
    assert(("dist" in attrs) !is null,
        "falloff stage publishes no `dist` attribute: " ~ attrs.to!string);
    return attrs["dist"].to!double;
}

/// True when the active tool is `id`. `tool.attr <id> T ?` is a pure read
/// that refuses unless `id` is the active tool.
private bool activeToolIs(string id)
{
    auto result = postJson("/api/command", "tool.attr " ~ id ~ " T ?");
    return result["status"].str == "ok";
}

// ---------------------------------------------------------------------------
// Real input
// ---------------------------------------------------------------------------

private string viewportLine(CameraState camera)
{
    return format(
        `{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        camera.vpX, camera.vpY, camera.width, camera.height);
}

private void pressKey(int sym)
{
    const camera = fetchCamera();
    playAndWait(viewportLine(camera)
        ~ format(`{"t":30,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":0,"repeat":0}` ~ "\n", sym)
        ~ format(`{"t":60,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":0,"repeat":0}` ~ "\n", sym));
    settle();
}

private int[2] topPixel(V3 point)
{
    auto camera = getJson("/api/camera");
    immutable double halfHeight = number(camera["distance"]) * tan(PI / 8.0);
    immutable double aspect = number(camera["width"]) / number(camera["height"]);
    immutable double ndcX = (point[0] - number(camera["focus"]["x"]))
                          / (halfHeight * aspect);
    immutable double ndcY = -(point[2] - number(camera["focus"]["z"]))
                          / halfHeight;
    return [cast(int)((ndcX * 0.5 + 0.5) * number(camera["width"])
                      + number(camera["vpX"]) + 0.5),
            cast(int)((1.0 - (ndcY * 0.5 + 0.5)) * number(camera["height"])
                      + number(camera["vpY"]) + 0.5)];
}

/// Hover the vertex, press, haul `dx` pixels to the right in 8 steps, release.
private void haul(V3 point, int dx)
{
    const camera = fetchCamera();
    const pixel = topPixel(point);
    immutable int x = pixel[0], y = pixel[1];

    string hover = viewportLine(camera);
    foreach (i; 0 .. 5)
        hover ~= format(
            `{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            30 + i * 20, x, y);
    playAndWait(hover);
    settle();

    playAndWait(viewportLine(camera) ~ format(
        `{"t":30,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y));
    settle();

    string motion = viewportLine(camera);
    int previous = x;
    foreach (i; 1 .. 9) {
        immutable int next = x + cast(int)(cast(double)dx * i / 8 + 0.5);
        motion ~= format(
            `{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":0,"state":1,"mod":0}` ~ "\n",
            60 + i * 25, next, y, next - previous);
        previous = next;
    }
    playAndWait(motion);
    settle();

    playAndWait(viewportLine(camera) ~ format(
        `{"t":30,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x + dx, y));
    settle();
}

// ---------------------------------------------------------------------------
// Rig
// ---------------------------------------------------------------------------

private string gridJson()
{
    string verts, faces;
    foreach (r; 0 .. 5)
        foreach (c; 0 .. 5) {
            if (verts.length) verts ~= ",";
            verts ~= format("[%g,0,%g]", -1.0 + 0.5 * c, -1.0 + 0.5 * r);
        }
    foreach (r; 0 .. 4)
        foreach (c; 0 .. 4) {
            immutable int i = r * 5 + c;
            if (faces.length) faces ~= ",";
            faces ~= format("[%d,%d,%d,%d]", i, i + 5, i + 6, i + 1);
        }
    return `{"vertices":[` ~ verts ~ `],"faces":[` ~ faces ~ `]}`;
}

/// Reset, build the grid, select the two picks, arm Element Move, type the
/// Range, and haul both picks. Returns with the tool armed and the typed
/// Range verified to have survived the hauls.
private void armTypeAndHaul(string cell)
{
    postJson("/api/command", commandBody("scene.reset"));
    command("tool.pipe.attr snap enabled false");
    command("tool.pipe.attr symmetry enabled false");
    auto loaded = postJson("/api/command", commandBody("scene.loadMesh", gridJson()));
    assert(loaded["status"].str == "ok", cell ~ ": grid load failed: " ~ loaded.toString);
    command("viewport.view Top");
    postJson("/api/camera", `{"distance":6,"focus":{"x":0,"y":0,"z":0}}`);
    command(format("select.element vertex set %d %d", kPickA, kPickB));
    command("tool.set xfrm.elementMove on");
    settle();

    const original = modelVertices();
    assert(original.length == 25,
        format("%s: grid floor — expected 25 vertices, got %d", cell, original.length));
    assert(activeToolIs("xfrm.elementMove"),
        cell ~ ": floor — Element Move is not the active tool after arming");
    assert(falloffAttrs()["type"] == "element",
        cell ~ ": floor — Element Move armed without the element falloff");

    command(format("tool.pipe.attr falloff dist %g", kTypedRange));
    settle();
    assert(abs(falloffRange() - kTypedRange) <= 1e-6,
        format("%s: floor — the typed Range did not reach /api/toolpipe (read %s)",
               cell, falloffRange()));

    // Haul 1: pick A, drag right. The picked vertex moves +X; B (selected,
    // outside the 0.37 sphere) and an unselected vertex stay.
    haul(original[kPickA], 30);
    auto afterFirst = modelVertices();
    assert(afterFirst[kPickA][0] - original[kPickA][0] > 0.05,
        format("%s: floor — haul 1 did not move the picked vertex +X (%s -> %s)",
               cell, original[kPickA], afterFirst[kPickA]));
    assert(abs(afterFirst[kPickB][0] - original[kPickB][0]) < 1e-5,
        format("%s: floor — haul 1 moved the far selected vertex (%s -> %s)",
               cell, original[kPickB], afterFirst[kPickB]));

    // Haul 2: pick B, drag right.
    haul(original[kPickB], 30);
    auto afterSecond = modelVertices();
    assert(afterSecond[kPickB][0] - original[kPickB][0] > 0.05,
        format("%s: floor — haul 2 did not move the picked vertex +X (%s -> %s)",
               cell, original[kPickB], afterSecond[kPickB]));
    assert(afterSecond[kIdle] == original[kIdle],
        format("%s: floor — an unselected vertex moved (%s -> %s)",
               cell, original[kIdle], afterSecond[kIdle]));

    assert(abs(falloffRange() - kTypedRange) <= 1e-6,
        format("%s: element range changed by a haul (read %s, typed %s)",
               cell, falloffRange(), kTypedRange));
}

/// Select the seven re-arm vertices and re-arm Element Move with its key.
private void selectAndRearm(string cell)
{
    command(format("select.element vertex set %(%d %)", kRearmSelection));
    settle();
    auto selected = getJson("/api/selection")["selectedVertices"].array;
    // 7 is the fixture's `selection_at_rearm_vertices`, a literal on purpose:
    // comparing against the command's own list could not disagree with it.
    assert(selected.length == 7,
        format("%s: floor — re-arm selection expected 7 vertices, got %d",
               cell, selected.length));

    pressKey(kSymT);
    assert(activeToolIs("xfrm.elementMove"),
        cell ~ ": floor — the `t` key did not re-arm Element Move");
    assert(falloffAttrs()["type"] == "element",
        cell ~ ": floor — Element Move re-armed without the element falloff");
}

// ---------------------------------------------------------------------------
// Block W — drop by switching to Move with `w`.   (named red on HEAD)
// ---------------------------------------------------------------------------

unittest
{
    enum cell = "range-persist W";
    armTypeAndHaul(cell);

    pressKey(kSymW);
    assert(activeToolIs("move"),
        cell ~ ": floor — the `w` key did not switch the active tool to Move");
    assert(!activeToolIs("xfrm.elementMove"),
        cell ~ ": floor — Element Move is still active after `w`");

    selectAndRearm(cell);

    immutable double range = falloffRange();
    assert(abs(range - kTypedRange) <= 1e-6,
        format("element range was not kept across re-arm (drop by w): read %s, typed %s",
               range, kTypedRange));

    command("tool.set xfrm.elementMove off");
}

// ---------------------------------------------------------------------------
// Block E — drop by Escape.
// ---------------------------------------------------------------------------

unittest
{
    enum cell = "range-persist E";
    armTypeAndHaul(cell);

    pressKey(kSymEscape);
    auto state = getJson("/api/tool/state");
    assert(state.type == JSONType.object && state.object.length == 0,
        cell ~ ": floor — Escape did not drop Element Move (tool state "
        ~ state.toString ~ ")");

    selectAndRearm(cell);

    immutable double range = falloffRange();
    assert(abs(range - kTypedRange) <= 1e-6,
        format("element range was not kept across re-arm (drop by escape): read %s, typed %s",
               range, kTypedRange));

    command("tool.set xfrm.elementMove off");
}
