// The primitive centre box drags on a viewport-chosen principal world plane,
// independent of the pinned construction plane used to create the shape.

import http_client : getJson, postJson, testBaseUrl;
import http_command_helpers : commandBody;
import drag_helpers : buildDragLog, fetchCamera, playAndWait;
import std.format : format;
import std.json;
import std.math : abs, sqrt, tan, PI;

void main() {}

alias BASE = testBaseUrl;

struct V3 {
    double x, y, z;
    V3 opBinary(string op : "+")(V3 o) const { return V3(x+o.x, y+o.y, z+o.z); }
    V3 opBinary(string op : "-")(V3 o) const { return V3(x-o.x, y-o.y, z-o.z); }
    V3 opBinary(string op : "*")(double s) const { return V3(x*s, y*s, z*s); }
    string toString() const { return format("(%+.4f,%+.4f,%+.4f)", x, y, z); }
}

double dot(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
V3 cross(V3 a, V3 b) {
    return V3(a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x);
}
V3 unit(V3 v) { return v * (1.0 / sqrt(dot(v, v))); }

double num(JSONValue v) {
    if (v.type == JSONType.INTEGER)  return cast(double)v.integer;
    if (v.type == JSONType.UINTEGER) return cast(double)v.uinteger;
    return v.floating;
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
           "command failed: " ~ line ~ ": " ~ r.toString);
}

double qf(string tool, string attr) {
    auto r = postJson("/api/command", "tool.attr " ~ tool ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query failed: " ~ attr);
    return num(r["value"]);
}

V3 position(string tool) {
    return V3(qf(tool, "cenX"), qf(tool, "cenY"), qf(tool, "cenZ"));
}

V3 sizeTriple(string tool) {
    return V3(qf(tool, "outerRadius"), qf(tool, "innerRadius"),
              qf(tool, "height"));
}

void drag(int x0, int y0, int x1, int y1, int steps = 8, uint mod = 0) {
    auto c = fetchCamera(BASE);
    playAndWait(buildDragLog(c.vpX, c.vpY, c.width, c.height,
                             x0, y0, x1, y1, steps, mod), BASE);
}

void settle() {
    import core.thread : Thread;
    import core.time : dur;
    Thread.sleep(dur!"msecs"(150));
}

void buildPinnedPrimitive(string tool) {
    auto reset = postJson("/api/command",
        commandBody("scene.reset", `{"empty":true}`));
    assert(reset["status"].str == "ok", "scene reset failed");
    cmd("history.clear");
    cmd("workplane.reset");
    cmd("viewport.view Perspective");
    auto cs = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":0.4,"distance":4.0,` ~
        `"focus":{"x":0,"y":0,"z":0}}`);
    assert(cs["status"].str == "ok", "build camera set failed");
    cmd("workplane.edit rotX:90"); // world XY, normal world Z
    cmd("tool.set " ~ tool);

    auto c = fetchCamera(BASE);
    int cx = c.vpX + c.width / 2;
    int cy = c.vpY + c.height / 2;
    drag(cx, cy, cx + 110, cy - 70); // OuterSet
    drag(cx, cy, cx, cy - 90);       // HeightSet
    drag(cx + 20, cy, cx + 20, cy, 1); // InnerSet: mover is visible

    cmd("tool.attr " ~ tool ~ " cenX 0");
    cmd("tool.attr " ~ tool ~ " cenY 0");
    cmd("tool.attr " ~ tool ~ " cenZ 0");
    cmd("tool.attr " ~ tool ~ " outerRadius 0.5");
    cmd("tool.attr " ~ tool ~ " innerRadius 0.25");
    cmd("tool.attr " ~ tool ~ " height 1.0");
    cmd("tool.attr " ~ tool ~ " segments 24");
    cmd("tool.attr " ~ tool ~ " cap true");
}

void setOrtho(string preset) {
    cmd("viewport.view " ~ preset);
    auto c = fetchCamera(BASE);
    double distance = cast(double)c.height / (64.0 * tan(PI / 8.0));
    auto r = postJson("/api/camera", format(`{"distance":%.9f}`, distance));
    assert(r["status"].str == "ok", preset ~ " distance set failed");
}

