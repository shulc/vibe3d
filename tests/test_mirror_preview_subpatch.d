// Task 7115 (S3-R, item 5) — the Mirror tool is a live edit of the DOCUMENT
// mesh from the first viewport press, drawn by the ordinary path, with a
// WORLD-space plane; dropping the tool commits it.
//
// Law (frozen in tests/fixtures/editor_display_laws_w17.json,
// `mirror_preview` / `mirror_item_space`): arming the tool and typing the
// plane evaluates nothing; the first viewport press makes the copy a real mesh
// edit (12 polygons while live), drawn exactly as the committed result; the
// panel's apply is refused while the edit is live; the drop commits; the plane
// centre and normal are WORLD-space, so under an item transform the copy is
// the reflection of the WORLD positions (rival `plane_in_item_local` predicts
// a copy centred at (4.598, 0, -1.5)).
//
// Blocks, in the order the law needs them: A (time: nothing before the press),
// B (press = live edit; refusal; drop; one undo step), C (item space), D (the
// first Ctrl+Z drops the live copy and keeps the tool); task 7116 adds E (a
// press on a handle also starts the edit), F (a tool switch commits it), G
// (a switch from an untouched tool records nothing); the review added H (the
// base is taken at the first press) and I (the weld distance is a world length).
// Each block opens with its rig floor, so a red below it cannot be a rig that
// never happened.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import drag_helpers : playAndWait;

import core.thread : Thread;
import core.time : msecs;
import std.algorithm : max;
import std.conv : to;
import std.file : readText;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs, tan, PI, round;
import std.stdio : writefln;

void main() {}

enum string TOOL = "mesh.mirrorTool";

JSONValue fixture() {
    return parseJSON(readText("tests/fixtures/editor_display_laws_w17.json"));
}

void cmd(string script) {
    auto r = postJson("/api/command", script);
    assert(r["status"].str == "ok",
           "/api/command failed for " ~ script ~ ": " ~ r.toString);
}

JSONValue cmdRaw(string script) { return postJson("/api/command", script); }

void cmdId(string id) { cmd(`{"id":"` ~ id ~ `"}`); }

void attrCenter(double x, double y, double z) {
    cmd(format(`{"id":"tool.attr","params":{"_positional":["%s","center",[%.9g,%.9g,%.9g]]}}`,
               TOOL, x, y, z));
}

