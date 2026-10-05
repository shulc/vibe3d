// Polygon pen: undo / redo INSIDE a live stroke, against the captured cells of
// tests/fixtures/pen_instroke_undo.json (top orthographic view, 440 px/m,
// points on the plane y = 1 through the camera focus). Ctrl+Z restores the
// stroke to its state before the LAST event (a click, a whole drag, each typed
// panel field incl. the current point, a flag write) with no history row;
// Ctrl+Shift+Z re-applies it; flip comes back with the state, never
// re-decided; a stroke commits ONE row. The mechanism is the tool session's
// attribute-image steps (the stroke = the hidden `points` attribute + every
// pen attribute).
//
// Cells beside the fixture: A4d-ctrlz (pen_facing.json); undo_one_point_stroke
// (the fixture's `related_cells`); and ours-only constructions —
//   reset-discards     4 clicks, `tool.reset`: the whole stroke goes, no row;
//   long-stroke-replace 70 clicks, a scene replace: nothing of the stroke stays;
//   idle-write-ctrlz   commit T, an Idle panel write, Ctrl+Z: the write opens
//                      no step, so the Ctrl+Z undoes T's row (as before);
//   commit-then-ctrlz  commit T with Enter, Ctrl+Z: T's row is undone and no
//                      image of T's stroke comes back (the commit ended the
//                      session's account);
//   ctrlz-after-commit commit T with Enter, 4 clicks, Ctrl+Z, drop: T and a
//                      triangle, 2 rows;
//   switch-rearm-no-leftover 3 clicks, arm another tool, re-arm the pen: no
//                      point is left and the next click makes a 1-point stroke;
//   points-not-injectable `tool.attr pen points …` is refused, no row;
//   rmb-then-ctrlz     3 clicks, RMB, Ctrl+Z: the cancel ended the account;
//   backspace-then-ctrlz, pop-to-empty-new-view, undo-then-drag: what the
//                      restored image re-derives (see the block).
// And quads-undo-pair, the captured QU-pair law (one step = a click and its
// automatic corner).
// Typed fields go through the interactive door (`/api/script?interactive=true`,
// the panel's source); keys through /api/play-events. `VIBE3D_CELL=<id>` runs
// one cell alone (the population floors hold for the full run only).

import drag_helpers : Vec3, fetchCamera, kPaceLine, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import pen_rig_helpers;
import std.algorithm : canFind;
import std.array : join;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs;
import std.process : environment;

void main() {}

private enum Vec3 kFocus = Vec3(0, 1, 0);
private enum int kSymZ = 122, kSymReturn = 13, kModCtrl = 64, kModShift = 1;

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger
         : v.type == JSONType.float_ ? v.floating : double.nan;
}
private Vec3 xz(double x, double z) { return Vec3(cast(float)x, 1, cast(float)z); }
private Vec3 v3(JSONValue a) {
    return Vec3(cast(float)num(a.array[0]), cast(float)num(a.array[1]),
                cast(float)num(a.array[2]));
}

private void key(int sym, int mod) {
    auto cam = fetchCamera();
    playAndWait(format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,`
        ~ `"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~ kPaceLine
        ~ `{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n"
        ~ `{"t":100.000,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, sym, mod, sym, mod));
}
private void ctrlZ()      { key(kSymZ, kModCtrl); }
private void ctrlShiftZ() { key(kSymZ, kModCtrl | kModShift); }
private void enter()      { key(kSymReturn, 0); }
private void backspace()  { key(8, 0); }
/// A right click on a world point (the pen's cancel).
private void rmbAt(Vec3 w) {
    auto cam = fetchCamera();
    auto p = worldPixel(w);
    playAndWait(format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,`
        ~ `"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~ kPaceLine
        ~ `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
        ~ `{"t":100.000,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, p[0], p[1], p[0], p[1]));
}

/// A typed panel field: the interactive door (ParameterChangeSource.InteractiveValue).
private void typed(string name, string value) {
    auto r = postJson("/api/script?interactive=true",
        "tool.attr pen " ~ name ~ " " ~ value);
    assert(r["status"].str == "ok", "typed " ~ name ~ " failed: " ~ r.toString);
}

