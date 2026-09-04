module test_create_click_workplane;


import http_command_helpers : commandBody;
// Where an interactive create-click actually puts geometry, per view preset
// (task 0661).
//
// THE STAND CONTAINS A PRESET THAT WAS BROKEN AND ONE THAT WAS NOT, and that
// pairing is the whole design of this file. The defect lived only in the
// ORTHOGRAPHIC cursor ray: the create tools built their ray from the camera
// eye plus `screenRay`, which is the perspective law — one apex with the
// direction fanning out from it. Under an orthographic projection the rays are
// parallel and each starts on the image plane, so the perspective pencil only
// reaches the construction plane after travelling the camera DISTANCE and the
// click's in-plane offset is scaled by it. Measured before the fix, on a
// distance-3 camera: a click aimed at 0.4 units right of the focus created
// geometry at 1.206.
//
// Two things that would make this file green against the live defect, both
// avoided on purpose:
//
//  * TESTING ONLY THE PERSPECTIVE VIEW. It was never broken, so a suite built
//    on it alone cannot tell "fixed" from "untouched". Perspective is here as
//    the CONTROL — it must stay exactly as accurate as it always was.
//  * ASSERTING THAT A PRIMITIVE EXISTS. "Some geometry appeared" passes under
//    every value of the bug. Every assertion below is on the created
//    primitive's world COORDINATES against the point the click was aimed at.
//
// A note on the ortho presets, because a plausible-sounding prediction about
// them is wrong: it is NOT the case that the four horizontal presets fail and
// Top/Bottom work. The failing quantity is the camera distance, which is the
// same in all six, so all six were misplaced by the same factor — Top
// included. That is asserted here for Top explicitly.
//
// Tolerance: half a pixel of the ortho view's world-per-pixel, which at this
// camera is about 0.0023 world units. Assertions use 0.01 so a genuine
// distance-scaling regression (which is off by ~0.8 units at these offsets)
// cannot hide inside it.
//
// VERIFIED BY MUTATION. Each wrong implementation below was applied to the
// green tree, built, and run; the observed failure is quoted, then reverted
// and re-run green. The pair M1/M4 is the point: they are complements, and
// each turns red exactly the half of this file the other leaves alone.
//
//   M1 — the pre-fix cursor ray: `create_common.workplaneCursorRay` built
//        from `vp.eye` + `screenRay` (the perspective pencil) in every cell.
//        RED: "Front: ... worst corner miss 1.0725", and with the Front block
//        skipped, "Top: ... worst corner miss 1.0725" — Top is not spared.
//        The Perspective control stayed GREEN at 0.0024, which is what makes
//        this file able to say the ORTHO arm was fixed.
//   M4 — the complement: take the ortho arm unconditionally. All five ortho
//        rows stayed GREEN at 0.0025 and only the control went RED at 0.3759,
//        so the control is not passing by accident.
//   M3 — anchor the auto construction plane at the world ORIGIN instead of
//        the camera focus (in `screenToConstructionPlane` and in
//        `pickWorkplaneFrame`). Every focus-at-origin row stayed GREEN — they
//        structurally cannot see it — and the depth block went RED: "must sit
//        at 2.0000 on axis 2; got (+0.2020,+0.2990,+0.0000)".
//   M2 — the deleted helper's law restored inside
//        `screenToConstructionPlane`: the fixed world floor plus a refusal
//        that returns the plane origin, which is where the radial tool's
//        centre already sits, so it reproduces "kept the previous value".
//        Every create row stayed GREEN (they do not use that function) and
//        the last block went RED with the centre at (+0.0000,+0.0000,+0.0000)
//        against an aim of (+0.9000,-0.8000,+0.0000).

import http_client : testBaseUrl, getJson, postJson;
import std.conv    : to;
import std.format  : format;
import std.json;
import std.math    : abs, cos, sin, sqrt, tan, PI;
import std.net.curl : get, post;
import std.stdio   : writefln, writeln;

