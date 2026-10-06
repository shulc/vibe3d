import camera_lens_control_helpers;
// mesh.clone: a linear generator, then a clone effector. Two direct
// drags must re-space the same copies and produce two ToolSession steps.
import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.json;
import std.math : abs;
import std.format : format;
import std.net.curl : get;
import drag_helpers;

void main() {}
alias BASE = testBaseUrl;
enum string TOOL = "mesh.clone";

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command '" ~ line ~ "' failed: " ~ r.toString);
}
string planes() { return cast(string)get(BASE ~ "/api/mesh/planes"); }
long undoLen() { return cast(long)getJson("/api/history")["undo"].array.length; }
auto verts() { return getJson("/api/model")["vertices"].array; }
double number(JSONValue v) {
    switch (v.type) {
        case JSONType.integer: return cast(double)v.integer;
        case JSONType.uinteger: return cast(double)v.uinteger;
        case JSONType.float_: return v.floating;
        default: assert(false, "expected numeric JSON value, got " ~ v.toString);
    }
}
double attrOf(string name) {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " " ~ name ~ " ?");
    assert(r["status"].str == "ok", "query failed: " ~ r.toString);
    return number(r["value"]);
}
void navigate(bool redo) {
    import core.thread : Thread;
    import core.time : dur;
    playAndWaitLensControl(format(
        `{"t":0.000,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":%d,"repeat":0}`,
        redo ? 65 : 64), BASE);
    Thread.sleep(dur!"msecs"(150));
}
void assertLinearCopies() {
    auto v = verts();
    assert(v.length == 20, "three clones of one cube face need 20 vertices; got "
        ~ v.length.to!string);
    assert(v[3].array.length == 3 && v[8].array.length == 3 &&
           v[12].array.length == 3 && v[16].array.length == 3,
        "unexpected vertex layout: " ~ v[3].toString ~ " / " ~ v[8].toString
        ~ " / " ~ v[12].toString ~ " / " ~ v[16].toString);
    // The selected top face is [3,7,6,2]. The generator appends each four
    // vertices as a distinct slot, with one common three-dimensional step.
    foreach (axis; 0 .. 3) {
        assert(v[3].array[axis].type != JSONType.null_ &&
               v[8].array[axis].type != JSONType.null_ &&
               v[12].array[axis].type != JSONType.null_ &&
               v[16].array[axis].type != JSONType.null_,
            "null coordinate, offsets " ~
            postJson("/api/command", "tool.attr " ~ TOOL ~ " offX ?").toString ~ " " ~
            postJson("/api/command", "tool.attr " ~ TOOL ~ " offY ?").toString ~ " " ~
            postJson("/api/command", "tool.attr " ~ TOOL ~ " offZ ?").toString ~
            ": " ~ v[3].toString ~ " / " ~ v[8].toString
            ~ " / " ~ v[12].toString ~ " / " ~ v[16].toString);
        double p0 = number(v[3].array[axis]);
        double p1 = number(v[8].array[axis]);
        double p2 = number(v[12].array[axis]);
        double p3 = number(v[16].array[axis]);
        assert(abs((p2 - p1) - (p1 - p0)) < 1e-5 &&
               abs((p3 - p2) - (p1 - p0)) < 1e-5,
            "clone positions are not a linear progression on axis " ~ axis.to!string);
    }
}

