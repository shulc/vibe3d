// reference editor poly.clone: a linear generator, then a Clone Effector. Two direct
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
    playAndWait(format(
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
    auto cam = fetchCamera(BASE);
    immutable int cx = cam.vpX + cam.width / 2;
    immutable int cy = cam.vpY + cam.height / 2;
    void dragOnce() {
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
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
    navigate(true);
    assert(planes() == second && abs(attrOf("offX") - off2) < 1e-5,
        "second redo must restore second clone spacing");
    cmd("tool.set " ~ TOOL ~ " off");
    assert(undoLen() == u0 + 2, "drop must not add a history row");
}

unittest { // captured gen.linear sclX=1.2 grows each successive copy by 20%
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
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
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
