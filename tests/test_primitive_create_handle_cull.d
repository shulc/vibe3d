// Create-tool handle visibility regression (task 5350).
//
// The create rigs deliberately register their complete handle population,
// including view-collapsed parts; visibility then removes only the collapsed
// parts from drawing and picking. Plane rings are different: create tools do
// not register them at all, so their per-instance MoveHandler gate must keep
// them out of the draw while transform tools retain their own plane handles.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import drag_helpers;

import core.thread : Thread;
import core.time : dur;
import std.algorithm : canFind, sort;
import std.array : array;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs;
import std.stdio : writefln;

void main() {}

private void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
           "command failed: " ~ line ~ " -> " ~ r.toString());
}

private void script(string line) {
    auto r = postJson("/api/script", line);
    assert(r["status"].str == "ok", "script failed: " ~ line ~ " -> " ~ r.toString());
}

private void setView(string name) {
    auto r = postJson("/api/command", format(
        `{"command":"viewport.view","id":"viewport.view","params":"%s"}`, name));
    assert(r["status"].str == "ok", "viewport.view failed: " ~ r.toString());
    if (name == "Perspective") {
        r = postJson("/api/camera",
            `{"azimuth":0.5,"elevation":0.4,"distance":4.0,`
            ~ `"focus":{"x":0,"y":0,"z":0}}`);
        assert(r["status"].str == "ok", "perspective camera failed: " ~ r.toString());
    }
}

private void resetAndArm(string tool, string view) {
    auto r = postJson("/api/command", commandBody("scene.reset", `{"empty":true}`));
    assert(r["status"].str == "ok", "empty reset failed: " ~ r.toString());
    cmd("history.clear");
    script("workplane.edit cenX:0 cenY:0 cenZ:0 rotX:0 rotY:0 rotZ:0");
    setView(view);
    cmd("tool.set " ~ tool);
}

private void dragPixels(int x0, int y0, int x1, int y1, int steps = 2) {
    auto cam = fetchCamera();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, steps));
    Thread.sleep(dur!"msecs"(140));
}

private void originPixel(out int x, out int y) {
    auto vp = viewportFromCamera(fetchCamera());
    float sx, sy;
    assert(projectToWindow(Vec3(0, 0, 0), vp, sx, sy), "world origin is off-camera");
    x = cast(int)(sx + 0.5f);
    y = cast(int)(sy + 0.5f);
}

private void setAttr(string tool, string name, double value) {
    cmd(format("tool.attr %s %s %.9g", tool, name, value));
}

private void setCenter(string tool) {
    setAttr(tool, "cenX", 0.0);
    setAttr(tool, "cenY", 0.0);
    setAttr(tool, "cenZ", 0.0);
}

private void makeReady(string tool) {
    int cx, cy;
    originPixel(cx, cy);

    if (tool == "prim.tube") {
        dragPixels(cx, cy, cx + 120, cy + 90);       // OuterSet
        dragPixels(cx - 15, cy, cx - 15, cy - 80);  // HeightSet
        setCenter(tool);
        setAttr(tool, "outerRadius", 1.0);
        setAttr(tool, "innerRadius", 0.35);
        setAttr(tool, "height", 1.0);
        dragPixels(cx + 45, cy, cx + 45, cy, 1);     // InnerSet
        setCenter(tool);
        return;
    }

    dragPixels(cx - 90, cy - 70, cx + 90, cy + 70); // BaseSet / MajorSet
    setCenter(tool);
    if (tool == "prim.torus") {
        setAttr(tool, "majorRadius", 1.0);
        setAttr(tool, "minorRadius", 0.3);
    } else {
        setAttr(tool, "sizeX", 1.0);
        setAttr(tool, "sizeY", 1.0);
        setAttr(tool, "sizeZ", 1.0);
    }
}

private struct Registry {
    int[] ids;
    int collapsed;
    int planeRingsDrawn;
    int captured;
    JSONValue raw;
}

private Registry registry() {
    auto h = getJson("/api/tool/handles")["handles"];
    assert(h.type == JSONType.object, "create tool published no handle registry");
    Registry r;
    r.raw = h;
    foreach (p; h["parts"].array) {
        r.ids ~= cast(int)p["part"].integer;
        if (p["visible"].type != JSONType.true_) ++r.collapsed;
    }
    r.ids.sort();
    r.planeRingsDrawn = cast(int)h["planeRingsDrawn"].integer;
    r.captured = cast(int)h["captured"].integer;
    return r;
}

private double attr(string tool, string name) {
    auto r = postJson("/api/command", "tool.attr " ~ tool ~ " " ~ name ~ " ?");
    assert(r["status"].str == "ok", "attribute query failed: " ~ r.toString());
    return r["value"].type == JSONType.integer
        ? cast(double)r["value"].integer : r["value"].floating;
}

