// In-session redo restores the undone gesture (task 9500; capture K-RD rule 1,
// cells RD_TM_C / RD_ROT / RD_SCL): inside a live transform session Ctrl+Z
// takes back the last drag and Ctrl+Shift+Z brings it back, for every preset
// and handle. The reference's redo COUNTER reads 0 there (the undone pair is
// parked in a side branch), so nothing here may be gated on a redo depth; ours
// keeps the entry on its redo stack. The re-grade walk is the card's: a
// falloff re-grade entry undone and redone inside the live run.
// Rig (K-RD): a 0.3 m quad at the origin, all four vertices, top view 440 px/m.

import drag_helpers : Vec3, buildDragLog, fetchCamera, fetchHandlePart, playAndWait;
import http_client : getJson, postJson, quiesce;
import http_command_helpers : commandBody;
import pen_rig_helpers : penCameraAt, worldPixel;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, round;

void main() {}

private void cmd(string line) {
    import std.string : indexOf;
    auto r = postJson("/api/command", line[0] == '{' || line.indexOf(' ') >= 0 ? line : commandBody(line));
    assert(r["status"].str == "ok", format("`%s` failed: %s", line, r));
    quiesce();
}
private void script(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", format("`%s` failed: %s", line, r));
    quiesce();
}
private void nav(bool redo) {
    const mod = redo ? 65 : 64;
    playAndWait(format(`{"t":0,"type":"PACE","mode":"frames"}` ~ "\n" ~
        `{"t":30,"type":"SDL_KEYDOWN","sym":122,"scan":29,"mod":%s,"repeat":0}` ~ "\n" ~
        `{"t":60,"type":"SDL_KEYUP","sym":122,"scan":29,"mod":%s,"repeat":0}` ~ "\n", mod, mod));
    quiesce();
}
private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double) v.integer : v.floating;
}
private double[3][] verts() {
    double[3][] r;
    foreach (v; getJson("/api/model")["vertices"].array)
        r ~= [num(v.array[0]), num(v.array[1]), num(v.array[2])];
    return r;
}
private double gap(const double[3][] a, const double[3][] b) {
    assert(a.length == b.length && a.length == 4, "population: 4 quad vertices");
    double m = 0;
    foreach (i; 0 .. a.length) foreach (k; 0 .. 3) m = abs(a[i][k] - b[i][k]) > m ? abs(a[i][k] - b[i][k]) : m;
    return m;
}
private size_t depth(string k) { return getJson("/api/history")[k].array.length; }
private string tool() {
    auto s = getJson("/api/tool/state");
    return ("tool" in s.object) ? s["tool"].str : "";
}
private void dragPx(int[2] a, int dx, int dy) {
    auto c = fetchCamera();
    playAndWait(buildDragLog(c.vpX, c.vpY, c.width, c.height, a[0], a[1], a[0] + dx, a[1] + dy, 10));
    quiesce();
}
private int[2] part(int id) {
    double x, y; bool found;
    fetchHandlePart(id, x, y, found);
    assert(found, format("handle part %s missing", id));
    return [cast(int) round(x), cast(int) round(y)];
}
private void rig(string preset) {
    cmd("scene.reset");
    cmd(commandBody("scene.loadMesh",
        `{"vertices":[[0,0,0],[0.3,0,0],[0.3,0,0.3],[0,0,0.3]],"faces":[[0,3,2,1]]}`));
    cmd("viewport.view Top");
    penCameraAt(Vec3(0.15f, 0, 0.15f), 440);
    cmd("select.typeFrom vertex");
    cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3]}`));
    cmd("tool.set " ~ preset);
    cmd("history.clear");
    assert(tool() == "xfrm", "rig: " ~ preset ~ " not armed");
}

/// drag 1, drag 2, Ctrl+Z, Ctrl+Shift+Z: the redo restores the drag-2 state and
/// the tool stays live. Returns the restored positions.
private double[3][] walk(string cell, string preset, void delegate() d1, void delegate() d2) {
    rig(preset);
    d1();
    const one = verts(), n1 = depth("undo");
    d2();
    const two = verts(), n2 = depth("undo");
    assert(n1 >= 1 && n2 == n1 + 1 && gap(one, two) > 0.01,
        format("%s floor: drag 2 recorded nothing (undo %s -> %s, moved %.4f)", cell, n1, n2, gap(one, two)));
    nav(false);
    assert(gap(verts(), one) <= 1e-6 && depth("undo") == n1 && depth("redo") == 1 && tool() == "xfrm",
        format("%s Ctrl+Z: off the drag-1 state by %.6f, undo %s redo %s, tool '%s'",
            cell, gap(verts(), one), depth("undo"), depth("redo"), tool()));
    nav(true);
    assert(gap(verts(), two) <= 1e-6 && depth("undo") == n2 && depth("redo") == 0 && tool() == "xfrm",
        format("%s Ctrl+Shift+Z: off the drag-2 state by %.6f, undo %s redo %s, tool '%s'",
            cell, gap(verts(), two), depth("undo"), depth("redo"), tool()));
    return verts();
}

unittest { // RD_TM_C: two centre drags (+40 px X, then +40 px Z); fixture end_pos
    const c0 = worldPixel(Vec3(0.15f, 0, 0.15f));
    double[3][] got;
    foreach (preset; ["TransformMove", "move"])
        got = walk("RD_TM_C " ~ preset, preset,
            () { dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0); },
            () { dragPx(worldPixel(Vec3(0.24f, 0, 0.15f)), 0, 40); });
    const double[3][] want = [[0.09, 0, 0.09], [0.39, 0, 0.09], [0.39, 0, 0.39], [0.09, 0, 0.39]];
    assert(gap(got, want) <= 1.5 / 440.0,
        format("RD_TM_C: after the redo %s, K-RD end_pos %s", got, want));
}

unittest { // RD_ROT: two Y-ring drags; RD_SCL: X-handle then Z-handle drag
    walk("RD_ROT", "TransformRotate",
        () { auto p = part(11); dragPx([p[0] + 2, p[1] - 117], 30, 0); },
        () { auto p = part(11); dragPx([p[0] + 2, p[1] - 117], 15, 0); });
    walk("RD_SCL", "TransformScale",
        () { dragPx(part(20), 40, 0); },
        () { dragPx(part(22), 0, 40); });
}

unittest { // the card's walk: a falloff re-grade entry undone and redone inside the run
    foreach (preset; ["TransformMove", "TransformRotate", "TransformScale"]) {
        cmd("scene.reset");
        cmd("viewport.view Top");
        postJson("/api/camera", `{"distance":6,"focus":{"x":0,"y":0,"z":0}}`);
        cmd("tool.set " ~ preset);
        script(`tool.pipe.attr falloff type radial`);
        script(`tool.pipe.attr falloff shape linear`);
        script(`tool.pipe.attr falloff center "0.5,0.5,0.5"`);
        script(`tool.pipe.attr falloff size "1,1,1"`);
        cmd("history.clear");
        auto c = fetchCamera();
        dragPx([c.vpX + c.width / 2, c.vpY + c.height / 2], 60, 0);
        const n1 = depth("undo");
        script(`tool.pipe.attr falloff size "5,5,5"`);
        const regraded = getJson("/api/model")["vertices"].toString;
        assert(depth("undo") == n1 + 1, format("%s floor: the re-grade recorded nothing (undo %s)", preset, depth("undo")));
        nav(false);
        assert(depth("undo") == n1 && depth("redo") == 1 && getJson("/api/model")["vertices"].toString != regraded,
            format("%s Ctrl+Z: undo %s redo %s", preset, depth("undo"), depth("redo")));
        nav(true);
        assert(depth("undo") == n1 + 1 && depth("redo") == 0
                && getJson("/api/model")["vertices"].toString == regraded && tool() == "xfrm",
            format("%s: the redo of the re-grade did not restore it (undo %s redo %s, tool '%s')",
                preset, depth("undo"), depth("redo"), tool()));
        script(`tool.pipe.attr falloff type none`);
        cmd("tool.set " ~ preset ~ " off");
    }
}
