// Primitive Position fields are expressed in the active workplane frame.
// In automatic mode that frame is the unit world frame for every camera;
// the camera-facing frame remains a cursor-placement concern only.

import http_client : getJson, postJson, testBaseUrl;
import http_command_helpers : commandBody;
import drag_helpers : buildDragLog, fetchCamera, playAndWait;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs;

void main() {}

alias BASE = testBaseUrl;

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
    assert(r["status"].str == "ok", "query failed: " ~ tool ~ "." ~ attr);
    return num(r["value"]);
}

void drag(int x0, int y0, int x1, int y1, uint mod = 0) {
    auto c = fetchCamera(BASE);
    playAndWait(buildDragLog(c.vpX, c.vpY, c.width, c.height,
                             x0, y0, x1, y1, 8, mod), BASE);
}

struct CameraCell {
    string name;
    double azimuth, elevation, focusX;
}

struct ToolCell {
    string id;
    long vertexFloor;
}

enum CameraCell[] cameras = [
    CameraCell("TOP",     0.30, 1.10, 0.0),
    CameraCell("FRONT",   0.08, 0.08, 0.0),
    CameraCell("LEFT",    1.50, 0.08, 0.0),
    CameraCell("TOP+PAN", 0.30, 1.10, 1.5),
];

enum ToolCell[] tools = [
    ToolCell("prim.cylinder",  48),
    ToolCell("prim.cube",       8),
    ToolCell("prim.cone",      25),
    ToolCell("prim.sphere",   554),
    ToolCell("prim.torus",    288),
    ToolCell("prim.tube",      96),
    ToolCell("prim.capsule",  266),
    ToolCell("prim.ellipsoid",554),
];

void constructPrimitive(string tool) {
    auto c = fetchCamera(BASE);
    int cx = c.vpX + c.width / 2;
    int cy = c.vpY + c.height / 2;
    if (tool == "prim.torus") {
        drag(cx, cy, cx + 100, cy - 70);
    } else if (tool == "prim.tube") {
        drag(cx, cy, cx + 100, cy - 70);
        drag(cx, cy, cx, cy - 80);
    } else {
        drag(cx, cy, cx + 100, cy - 70, 64);
    }
}

unittest { // Four cameras, including the one whose old basis hid the defect.
    enum double marker = 0.777;
    foreach (camera; cameras) {
        foreach (tool; tools) {
            auto reset = postJson("/api/command",
                commandBody("scene.reset", `{"empty":true}`));
            assert(reset["status"].str == "ok", "scene reset failed");
            cmd("history.clear");
            cmd("workplane.reset");
            cmd("viewport.view Perspective");
            auto camSet = postJson("/api/camera", format(
                `{"azimuth":%.6f,"elevation":%.6f,"distance":4.0,` ~
                `"focus":{"x":%.6f,"y":0,"z":0}}`,
                camera.azimuth, camera.elevation, camera.focusX));
            assert(camSet["status"].str == "ok", "camera set failed");

            cmd("tool.set " ~ tool.id);
            constructPrimitive(tool.id);
            cmd(format("tool.attr %s cenX %.3f", tool.id, marker));
            double[3] expected = [qf(tool.id, "cenX"),
                                  qf(tool.id, "cenY"),
                                  qf(tool.id, "cenZ")];
            cmd("tool.set " ~ tool.id ~ " off");

            auto model = getJson("/api/model");
            auto verts = model["vertices"].array;
            assert(verts.length >= tool.vertexFloor,
                format("%s %s: population floor %d, got %d vertices",
                       camera.name, tool.id, tool.vertexFloor, verts.length));

            double[3] lo = [double.max, double.max, double.max];
            double[3] hi = [-double.max, -double.max, -double.max];
            foreach (v; verts) {
                auto p = v.array;
                foreach (axis; 0 .. 3) {
                    double x = num(p[axis]);
                    if (x < lo[axis]) lo[axis] = x;
                    if (x > hi[axis]) hi[axis] = x;
                }
            }
            foreach (axis; 0 .. 3) {
                double actual = (lo[axis] + hi[axis]) * 0.5;
                assert(abs(actual - expected[axis]) < 0.025,
                    format("%s %s Position axis %d: expected %.6f, actual %.6f",
                           camera.name, tool.id, axis, expected[axis], actual));
            }
        }
    }
}