private size_t depth() { return getJson("/api/history")["undo"].array.length; }
private string activeTool() {
    auto r = postJson("/api/command", "tool.attr pen currentPoint ?");
    return r["status"].str == "ok" ? "pen" : "other";
}
/// The stroke's point count (the hidden `points` attribute); -1 when the
/// read is refused (no pen armed, or no such attribute).
private long strokePoints() {
    auto r = postJson("/api/command", "tool.attr pen points ?");
    return r["status"].str == "ok" ? cast(long)num(r["value"]) : -1;
}
private double attrOr(string name, double fallback) {
    auto r = postJson("/api/command", "tool.attr pen " ~ name ~ " ?");
    if (r["status"].str != "ok") return fallback;
    auto v = r["value"];
    return v.type == JSONType.true_ ? 1 : v.type == JSONType.false_ ? 0 : num(v);
}
/// Drop the tool (a live stroke commits); tolerant: the pen may be gone already.
private void drop() { postJson("/api/command", "tool.set pen off"); }

private struct Model { Vec3[] verts; long[][] faces; }
private Model model() {
    Model m;
    auto j = getJson("/api/model");
    foreach (v; j["vertices"].array) m.verts ~= v3(v);
    foreach (f; j["faces"].array) {
        long[] ring;
        foreach (e; f.array) ring ~= e.integer;
        m.faces ~= ring;
    }
    return m;
}

private void expectModel(string cell, Vec3[] wantV, long[][] wantF, ref string[] fails) {
    auto m = model();
    if (m.verts.length != wantV.length || m.faces != wantF) {
        fails ~= format("%s: %s vertices, faces %s; expected %s vertices, faces %s",
            cell, m.verts.length, m.faces, wantV.length, wantF);
        return;
    }
    foreach (i, w; wantV) {
        const g = m.verts[i];
        if (abs(g.x - w.x) > 1e-4 || abs(g.y - w.y) > 1e-4 || abs(g.z - w.z) > 1e-4)
            fails ~= format("%s: vertex %s at (%s, %s, %s), expected (%s, %s, %s)",
                cell, i, g.x, g.y, g.z, w.x, w.y, w.z);
    }
}
private void expectFixture(string cell, JSONValue exp, ref string[] fails) {
    Vec3[] vs;
    foreach (v; exp["vertices"].array) vs ~= v3(v);
    long[][] fs;
    foreach (f; exp["polygons"].array) {
        long[] ring;
        foreach (e; f.array) ring ~= e.integer;
        fs ~= ring;
    }
    expectModel(cell, vs, fs, fails);
}
private void expectNum(string cell, string what, double got, double want, ref string[] fails) {
    if (abs(got - want) > 1e-4)
        fails ~= format("%s: %s = %s, expected %s", cell, what, got, want);
}
private void expectDepth(string cell, string when, size_t want, ref string[] fails) {
    const d = depth();
    if (d != want)
        fails ~= format("%s: history depth %s %s, expected %s", cell, when, d, want);
}
private void expectArmed(string cell, string when, long points, ref string[] fails) {
    const a = activeTool();
    const p = strokePoints();
    if (a != "pen" || p != points)
        fails ~= format("%s: %s the pen is %s with %s stroke points, expected armed with %s",
            cell, when, a == "pen" ? "armed" : "not armed", p, points);
}

/// Armed with no live stroke, read through today's attributes only (the
/// must-stay-green cells run unchanged on a binary without `points`).
private void expectIdlePen(string cell, string when, ref string[] fails) {
    const a = activeTool();
    const cur = attrOr("currentPoint", double.nan);
    if (a != "pen" || cur != -1)
        fails ~= format("%s: %s the pen is %s, current point %s; expected armed and idle (-1)",
            cell, when, a == "pen" ? "armed" : "not armed", cur);
}

/// The captured rig: top ortho at 440 px/m (ortho pixel = 2 d tan(pi/8) / h),
/// focus on the y-1 plane; our pixel size must sit in the 0.005 rung's
/// bracket (0.002, 0.005] so the drag's quantised landing (0.59) is exact.
private void rig() {
    import drag_helpers : fetchCamera;
    import std.math : PI, tan;
    const h = fetchCamera().height;
    penRigEmpty(kFocus, "Top", h / (440.0 * 2.0 * tan(PI / 8)));
    const px = num(getJson("/api/viewport/display")["cells"].array[0]["grid"]["pixelSize"]);
    assert(px > 0.002 && px <= 0.005,
        format("rig zoom drifted: pixel size %s outside (0.002, 0.005]", px));
}

private enum Vec3[3] kTri = [Vec3(-0.5f, 1, 0.3f), Vec3(0.5f, 1, 0.3f), Vec3(0, 1, -0.5f)];
private enum Vec3[4] kA = [Vec3(-0.4f, 1, 0.5f), Vec3(0.1f, 1, 0.1f),
                           Vec3(0.6f, 1, 0.5f), Vec3(0.1f, 1, -0.5f)];