double[3] readCenter() {
    auto r = cmdRaw("tool.attr " ~ TOOL ~ " center ?");
    assert(r["status"].str == "ok", "7115: centre query failed: " ~ r.toString);
    auto v = r["value"].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

void waitPreviewSettled() {
    foreach (_; 0 .. 1500) {
        auto p = getJson("/api/subpatch/preview");
        if (p["active"].type == JSONType.true_
            && p["pending"].type != JSONType.true_) {
            Thread.sleep(80.msecs);
            return;
        }
        Thread.sleep(20.msecs);
    }
    assert(false, "7115: subpatch preview did not settle");
}

void settle() {
    Thread.sleep(250.msecs);
    waitPreviewSettled();
}

size_t faceCount() { return getJson("/api/model")["faces"].array.length; }
size_t vertexCount() { return getJson("/api/model")["vertices"].array.length; }

double[3][] modelVerts() {
    double[3][] r;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        r ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return r;
}

/// Edit records on the undo stack; tool lifecycle rows (flag bit 10) share it.
string[] editLabels() {
    string[] edits;
    foreach (e; getJson("/api/history")["undo"].array)
        if ((e["flags"].integer & (1L << 10)) == 0) edits ~= e["label"].str;
    return edits;
}

string activeTool() {
    return getJson("/api/buttons/availability")["activeToolId"].str;
}

// ---- orthographic camera + projection --------------------------------------

struct Cam {
    double[3] focus, right, up;
    double distance;
    int width, height, vpX, vpY;
}

/// A principal orthographic view through `focus` at `distance`.
Cam orthoCamera(string preset, double[3] focus, double distance) {
    postJson("/api/camera", format(`{"focus":{"x":%.6f,"y":%.6f,"z":%.6f},"distance":%.6f}`,
                                   focus[0], focus[1], focus[2], distance));
    cmd("viewport.view " ~ preset);
    Thread.sleep(150.msecs);
    auto c = getJson("/api/camera");
    assert(c["projKind"].str != "Perspective" && c["viewPreset"].str == preset,
           "7115 rig: the camera is not the " ~ preset ~ " orthographic view");
    Cam r;
    foreach (i, k; ["x", "y", "z"]) r.focus[i] = c["focus"][k].floating;
    r.distance = c["distance"].floating;
    r.width = cast(int)c["width"].integer;
    r.height = cast(int)c["height"].integer;
    r.vpX = cast(int)c["vpX"].integer;
    r.vpY = cast(int)c["vpY"].integer;
    if (preset == "Front") { r.right = [1, 0, 0]; r.up = [0, 1, 0]; }
    else if (preset == "Top") { r.right = [1, 0, 0]; r.up = [0, 0, -1]; }
    else assert(false, "7115 rig: unsupported preset " ~ preset);
    return r;
}

/// World point -> cell pixel (top-left origin, cell-relative) and window pixel.
void pixelOf(const ref Cam c, double[3] p, out int cellX, out int cellY) {
    immutable double halfH = c.distance * tan(PI / 8.0);
    immutable double aspect = cast(double)c.width / c.height;
    double[3] d = [p[0] - c.focus[0], p[1] - c.focus[1], p[2] - c.focus[2]];
    double ndcX = (d[0]*c.right[0] + d[1]*c.right[1] + d[2]*c.right[2]) / (halfH * aspect);
    double ndcY = (d[0]*c.up[0] + d[1]*c.up[1] + d[2]*c.up[2]) / halfH;
    cellX = cast(int)round((ndcX * 0.5 + 0.5) * c.width);
    cellY = cast(int)round((1.0 - (ndcY * 0.5 + 0.5)) * c.height);
}

struct Rgb { long r, g, b; }

Rgb[] probe(const ref Cam c, double[3][] pts) {
    string q;
    foreach (p; pts) {
        int x, y;
        pixelOf(c, p, x, y);
        assert(x >= 0 && y >= 0 && x < c.width && y < c.height,
               format("7115 rig: probe point %s is outside the cell", p));
        if (q.length) q ~= ";";
        q ~= format("%d,%d", x, y);
    }
    Rgb[] out_;
    foreach (p; getJson("/api/viewport/probe?cell=0&points=" ~ q)["points"].array)
        out_ ~= Rgb(p["r"].integer, p["g"].integer, p["b"].integer);
    assert(out_.length == pts.length, "7115: probe population changed");
    return out_;
}

string vpLine(const ref Cam c) {
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        c.vpX, c.vpY, c.width, c.height);
}

