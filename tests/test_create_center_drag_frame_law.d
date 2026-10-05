// The primitive centre handle writes its world delta straight into Position.
// A unit-frame control precedes the oblique 30/40-degree separating cell.

import create_law_helpers;
import drag_helpers : fetchCamera, fetchHandlePart, playAndWait;
import http_client : getJson, postJson, testBaseUrl;
import core.thread : Thread;
import core.time : dur;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs, round, sqrt;

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

// Construction cells, not a capture (task 9412): under the oblique plane a
// drawn handle tracks the cursor along its own screen line (LAW A, own). The
// Box X arrow moves only local cenX; the cylinder +Y size handle ends where
// the pointer travel along its line puts it. +Y, not +X: world X has no
// normal component under this plane, so a local +X read as world shows the
// same screen line and tracks anyway. Each pins one local<->world
// conversion of the handle axis (`moverDrag`, `handleSizeDrag`).
struct Px { double x, y; }

Px anchorOf(int part) {
    double sx, sy;
    bool found;
    foreach (_; 0 .. 40) {
        fetchHandlePart(part, sx, sy, found);
        if (found) return Px(sx, sy);
        Thread.sleep(dur!"msecs"(25));
    }
    assert(false, format("handle part %d has no screen anchor", part));
}

double primAttr(string tool, string name) {
    auto r = postJson("/api/command", "tool.attr " ~ tool ~ " " ~ name ~ " ?");
    assert(r["status"].str == "ok", "attribute query failed: " ~ r.toString);
    return number(r["value"]);
}

// Drag from `part`'s anchor 40 px along the screen line from the mover centre
// (part 13) through it; returns the travel the line admits (the pixel delta
// projected on the line) and the unit line direction.
double dragAlongLine(int part, out Px u, out int dx, out int dy) {
    Px c = anchorOf(13), a = anchorOf(part);
    immutable double len = sqrt((a.x - c.x) ^^ 2 + (a.y - c.y) ^^ 2);
    assert(len > 8, format("part %d sits on the mover centre (%.2f px)", part, len));
    u = Px((a.x - c.x) / len, (a.y - c.y) / len);
    immutable int x0 = cast(int)round(a.x), y0 = cast(int)round(a.y);
    dx = cast(int)round(40 * u.x);
    dy = cast(int)round(40 * u.y);
    dragPixels(x0, y0, x0 + dx, y0 + dy, 8);
    Thread.sleep(dur!"msecs"(120));
    return dx * u.x + dy * u.y;
}

void assertTracks(string what, Px before, Px after, Px u, double travel) {
    immutable Px want = Px(before.x + travel * u.x, before.y + travel * u.y);
    assert(abs(after.x - want.x) <= 1.5 && abs(after.y - want.y) <= 1.5,
        format("%s: expected the anchor at (%.2f,%.2f) after %.2f px along its "
             ~ "line, actual (%.2f,%.2f)", what, want.x, want.y, travel,
               after.x, after.y));
}

unittest { // oblique_frame: the X arrow and the +Y size handle track their lines
    auto fixture = parseJSON(import("fixtures/create_center_drag_frame_law.json"));
    auto cell = fixture["cells"].array[1];
    assert(cell["name"].str == "oblique_frame", "fixture cell 1 is not oblique_frame");
    immutable V3 euler = vector(cell["plane_euler_deg"]);
    auto camera = fetchCamera(testBaseUrl);
    immutable int cx = camera.vpX + camera.width / 2;
    immutable int cy = camera.vpY + camera.height / 2;
    Px u;
    int dx, dy;

    // The Box mover's X arrow (part 10).
    resetCreateCell(V3(0, 0, 0), true, V3(0, 0, 0), euler);
    dragPixels(cx, cy, cx + 48, cy - 48, 8, 64);
    setPosition(V3(0, 0, 0));
    setCubeSize(V3(0.5, 0.5, 0.5));
    Thread.sleep(dur!"msecs"(120));
    Px centre0 = anchorOf(13);
    double travel = dragAlongLine(10, u, dx, dy);
    V3 p = position();
    assert(abs(p.x) > 0.1 && abs(p.y) < 1e-3 && abs(p.z) < 1e-3,
        format("arrow X drag (%d,%d) px: expected only local cenX to move, "
             ~ "Position %s", dx, dy, p.toString()));
    assertTracks("Box mover centre on the X arrow", centre0, anchorOf(13), u, travel);
    assert(commitAndVertexCount() == 8, "Box arrow cell: expected the 8-vertex cube");

    // The cylinder's +Y size handle (part 2).
    resetCreateCell(V3(0, 0, 0), true, V3(0, 0, 0), euler);
    command("tool.set prim.cylinder");
    dragPixels(cx, cy, cx + 60, cy + 50, 8);
    dragPixels(cx - 15, cy, cx - 15, cy - 80, 8);
    foreach (n; ["cenX", "cenY", "cenZ"]) command("tool.attr prim.cylinder " ~ n ~ " 0");
    foreach (n; ["sizeX", "sizeY", "sizeZ"]) command("tool.attr prim.cylinder " ~ n ~ " 1");
    Thread.sleep(dur!"msecs"(120));
    Px handle0 = anchorOf(2);
    immutable double size0 = primAttr("prim.cylinder", "sizeY");
    travel = dragAlongLine(2, u, dx, dy);
    assert(primAttr("prim.cylinder", "sizeY") > size0 + 0.05,
        format("+Y size drag (%d,%d) px did not grow sizeY from %.4f", dx, dy, size0));
    assertTracks("cylinder +Y size handle", handle0, anchorOf(2), u, travel);
    command("tool.set prim.cylinder off");
}
