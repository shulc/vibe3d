// A region gesture evaluates every candidate independently (task 5270).
// Geometry and expected counts are copied from the frozen
// `toolcards/lasso_coincident_pixel/fixture_lasso_coincident_pixel.json`.
// The private capture is not read at test time; this remains a standalone
// regression test.  A click is the deliberate opposite and keeps one winner.

module test_region_pick_coincident;

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.json : JSONType;
import std.math : PI, lround, tan;
import std.process : environment;
import std.stdio : writeln;

import drag_helpers : Vec3, playAndWait;

void main() {}

enum string REGION_RIG = `{"vertices":[
    [-1.4,-1.4,0], [1.4,-1.4,0], [1.4,1.4,0], [-1.4,1.4,0],
    [5.6,-1.4,1], [8.4,-1.4,1], [8.4,1.4,1], [5.6,1.4,1],
    [5.6,-1.4,-1], [8.4,-1.4,-1], [8.4,1.4,-1], [5.6,1.4,-1],
    [12.6,0,1], [15.4,0,1], [12.6,0,-1], [15.4,0,-1],
    [19.6,0,-1], [22.4,0,-1], [22.4,0,1], [19.6,0,1]],
  "faces":[[0,1,2,3], [4,5,6,7], [8,9,10,11], [16,17,18,19]]}`;

enum float TARGET_PPU = 24.0f;

void settle() {
    import core.thread : Thread;
    import core.time : msecs;
    Thread.sleep(150.msecs);
}

void cmdOk(string body) {
    auto r = postJson("/api/command", body);
    assert(r["status"].str == "ok" || r["status"].str == "success",
           "command failed: " ~ body ~ " -> " ~ r.toString);
}

void setMode(string mode) {
    cmdOk(commandBody("mesh.select", format(`{"mode":"%s","indices":[]}`, mode)));
    settle();
}

void setStyle(string style) {
    cmdOk(format(`{"id":"viewport.displayStyle","params":"%s"}`, style));
    settle();
}

struct OrthoCamera {
    float focusX;
    float focusY;
    float ppu;
    int vpX;
    int vpY;
    int width;
    int height;
}

OrthoCamera setFrontOrtho(float focusX, float focusY) {
    cmdOk("viewport.view Front");
    auto before = getJson("/api/camera");
    immutable int h = cast(int)before["height"].integer;
    immutable float distance = h / (2.0f * TARGET_PPU * tan(cast(float)(PI / 8.0)));
    auto r = postJson("/api/camera", format(
        `{"distance":%.9g,"focus":{"x":%.9g,"y":%.9g,"z":0}}`,
        distance, focusX, focusY));
    assert(r["status"].str == "ok" || r["status"].str == "success",
           "camera setup failed: " ~ r.toString);
    settle();

    auto j = getJson("/api/camera");
    assert(j["projKind"].str == "Ortho" && j["viewPreset"].str == "Front",
           "fixture requires the Front orthographic view: " ~ j.toString);
    assert(j["eye"]["z"].floating > 0.0,
           "fixture requires an eye on +Z: " ~ j.toString);

    OrthoCamera c;
    c.focusX = cast(float)j["focus"]["x"].floating;
    c.focusY = cast(float)j["focus"]["y"].floating;
    c.width  = cast(int)j["width"].integer;
    c.height = cast(int)j["height"].integer;
    c.vpX    = cast(int)j["vpX"].integer;
    c.vpY    = cast(int)j["vpY"].integer;
    immutable float d = cast(float)j["distance"].floating;
    c.ppu = c.height / (2.0f * d * tan(cast(float)(PI / 8.0)));
    assert(c.ppu > 23.99f && c.ppu < 24.01f,
           format("orthographic scale drifted: expected %.2f px/unit, got %.6f",
                  TARGET_PPU, c.ppu));
    return c;
}

void worldPixel(ref const OrthoCamera c, float x, float y,
                out int px, out int py) {
    px = cast(int)lround(c.vpX + c.width * 0.5f + (x - c.focusX) * c.ppu);
    py = cast(int)lround(c.vpY + c.height * 0.5f - (y - c.focusY) * c.ppu);
}

string rectangleLog(ref const OrthoCamera c,
                    float x0w, float y0w, float x1w, float y1w,
                    ubyte button) {
    int x0, y0, x1, y1;
    worldPixel(c, x0w, y0w, x0, y0);
    worldPixel(c, x1w, y1w, x1, y1);
    assert(x0 >= c.vpX && x1 < c.vpX + c.width
        && y0 >= c.vpY && y1 < c.vpY + c.height,
        format("region rectangle lies outside the viewport: (%d,%d)-(%d,%d), "
             ~ "viewport=(%d,%d %dx%d)",
               x0, y0, x1, y1, c.vpX, c.vpY, c.width, c.height));

    string log = format(
        `{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        c.vpX, c.vpY, c.width, c.height);
    double t = 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, button, x0, y0);
    int px = x0;
    int py = y0;
    immutable uint state = 1u << (button - 1);
    void go(int x, int y) {
        t += 25.0;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":%u,"mod":0}` ~ "\n",
            t, x, y, x - px, y - py, state);
        px = x;
        py = y;
    }
    foreach (i; 1 .. 5) go(x0 + (x1 - x0) * i / 4, y0);
    foreach (i; 1 .. 5) go(x1, y0 + (y1 - y0) * i / 4);
    foreach (i; 1 .. 5) go(x1 - (x1 - x0) * i / 4, y1);
    foreach (i; 1 .. 5) go(x0, y1 - (y1 - y0) * i / 4);
    t += 25.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, button, x0, y0);
    return log;
}