/// A left press + release at the WORLD point `p` (no motion in between).
void pressAt(const ref Cam c, double[3] p) {
    int x, y;
    pixelOf(c, p, x, y);
    x += c.vpX; y += c.vpY;
    playAndWait(vpLine(c) ~ format(
        `{"t":30.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
        `{"t":60.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n" ~
        `{"t":90.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y, x, y, x, y));
    settle();
}

void ctrlZ(const ref Cam c) {
    playAndWait(vpLine(c) ~
        `{"t":30.000,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n" ~
        `{"t":60.000,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n");
    settle();
}

/// Subpatch cube, polygon mode, empty selection, history cleared.
void subpatchCube() {
    cmd("tool.set " ~ TOOL ~ " off");
    cmd(commandBody("scene.reset"));
    cmd("tool.pipe.attr snap enabled false");
    cmd("tool.pipe.attr symmetry enabled false");
    cmd("select.typeFrom polygon");
    cmdId("mesh.subpatch_toggle");
    waitPreviewSettled();
    cmd(commandBody("mesh.select", `{"mode":"polygons","indices":[]}`));
    cmdId("history.clear");
    assert(faceCount() == 6, "7115 rig: the cube is not 6 polygons");
}

/// Arm the tool with the plane centre at the origin, so a press at x = 1.5
/// misses both handles (the centre box sits at the origin, the rotate box one
/// arm along +X from it).
void armAtOrigin() {
    cmd("tool.set " ~ TOOL);
    attrCenter(0, 0, 0);
    cmd("tool.attr " ~ TOOL ~ " axis X");
    settle();
}

// ---- A: nothing is evaluated before the first viewport press ---------------
unittest {
    auto fx = fixture()["mirror_preview"];
    subpatchCube();
    auto c = orthoCamera("Front", [1.5, 0, 0], 6.0);
    // The copy region, off the plane's dashed normal line (y = 0) and inside
    // the smoothed copy (which spans |y| < 0.4 around x = 3).
    double[3][] copyPts = [[3.0, 0.25, 0], [3.0, -0.25, 0], [3.15, 0.2, 0]];
    auto empty = probe(c, copyPts);
    auto cube = probe(c, [[0.0, 0.25, 0.0]]);
    auto bg = probe(c, [[0.0, 1.5, 0.0]]);
    assert(cube[0] != bg[0], "7115 A rig: original cube not drawn");

    cmd("tool.set " ~ TOOL);
    attrCenter(1.5, 0, 0);
    cmd("tool.attr " ~ TOOL ~ " axis X");
    settle();
    assert(activeTool() == TOOL, "7115 A rig: the mirror tool is not armed");

    immutable size_t n = faceCount();
    assert(n == fx["before_first_viewport_press"]["polygons"].integer,
        format("7115 mirror evaluated before the first viewport press: %d polygons", n));
    auto armed = probe(c, copyPts);
    writefln("[7115 A] copy region before arming %s, armed %s", empty, armed);
    assert(armed == empty,
        format("7115 mirror copy drawn before the first viewport press: %s, was %s",
               armed, empty));
    cmd("tool.set " ~ TOOL ~ " off");
    settle();
    // Task 7116: an untouched drop commits nothing.
    assert(faceCount() == 6 && editLabels().length == 0,
        format("7116 untouched mirror drop recorded an edit: %d polygons, edits %s",
               faceCount(), editLabels()));
}

// ---- B: the press is a live edit; apply refused; the drop commits ----------
unittest {
    auto fx = fixture()["mirror_preview"];
    subpatchCube();
    auto c = orthoCamera("Front", [1.5, 0, 0], 6.0);
    armAtOrigin();
    pressAt(c, [1.5, 0, 0]);
    auto centre = readCenter();
    writefln("[7115 B] centre after the press = %s", centre);
    assert(abs(centre[0] - 1.5) < 0.02 && abs(centre[1]) < 0.02,
        format("7115 B rig: the press did not reach the tool (centre %s)", centre));
    attrCenter(1.5, 0, 0);
    settle();

    immutable size_t live = faceCount();
    assert(live == fx["live_before_commit"]["polygons"].integer,
        format("7115 mirror press did not apply a live mesh edit: %d polygons", live));
    assert(activeTool() == TOOL, "7115 B: the tool dropped at the press");
    double[3][] copyPts = [[3.0, 0.25, 0], [3.0, -0.25, 0], [3.15, 0.2, 0]];
    auto liveLook = probe(c, copyPts);

    auto ap = cmdRaw(`{"id":"tool.doApply"}`);
    writefln("[7115 B] tool.doApply while live -> %s", ap.toString);
    assert(ap["status"].str == "error" && faceCount() == live,
        format("7115 tool.doApply accepted while the mirror edit is live: %s, %d polygons",
               ap.toString, faceCount()));

    cmd("tool.set " ~ TOOL ~ " off");
    settle();
    auto counts = fx["after_commit"]["counts"].array;
    assert(faceCount() == counts[1].integer && vertexCount() == counts[0].integer,
        format("7115 mirror drop changed the live result: %d polygons, %d vertices",
               faceCount(), vertexCount()));
    auto committed = probe(c, copyPts);
    assert(committed == liveLook,
        format("7115 mirror live look differs from committed look: %s vs %s",
               liveLook, committed));
    cmdId("history.undo");
    settle();
    assert(faceCount() == 6,
        format("7115 mirror commit is not one undo step: %d polygons after one undo",
               faceCount()));
}

// ---- C: the plane is WORLD-space under an item transform (gap 190) ---------
unittest {
    auto fx = fixture()["mirror_item_space"];
    subpatchCube();
    cmd("layer.attr 0 pos.x 2");
    cmd("layer.attr 0 rot.y 30");
    settle();

    // Floor: the item matrix is the captured one (catches a rotation sign that
    // would otherwise read as a false mirror below).
    double[16] m;
    {
        auto layers = getJson("/api/layers");
        auto arr = layers.type == JSONType.array ? layers.array : layers["layers"].array;
        auto mj = arr[0]["xform"]["matrix"].array;
        assert(mj.length == 16, "7115 C rig: the layer matrix is not 16 values");
        size_t k;
        foreach (row; fx["rig"]["item_transform"]["world_matrix_rows"].array)
            foreach (v; row.array) {
                m[k] = mj[k].floating;
                assert(abs(m[k] - v.floating) < 1e-4,
                    format("7115 C rig: item matrix differs from the captured one at %d: "
                         ~ "%s vs %s", k, m[k], v.floating));
                ++k;
            }
    }
    double[3] world(double[3] p) {
        return [m[0]*p[0] + m[4]*p[1] + m[8]*p[2] + m[12],
                m[1]*p[0] + m[5]*p[1] + m[9]*p[2] + m[13],
                m[2]*p[0] + m[6]*p[1] + m[10]*p[2] + m[14]];
    }

    auto c = orthoCamera("Top", [1.5, 0, 0], 6.0);
    armAtOrigin();
    pressAt(c, [1.5, 0, 0]);
    auto centre = readCenter();
    assert(abs(centre[0] - 1.5) < 0.02,
        format("7115 C rig: the press did not reach the tool (centre %s)", centre));
    attrCenter(1.5, 0, 0);
    settle();
    cmd("tool.set " ~ TOOL ~ " off");
    settle();

    auto v = modelVerts();
    assert(v.length == 16, format("7115 C: the drop left %d vertices, expected 16", v.length));
    double[3] mean = [0, 0, 0];
    foreach (i; 8 .. 16) {
        auto w = world(v[i]);
        foreach (k; 0 .. 3) mean[k] += w[k] / 8.0;
    }
    auto want = fx["after_commit"]["copy_world_centre"].array;
    writefln("[7115 C] copy world centre = %s", mean);
    assert(abs(mean[0] - want[0].floating) < 1e-3 && abs(mean[1] - want[1].floating) < 1e-3
            && abs(mean[2] - want[2].floating) < 1e-3,
        format("7115 mirror copy world centre %s, expected (1,0,0)", mean));
    foreach (i; 8 .. 16) {
        auto w = world(v[i]);
        double best = double.infinity;
        foreach (j; 0 .. 8) {
            auto o = world(v[j]);
            double[3] refl = [2 * 1.5 - o[0], o[1], o[2]];
            best = best < max(abs(refl[0]-w[0]), max(abs(refl[1]-w[1]), abs(refl[2]-w[2])))
                 ? best : max(abs(refl[0]-w[0]), max(abs(refl[1]-w[1]), abs(refl[2]-w[2])));
        }
        assert(best < 1e-4,
            format("7115 mirror copy vertex %d is not the world reflection of an original "
                 ~ "(off by %g)", i, best));
    }
    cmd("viewport.view Perspective");
}

// ---- D: the first Ctrl+Z drops the live copy and keeps the tool ------------
unittest {
    subpatchCube();
    auto c = orthoCamera("Front", [1.5, 0, 0], 6.0);
    double[3][] copyPts = [[3.0, 0.25, 0], [3.0, -0.25, 0], [3.15, 0.2, 0]];
    auto empty = probe(c, copyPts);
    armAtOrigin();
    pressAt(c, [1.5, 0, 0]);
    assert(probe(c, copyPts) != empty, "7115 D rig: the press drew no copy");
    ctrlZ(c);
    assert(faceCount() == 6,
        format("7115 ctrl+z left the live mirror copy: %d polygons", faceCount()));
    assert(activeTool() == TOOL,
        "7115 ctrl+z dropped the mirror tool: active tool '" ~ activeTool() ~ "'");
    // Task 7116: the restored base is also what is DRAWN.
    auto after = probe(c, copyPts);
    assert(after == empty,
        format("7116 ctrl+z left the mirror copy drawn: %s, was %s", after, empty));
    // A press at the same spot (now ON the centre handle, which the first press
    // placed there) starts a FRESH live edit with the same parameters.
    pressAt(c, [1.5, 0, 0]);
    assert(faceCount() == 12,
        format("7116 re-press after ctrl+z did not start a fresh live edit: "
             ~ "%d polygons", faceCount()));
    cmd("tool.set " ~ TOOL ~ " off");
    cmd("viewport.view Perspective");
}

// ---- E (task 7116): a press ON a handle is also the first press ------------
unittest {
    subpatchCube();
    auto c = orthoCamera("Front", [1.5, 0, 0], 6.0);
    cmd("tool.set " ~ TOOL);
    attrCenter(1.5, 0, 0);
    cmd("tool.attr " ~ TOOL ~ " axis X");
    settle();
    assert(faceCount() == 6, "7116 E rig: the tool evaluated before the press");
    // The centre box sits at the plane centre; a press and release there
    // with no motion must still start the live edit.
    pressAt(c, [1.5, 0, 0]);
    auto centre = readCenter();
    assert(abs(centre[0] - 1.5) < 1e-6,
        format("7116 E rig: the handle press moved the centre to %s — it missed "
             ~ "the handle", centre));
    assert(faceCount() == 12,
        format("7116 handle press did not start the live mirror edit: %d polygons",
               faceCount()));
    cmd("tool.set " ~ TOOL ~ " off");
    cmd("viewport.view Perspective");
}

// ---- F (task 7116): switching to another tool commits the live copy --------
// The tool-to-tool switch goes through the prepared deactivation door, not
// `deactivate()`, so it is its own cell.
unittest {
    subpatchCube();
    auto c = orthoCamera("Front", [1.5, 0, 0], 6.0);
    armAtOrigin();
    pressAt(c, [1.5, 0, 0]);
    assert(faceCount() == 12, "7116 F rig: the press did not start the live edit");
    cmd("tool.set move");
    settle();
    assert(activeTool() == "move", "7116 F rig: the switch did not arm move");
    assert(faceCount() == 12 && vertexCount() == 16,
        format("7116 tool switch changed the live mirror result: %d polygons, "
             ~ "%d vertices", faceCount(), vertexCount()));
    cmd("tool.set move off");
    auto edits = editLabels();
    assert(edits == ["Mirror"],
        format("7116 tool switch did not commit the mirror as one edit record: %s",
               edits));
    cmd("viewport.view Perspective");
}

// ---- G (task 7116): switching away from an UNTOUCHED mirror records nothing -
unittest {
    subpatchCube();
    orthoCamera("Front", [1.5, 0, 0], 6.0);
    armAtOrigin();
    cmd("tool.set move");
    settle();
    assert(activeTool() == "move", "7116 G rig: the switch did not arm move");
    cmd("tool.set move off");
    assert(faceCount() == 6 && editLabels().length == 0,
        format("7116 switch from an untouched mirror recorded an edit: %d polygons, "
             ~ "edits %s", faceCount(), editLabels()));
    cmd("viewport.view Perspective");
}

// ---- H (task 7116 review): the base is taken at the FIRST PRESS, not at arm -
// A `tool.doApply` between arm and the first press is part of the base the
// live edit starts from: the press mirrors the applied mesh's SELECTED copies
// (12 + 6 = 18; a base taken at arm gives 12), and one undo removes only the
// live edit (12), leaving the Apply record (a stale base leaves 6). The live
// plane is x = 4, clear of both cubes.
unittest {
    subpatchCube();
    auto c = orthoCamera("Front", [1.5, 0, 0], 6.0);
    armAtOrigin();
    cmd("tool.attr " ~ TOOL ~ " mergeVerts false");
    attrCenter(1.5, 0, 0);
    cmd(`{"id":"tool.doApply"}`);
    settle();
    assert(faceCount() == 12, format("7116 H rig: doApply left %d polygons", faceCount()));
    // The apply selects its six copies (faces 6..11), so the face mask taken
    // at the press is those six — a mask taken at ARM would be the 6-face
    // cube's, whose length no longer matches and mirrors nothing.
    auto sel = getJson("/api/selection")["selectedFaces"].array;
    assert(sel.length == 6 && sel[0].integer == 6,
        format("7116 H rig: the apply did not select its copies: %s", sel));
    // Off both handles (centre box at x = 1.5 now), still world x > 1.5.
    pressAt(c, [2.0, -1.0, 0]);
    attrCenter(4, 0, 0);
    settle();
    assert(faceCount() == 18,
        format("7116 press after doApply mirrored a stale base: %d polygons, "
             ~ "expected 18", faceCount()));
    cmd("tool.set " ~ TOOL ~ " off");
    settle();
    cmdId("history.undo");
    settle();
    assert(faceCount() == 12,
        format("7116 one undo after doApply + live mirror left %d polygons, "
             ~ "expected 12 (the applied copy survives)", faceCount()));
    cmd("viewport.view Perspective");
}

// ---- I (task 7116 review): the weld distance is a WORLD length -------------
// Item scale 2: the cube spans world x in [-1, 1]. A plane at world x = 1.05
// puts the copy's near face 0.1 world units from the original's. A weld of
// 0.08 world units must NOT merge them; carried unscaled into local space
// (where the gap is 0.05) it would.
unittest {
    subpatchCube();
    foreach (a; ["x", "y", "z"]) cmd("layer.attr 0 scl." ~ a ~ " 2");
    settle();
    cmd("tool.set " ~ TOOL);
    cmd("tool.attr " ~ TOOL ~ " axis X");
    cmd("tool.attr " ~ TOOL ~ " mergeVerts true");
    cmd("tool.attr " ~ TOOL ~ " distance 0.08");
    attrCenter(1.05, 0, 0);
    cmd(`{"id":"tool.doApply"}`);
    settle();
    assert(faceCount() == 12, format("7116 I rig: doApply left %d polygons", faceCount()));
    assert(vertexCount() == 16,
        format("7116 weld distance applied in local units: %d vertices, expected "
             ~ "16 (a 0.1 world gap is wider than a 0.08 world weld)", vertexCount()));
    cmd("tool.set " ~ TOOL ~ " off");
}