/// One fixture cell, scripted as captured; returns its failures.
private string[] runCell(string name, JSONValue c) {
    auto exp = c["expected"];
    string[] fails;
    rig();
    final switch (name) {
    case "drag_then_undo", "drag_then_two_undos":
        clickWorld(kTri[]);
        dragWorld(kTri[1], 40);
        // positive control: the drag moved point 1 to x 0.59 (current 1).
        expectNum(name, "posX after the drag", attrOr("posX", double.nan), 0.59, fails);
        ctrlZ();
        if (name == "drag_then_two_undos") ctrlZ();
        expectNum(name, "current after the undo", attrOr("currentPoint", double.nan),
            num(exp["current_after_undo"]), fails);
        break;
    case "typed_then_undo", "typed_then_two_undos":
        clickWorld(kTri[]);
        typed("currentPoint", "1");
        typed("posX", "0.7");
        expectNum(name, "posX after typing", attrOr("posX", double.nan), 0.7, fails);
        ctrlZ();
        if (name == "typed_then_two_undos") ctrlZ();
        expectNum(name, "panel current", attrOr("currentPoint", double.nan),
            num(c["expected"]["panel_after_undo"]["current"]), fails);
        expectNum(name, "panel posX", attrOr("posX", double.nan),
            num(c["expected"]["panel_after_undo"]["posX"]), fails);
        break;
    case "undo_then_redo":
        clickWorld(kA[]);
        ctrlZ();
        expectNum(name, "current after the undo", attrOr("currentPoint", double.nan),
            num(exp["panel_after_undo"]["current"]), fails);
        ctrlShiftZ();
        expectNum(name, "current after the redo", attrOr("currentPoint", double.nan),
            num(exp["panel_after_redo"]["current"]), fails);
        expectNum(name, "flip", attrOr("flip", double.nan), 1, fails);
        break;
    case "pop_to_empty_then_click":
        clickWorld(kA[0], kA[1]);
        ctrlZ();
        ctrlZ();
        expectArmed(name, "after two undos", 0, fails);
        clickWorld(kTri[]);
        break;
    case "flag_write_then_undo":
        clickWorld(kA[]);
        expectNum(name, "flip decided", attrOr("flip", double.nan), 1, fails);
        typed("flip", "false");
        ctrlZ();
        expectNum(name, "flip after the undo", attrOr("flip", double.nan),
            exp["flip_on_after_undo"].type == JSONType.true_ ? 1 : 0, fails);
        expectArmed(name, "after the undo", 4, fails);
        break;
    case "flag_write_before_last_point_then_undo":
        clickWorld(kA[0 .. 3]);
        expectNum(name, "flip decided", attrOr("flip", double.nan), 1, fails);
        typed("flip", "false");
        clickWorld(kA[3]);
        ctrlZ();
        expectNum(name, "flip after the undo", attrOr("flip", double.nan),
            exp["flip_on_after_undo"].type == JSONType.true_ ? 1 : 0, fails);
        break;
    }
    expectDepth(name, "inside the stroke", 0, fails);
    drop();
    expectFixture(name, exp, fails);
    expectDepth(name, "after the stroke", cast(size_t)num(exp["rows"]), fails);
    return fails;
}