void setObliquePerspective() {
    cmd("viewport.view Perspective");
    auto c = fetchCamera(BASE);
    immutable V3 target = V3(0.0, 2.5, 3.75);
    V3 back = unit(V3(-4.0, 1.0, 1.0));
    V3 p = unit(target - back * dot(target, back));
    V3 t = cross(p, back);
    V3 right = p * (3.0 / sqrt(13.0)) + t * (2.0 / sqrt(13.0));
    V3 up    = p * (2.0 / sqrt(13.0)) - t * (3.0 / sqrt(13.0));
    double k = cast(double)c.height / (2.0 * tan(PI / 8.0));
    double distance = dot(target, back) + k * dot(target, right) / 96.0;
    auto r = postJson("/api/camera", format(
        `{"focus":{"x":0,"y":0,"z":0},"distance":%.9f,` ~
        `"orientation":[%.12f,%.12f,%.12f,%.12f,%.12f,%.12f,%.12f,%.12f,%.12f]}`,
        distance, right.x, right.y, right.z, up.x, up.y, up.z,
        back.x, back.y, back.z));
    assert(r["status"].str == "ok", "oblique camera set failed");
}

struct Cell { string name, preset; V3 expected; bool perspective; }
enum Cell[] cells = [
    Cell("front (face-on)", "Front", V3(3.0, 2.0, 0.0), false),
    Cell("top (edge-on)",   "Top",   V3(3.0, 0.0,-2.0), false),
    Cell("left (edge-on)",  "Left",  V3(0.0, 2.0, 3.0), false),
    Cell("perspective (oblique)", "Perspective", V3(0.0, 2.5, 3.75), true),
];

bool close(V3 a, V3 b, double eps = 0.04) {
    return abs(a.x-b.x) < eps && abs(a.y-b.y) < eps && abs(a.z-b.z) < eps;
}

unittest { // (+96,-64) px at 32 px/m, with world XY frozen underneath.
    foreach (tool; ["prim.tube"]) {
        V3[4] actual;
        foreach (i, cell; cells) {
            buildPinnedPrimitive(tool);
            if (cell.perspective) setObliquePerspective();
            else                  setOrtho(cell.preset);
            settle();

            auto c = fetchCamera(BASE);
            int cx = c.vpX + c.width / 2;
            int cy = c.vpY + c.height / 2;
            V3 sizeBefore = sizeTriple(tool);
            drag(cx, cy, cx + 96, cy - 64);
            actual[i] = position(tool);
            V3 sizeAfter = sizeTriple(tool);
            assert(close(sizeAfter, sizeBefore, 1e-5),
                format("%s %s: central handle changed sizes: before %s, after %s",
                       tool, cell.name, sizeBefore.toString(), sizeAfter.toString()));

            cmd("tool.set " ~ tool ~ " off");
            auto model = getJson("/api/model");
            size_t floor = 96;
            assert(model["vertices"].array.length >= floor,
                format("%s %s: population floor %d, got %d vertices",
                       tool, cell.name, floor, model["vertices"].array.length));
        }

        // The face-on control is intentionally above the edge-on assertion.
        assert(close(actual[0], cells[0].expected),
            format("%s %s: expected %s, actual %s", tool, cells[0].name,
                   cells[0].expected.toString(), actual[0].toString()));

        string edgeErrors;
        foreach (i; 1 .. 3) {
            if (!close(actual[i], cells[i].expected))
                edgeErrors ~= format("%s %s: expected %s, actual %s; ", tool,
                                     cells[i].name, cells[i].expected.toString(),
                                     actual[i].toString());
        }
        assert(edgeErrors.length == 0, "edge-on centre drag mismatch: " ~ edgeErrors);

        assert(close(actual[3], cells[3].expected),
            format("%s %s: expected %s, actual %s", tool, cells[3].name,
                   cells[3].expected.toString(), actual[3].toString()));
    }
}