void main() {}

alias BASE = testBaseUrl;


void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void waitPlayback() {
    import core.thread : Thread;
    import core.time   : dur;
    foreach (i; 0 .. 400) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.TRUE) {
            Thread.sleep(dur!"msecs"(120));
            return;
        }
        Thread.sleep(dur!"msecs"(20));
    }
    assert(false, "play-events did not finish within 8 s");
}

struct V3 {
    double x = 0, y = 0, z = 0;
    V3 opBinary(string op : "+")(V3 o) const { return V3(x+o.x, y+o.y, z+o.z); }
    V3 opBinary(string op : "-")(V3 o) const { return V3(x-o.x, y-o.y, z-o.z); }
    V3 opBinary(string op : "*")(double s) const { return V3(x*s, y*s, z*s); }
    double len() const { return sqrt(x*x + y*y + z*z); }
    string toString() const { return format("(%+.4f,%+.4f,%+.4f)", x, y, z); }
}

double dot(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }

// `/api/camera` writes the orientation with `%.9g`, so an exactly-zero lane
// arrives as the JSON integer `0` and `.floating` throws on it. Every number
// read from an API response goes through here.
double num(JSONValue v) {
    if (v.type == JSONType.INTEGER)  return cast(double)v.integer;
    if (v.type == JSONType.UINTEGER) return cast(double)v.uinteger;
    return v.floating;
}

// The `presetBasis` table from source/view.d. Duplicated here rather than
// derived from /api/camera because that endpoint's `orientation` field still
// reports the SPHERICAL basis in an axis preset — it is not preset-aware, and
// reading it would silently aim every click with the wrong basis.
void presetBasis(string preset, out V3 right, out V3 up) {
    switch (preset) {
        case "Top":    right = V3( 1, 0, 0); up = V3(0, 0,-1); break;
        case "Bottom": right = V3( 1, 0, 0); up = V3(0, 0, 1); break;
        case "Front":  right = V3( 1, 0, 0); up = V3(0, 1, 0); break;
        case "Back":   right = V3(-1, 0, 0); up = V3(0, 1, 0); break;
        case "Right":  right = V3( 0, 0,-1); up = V3(0, 1, 0); break;
        case "Left":   right = V3( 0, 0, 1); up = V3(0, 1, 0); break;
        default: assert(false, "not an axis preset: " ~ preset);
    }
}

struct Cam {
    V3 focus, eye, right, up, back;
    double distance;
    int width, height, vpX, vpY;
    bool ortho;
}

Cam readCamera(string preset) {
    auto c = getJson("/api/camera");
    Cam r;
    r.focus = V3(num(c["focus"]["x"]), num(c["focus"]["y"]), num(c["focus"]["z"]));
    r.eye   = V3(num(c["eye"]["x"]), num(c["eye"]["y"]), num(c["eye"]["z"]));
    r.distance = num(c["distance"]);
    r.width  = cast(int)c["width"].integer;
    r.height = cast(int)c["height"].integer;
    r.vpX    = cast(int)c["vpX"].integer;
    r.vpY    = cast(int)c["vpY"].integer;
    r.ortho  = c["projKind"].str != "Perspective";
    assert(c["viewPreset"].str == preset,
        "asked for preset " ~ preset ~ " but the cell reports "
        ~ c["viewPreset"].str);
    if (preset == "Perspective") {
        auto o = c["orientation"].array;
        r.right = V3(num(o[0]), num(o[1]), num(o[2]));
        r.up    = V3(num(o[3]), num(o[4]), num(o[5]));
        r.back  = V3(num(o[6]), num(o[7]), num(o[8]));
    } else {
        presetBasis(preset, r.right, r.up);
        r.back = (r.eye - r.focus) * (1.0 / r.distance);
    }
    return r;
}

