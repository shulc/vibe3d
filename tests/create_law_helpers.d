module create_law_helpers;

import drag_helpers : buildDragLog, fetchCamera, playAndWait;
import http_client : getJson, postJson, testBaseUrl;
import http_command_helpers : commandBody;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, round, tan, PI;

struct V3 {
    double x, y, z;

    V3 opBinary(string op : "-")(V3 other) const {
        return V3(x - other.x, y - other.y, z - other.z);
    }

    string toString() const {
        return format("(%+.6f,%+.6f,%+.6f)", x, y, z);
    }
}

double number(JSONValue value) {
    if (value.type == JSONType.INTEGER)
        return cast(double)value.integer;
    if (value.type == JSONType.UINTEGER)
        return cast(double)value.uinteger;
    return value.floating;
}

V3 vector(JSONValue value) {
    auto a = value.array;
    assert(a.length == 3, "expected a three-component fixture vector");
    return V3(number(a[0]), number(a[1]), number(a[2]));
}

bool close(V3 actual, V3 expected, double tolerance) {
    return abs(actual.x - expected.x) <= tolerance
        && abs(actual.y - expected.y) <= tolerance
        && abs(actual.z - expected.z) <= tolerance;
}

void command(string line) {
    auto response = postJson("/api/command", line);
    assert(response["status"].str == "ok"
        || response["status"].str == "success",
        "command failed: " ~ line ~ ": " ~ response.toString);
}

double attribute(string name) {
    auto response = postJson("/api/command",
        "tool.attr prim.cube " ~ name ~ " ?");
    assert(response["status"].str == "ok",
        "attribute query failed for " ~ name ~ ": " ~ response.toString);
    return number(response["value"]);
}

V3 position() {
    return V3(attribute("cenX"), attribute("cenY"), attribute("cenZ"));
}

V3 cubeSize() {
    return V3(attribute("sizeX"), attribute("sizeY"), attribute("sizeZ"));
}

void setPosition(V3 value) {
    command(format("tool.attr prim.cube cenX %.9f", value.x));
    command(format("tool.attr prim.cube cenY %.9f", value.y));
    command(format("tool.attr prim.cube cenZ %.9f", value.z));
}

void setCubeSize(V3 value) {
    command(format("tool.attr prim.cube sizeX %.9f", value.x));
    command(format("tool.attr prim.cube sizeY %.9f", value.y));
    command(format("tool.attr prim.cube sizeZ %.9f", value.z));
}

void resetCreateCell(V3 focus, bool pinned = false,
                     V3 planeOrigin = V3(0, 0, 0),
                     V3 planeEuler = V3(0, 0, 0)) {
    auto response = postJson("/api/command",
        commandBody("scene.reset", `{"empty":true}`));
    assert(response["status"].str == "ok",
        "empty scene reset failed: " ~ response.toString);
    command("history.clear");
    command("workplane.reset");
    command("viewport.view Front");

    auto camera = fetchCamera(testBaseUrl);
    immutable double distance = cast(double)camera.height
        / (64.0 * tan(PI / 8.0));
    response = postJson("/api/camera", format(
        `{"focus":{"x":%.9f,"y":%.9f,"z":%.9f},"distance":%.9f}`,
        focus.x, focus.y, focus.z, distance));
    assert(response["status"].str == "ok",
        "camera setup failed: " ~ response.toString);

    if (pinned) {
        command(format("workplane.edit cenX:%.9f cenY:%.9f cenZ:%.9f "
                     ~ "rotX:%.9f rotY:%.9f rotZ:%.9f",
                       planeOrigin.x, planeOrigin.y, planeOrigin.z,
                       planeEuler.x, planeEuler.y, planeEuler.z));
    }
    command("tool.set prim.cube");
}

void dragPixels(int x0, int y0, int x1, int y1, int steps = 8,
                uint modifiers = 0) {
    auto camera = fetchCamera(testBaseUrl);
    playAndWait(buildDragLog(camera.vpX, camera.vpY,
                             camera.width, camera.height,
                             x0, y0, x1, y1, steps, modifiers),
                testBaseUrl);
}

void dragAtMetres(V3 start, V3 finish, double pixelsPerMetre = 32.0,
                  uint modifiers = 0) {
    auto camera = fetchCamera(testBaseUrl);
    immutable int cx = camera.vpX + camera.width / 2;
    immutable int cy = camera.vpY + camera.height / 2;
    immutable int x0 = cx + cast(int)round(start.x * pixelsPerMetre);
    immutable int y0 = cy - cast(int)round(start.y * pixelsPerMetre);
    immutable int x1 = cx + cast(int)round(finish.x * pixelsPerMetre);
    immutable int y1 = cy - cast(int)round(finish.y * pixelsPerMetre);
    dragPixels(x0, y0, x1, y1, 8, modifiers);
}

size_t commitAndVertexCount() {
    command("tool.set prim.cube off");
    return getJson("/api/model")["vertices"].array.length;
}

V3 modelCenter(out V3 extent) {
    auto vertices = getJson("/api/model")["vertices"].array;
    assert(vertices.length > 0, "modelCenter requires a populated mesh");
    V3 lo = V3(double.max, double.max, double.max);
    V3 hi = V3(-double.max, -double.max, -double.max);
    foreach (vertex; vertices) {
        auto p = vertex.array;
        immutable double x = number(p[0]);
        immutable double y = number(p[1]);
        immutable double z = number(p[2]);
        if (x < lo.x) lo.x = x;
        if (y < lo.y) lo.y = y;
        if (z < lo.z) lo.z = z;
        if (x > hi.x) hi.x = x;
        if (y > hi.y) hi.y = y;
        if (z > hi.z) hi.z = z;
    }
    extent = V3(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z);
    return V3((lo.x + hi.x) * 0.5,
              (lo.y + hi.y) * 0.5,
              (lo.z + hi.z) * 0.5);
}