unittest {
    auto fx = parseJSON(import("fixtures/pen_instroke_undo.json"));
    auto facing = parseJSON(import("fixtures/pen_facing.json"));
    string[] fails;
    size_t ran;
    const only = environment.get("VIBE3D_CELL", "");
    bool want(string cell) { return only.length == 0 || only == cell; }

    // ---- must stay green: today's behaviour, kept ---------------------------
    string[] green;
    size_t ranGreen;
    if (want("reset-discards")) {
        rig();
        clickWorld(kA[]);
        auto r = postJson("/api/command",
            `{"id":"tool.reset","params":{"_positional":["pen"]}}`);
        if (r["status"].str != "ok") green ~= "reset-discards: tool.reset " ~ r.toString;
        expectIdlePen("reset-discards", "after tool.reset", green);
        drop();
        expectModel("reset-discards", null, null, green);
        expectDepth("reset-discards", "after the drop", 0, green);
        ++ranGreen;
    }
    if (want("long-stroke-replace")) {
        rig();
        // The zigzag presses within the merge radius of its own stroke edges
        // (an edge press inserts); merge is not this cell's subject, so it is
        // written off while Idle (no step opens).
        penCommand("tool.attr pen merge false");
        Vec3[] pts;
        foreach (i; 0 .. 70) pts ~= xz(-0.65 + 0.1 * (i % 14), -0.4 + 0.2 * (i / 14));
        clickWorld(pts);
        expectNum("long-stroke-replace", "current before the replace (floor)",
            attrOr("currentPoint", double.nan), 69, green);
        auto r = postJson("/api/command", commandBody("scene.reset", `{"empty":true}`));
        if (r["status"].str != "ok") green ~= "long-stroke-replace: replace " ~ r.toString;
        drop();
        expectModel("long-stroke-replace", null, null, green);
        foreach (e; getJson("/api/history")["undo"].array)
            if (e["label"].str.canFind("Pen"))
                green ~= "long-stroke-replace: a pen row was recorded: " ~ e.toString;
        ++ranGreen;
    }
    if (want("idle-write-ctrlz")) {
        rig();
        clickWorld(kTri[]);
        enter();
        expectDepth("idle-write-ctrlz", "after T", 1, green);
        typed("makeQuads", "true");
        ctrlZ();
        expectIdlePen("idle-write-ctrlz", "after the undo", green);
        expectModel("idle-write-ctrlz", null, null, green);
        expectDepth("idle-write-ctrlz", "after the undo", 0, green);
        typed("makeQuads", "false");
        drop();
        ++ranGreen;
    }
    if (want("commit-then-ctrlz")) {
        rig();
        clickWorld(kTri[]);
        enter();
        expectDepth("commit-then-ctrlz", "after T", 1, green);
        ctrlZ();
        expectIdlePen("commit-then-ctrlz", "after the undo", green);
        expectModel("commit-then-ctrlz", null, null, green);
        expectDepth("commit-then-ctrlz", "after the undo", 0, green);
        drop();
        ++ranGreen;
    }
    if (want("rmb-then-ctrlz")) {   // the cancel ends the session's account
        rig();
        clickWorld(kTri[]);
        rmbAt(Vec3(0.3f, 1, -0.3f));
        ctrlZ();
        expectIdlePen("rmb-then-ctrlz", "after the undo", green);
        drop();
        expectModel("rmb-then-ctrlz", null, null, green);
        expectDepth("rmb-then-ctrlz", "after the drop", 0, green);
        ++ranGreen;
    }
    assert(only.length || ranGreen == 5,
        format("must-stay-green cells ran %s, expected 5", ranGreen));
    assert(green.length == 0, "pen in-stroke undo (must stay green): " ~ green.join(" | "));
    ran += ranGreen;

    // ---- the captured law ---------------------------------------------------
    size_t fixtureCells;
    import std.algorithm : sort;
    auto names = fx["cells"].object.keys;
    sort(names);
    foreach (name; names) {
        if (!want(name)) continue;
        fails ~= runCell(name, fx["cells"][name]);
        ++fixtureCells;
    }
    assert(only.length || fixtureCells == 8,
        format("fixture cells ran %s, expected 8", fixtureCells));
    ran += fixtureCells;

    if (want("A4d-ctrlz")) {
        JSONValue c;
        foreach (k; facing["cases"].array) if (k["case"].str == "A4d-ctrlz") c = k;
        Vec3[] pts;
        foreach (p; c["clicks_xz_on_plane_y1"].array)
            pts ~= xz(num(p.array[0]), num(p.array[1]));
        rig();
        clickWorld(pts);
        expectNum("A4d-ctrlz", "flip after point 4", attrOr("flip", double.nan),
            num(c["flip_attr_after_point4"]), fails);
        ctrlZ();
        expectNum("A4d-ctrlz", "flip after the undo", attrOr("flip", double.nan),
            num(c["flip_attr_after_undo"]), fails);
        expectDepth("A4d-ctrlz", "inside the stroke", 0, fails);
        drop();
        Vec3[] vs;
        foreach (v; c["expected"]["vertices"].array) vs ~= v3(v);
        long[][] fs;
        foreach (f; c["expected"]["faces"].array) {
            long[] ring;
            foreach (e; f.array) ring ~= e.integer;
            fs ~= ring;
        }
        expectModel("A4d-ctrlz", vs, fs, fails);
        expectDepth("A4d-ctrlz", "after the stroke", 1, fails);
        ++ran;
    }
    if (want("undo_one_point_stroke")) {
        auto exp = fx["related_cells"]["undo_one_point_stroke"]["expected"];
        rig();
        clickWorld(xz(0, 0.2), xz(0.5, 0.2), xz(0.25, -0.3));
        drop();
        penCommand("tool.set pen on");
        clickWorld(xz(0, 0.2));
        ctrlZ();
        expectArmed("undo_one_point_stroke", "after the undo", 0, fails);
        expectDepth("undo_one_point_stroke", "after the undo", 1, fails);
        clickWorld(xz(-0.4, 0.6), xz(-0.6, 0.1));
        drop();
        expectFixture("undo_one_point_stroke", exp, fails);
        ++ran;
    }
    if (want("ctrlz-after-commit")) {
        rig();
        clickWorld(xz(0, 0.2), xz(0.5, 0.2), xz(0.25, -0.3));
        enter();
        clickWorld(kA[]);
        ctrlZ();
        expectArmed("ctrlz-after-commit", "after the undo", 3, fails);
        expectDepth("ctrlz-after-commit", "inside the stroke", 1, fails);
        drop();
        auto m = model();
        if (m.verts.length != 6 || m.faces.length != 2)
            fails ~= format("ctrlz-after-commit: %s vertices / %s faces, expected 6 / 2 "
                ~ "(T and a triangle)", m.verts.length, m.faces.length);
        expectDepth("ctrlz-after-commit", "after the stroke", 2, fails);
        ++ran;
    }
    if (want("switch-rearm-no-leftover")) {
        rig();
        clickWorld(kTri[]);
        penCommand("tool.set move on");
        penCommand("tool.set pen on");
        expectArmed("switch-rearm-no-leftover", "after the re-arm", 0, fails);
        clickWorld(kA[0]);
        expectArmed("switch-rearm-no-leftover", "after one click", 1, fails);
        drop();
        ++ran;
    }
    if (want("points-not-injectable")) {
        rig();
        clickWorld(kTri[]);
        const d0 = depth();
        auto r = postJson("/api/command", "tool.attr pen points 0");
        if (r["status"].str != "error" || !r.toString.canFind("not injectable"))
            fails ~= "points-not-injectable: " ~ r.toString;
        expectDepth("points-not-injectable", "after the write", d0, fails);
        expectArmed("points-not-injectable", "after the write", 3, fails);
        drop();
        ++ran;
    }
    // Ours-only: what the restored image re-derives. A Backspace (interim
    // arm) is a step of its own; an emptied stroke is Idle again (the next
    // click re-chooses the plane from the current view); restored points are
    // pressable again (their markers come back).
    if (want("backspace-then-ctrlz")) {
        rig();
        clickWorld(kA[]);
        backspace();
        expectArmed("backspace-then-ctrlz", "after the Backspace", 3, fails);
        ctrlZ();
        expectArmed("backspace-then-ctrlz", "after the undo", 4, fails);
        drop();
        expectModel("backspace-then-ctrlz", kA[], [[0L, 1, 2, 3]], fails);
        ++ran;
    }
    if (want("pop-to-empty-new-view")) {
        rig();
        clickWorld(kA[0], kA[1]);
        ctrlZ();
        ctrlZ();
        penCommand("viewport.view Front");
        clickWorld(Vec3(-0.3f, 1.2f, 0), Vec3(0.3f, 1.2f, 0), Vec3(0, 0.8f, 0));
        drop();
        auto m = model();
        bool onZPlane = m.verts.length == 3;
        foreach (v; m.verts) onZPlane = onZPlane && abs(v.z - m.verts[0].z) < 1e-4;
        if (!onZPlane || abs(m.verts[0].y - m.verts[2].y) < 0.3)
            fails ~= format("pop-to-empty-new-view: %s; expected 3 points on the front "
                ~ "view's plane", m.verts);
        ++ran;
    }
    if (want("undo-then-drag")) {
        rig();
        clickWorld(kTri[]);
        ctrlZ();
        dragWorld(kTri[0], 40);
        drop();
        expectModel("undo-then-drag", [Vec3(-0.41f, 1, 0.3f), kTri[1]], [[0L, 1]], fails);
        ++ran;
    }
    // K-C2 QU-pair (toolcard findings H2, cell C2-undo): under Make Quads one
    // Ctrl+Z pops the last click AND its automatic corner (4 -> 2 points).
    // Count only: the strip's ring order is the strip slice's.
    if (want("quads-undo-pair")) {
        rig();
        typed("makeQuads", "true");
        clickWorld(kA[0 .. 3]);
        expectArmed("quads-undo-pair", "after three clicks", 4, fails);
        ctrlZ();
        expectArmed("quads-undo-pair", "after the undo", 2, fails);
        expectDepth("quads-undo-pair", "inside the stroke", 0, fails);
        postJson("/api/command", `{"id":"tool.reset","params":{"_positional":["pen"]}}`);
        typed("makeQuads", "false");
        drop();
        ++ran;
    }
    assert(only.length || ran == 22, format("cells ran %s, expected 22", ran));
    assert(fails.length == 0, "pen in-stroke undo: " ~ fails.join(" | "));
}
