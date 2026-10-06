// Event-owned background hits in Single and every Quad cell (task 9523).
// VIEWPORT metadata describes the complete replay owner, before Quad splits it.
module test_constraint_cell_hit;

import drag_helpers : Vec3, Viewport, CameraState, fetchCamera, projectToWindow,
    pixelRay, playAndWait, dot;
import pen_rig_helpers : penCommand, penSceneEmpty, readVerts;
import http_client : getJson, postJson;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : sqrt, abs;

void main() {}

private float num(JSONValue v) {
    return v.type == JSONType.float_ ? cast(float)v.floating : cast(float)v.integer;
}

private Viewport cellViewport(int cell) {
    auto j = getJson(format("/api/camera?viewport=%d", cell));
    Viewport vp;
    foreach (i; 0 .. 16) {
        vp.view[i] = num(j["viewMatrix"].array[i]);
        vp.proj[i] = num(j["projMatrix"].array[i]);
    }
    vp.width = cast(int)j["width"].integer;
    vp.height = cast(int)j["height"].integer;
    vp.x = cast(int)j["vpX"].integer;
    vp.y = cast(int)j["vpY"].integer;
    vp.eye = Vec3(num(j["eye"]["x"]), num(j["eye"]["y"]), num(j["eye"]["z"]));
    return vp;
}

private void event(CameraState owner, string type, int x, int y) {
    playAndWait(format(
        `{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":50,"type":"%s","x":%d,"y":%d,"btn":1,"clicks":1,"state":0,"xrel":0,"yrel":0,"mod":0}` ~ "\n",
        owner.vpX, owner.vpY, owner.width, owner.height, type, x, y));
}

private float distance(Vec3 a, Vec3 b) { auto d = a - b; return sqrt(dot(d, d)); }

unittest {
    scope(exit) penCommand("viewport.layout Single");
    size_t presses, nonactive;
    foreach (cell; -1 .. 4) {
        penCommand("viewport.layout Single");
        penSceneEmpty("Perspective");
        auto owner = fetchCamera();
        penCommand("prim.sphere cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 sides:64 segments:32");
        penCommand("layer.add name:Edit");
        assert(readVerts().length == 0, "rig: the new primary layer must be empty");
        if (cell >= 0) penCommand("viewport.layout Quad");
        auto vp = cellViewport(cell < 0 ? 0 : cell);
        assert(vp.width > 16 && vp.height > 16, "rig: the target cell must be populated");
        float sx, sy;
        assert(projectToWindow(Vec3(0, 0, 0), vp, sx, sy), "rig: sphere centre must project");
        const x = cast(int)sx, y = cast(int)sy;
        assert(x > vp.x && x < vp.x + vp.width && y > vp.y && y < vp.y + vp.height,
            "rig: sphere aim must be inside its cell");
        Vec3 org, dir;
        pixelRay(x + 0.5f, y + 0.5f, vp, org, dir);
        // Independent unit-sphere intersection: the mesh facets lie just inside it.
        const b = dot(org, dir), c = dot(org, org) - 1;
        const discriminant = b * b - c;
        assert(discriminant > 0 && abs(dot(dir, dir) - 1) < 1e-5,
            "rig: the pixel-centre ray must cross the unit sphere");
        const expected = org + dir * (-b - sqrt(discriminant));
        penCommand("tool.set mesh.topoPen on");
        penCommand("tool.attr mesh.topoPen mode point");
        penCommand("tool.pipe.attr constrain enabled true");
        penCommand("tool.pipe.attr constrain geometry point");
        penCommand("tool.pipe.attr constrain handle true");
        penCommand("tool.pipe.attr constrain offset 0");
        penCommand("tool.pipe.attr constrain dblSided true");
        penCommand(`tool.pipe.attr snap types ""`);
        if (cell >= 0) {
            const other = (cell + 1) % 4;
            auto parked = cellViewport(other);
            event(owner, "SDL_MOUSEMOTION", parked.x + 10, parked.y + 10);
            assert(getJson("/api/viewport/display")["activeId"].integer == other,
                "rig: a different Quad cell must own the pointer before the press");
            ++nonactive;
        }
        // The first motion into this cell must publish its own surface hit.
        event(owner, "SDL_MOUSEMOTION", x, y);
        auto state = getJson("/api/tool/state");
        assert(state["hit"].type == JSONType.TRUE,
            format("cell %d: event-owned sphere motion must hit", cell));
        assert(state["layer"].integer == 0 && state["face"].integer >= 0,
            format("cell %d: hit must identify the background sphere", cell));
        const p = state["point"].array;
        auto hit = Vec3(num(p[0]), num(p[1]), num(p[2]));
        assert(distance(hit, expected) < 0.004,
            format("cell %d: stage hit %s must lie on its own pixel ray near %s", cell, hit, expected));
        event(owner, "SDL_MOUSEBUTTONDOWN", x, y);
        state = getJson("/api/tool/state");
        assert(state["placeArmed"].type == JSONType.TRUE,
            format("cell %d: Point press must arm placement", cell));
        event(owner, "SDL_MOUSEBUTTONUP", x, y);
        auto vertices = readVerts();
        assert(vertices.length == 1,
            format("cell %d: sphere press places exactly one point, got %d", cell, vertices.length));
        assert(distance(vertices[0], hit) < 2e-6,
            format("cell %d: model point %s must equal the stage hit %s", cell, vertices[0], hit));
        assert(getJson("/api/tool/state")["placeArmed"].type == JSONType.FALSE,
            format("cell %d: release must finish placement", cell));
        ++presses;
        penCommand("tool.set mesh.topoPen off");
    }
    assert(presses == 5 && nonactive == 4, "population: Single and all four non-active Quad presses must run");
}
