// Completed alignment gestures use ToolSession topology rows. The second
// gesture operates on the same source layout; undo walks the two releases.
import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.json;
import std.net.curl : get;
import std.conv : to;
import std.math : abs;
import std.format : format;
import core.thread : Thread;
import core.time : dur;
import drag_helpers;

void main() {}
alias BASE = testBaseUrl;

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ line ~ " " ~ r.toString);
}
void cmdUi(string line) {
    auto r = postJson("/api/command?origin=ui", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "UI command failed: " ~ line ~ " " ~ r.toString);
}
string planes() { return cast(string)get(BASE ~ "/api/mesh/planes"); }
size_t vertexCount() { return getJson("/api/model")["vertices"].array.length; }
long undoLen() { return cast(long)getJson("/api/history")["undo"].array.length; }
void navigate(bool redo) {
    playAndWait(format(
        `{"t":0.000,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":%d,"repeat":0}`,
        redo ? 65 : 64), BASE);
    Thread.sleep(dur!"msecs"(150));
}
void setup() {
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok");
    r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"polygons","indices":[4]}`));
    assert(r["status"].str == "ok");
    cmd("history.clear");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok");
}
void dragFrom(Vec3 press, Vec3 axis, int pixels) {
    auto cam = fetchCamera(BASE);
    auto vp = viewportFromCamera(cam);
    float px, py, ax, ay;
    assert(projectToWindow(press, vp, px, py));
    assert(projectToWindow(press + axis, vp, ax, ay));
    double dx = ax - px, dy = ay - py;
    double len = (dx * dx + dy * dy) ^^ 0.5;
    assert(len > 1e-6);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        cast(int)px, cast(int)py,
        cast(int)(px + dx / len * pixels),
        cast(int)(py + dy / len * pixels), 16), BASE);
    Thread.sleep(dur!"msecs"(150));
}

unittest { // Radial Array: second haul changes the same copies
    setup();
    cmdUi("tool.set mesh.radialArrayTool on");
    cmd("tool.attr mesh.radialArrayTool count 4");
    cmd("tool.attr mesh.radialArrayTool angle 270");
    Thread.sleep(dur!"msecs"(300));
    immutable source = planes();
    immutable long u0 = undoLen();
    auto vp = viewportFromCamera(fetchCamera(BASE));
    immutable float arm = gizmoSize(Vec3(0, 0, 0), vp);
    void drag() { dragFrom(Vec3(0, arm * 0.6f, 0), Vec3(0, 1, 0), 80); }
    drag();
    immutable first = planes();
    assert(first != source && vertexCount() == 20 && undoLen() == u0 + 1,
        "first radial gesture must create three copies and one step");
    drag();
    immutable second = planes();
    assert(second != first && vertexCount() == 20 && undoLen() == u0 + 2,
        "second radial gesture must rearrange the copies without growing topology");
    navigate(false);
    assert(planes() == first, "radial undo must restore first layout");
    navigate(false);
    assert(planes() == source, "radial second undo must restore source");
    navigate(true);
    assert(planes() == first, "radial redo must restore first layout");
    navigate(true);
    assert(planes() == first,
        "second radial redo after re-arm must leave the first layout");
    cmd("tool.set mesh.radialArrayTool off");
}

unittest { // Mirror: live copy and two completed groups, no cumulative drop row
    setup();
    cmdUi("tool.set mesh.mirrorTool on");
    Thread.sleep(dur!"msecs"(300));
    immutable source = planes();
    immutable long u0 = undoLen();
    dragFrom(Vec3(0, 0, 0), Vec3(1, 0, 0), 60);
    immutable first = planes();
    assert(first != source && vertexCount() == 12 && undoLen() == u0 + 1,
        "first mirror gesture must create one live copy and one step: changed="
        ~ (first != source).to!string ~ " vertices=" ~ vertexCount().to!string
        ~ " undo=" ~ undoLen().to!string ~ " baseline=" ~ u0.to!string);
    dragFrom(Vec3(0, 0, 0), Vec3(1, 0, 0), 60);
    immutable second = planes();
    assert(vertexCount() == 12 && undoLen() == u0 + 2,
        "second mirror gesture must keep one copy and record a step");
    navigate(false);
    assert(planes() == first, "mirror undo must restore first layout");
    navigate(false);
    assert(planes() == source, "mirror second undo must restore source");
    navigate(true);
    assert(planes() == first, "mirror redo must restore first copy");
    navigate(true);
    assert(planes() == first,
        "second mirror redo after re-arm must leave the first copy");
    cmd("tool.set mesh.mirrorTool off");
}
