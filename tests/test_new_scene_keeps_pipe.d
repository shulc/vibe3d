// A new scene keeps the tool pipe (task 9402): `file.new` drops the armed tool
// and resets only state stored IN the scene (the work plane); falloff, action
// centre, symmetry, the constraint, global snap and the Element pin survive.
// `scene.reset` (and so `/api/reset`) stays a full reset. Rows:
// `fixtures/constraint_boot.json` `new_scene_stages` and the E8 case
// `newscene-armed-seeds`.
module test_new_scene_keeps_pipe;

import drag_helpers : CameraState, Vec3, Viewport, fetchCamera, playAndWait,
    projectToWindow, viewportFromCamera;
import http_client : getJson, postJson, quiesce;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs;
import std.string : indexOf;

void main() {}

private JSONValue fixture() {
    static JSONValue cached;
    if (cached.type == JSONType.null_)
        cached = parseJSON(import("fixtures/constraint_boot.json"));
    return cached;
}

private JSONValue row(string id) {
    foreach (c; fixture()["new_scene_stages"].array)
        if (c["id"].str == id) return c;
    foreach (c; fixture()["cases"].array)
        if (c["id"].str == id) return c;
    assert(0, "fixture row missing: " ~ id);
}

private void cmd(string text) {
    const body_ = text[0] == '{' || text.indexOf(' ') >= 0 ? text : commandBody(text);
    auto answer = postJson("/api/command", body_);
    assert(answer["status"].str == "ok",
        format("command `%s` failed: %s", text, answer.toString));
    quiesce();
}

private void key(int sym, int scan) {
    playAndWait(
        `{"t":0.000,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n" ~
        format(`{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":0,"repeat":0}`, sym, scan) ~ "\n" ~
        format(`{"t":100.000,"type":"SDL_KEYUP","sym":%d,"scan":%d,"mod":0,"repeat":0}`, sym, scan) ~ "\n");
    quiesce();
}
private void keyW() { key(119, 26); }   // arm move
private void keyQ() { key(113, 20); }   // the drop key

private string[string] stage(string id, bool mustExist = true) {
    foreach (st; getJson("/api/toolpipe")["stages"].array)
        if (st["id"].str == id) {
            string[string] o;
            foreach (k, v; st["attrs"].object) o[k] = v.str;
            return o;
        }
    assert(!mustExist, "stage missing from /api/toolpipe: " ~ id);
    return null;
}

private bool toolArmed() {
    const t = getJson("/api/input/context")["tool"].toString;
    return t != "null" && t != `""`;
}

private void want(string where, string id, string attr, string expected) {
    const got = stage(id)[attr];
    assert(got == expected, format("%s: %s.%s want %s got %s", where, id, attr, expected, got));
}

private void wantNum(string where, string id, string attr, double expected) {
    const got = stage(id)[attr].to!double;
    assert(abs(got - expected) <= 1e-5,
        format("%s: %s.%s want %s got %s", where, id, attr, expected, got));
}

private void wantConstraint(string where, JSONValue c) {
    const s = stage("constrain");
    size_t n;
    foreach (k, v; c.object) {
        const attr = k == "double_sided" ? "dblSided" : k;
        const got = s[attr];
        const exp = v.type == JSONType.string ? v.str
            : v.type == JSONType.float_ ? format("%g", v.floating) : v.toString;
        assert(got == exp, format("%s: constraint %s want %s got %s", where, k, exp, got));
        ++n;
    }
    assert(n >= 1, where ~ ": fixture row compared no constraint field");
}

private string vec(JSONValue a) {
    return format("%g,%g,%g", a[0].floating, a[1].floating, a[2].floating);
}

/// The captured stage values (rows newscene-stages-after-drop and
/// newscene-workplane-snap), set through the user doors.
private void setStages() {
    const s = row("newscene-stages-after-drop")["set"];
    cmd(format(`tool.pipe.attr falloff type %s`, s["falloff"]["type"].str));
    cmd(format(`tool.pipe.attr falloff start "%s"`, vec(s["falloff"]["start"])));
    cmd(format(`tool.pipe.attr falloff end "0,0,%g"`, s["falloff"]["end_z"].floating));
    cmd("falloff.add radial");   // a stacked falloff is a pipe stage too (law_remembered.new_scene)
    cmd("actr.origin");
    cmd("tool.pipe.attr symmetry enabled true");
    cmd("tool.pipe.attr symmetry axis " ~ s["symmetry"]["axis"].str);
    const w = row("newscene-workplane-snap")["set"];
    cmd(format("tool.pipe.attr workplane cenX %g", w["work_plane"]["centre"][0].floating));
    cmd(format("tool.pipe.attr workplane cenY %g", w["work_plane"]["centre"][1].floating));
    cmd(format("tool.pipe.attr workplane rotX %g", w["work_plane"]["rotation_deg"][0].floating));
    cmd("tool.pipe.attr snap enabled true");
    cmd(`tool.pipe.attr snap types "grid,edge"`);
}

private void loadQuad(double x0, double x1) {
    cmd(commandBody("scene.loadMesh", format(
        `{"vertices":[[%g,0,-0.2],[%g,0,-0.2],[%g,0,0.2],[%g,0,0.2]],"faces":[[0,3,2,1]]}`,
        x0, x1, x1, x0)));
}

private double[3] acenEval() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return [c[0].floating, c[1].floating, c[2].floating];
}

