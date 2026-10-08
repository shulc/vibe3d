// Detached Bridge display uses the ordinary primary-item passes. Production
// pixels compare a standing preview with its released model at one camera.
module test_bridge_model_preview;

import http_client : getJson, postJson, frameFence, quiesce;
import http_command_helpers : commandBody;
import drag_helpers : fetchCamera, buildDragLog, playAndWait;
import viewport_lattice_helpers : fillLattice, erodedFillIndices,
    kFillNX, kFillNY;
import std.exception : enforce, collectException;
import std.format : format;
import std.json : JSONValue, JSONType, parseJSON;
import std.math : abs;
import std.stdio : writeln, writefln;

enum string kTool = "mesh.bridgeTool";
enum string kCaps = `{"vertices":[[-1,-1,-1],[1,-1,-1],[1,1,-1],[-1,1,-1],
    [-1,-1,1],[1,-1,1],[1,1,1],[-1,1,1]],"faces":[[0,1,2,3],[4,5,6,7]]}`;

// Offset, differently sized blocks give the connecting limit surface a
// nonuniform cage; adding intermediate rings changes its rounded silhouette.
enum string kBlocks = `{"vertices":[
    [-1,-0.8,-2],[1,-0.8,-2],[1,0.8,-2],[-1,0.8,-2],
    [-1,-0.8,-0.7],[1,-0.8,-0.7],[1,0.8,-0.7],[-1,0.8,-0.7],
    [-0.45,-0.45,0.8],[1.15,-0.45,0.8],[1.15,0.95,0.8],[-0.45,0.95,0.8],
    [-0.45,-0.45,2.1],[1.15,-0.45,2.1],[1.15,0.95,2.1],[-0.45,0.95,2.1]],
    "faces":[[3,2,1,0],[4,5,6,7],[0,1,5,4],[1,2,6,5],[2,3,7,6],[3,0,4,7],
    [11,10,9,8],[12,13,14,15],[8,9,13,12],[9,10,14,13],[10,11,15,14],[11,8,12,15]]}`;

void cmd(string line) {
    auto r = postJson("/api/command", line);
    enforce(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ line ~ " => " ~ r.toString);
}

void command(string id, string params = "{}") { cmd(commandBody(id, params)); }
void fence() { quiesce(); frameFence(null, 2); }

void cleanup() {
    collectException(cmd("tool.set " ~ kTool ~ " off"));
    foreach (cell; 0 .. 4) {
        collectException(command("viewport.displayStyle", format(`{"value":"shaded","viewport":%d}`, cell)));
        collectException(command("viewport.wireOverlay", format(`{"value":"uniform","viewport":%d}`, cell)));
    }
    collectException(command("viewport.layout", `{"preset":"Single"}`));
}

void style(string value) {
    command("viewport.displayStyle", format(`{"value":"%s"}`, value));
    fence();
}

void wire(string value) {
    command("viewport.wireOverlay", format(`{"value":"%s"}`, value));
    fence();
}

void select(int[] indices) {
    JSONValue p = JSONValue.emptyObject;
    p["mode"] = JSONValue("polygons");
    JSONValue[] a;
    foreach (i; indices) a ~= JSONValue(i);
    p["indices"] = JSONValue(a);
    command("mesh.select", p.toString);
}