string clickLog(ref const OrthoCamera c, int x, int y) {
    return format(
        `{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":50,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
      ~ `{"t":100,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
      ~ `{"t":150,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        c.vpX, c.vpY, c.width, c.height, x, y, x, y, x, y);
}

size_t selectedCount(string mode) {
    auto s = getJson("/api/selection");
    switch (mode) {
        case "vertices": return s["selectedVertices"].array.length;
        case "edges":    return s["selectedEdges"].array.length;
        case "polygons": return s["selectedFaces"].array.length;
        default: assert(false, "unknown selection mode " ~ mode);
    }
}

void runRegion(ref const OrthoCamera cam, string style, string station,
               float centerX, string mode, size_t expected) {
    setMode(mode);
    playAndWait(rectangleLog(cam, centerX - 3.0f, -3.0f,
                                  centerX + 3.0f,  3.0f, 3));
    settle();
    immutable size_t got = selectedCount(mode);
    writeln("REGION_RESULT ", style, " ", station, " ", mode,
            " got=", got, " expected=", expected);
    assert(got == expected,
        format("region/%s/%s/%s: expected %d selected elements, got %d",
               style, station, mode, expected, got));
}

void runClickRankingCell() {
    cmdOk(commandBody("scene.reset"));
    cmdOk(commandBody("scene.loadMesh",
        `{"vertices":[[0,0,0],[0.125,0,0]],"faces":[]}`));
    auto cam = setFrontOrtho(0.0f, 0.0f);
    setMode("vertices");

    int x0, y0, x1, y1;
    worldPixel(cam, 0.0f,   0.0f, x0, y0);
    worldPixel(cam, 0.125f, 0.0f, x1, y1);
    assert(y0 == y1 && x1 - x0 == 3,
        format("click ranking fixture must put candidates 3 px apart, got "
             ~ "(%d,%d) and (%d,%d)", x0, y0, x1, y1));

    playAndWait(clickLog(cam, x0, y0));
    settle();
    auto selected = getJson("/api/selection")["selectedVertices"].array;
    assert(selected.length == 1 && selected[0].integer == 0,
        format("click/ranking: the exact-pixel candidate 0 must beat candidate "
             ~ "1 at distance 3; selected=%s", selected.to!string));
    writeln("CLICK_RESULT exact=0 farther=1 selected=0");
}

unittest {
    // This cell is intentionally above every region assertion. Reverting the
    // region fix must reach the first differing region row only after proving
    // that click still picks one nearest candidate.
    runClickRankingCell();

    cmdOk(commandBody("scene.reset"));
    cmdOk(commandBody("scene.loadMesh", REGION_RIG));
    auto cam = setFrontOrtho(10.5f, 0.0f);

    auto model = getJson("/api/model");
    immutable size_t nv = model["vertices"].array.length;
    immutable size_t ne = model["edges"].array.length;
    immutable size_t np = model["faces"].array.length;
    assert(nv == 20 && ne == 16 && np == 4,
        format("region population floor: expected 20v/16e/4p before "
             ~ "coincidence checks, got %dv/%de/%dp", nv, ne, np));
    writeln("REGION_POPULATION vertices=", nv, " edges=", ne, " polygons=", np);

    immutable string onlyStation = environment.get("VIBE3D_REGION_STATION", "all");
    immutable string onlyStyle = environment.get("VIBE3D_REGION_STYLE", "all");
    foreach (style; ["shaded", "wireframe"]) {
        if (onlyStyle != "all" && onlyStyle != style) continue;
        setStyle(style);

        // Positive control first: a mutation run that reaches a differing row
        // has already proved the gesture and count channel are alive.
        if (onlyStation == "all" || onlyStation == "ctrl") {
            runRegion(cam, style, "ctrl", 0.0f, "vertices", 4);
            runRegion(cam, style, "ctrl", 0.0f, "edges", 4);
            runRegion(cam, style, "ctrl", 0.0f, "polygons", 1);
        }
        if (onlyStation == "all" || onlyStation == "coinc") {
            runRegion(cam, style, "coinc", 7.0f, "vertices", 8);
            runRegion(cam, style, "coinc", 7.0f, "edges", 8);
            runRegion(cam, style, "coinc", 7.0f, "polygons", 2);
        }
        if (onlyStation == "all" || onlyStation == "coincE")
            runRegion(cam, style, "coincE", 14.0f, "vertices", 4);
        if (onlyStation == "all" || onlyStation == "coincXZ") {
            runRegion(cam, style, "coincXZ", 21.0f, "vertices", 4);
            runRegion(cam, style, "coincXZ", 21.0f, "edges", 4);
        }
    }
}