unittest {
    size_t ran;
    // `VIBE3D_CELL=<id>` runs one cell alone (a mutation drill names the cell
    // it must redden); the population floor holds for the full run only.
    import std.process : environment;
    const only = environment.get("VIBE3D_CELL", "");
    bool cell(string id) { return only.length == 0 || only == id; }

    if (cell("new-scene-keeps")) { // every tool-pipe value survives; the work plane resets
        const r = row("newscene-stages-after-drop");
        cmd("scene.reset");
        keyW();
        keyQ();
        setStages();
        cmd("file.new");
        const a = r["after"];
        want("new-scene-keeps", "falloff", "type", a["falloff"]["type"].str);
        want("new-scene-keeps", "falloff", "start", vec(a["falloff"]["start"]));
        want("new-scene-keeps", "falloff", "end", format("0,0,%g", a["falloff"]["end_z"].floating));
        want("new-scene-keeps", "falloff#1", "type", "radial");
        want("new-scene-keeps", "actionCenter", "mode", "origin");
        want("new-scene-keeps", "symmetry", "enabled", "true");
        want("new-scene-keeps", "symmetry", "axis", a["symmetry"]["axis"].str);
        wantConstraint("new-scene-keeps", a["constraint"]);
        const w = row("newscene-workplane-snap")["after"];
        foreach (i, k; ["cenX", "cenY", "cenZ"])
            wantNum("new-scene-keeps", "workplane", k, w["work_plane"]["centre"][i].floating);
        foreach (i, k; ["rotX", "rotY", "rotZ"])
            wantNum("new-scene-keeps", "workplane", k, w["work_plane"]["rotation_deg"][i].floating);
        want("new-scene-keeps", "snap", "enabled", "true");
        want("new-scene-keeps", "snap", "types", "edge,grid");
        ++ran;
    }
    if (cell("new-scene-armed-seeds")) { // (E8): the new scene drops the armed tool, and
      // that drop inserts the remembered constraint
        const r = row("newscene-armed-seeds");
        cmd("scene.reset");
        wantConstraint("new-scene-armed-seeds before", r["before"]);
        keyW();
        assert(toolArmed(), "new-scene-armed-seeds: the move key armed nothing");
        cmd("file.new");
        assert(!toolArmed(), "new-scene-armed-seeds: file.new left a tool armed");
        wantConstraint("new-scene-armed-seeds", r["after"]);
        keyW();
        keyQ();
        wantConstraint("new-scene-armed-seeds drop", r["after_drop"]["constraint"]);
        ++ran;
    }
    if (cell("new-scene-no-tool-stays-off")) { // nothing armed, nothing inserted
        cmd("scene.reset");
        cmd("file.new");
        wantConstraint("new-scene-no-tool-stays-off",
            row("newscene-stages-boot")["after"]["constraint"]);
        ++ran;
    }
    if (cell("cleared-new-scene-not-readded")) { // once cleared, a new scene with a tool
      // armed does not re-add it (law.boot)
        cmd("scene.reset");
        keyW();
        keyQ();
        wantConstraint("cleared-new-scene first drop", row("newscene-armed-seeds")["after"]);
        key(27, 41);   // Escape clears the enabled constraint
        keyW();
        cmd("file.new");
        wantConstraint("cleared-new-scene-not-readded", parseJSON(`{"enabled":false}`));
        ++ran;
    }
    if (cell("api-reset-still-resets")) { // the same setup, then the full reset
        cmd("scene.reset");
        keyW();
        keyQ();
        setStages();
        cmd("scene.reset");
        want("api-reset-still-resets", "falloff", "type", "none");
        assert(stage("falloff#1", false) is null, "api-reset-still-resets: the stacked falloff survived");
        want("api-reset-still-resets", "actionCenter", "mode", "none");
        want("api-reset-still-resets", "symmetry", "enabled", "false");
        wantConstraint("api-reset-still-resets", parseJSON(`{"enabled":false,"geometry":"off"}`));
        want("api-reset-still-resets", "workplane", "auto", "true");
        wantNum("api-reset-still-resets", "workplane", "rotX", 0);
        want("api-reset-still-resets", "snap", "enabled", "false");
        want("api-reset-still-resets", "snap", "types", "vertex");
        ++ran;
    }
    if (cell("new-scene-keeps-element-pin")) { // the pin a vertex press stored in the old
      // scene is the pivot of the new scene's first rotate
        const r = row("newscene-element-pin");
        const pin = r["set"]["pin_written_by_pick"];
        cmd("scene.reset");
        loadQuad(0.6, 1.0);
        cmd("actr.element");   // the user preset: locks the stage
        keyW();
        auto cam = fetchCamera();
        auto vp = viewportFromCamera(cam);
        float sx, sy;
        assert(projectToWindow(Vec3(pin[0].floating, pin[1].floating, pin[2].floating), vp, sx, sy),
            "element pin: the picked vertex is off screen");
        const vpLine = format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
            cam.vpX, cam.vpY, cam.width, cam.height);
        playAndWait(vpLine ~ "\n" ~ format(
            `{"t":30.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n" ~
            `{"t":60.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
            cast(int) sx, cast(int) sy, cast(int) sx, cast(int) sy));
        quiesce();
        keyQ();
        cmd("file.new");
        loadQuad(-1.0, -0.6);
        const c = acenEval();
        foreach (i; 0 .. 3)
            assert(abs(c[i] - pin[i].floating) <= 1e-5,
                format("element pin: centre after file.new %s, captured pin %s", c, pin));
        cmd("tool.set rotate on");
        cmd("tool.attr rotate RY 90");
        cmd("tool.doApply");
        const before = [[-1.0, -0.2], [-0.6, -0.2], [-0.6, 0.2], [-1.0, 0.2]];
        const px = pin[0].floating, pz = pin[2].floating;
        auto verts = getJson("/api/model")["vertices"].array;
        assert(verts.length == 4, "element pin: the new quad has " ~ verts.length.to!string ~ " vertices");
        foreach (i, v; verts) {
            // +90 about Y: (x, z) - p -> (z, -x)
            const dx = before[i][0] - px, dz = before[i][1] - pz;
            const ex = px + dz, ez = pz - dx;
            assert(abs(v[0].floating - ex) <= 1e-5 && abs(v[2].floating - ez) <= 1e-5,
                format("element pin: vertex %s at (%g, %g), a turn about the pin puts it at (%g, %g)",
                    i, v[0].floating, v[2].floating, ex, ez));
        }
        ++ran;
    }

    assert(only.length ? ran == 1 : ran == 6, format("new scene cells: ran %s, expected 6", ran));
}