// Project a world point to a window pixel, using the cell's own projection.
// halfH = distance * tan(fovY/2) with fovY = 45 deg, the same formula
// view.d's viewport() uses for both projection kinds.
void pixelOf(const ref Cam c, V3 p, out int px, out int py) {
    immutable double t = tan(PI / 8.0);
    double halfH  = c.distance * t;
    double aspect = cast(double)c.width / c.height;
    V3 d = p - c.focus;
    double ndcX, ndcY;
    if (c.ortho) {
        ndcX = dot(d, c.right) / (halfH * aspect);
        ndcY = dot(d, c.up)    / halfH;
    } else {
        double depth = c.distance - dot(d, c.back);
        ndcX = dot(d, c.right) / (t * aspect * depth);
        ndcY = dot(d, c.up)    / (t * depth);
    }
    px = cast(int)((ndcX * 0.5 + 0.5) * c.width  + c.vpX + 0.5);
    py = cast(int)((1.0 - (ndcY * 0.5 + 0.5)) * c.height + c.vpY + 0.5);
}

V3[] modelVerts() {
    V3[] r;
    foreach (jv; getJson("/api/model")["vertices"].array) {
        auto a = jv.array;
        r ~= V3(num(a[0]), num(a[1]), num(a[2]));
    }
    return r;
}

// The camera-most-facing world axis: 0 = X, 1 = Y, 2 = Z. Same argmax (and
// same `>=` tie-break) the construction-plane picker runs.
int mostFacingAxis(V3 back) {
    double ax = abs(back.x), ay = abs(back.y), az = abs(back.z);
    if (ax >= ay && ax >= az) return 0;
    if (ay >= ax && ay >= az) return 1;
    return 2;
}

double axisComp(V3 v, int i) { return i == 0 ? v.x : (i == 1 ? v.y : v.z); }

