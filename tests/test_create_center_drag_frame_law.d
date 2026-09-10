// The primitive centre handle writes its world delta straight into Position.
// A unit-frame control precedes the oblique 30/40-degree separating cell.

import create_law_helpers;
import drag_helpers : fetchCamera, playAndWait;
import http_client : getJson, testBaseUrl;
import core.thread : Thread;
import core.time : dur;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;

void main() {}

struct Result {
    string name;
    V3 delta;
    V3 sizeBefore;
    V3 sizeAfter;
}

void pressCenterHandle(int x, int y) {
    auto camera = fetchCamera(testBaseUrl);
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":10.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        camera.vpX, camera.vpY, camera.width, camera.height, x, y);
    playAndWait(log, testBaseUrl);
    foreach (_; 0 .. 40) {
        auto handles = getJson("/api/tool/handles")["handles"];
        if (handles.type != JSONType.null_
            && cast(int)handles["captured"].integer == 13)
            return;
        Thread.sleep(dur!"msecs"(25));
    }
    assert(false, "the press did not capture primitive centre handle part 13");
}

void releaseCenterDrag(int x0, int y0, int x1, int y1) {
    auto camera = fetchCamera(testBaseUrl);
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":10.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n"
      ~ `{"t":20.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        camera.vpX, camera.vpY, camera.width, camera.height,
        x1, y1, x1 - x0, y1 - y0, x1, y1);
    playAndWait(log, testBaseUrl);
}

Result runCell(JSONValue cell, V3 positionBefore, V3 sizeBefore,
               int dragX, int dragY, size_t vertexFloor) {
    immutable V3 euler = vector(cell["plane_euler_deg"]);
    resetCreateCell(V3(0, 0, 0), true, V3(0, 0, 0), euler);

    // Ctrl-drag enters the completed-cube state in one gesture, making the
    // centre handle live. The captured Position and Size are then installed.
    auto camera = fetchCamera(testBaseUrl);
    immutable int cx = camera.vpX + camera.width / 2;
    immutable int cy = camera.vpY + camera.height / 2;
    dragPixels(cx, cy, cx + 48, cy - 48, 8, 64);
    setPosition(positionBefore);
    // Our size handles have a deliberately generous pick volume. Separate
    // them for the press, prove the centre part was captured, then restore
    // the fixture Size before any drag motion is delivered.
    setCubeSize(V3(2, 2, 2));
    Thread.sleep(dur!"msecs"(120));
    pressCenterHandle(cx, cy);
    setCubeSize(sizeBefore);

    V3 before = position();
    V3 actualSizeBefore = cubeSize();
    releaseCenterDrag(cx, cy, cx + dragX, cy + dragY);
    V3 after = position();
    V3 actualSizeAfter = cubeSize();
    auto vertices = commitAndVertexCount();
    assert(vertices >= vertexFloor,
        format("%s: population floor %d, got %d vertices",
               cell["name"].str, vertexFloor, vertices));

    return Result(cell["name"].str, after - before,
                  actualSizeBefore, actualSizeAfter);
}

unittest {
    auto fixture = parseJSON(import("fixtures/create_center_drag_frame_law.json"));
    immutable double tolerance = number(fixture["tolerance"]);
    immutable V3 positionBefore = vector(fixture["position_before"]);
    immutable V3 sizeBefore = vector(fixture["size_before"]);
    immutable V3 expected = vector(fixture["expected_delta"]);
    immutable int dragX = cast(int)number(fixture["drag_px"][0]);
    immutable int dragY = cast(int)number(fixture["drag_px"][1]);
    immutable size_t vertexFloor = cast(size_t)number(fixture["vertex_floor"]);
    auto cells = fixture["cells"].array;
    assert(cells.length == 2,
        format("frame cell population must be 2, got %d", cells.length));

    auto identity = runCell(cells[0], positionBefore, sizeBefore,
                            dragX, dragY, vertexFloor);
    assert(close(identity.sizeBefore, sizeBefore, 1e-5),
        format("%s: expected fixture Size %s before centre drag, actual %s",
               identity.name, sizeBefore.toString(), identity.sizeBefore.toString()));
    assert(close(identity.sizeAfter, identity.sizeBefore, 1e-5),
        format("%s: centre handle changed Size from %s to %s", identity.name,
               identity.sizeBefore.toString(), identity.sizeAfter.toString()));
    assert(close(identity.delta, expected, tolerance),
        format("%s: expected delta %s, actual %s", identity.name,
               expected.toString(), identity.delta.toString()));

    auto oblique = runCell(cells[1], positionBefore, sizeBefore,
                           dragX, dragY, vertexFloor);
    assert(close(oblique.sizeBefore, sizeBefore, 1e-5),
        format("%s: expected fixture Size %s before centre drag, actual %s",
               oblique.name, sizeBefore.toString(), oblique.sizeBefore.toString()));
    assert(close(oblique.sizeAfter, oblique.sizeBefore, 1e-5),
        format("%s: centre handle changed Size from %s to %s", oblique.name,
               oblique.sizeBefore.toString(), oblique.sizeAfter.toString()));
    assert(close(oblique.delta, expected, tolerance),
        format("%s: expected delta %s, actual %s", oblique.name,
               expected.toString(), oblique.delta.toString()));
}
