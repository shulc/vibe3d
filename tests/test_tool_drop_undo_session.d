// probe (step 0)
import drag_helpers : Vec3, buildDragLog, fetchCamera, fetchHandlePart, playAndWait;
import http_client : getJson, postJson, quiesce;
import http_command_helpers : commandBody;
import pen_rig_helpers : penCameraAt, worldPixel;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, round;
import std.stdio : writeln;
import std.string : indexOf;

void main() {}

private void cmd(string line) {
    auto r = postJson("/api/command", line[0] == '{' || line.indexOf(' ') >= 0 ? line : commandBody(line));
    assert(r["status"].str == "ok", format("`%s` failed: %s", line, r));
    quiesce();
}
private void key(int sym, int scan, int mod = 0) {
    playAndWait(format(`{"t":0,"type":"PACE","mode":"frames"}` ~ "\n" ~
        `{"t":30,"type":"SDL_KEYDOWN","sym":%s,"scan":%s,"mod":%s,"repeat":0}` ~ "\n" ~
        `{"t":60,"type":"SDL_KEYUP","sym":%s,"scan":%s,"mod":%s,"repeat":0}` ~ "\n", sym, scan, mod, sym, scan, mod));
    quiesce();
}
private string tool() {
    auto s = getJson("/api/tool/state");
    return ("tool" in s.object) ? s["tool"].str : "";
}
private string ictx() { return getJson("/api/input/context")["tool"].toString; }
private void dragPx(int[2] a, int dx, int dy) {
    auto c = fetchCamera();
    playAndWait(buildDragLog(c.vpX, c.vpY, c.width, c.height, a[0], a[1], a[0] + dx, a[1] + dy, 10));
    quiesce();
}
private void show(string tag) {
    auto h = getJson("/api/history");
    string[] u, r;
    foreach (e; h["undo"].array) u ~= e["label"].str;
    foreach (e; h["redo"].array) r ~= e["label"].str;
    writeln(tag, ": tool=", ictx(), " v0=", getJson("/api/model")["vertices"].array[0].toString,
        " undo=", u, " redo=", r);
}

private void ui(string line) {
    auto r = postJson("/api/command?origin=ui", line);
    assert(r["status"].str == "ok", format("ui `%s` failed: %s", line, r));
    quiesce();
}
private void walk(string preset, bool sameKey, bool twoDrags) {
    writeln("=== ", preset, sameKey ? " key1" : " Q", twoDrags ? " 2drags" : "");
    cmd("scene.reset");
    cmd(commandBody("scene.loadMesh",
        `{"vertices":[[0,0,0],[0.3,0,0],[0.3,0,0.3],[0,0,0.3]],"faces":[[0,3,2,1]]}`));
    cmd("viewport.view Top");
    penCameraAt(Vec3(0.15f, 0, 0.15f), 440);
    cmd("select.typeFrom vertex");
    cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3]}`));
    cmd("history.clear");
    ui("tool.set " ~ preset ~ " on"); show("arm");
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0); show("d1");
    if (twoDrags) { dragPx(worldPixel(Vec3(0.24f, 0, 0.15f)), 0, 40); show("d2"); }
    if (sameKey) key(49, 30); else key(113, 20);
    show("drop");
    key(122, 29, 64); show("z1");
    key(122, 29, 64); show("z2");
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0); show("drag-after");
}
unittest {
    foreach (p; ["move", "TransformMove", "TransformRotate", "TransformScale"]) {
        walk(p, false, false);
        walk(p, true, false);
    }
    walk("TransformMove", false, true);
    walk("TransformRotate", false, true);
    writeln("=== redo after z1");
    cmd("scene.reset");
    cmd(commandBody("scene.loadMesh",
        `{"vertices":[[0,0,0],[0.3,0,0],[0.3,0,0.3],[0,0,0.3]],"faces":[[0,3,2,1]]}`));
    cmd("viewport.view Top");
    penCameraAt(Vec3(0.15f, 0, 0.15f), 440);
    cmd("select.typeFrom vertex");
    cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3]}`));
    cmd("history.clear");
    ui("tool.set TransformRotate on");
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    key(113, 20); key(122, 29, 64); show("z1");
    key(122, 29, 65); show("redo");
}