unittest {
    foreach(controlLens;[defaultLensControl,explicitLensControl]) {
    import core.thread : Thread;
    import core.time : dur;
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "reset failed");
    r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"polygons","indices":[4]}`));
    assert(r["status"].str == "ok", "select failed");
    cmd("history.clear");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera failed");
    cmd("tool.set " ~ TOOL ~ " on");
    cmd("tool.attr " ~ TOOL ~ " num 3");
    Thread.sleep(dur!"msecs"(300));
    assert(attrOf("num") == 3, "clone count was not installed");
    immutable source = planes();
    immutable u0 = undoLen();
    assert(verts().length == 8, "source cube should have 8 vertices");
    applyLensControl(controlLens,BASE);
    auto cam = fetchCamera(BASE);
    immutable int cx = cam.vpX + cam.width / 2;
    immutable int cy = cam.vpY + cam.height / 2;
    void dragOnce() {
        playAndWaitLensControl(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
            cx, cy, cx + 70, cy - 40, 12), BASE);
        Thread.sleep(dur!"msecs"(200));
    }
    dragOnce();
    assertLinearCopies();
    immutable first = planes();
    immutable off1 = attrOf("offX");
    assert(first != source && undoLen() == u0 + 1 && abs(off1) > 1e-3,
        "first drag must build and record three copies");
    dragOnce();
    assertLinearCopies();
    immutable second = planes();
    immutable off2 = attrOf("offX");
    assert(second != first && undoLen() == u0 + 2 && abs(off2 - off1) > 1e-3,
        "second drag must re-space the same three copies and record a step");
    navigate(false);
    assert(planes() == first && abs(attrOf("offX") - off1) < 1e-5,
        "undo of second drag must restore first clone spacing");
    navigate(false);
    assert(planes() == source, "second undo must restore the source mesh");
    navigate(true);
    assert(planes() == first, "redo must restore first clone spacing");
    // EXPECTATION changed by law 3 (topology-redo S5, task 9170): the undo that
    // ended the post mode cut the second drag (a refire) from the redo, so the
    // second redo is refused. Capture: the reference's direct two-gesture Clone
    // cell (after_r3 = the first spacing, "Out of redos"), findings §1.
    navigate(true);
    assert(planes() == first && abs(attrOf("offX") - off1) < 1e-5 && undoLen() == u0 + 1,
        "the second redo must be refused: law 3 cut the second drag at the undo that "
        ~ "ended the post mode (redo restored " ~ (planes() == second
            ? "the second spacing" : "another image") ~ ")");
    cmd("tool.set " ~ TOOL ~ " off");
    assert(undoLen() == u0 + 1, "drop must not add a history row");

    }
    applyLensControl(defaultLensControl);
}

unittest { // captured: a 1.2 per-copy X scale grows each successive copy by 20%
    import core.thread : Thread;
    import core.time : dur;
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok");
    r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"polygons","indices":[4]}`));
    assert(r["status"].str == "ok");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok");
    cmd("tool.set " ~ TOOL ~ " on");
    cmd("tool.attr " ~ TOOL ~ " num 3");
    cmd("tool.attr " ~ TOOL ~ " sclX 120");
    Thread.sleep(dur!"msecs"(300));
    auto cam = fetchCamera(BASE);
    immutable int cx = cam.vpX + cam.width / 2;
    immutable int cy = cam.vpY + cam.height / 2;
    playAndWaitLensControl(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        cx, cy, cx + 70, cy - 40, 12), BASE);
    auto v = verts();
    assert(v.length == 20, "scaled clone must still create three copies");
    foreach (i; 1 .. 4) {
        immutable size_t base = cast(size_t)(4 + i * 4);
        double width = number(v[base + 3].array[0]) -
                       number(v[base].array[0]);
        double expected = i == 1 ? 1.2 : i == 2 ? 1.44 : 1.728;
        assert(abs(width - expected) < 1e-4,
            "clone " ~ i.to!string ~ " width " ~ width.to!string
            ~ " differs from the reference editor's sequential scale " ~ expected.to!string);
    }
    cmd("tool.set " ~ TOOL ~ " off");
}

unittest { // the offset haul is a free handle, quantised (K-H3 H3_NT): top ortho
    // view at 440 px/m (T = pixels / 440), q 0.005, the top face's centroid A
    // (0, 0.5, 0) on the lattice; a (70, -42) px haul writes q(A + T) - q(A) =
    // (0.16, 0, -0.095). RAW is (0.159091, 0, -0.095455).
    import core.thread : Thread;
    import core.time : dur;
    import pen_rig_helpers : penCameraAt;
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok");
    r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"polygons","indices":[4]}`));
    assert(r["status"].str == "ok");
    cmd("viewport.view Top");
    penCameraAt(Vec3(0, 0, 0), 440.0);
    assert(getJson("/api/camera")["projKind"].str == "Ortho",
        "rig: the top view must be orthographic");
    cmd("tool.set " ~ TOOL ~ " on");
    cmd("tool.attr " ~ TOOL ~ " num 1");
    Thread.sleep(dur!"msecs"(300));
    immutable double[3] o0 = [attrOf("offX"), attrOf("offY"), attrOf("offZ")];
    auto cam = fetchCamera(BASE);
    immutable int cx = cam.vpX + cam.width / 2, cy = cam.vpY + cam.height / 2;
    playAndWaitLensControl(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        cx, cy, cx + 70, cy - 42, 12), BASE);
    Thread.sleep(dur!"msecs"(200));
    immutable double[3] d = [attrOf("offX") - o0[0], attrOf("offY") - o0[1],
                             attrOf("offZ") - o0[2]];
    assert(abs(d[0] - 0.16) <= 1e-4 && abs(d[1]) <= 1e-4 && abs(d[2] + 0.095) <= 1e-4,
        format("clone-offset-quantised: the haul expected (0.16, 0, -0.095), got (%.6f, %.6f, %.6f)",
               d[0], d[1], d[2]));
    cmd("tool.set " ~ TOOL ~ " off");
}