void camera(bool aperture = false) {
    auto r = postJson("/api/camera", aperture
        ? `{"azimuth":0.03,"elevation":0.02,"distance":7.5,"focus":{"x":0,"y":0,"z":0}}`
        : `{"azimuth":0.85,"elevation":0.38,"distance":8.5,"focus":{"x":0.1,"y":0.1,"z":0.05}}`);
    enforce(r["status"].str == "ok", "camera setup: " ~ r.toString);
    // Keep geometry hover away from the fixture in both preview and release.
    auto c = fetchCamera();
    playAndWait(format(`{"t":0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
        ~ "\n", c.vpX + 8, c.vpY + 8));
    fence();
}

void setup(bool aperture = false, bool materials = false, bool subpatch = false) {
    cleanup();
    command("scene.reset", `{"empty":true}`);
    command("scene.loadMesh", aperture ? kCaps : kBlocks);
    if (materials) {
        // Use the ordinary native surface path, as viewport-display's material
        // fixture does; loadMesh intentionally has no surface-table parameter.
        import std.file : write, tempDir, exists, remove;
        import std.path : buildPath;
        import std.process : thisProcessID;
        auto mesh = parseBlocks();
        mesh["surfaces"] = parseJSON(`[
            {"name":"Connector","baseColor":[0.9,0.12,0.08],"diffuse":1,"specular":0,"opacity":1},
            {"name":"Blocks","baseColor":[0.08,0.16,0.9],"diffuse":1,"specular":0,"opacity":1}]`);
        mesh["faceMaterial"] = parseJSON(`[1,0,1,1,1,1,0,1,1,1,1,1]`);
        auto layer = JSONValue.emptyObject;
        layer["type"] = JSONValue("mesh"); layer["selected"] = JSONValue(true);
        layer["channels"] = parseJSON(`{"name":"Bridge rig","visible":true}`);
        layer["mesh"] = mesh;
        auto scene = JSONValue.emptyObject;
        scene["formatVersion"] = JSONValue(8); scene["primaryLayer"] = JSONValue(0);
        scene["focusedItem"] = JSONValue(0); scene["layers"] = JSONValue([layer]);
        auto path = buildPath(tempDir(), format("vibe3d-bridge-preview-%d.v3d", thisProcessID()));
        write(path, scene.toString);
        scope(exit) if (exists(path)) remove(path);
        command("file.load", format(`{"path":"%s"}`, path));
        enforce(getJson("/api/model")["surfaces"].array.length == 2,
            "material rig needs both production surface slots");
    }
    if (subpatch) {
        select([]);
        command("mesh.subpatch_toggle");
        fence();
        auto p = getJson("/api/subpatch/preview");
        enforce(p["active"].boolean && !p["pending"].boolean,
            "subpatch rig needs a settled ordinary limit surface");
    }
    select(aperture ? [0, 1] : [1, 6]);
    camera(aperture);
    wire("none");
    cmd("history.clear");
    fence();
}

JSONValue parseBlocks() { return parseJSON(kBlocks); }

string planes() { return getJson("/api/mesh/planes").toString; }
size_t undoCount() { return getJson("/api/history")["undo"].array.length; }

void arm(bool removeCaps = true) {
    cmd("tool.set " ~ kTool ~ " on");
    fence();
    auto s = getJson("/api/tool/state");
    enforce(s["valid"].boolean && !s["engaged"].boolean,
        "standing preview must be valid before any gesture: " ~ s.toString);
    if (!removeCaps) {
        cmd("tool.attr " ~ kTool ~ " remove false");
        fence();
    }
}

void release(string before, size_t historyBefore, size_t expectedFaces) {
    enforce(planes() == before && undoCount() == historyBefore,
        "standing preview changed authoritative source planes or mesh history");
    auto c = fetchCamera();
    immutable x = c.vpX + 8, y = c.vpY + 8;
    playAndWait(buildDragLog(c.vpX, c.vpY, c.width, c.height, x, y, x, y, 0));
    enforce(getJson("/api/tool/state")["engaged"].boolean,
        "zero-motion production click did not engage Bridge");
    enforce(planes() == before && undoCount() == historyBefore,
        "click changed source before explicit release");
    cmd("tool.release");
    fence();
    enforce(planes() != before && undoCount() == historyBefore + 1,
        "release must save one real mesh edit");
    enforce(getJson("/api/model")["faces"].array.length == expectedFaces,
        format("release expected %d bridge-result faces", expectedFaces));
}

long number(JSONValue j) {
    if (j.type == JSONType.uinteger) return cast(long)j.uinteger;
    return j.integer;
}

struct Pixel { int r, g, b; }
struct Image { int w, h; Pixel[] pixels; }

Image probe(string points = "", int cell = 0) {
    auto j = getJson(format("/api/viewport/probe?cell=%d", cell) ~ (points.length ? "&points=" ~ points : ""));
    enforce(j["renders"].boolean, "production cell must render");
    Image im;
    im.w = cast(int)number(j["w"]); im.h = cast(int)number(j["h"]);
    enforce(im.w > 64 && im.h > 64, "implausible production cell dimensions");
    foreach (p; j["points"].array) {
        enforce("error" !in p, "invalid production probe sample: " ~ p.toString);
        im.pixels ~= Pixel(cast(int)number(p["r"]), cast(int)number(p["g"]), cast(int)number(p["b"]));
    }
    return im;
}

bool same(Pixel a, Pixel b) {
    return abs(a.r - b.r) <= 2 && abs(a.g - b.g) <= 2 && abs(a.b - b.b) <= 2;
}

size_t differences(in Image a, in Image b) {
    enforce(a.pixels.length == b.pixels.length && a.pixels.length > 0,
        "pixel comparison needs equal nonempty populations");
    size_t n;
    foreach (i, p; a.pixels) if (!same(p, b.pixels[i])) ++n;
    return n;
}

struct SurfaceImage { Image shaded; bool[] fill; size_t[] interior; }

SurfaceImage surface(string points) {
    style("shaded");
    auto a = probe(points);
    style("wireframe");
    auto b = probe(points);
    style("shaded");
    SurfaceImage s; s.shaded = a;
    enforce(a.pixels.length == kFillNX * kFillNY && b.pixels.length == a.pixels.length,
        "surface comparison requires the complete shared lattice");
    foreach (i, p; a.pixels) s.fill ~= !same(p, b.pixels[i]);
    s.interior = erodedFillIndices(s.fill);
    enforce(s.interior.length >= 80,
        format("only %d eroded fill samples; fixture cannot witness the bridge", s.interior.length));
    return s;
}

void matches(SurfaceImage live, SurfaceImage saved, string cell) {
    enforce(live.shaded.w == saved.shaded.w && live.shaded.h == saved.shaded.h,
        cell ~ ": camera cell changed dimensions across release");
    size_t changed;
    foreach (i; live.interior) if (!same(live.shaded.pixels[i], saved.shaded.pixels[i])) ++changed;
    enforce(changed == 0,
        format("%s: %d/%d preview interior pixels differ from the released model",
            cell, changed, live.interior.length));
    size_t silhouette;
    foreach (i, covered; live.fill) if (covered != saved.fill[i]) ++silhouette;
    enforce(silhouette == 0,
        format("%s: %d fill-occupancy samples move on release", cell, silhouette));
    writefln("  %s: %d matching interior pixels, unchanged fill occupancy", cell, live.interior.length);
}

void capsCell() {
    foreach (removeCaps; [true, false]) {
        setup(true);
        scope(exit) cleanup();
        auto dim = probe();
        auto lattice = fillLattice(dim.w, dim.h);
        string aperture;
        foreach (y; -3 .. 4) foreach (x; -3 .. 4)
            aperture ~= format("%d,%d;", dim.w / 2 + x * 5, dim.h / 2 + y * 5);
        auto original = probe(aperture);
        auto before = planes(); auto history = undoCount();
        arm(removeCaps);
        auto live = probe(aperture);
        auto liveLattice = probe(lattice);
        release(before, history, removeCaps ? 4 : 6);
        auto saved = probe(aperture);
        auto savedLattice = probe(lattice);
        enforce(live.pixels.length == 49 && saved.pixels.length == 49,
            "aperture probe population must be 49");
        enforce(differences(live, saved) == 0,
            "CAP_APERTURE_MATCH: preview retains a cap or changes when released");
        if (removeCaps)
            enforce(differences(original, live) >= 35,
                "CAP_REMOVAL_WITNESS: standing preview must expose the opening before engagement");
        else
            enforce(differences(original, live) == 0,
                "CAP_KEEP_WITNESS: remove=false must keep the visible cap");
        // The entire image also catches an additive source/preview wire pass.
        enforce(differences(liveLattice, savedLattice) == 0,
            "CAP_REPLACEMENT_MATCH: original and replacement geometry were both drawn");
        writefln("  caps remove=%s: 49 aperture pixels match release", removeCaps);
    }
}

void materialCell() {
    setup(false, true);
    scope(exit) cleanup();
    auto dim = probe(); auto pts = fillLattice(dim.w, dim.h);
    auto original = probe(pts);
    auto before = planes(); auto history = undoCount();
    arm();
    auto live = surface(pts);
    size_t red, blue, bridge;
    foreach (i; live.interior) {
        auto p = live.shaded.pixels[i];
        if (p.r > p.b + 20) ++red;
        if (p.b > p.r + 20) ++blue;
        if (!same(p, original.pixels[i])) ++bridge;
    }
    enforce(red >= 5 && blue >= 5, format("MATERIAL_SLOTS_WITNESS: red=%d blue=%d", red, blue));
    enforce(bridge >= 20, "BRIDGE_INTERIOR_WITNESS: preview added no visible connector");
    wire("uniform"); auto liveWire = probe(pts);
    wire("none"); auto liveNone = probe(pts);
    enforce(differences(liveWire, liveNone) >= 5,
        "WIRE_AXIS_WITNESS: fixture must expose ordinary overlay edges");
    release(before, history, 14);
    auto saved = surface(pts);
    matches(live, saved, "MATERIAL_WIRE_OFF_MATCH");
    auto savedNone = probe(pts);
    enforce(differences(liveNone, savedNone) == 0,
        "WIRE_OFF_MATCH: standing preview forces wire absent from released model");
    wire("uniform"); auto savedWire = probe(pts);
    enforce(differences(liveWire, savedWire) == 0,
        "WIRE_ON_MATCH: standing preview bypasses ordinary overlay policy");
}

void transformCell() {
    setup();
    scope(exit) cleanup();
    auto dim = probe(); auto pts = fillLattice(dim.w, dim.h);
    auto before = planes(); auto history = undoCount();
    arm();
    auto identity = surface(pts);
    cmd("layer.attr 0 pos.x 0.75");
    cmd("layer.attr 0 pos.y 0.3");
    cmd("layer.attr 0 rot.y 31");
    fence();
    // Layer channels are persistent, and retain the same live tool. Record
    // their history separately from the Bridge commit being checked below.
    history = undoCount();
    enforce(planes() == before, "layer transform must leave mesh planes unchanged");
    auto transformed = surface(pts);
    size_t moved;
    foreach (i, f; identity.fill) if (f != transformed.fill[i]) ++moved;
    enforce(moved >= 30,
        format("TRANSFORM_WITNESS: only %d occupancy samples differ from identity", moved));
    release(before, history, 14);
    matches(transformed, surface(pts), "TRANSFORM_MATCH");
}

void subpatchCell() {
    setup();
    scope(exit) cleanup();
    auto dim = probe(); auto pts = fillLattice(dim.w, dim.h);
    auto before = planes(); auto history = undoCount();
    arm();
    cmd("tool.attr " ~ kTool ~ " twist 1");
    cmd("tool.attr " ~ kTool ~ " segments 3"); fence();
    release(before, history, 22);
    auto cage = surface(pts);

    foreach (changeSegments; [false, true]) {
        setup(false, false, true);
        before = planes(); history = undoCount();
        arm();
        // With one span there is no interior ring to twist. Three spans add
        // twisted rings, so this edit cannot be visually equivalent geometry.
        cmd("tool.attr " ~ kTool ~ " twist 1"); fence();
        auto first = surface(pts);
        if (changeSegments) {
            auto key = getJson("/api/viewport/display")["cells"].array[0]["toolPreviewKey"];
            cmd("tool.attr " ~ kTool ~ " segments 3"); fence();
            enforce(getJson("/api/viewport/display")["cells"].array[0]["toolPreviewKey"] != key,
                "SEGMENTS_UPLOAD_WITNESS: parameter edit must upload another preview");
        }
        auto live = changeSegments ? surface(pts) : first;
        if (changeSegments) {
            auto changed = differences(first.shaded, live.shaded);
            auto state = getJson("/api/tool/state");
            enforce(changed >= 20,
                format("SEGMENTS_DISPLAY_WITNESS: %d changed pixels after segments=3; effectiveSegments=%s; source faces=%d",
                    changed, state["effectiveSegments"].toString,
                    getJson("/api/model")["faces"].array.length));
            size_t rounded;
            foreach (i, f; cage.fill) if (f != live.fill[i]) ++rounded;
            enforce(rounded >= 20,
                format("SUBPATCH_SILHOUETTE_WITNESS: only %d occupancy samples differ from cage", rounded));
        }
        release(before, history, changeSegments ? 22 : 14);
        matches(live, surface(pts), changeSegments ? "SUBPATCH_SEGMENTS_MATCH" : "SUBPATCH_MATCH");
    }
}

void multiCell() {
    setup(false, false, true);
    scope(exit) cleanup();
    command("viewport.layout", `{"preset":"SplitH"}`);
    fence();
    foreach (cell; 0 .. 2) {
        auto r = postJson(format("/api/camera?viewport=%d", cell),
            `{"azimuth":0.85,"elevation":0.38,"distance":8.5,"focus":{"x":0.1,"y":0.1,"z":0.05}}`);
        enforce(r["status"].str == "ok", "two-cell camera setup");
        command("viewport.displayStyle", format(`{"value":"%s","viewport":%d}`,
            cell == 0 ? "shaded" : "wireframe", cell));
        command("viewport.wireOverlay", format(`{"value":"%s","viewport":%d}`,
            cell == 0 ? "none" : "uniform", cell));
    }
    fence();
    auto cells = getJson("/api/viewport/display")["cells"].array;
    enforce(cells.length == 2 && cells[0]["plan"]["active"]["drawFaces"].boolean
        && !cells[1]["plan"]["active"]["drawFaces"].boolean,
        "TWO_CELL_PLAN_WITNESS: filled and lines-only cells must coexist");
    string[2] pts;
    Image[2] original, live;
    foreach (cell; 0 .. 2) {
        auto dim = probe("", cell);
        foreach (y; 0 .. 24) foreach (x; 0 .. 32)
            pts[cell] ~= format("%d,%d;", dim.w / 10 + x * dim.w * 8 / 310,
                dim.h / 10 + y * dim.h * 8 / 230);
        original[cell] = probe(pts[cell], cell);
    }
    auto before = planes(); auto history = undoCount();
    arm();
    foreach (cell; 0 .. 2) {
        live[cell] = probe(pts[cell], cell);
        enforce(live[cell].pixels.length == 768,
            "two-cell population must be 768 pixels per cell");
        enforce(differences(original[cell], live[cell]) >= 5,
            format("TWO_CELL_PREVIEW_WITNESS: cell %d did not display detached geometry", cell));
    }
    release(before, history, 14);
    foreach (cell; 0 .. 2)
        enforce(differences(live[cell], probe(pts[cell], cell)) == 0,
            format("TWO_CELL_MATCH: cell %d preview differs from release under its own plan", cell));
}

int main() {
    import liveness_gate : scenario;
    import std.process : environment;
    auto filter = environment.get("VIBE3D_CELL", "");
    int passed, failed;
    void run(void function() fn, string id, string name) {
        if (filter.length && filter != id) return;
        scenario(name);
        try { fn(); ++passed; writeln("  PASS: ", name); }
        catch (Exception e) { ++failed; writeln("  FAIL: ", name, " — ", e.msg); }
    }
    run(&capsCell, "caps", "removed and retained caps replace primary display");
    run(&materialCell, "material", "surface slots and wire overlay reach standing preview");
    run(&transformCell, "transform", "primary layer transform reaches standing preview");
    run(&subpatchCell, "subpatch", "detached limit surface refreshes after segments edit");
    run(&multiCell, "multi", "two live cells apply independent preview plans");
    cleanup();
    writefln("%d passed, %d failed", passed, failed);
    return failed ? 1 : 0;
}