private double[3] center(string tool) {
    return [attr(tool, "cenX"), attr(tool, "cenY"), attr(tool, "cenZ")];
}

private int[2] anchor(JSONValue handles, int part, string context) {
    foreach (p; handles["parts"].array) {
        if (cast(int)p["part"].integer != part) continue;
        assert(p["visible"].type == JSONType.true_,
               context ~ ": requested handle is collapsed");
        assert(p["screen"].type == JSONType.array,
               context ~ ": requested handle has no screen anchor");
        return [cast(int)(p["screen"].array[0].floating + 0.5),
                cast(int)(p["screen"].array[1].floating + 0.5)];
    }
    assert(false, format("%s: part %d is not registered", context, part));
}

private string eventHeader() {
    auto cam = fetchCamera();
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
        ~ "\n", cam.vpX, cam.vpY, cam.width, cam.height);
}

private void pressAt(int x, int y) {
    playAndWait(eventHeader() ~ format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`
        ~ "\n", x, y));
    Thread.sleep(dur!"msecs"(140));
}

private void releaseAt(int x, int y) {
    playAndWait(eventHeader() ~ format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`
        ~ "\n", x, y));
    Thread.sleep(dur!"msecs"(140));
}

private void moveAndRelease(int x0, int y0, int x1, int y1) {
    playAndWait(eventHeader() ~ format(
        `{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}`
        ~ "\n"
        ~ `{"t":100.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        x1, y1, x1 - x0, y1 - y0, x1, y1));
    Thread.sleep(dur!"msecs"(140));
}

private void assertPartGrabs(int part, string context) {
    auto r = registry();
    auto p = anchor(r.raw, part, context);
    pressAt(p[0], p[1]);
    immutable int got = registry().captured;
    releaseAt(p[0], p[1]);
    assert(got == part,
           format("%s: part %d press captured %d", context, part, got));
}

unittest { // Plane-ring gate: populated create rigs draw no unpickable rings.
    resetAndArm("prim.cylinder", "Perspective");
    scope(exit) script("tool.set prim.cylinder off");
    makeReady("prim.cylinder");

    auto handled = registry();
    assert(handled.ids == [0, 1, 2, 3, 4, 5, 10, 11, 12, 13],
           "handled create rig ids changed: " ~ handled.ids.to!string());
    assert(handled.planeRingsDrawn == 0,
           format("handled create rig drew %d unpickable plane rings",
                  handled.planeRingsDrawn));

    static immutable int[] handledSurvivors = [13, 10, 11, 12];
    static assert(handledSurvivors.length == 4, "handled survivor list shrank");
    foreach (part; handledSurvivors)
        assertPartGrabs(part, "handled create mover survivor");

    script("tool.set prim.cylinder off");
    resetAndArm("prim.tube", "Perspective");
    makeReady("prim.tube");
    auto moverOnly = registry();
    assert(moverOnly.ids == [0, 1, 2, 10],
           "mover-only create rig ids changed: " ~ moverOnly.ids.to!string());
    assert(moverOnly.planeRingsDrawn == 0,
           format("mover-only create rig drew %d unpickable plane rings",
                  moverOnly.planeRingsDrawn));
    static immutable int[] moverOnlySurvivors = [10, 0, 1, 2];
    static assert(moverOnlySurvivors.length == 4, "mover-only survivor list shrank");
    foreach (part; moverOnlySurvivors)
        assertPartGrabs(part, "mover-only create survivor");
    script("tool.set prim.tube off");
}

private struct MoveOutcome {
    int registered;
    int collapsed;
    int captured;
    int changedComponents;
    int planeRings;
    double[3] before;
    double[3] after;
}

private MoveOutcome moveCentre(string tool, string view) {
    resetAndArm(tool, view);
    makeReady(tool);
    auto r = registry();
    immutable int expectedRegistered = tool == "prim.cube" ? 9
        : (tool == "prim.tube" ? 4 : 10);
    assert(r.ids.length == expectedRegistered,
           format("%s %s registered %d handles, expected %d",
                  tool, view, r.ids.length, expectedRegistered));

    immutable int centrePart = tool == "prim.tube" ? 10 : 13;
    auto p = anchor(r.raw, centrePart, tool ~ " " ~ view ~ " centre");
    MoveOutcome outp;
    outp.registered = cast(int)r.ids.length;
    outp.collapsed = r.collapsed;
    outp.planeRings = r.planeRingsDrawn;
    // The ring gate is assigned in THREE classes, and the block above reaches
    // only two of them: prim.cylinder and prim.tube share one, and prim.cube is
    // the third. Without this line, flipping the cube's gate back on leaves the
    // whole file green -- measured, that mutation passed. Asserted here because
    // this sweep is the only place every tool is driven.
    assert(r.planeRingsDrawn == 0,
           format("%s %s drew %d unpickable plane rings",
                  tool, view, r.planeRingsDrawn));
    outp.before = center(tool);
    pressAt(p[0], p[1]);
    outp.captured = registry().captured;
    moveAndRelease(p[0], p[1], p[0] + 60, p[1] + 40);
    outp.after = center(tool);
    foreach (i; 0 .. 3)
        if (abs(outp.after[i] - outp.before[i]) > 1e-4)
            ++outp.changedComponents;

    assert(outp.changedComponents == 2,
           format("%s centre did not move in %s: before=[%.6f,%.6f,%.6f] "
                ~ "after=[%.6f,%.6f,%.6f], changed components=%d, captured=%d",
                  tool, view, outp.before[0], outp.before[1], outp.before[2],
                  outp.after[0], outp.after[1], outp.after[2],
                  outp.changedComponents, outp.captured));
    immutable int frozenAxis = view == "Perspective" ? 2 : 1;
    assert(abs(outp.after[frozenAxis] - outp.before[frozenAxis]) <= 1e-4,
           format("%s %s centre froze the wrong axis: expected axis %d "
                ~ "unchanged at %.6f, actual %.6f",
                  tool, view, frozenAxis, outp.before[frozenAxis],
                  outp.after[frozenAxis]));
    assert(outp.captured == centrePart,
           format("%s %s centre press captured part %d, expected %d",
                  tool, view, outp.captured, centrePart));

    immutable int expectedCollapsed = view == "Perspective" ? 0
        : (tool == "prim.cube" ? 2 : (tool == "prim.tube" ? 1 : 3));
    assert(outp.collapsed == expectedCollapsed,
           format("%s %s collapsed %d of %d handles, expected %d",
                  tool, view, outp.collapsed, outp.registered, expectedCollapsed));
    writefln("HANDLE-CULL %s %s registered=%d collapsed=%d "
           ~ "before=[%.6f,%.6f,%.6f] after=[%.6f,%.6f,%.6f]",
             tool, view, outp.registered, outp.collapsed,
             outp.before[0], outp.before[1], outp.before[2],
             outp.after[0], outp.after[1], outp.after[2]);
    script("tool.set " ~ tool ~ " off");
    return outp;
}

unittest { // Axial ortho culls size handles; perspective remains unchanged.
    static immutable string[] tools = [
        "prim.tube", "prim.cylinder", "prim.cube", "prim.cone",
        "prim.sphere", "prim.torus", "prim.capsule", "prim.ellipsoid",
    ];
    // Population floor. Every assert in this block lives inside moveCentre, so
    // an empty or shortened list leaves the block green while testing nothing:
    // measured, emptying `tools` returned EXIT=0 in well under a second. The
    // count of driven cells is pinned beside the list for the same reason.
    static assert(tools.length == 8, "the eight-primitive sweep lost a tool");
    size_t cells;
    foreach (tool; tools) { moveCentre(tool, "Top"); ++cells; }
    foreach (tool; tools) { moveCentre(tool, "Perspective"); ++cells; }
    assert(cells == 16, format("drove %d cells, expected 16", cells));
}

unittest { // Transform instances retain all three registered plane handles.
    auto r = postJson("/api/command", commandBody("scene.reset", `{"empty":true}`));
    assert(r["status"].str == "ok", "transform control reset failed");
    setView("Perspective");
    script("tool.set move on");
    scope(exit) script("tool.set move off");

    auto h = getJson("/api/tool/handles")["handles"];
    int[] ids;
    foreach (p; h["parts"].array) ids ~= cast(int)p["part"].integer;
    ids.sort();
    // Without this floor, emptying the list guts the whole block: `scene.reset`
    // and `tool.set move on` would be all that remains, and the half this
    // unittest exists to prove -- that transform rigs KEEP their plane handles
    // -- would vanish with nothing red. Measured green when emptied.
    static immutable int[] transformPlanes = [4, 5, 6];
    static assert(transformPlanes.length == 3, "transform plane list shrank");
    foreach (part; transformPlanes) {
        assert(ids.canFind(part),
               format("transform control: plane part %d is not registered", part));
        auto p = anchor(h, part, "transform plane survivor");
        pressAt(p[0], p[1]);
        auto after = getJson("/api/tool/handles")["handles"];
        immutable int captured = cast(int)after["captured"].integer;
        releaseAt(p[0], p[1]);
        assert(captured == part,
               format("transform plane part %d captured %d", part, captured));
        h = getJson("/api/tool/handles")["handles"];
    }
}