/// Drag a box between two points chosen ON the construction plane, then read
/// back the world geometry it created.
///
/// The two aim points are built in the plane's OWN in-plane world axes, not in
/// the camera's screen basis — under perspective those differ, and aiming with
/// the screen basis would put the intended points off the plane and produce a
/// miss that says nothing about the tool.
V3[] createByDrag(string preset, double a0, double b0, double a1, double b1,
                  V3 focus, out V3[2] aimed)
{
    postJson("/api/command", commandBody("scene.reset", "{}"));
    postJson("/api/camera",
             format(`{"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
                    focus.x, focus.y, focus.z));
    cmd("viewport.view " ~ preset);
    auto c = readCamera(preset);

    immutable int k = mostFacingAxis(c.back);
    int[2] inPlane;
    {
        int n = 0;
        foreach (i; 0 .. 3) if (i != k) inPlane[n++] = i;
    }
    V3 onPlane(double a, double b) {
        double[3] q = [c.focus.x, c.focus.y, c.focus.z];
        q[inPlane[0]] += a;
        q[inPlane[1]] += b;
        return V3(q[0], q[1], q[2]);
    }
    aimed[0] = onPlane(a0, b0);
    aimed[1] = onPlane(a1, b1);

    int px0, py0, px1, py1;
    pixelOf(c, aimed[0], px0, py0);
    pixelOf(c, aimed[1], px1, py1);

    bool[V3] before;
    foreach (v; modelVerts()) before[v] = true;

    cmd("tool.set prim.cube");
    string log =
        format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
               c.vpX, c.vpY, c.width, c.height) ~ "\n" ~
        format(`{"t":10.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
               px0, py0) ~ "\n" ~
        format(`{"t":20.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":1,"mod":0}`,
               (px0 + px1) / 2, (py0 + py1) / 2) ~ "\n" ~
        format(`{"t":30.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":1,"mod":0}`,
               px1, py1) ~ "\n" ~
        format(`{"t":40.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
               px1, py1) ~ "\n";
    auto pr = postJson("/api/play-events", log);
    assert(pr["status"].str == "success", "play-events failed: " ~ pr.toString);
    waitPlayback();
    cmd("tool.set prim.cube off");   // commits the base quad

    V3[] created;
    foreach (v; modelVerts()) if (v !in before) created ~= v;
    return created;
}

/// The distance from each aimed corner to the nearest created vertex.
double worstCornerMiss(V3[] created, V3[2] aimed) {
    assert(created.length >= 4,
        "the drag created " ~ to!string(created.length)
        ~ " vertices; a base quad is 4 — the click never registered");
    double worst = 0;
    foreach (a; aimed) {
        double best = double.infinity;
        foreach (v; created) {
            double d = (v - a).len;
            if (d < best) best = d;
        }
        if (best > worst) worst = best;
    }
    return worst;
}

enum double TOL = 0.01;

unittest { // Front — the preset the owner reported, and the one that was broken
    V3[2] aimed;
    auto created = createByDrag("Front", 0.4, 0.3, -0.5, -0.2, V3(0, 0, 0), aimed);
    double miss = worstCornerMiss(created, aimed);
    writefln("Front: aimed %s %s, worst corner miss %.4f",
             aimed[0], aimed[1], miss);
    assert(miss < TOL,
        format("Front: the box must be created AT the click. worst corner "
             ~ "miss %.4f (aimed %s / %s). The pre-fix perspective ray put it "
             ~ "at the camera distance times the intended offset.",
               miss, aimed[0], aimed[1]));
    // ...and on the plane: a Front view's construction plane is Z = focus.z.
    foreach (v; created)
        assert(abs(v.z - 0.0) < TOL,
            "Front: every created vertex must lie on Z = focus.z, got " ~ v.toString);
    cmd("viewport.view Perspective");
}

unittest { // Top — NOT a working preset, despite looking like one
    // Top is the preset most likely to be mistaken for healthy: its view ray
    // is perpendicular to the world floor, so a fixed-floor construction plane
    // would still intersect there. It was misplaced by the same distance
    // factor as the other five, because the failing quantity was the RAY, not
    // the plane. Asserting Top is what makes this suite able to say the ortho
    // ray law is fixed rather than that one preset's plane was patched.
    V3[2] aimed;
    auto created = createByDrag("Top", 0.4, 0.3, -0.5, -0.2, V3(0, 0, 0), aimed);
    double miss = worstCornerMiss(created, aimed);
    writefln("Top: aimed %s %s, worst corner miss %.4f",
             aimed[0], aimed[1], miss);
    assert(miss < TOL,
        format("Top: the box must be created AT the click. worst corner "
             ~ "miss %.4f (aimed %s / %s).", miss, aimed[0], aimed[1]));
    cmd("viewport.view Perspective");
}

unittest { // all four horizontal presets, where the old floor plane was edge-on
    foreach (preset; ["Back", "Left", "Right"]) {
        V3[2] aimed;
        auto created = createByDrag(preset, 0.4, 0.3, -0.5, -0.2, V3(0, 0, 0), aimed);
        double miss = worstCornerMiss(created, aimed);
        writefln("%s: worst corner miss %.4f", preset, miss);
        assert(miss < TOL,
            format("%s: the box must be created AT the click, worst corner "
                 ~ "miss %.4f", preset, miss));
    }
    cmd("viewport.view Perspective");
}

unittest { // the CONTROL: perspective was never broken and must stay accurate
    // Without this the suite cannot distinguish "the ortho arm was fixed" from
    // "both arms were replaced by something that happens to suit ortho".
    V3[2] aimed;
    auto created = createByDrag("Perspective", 0.4, 0.3, -0.5, -0.2,
                                V3(0, 0, 0), aimed);
    double miss = worstCornerMiss(created, aimed);
    writefln("Perspective (control): worst corner miss %.4f", miss);
    assert(miss < TOL,
        format("Perspective: the control must stay as accurate as it was; "
             ~ "worst corner miss %.4f", miss));
}

unittest { // the DEPTH discriminator: the plane is anchored at the FOCUS
    // With the focus at the world origin, "the plane through the focus" and
    // "the plane through the origin" are the same plane and a test cannot tell
    // them apart. Displace the focus and the two answers differ by 2.0 along
    // the view axis, which is the measurement that picks one.
    immutable V3 focus = V3(0.7, 0.5, 2.0);
    foreach (preset; ["Front", "Top", "Perspective"]) {
        V3[2] aimed;
        auto created = createByDrag(preset, 0.4, 0.3, -0.5, -0.2, focus, aimed);
        auto c = readCamera(preset);
        immutable int k = mostFacingAxis(c.back);
        double want = axisComp(focus, k);
        foreach (v; created)
            assert(abs(axisComp(v, k) - want) < TOL,
                format("%s: the construction plane passes through the camera "
                     ~ "FOCUS, so every created vertex must sit at %.4f on "
                     ~ "axis %d; got %s", preset, want, k, v.toString));
        double miss = worstCornerMiss(created, aimed);
        writefln("%s (focus %s): worst corner miss %.4f", preset, focus, miss);
        assert(miss < TOL,
            format("%s: displacing the focus must not displace the click; "
                 ~ "worst corner miss %.4f", preset, miss));
    }
    cmd("viewport.view Perspective");
    postJson("/api/command", commandBody("scene.reset", "{}"));
}

unittest { // the click that used to be dropped in silence, at its own call site
    // The radial-array tool's off-handle click repositions its rotation
    // centre, and used to do it by projecting onto the fixed world floor and
    // dropping the result when the projection refused:
    //
    //     if (screenToWorkPlane(...)) { center_ = hit; rebuildPreview(); }
    //
    // In a Front view the ray lies IN that floor, so the call refused on every
    // click and the missing `else` left the centre exactly where it was. The
    // user's click was not registered at all — and the tool reported nothing.
    //
    // `center` is a vec3 Param, so the retention is directly readable.
    postJson("/api/command", commandBody("scene.reset", "{}"));
    cmd("viewport.view Front");
    cmd("select.typeFrom polygon");
    cmd("select.polygon 0");
    cmd("tool.set mesh.radialArrayTool");

    auto c = readCamera("Front");
    // Aim well away from the tool's own handles (which sit around the current
    // centre at the origin) so the click is unambiguously an off-handle one.
    immutable V3 aim = V3(c.focus.x + 0.9, c.focus.y - 0.8, c.focus.z);
    int px, py;
    pixelOf(c, aim, px, py);

    string log =
        format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
               c.vpX, c.vpY, c.width, c.height) ~ "\n" ~
        format(`{"t":10.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
               px, py) ~ "\n" ~
        format(`{"t":20.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
               px, py) ~ "\n";
    auto pr = postJson("/api/play-events", log);
    assert(pr["status"].str == "success", "play-events failed: " ~ pr.toString);
    waitPlayback();

    auto r = postJson("/api/command", "tool.attr mesh.radialArrayTool center ?");
    assert(r["status"].str == "ok", "centre query failed: " ~ r.toString);
    // A Vec3 Param reads back as a three-element ARRAY, not an {x,y,z} object.
    auto val = r["value"].array;
    V3 got = V3(num(val[0]), num(val[1]), num(val[2]));
    writefln("radial array centre after a Front off-handle click: %s (aimed %s)",
             got, aim);
    assert((got - aim).len < TOL,
        format("the off-handle click must move the rotation centre to the "
             ~ "click point; aimed %s, centre is %s. A centre still at the "
             ~ "origin is the silent refusal: the projection failed and the "
             ~ "caller kept the old value.", aim, got));

    cmd("tool.set mesh.radialArrayTool off");
    cmd("viewport.view Perspective");
    postJson("/api/command", commandBody("scene.reset", "{}"));
    writeln("test_create_click_workplane PASS");
}
