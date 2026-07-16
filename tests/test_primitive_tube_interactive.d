// Interactive TubeTool regression coverage (task 0414 Phase 0).
//
// Recorded against UNMODIFIED main as the byte-stability oracle for the
// PrimitiveCreateTool base-class extraction (0407 sec A.D2). Tube is the
// highest-risk / lowest-payoff migration in the plan: a THREE-drag state
// machine (outer radius -> height -> inner radius) with NO size handles at
// all -- only a mover, and only once InnerSet (its id-scheme is
// {arrowX/Y/Z=0/1/2, centerBox=10}, unlike the cylinder family's
// {size=0..5, mover=10..13}). This test exercises exactly that surface:
//   1. three-stage construction drag, asserting live params after EACH
//      stage and the final committed geometry.
//   2. mover-handle drag (InnerSet only) moves the center.
//   3. Tool Properties (tool.attr) round-trip for every param, including
//      the bool `cap` param.
//   4. Undo ladder: hasUncommittedEdit only becomes true at HeightSet (the
//      first two stages establish the baseline with no live undo entry
//      yet, mirroring the cylinder family's "first committable state is
//      the baseline" pattern); the THIRD (inner-radius) stage is the first
//      live undo entry; drop collapses; post-drop undo clears.

import std.conv : to;
import std.json;
import std.math : fabs;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "prim.tube";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(BASE ~ path));
}

JSONValue postJson(string path, string body) {
    return parseJSON(cast(string)post(BASE ~ path, body));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double qf(string attr) {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query " ~ attr ~ " failed: " ~ r.toString);
    return r["value"].floating;
}

long qi(string attr) {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query " ~ attr ~ " failed: " ~ r.toString);
    return r["value"].integer;
}

// IntEnum (axis) reads back as its wire-tag STRING (params.d paramToJson),
// even though writes also accept a raw integer.
string qs(string attr) {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query " ~ attr ~ " failed: " ~ r.toString);
    return r["value"].str;
}

bool qb(string attr) {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query " ~ attr ~ " failed: " ~ r.toString);
    return r["value"].type == JSONType.true_;
}

enum string[3] AXIS_TAG = ["x", "y", "z"];

bool activeQueryOk() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " outerRadius ?");
    return r["status"].str == "ok";
}

bool approx(double a, double b, double eps = 1e-4) {
    return fabs(a - b) <= eps;
}

size_t undoLen() {
    return getJson("/api/history")["undo"].array.length;
}

long vertCount() {
    return getJson("/api/model")["vertexCount"].integer;
}

long faceCount() {
    return getJson("/api/model")["faceCount"].integer;
}

double dotD(Vec3 a, Vec3 b) {
    return cast(double)a.x * b.x + cast(double)a.y * b.y + cast(double)a.z * b.z;
}

// Mirrors choosePlane()'s mostFacingAxis pick for the UNROTATED default
// workplane used by every test here (no workplane.edit call).
struct PlaneFrame { Vec3 normal, axis1, axis2; }

PlaneFrame planeFrame() {
    auto vp = viewportFromCamera(fetchCamera(BASE));
    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    double da = fabs(camBack.x), db = fabs(camBack.y), dc = fabs(camBack.z);
    PlaneFrame f;
    if (da >= db && da >= dc) {
        f.normal = Vec3(1, 0, 0); f.axis1 = Vec3(0, 1, 0); f.axis2 = Vec3(0, 0, 1);
    } else if (db >= da && db >= dc) {
        f.normal = Vec3(0, 1, 0); f.axis1 = Vec3(1, 0, 0); f.axis2 = Vec3(0, 0, 1);
    } else {
        f.normal = Vec3(0, 0, 1); f.axis1 = Vec3(1, 0, 0); f.axis2 = Vec3(0, 1, 0);
    }
    return f;
}

Vec3 center() {
    return Vec3(cast(float)qf("cenX"), cast(float)qf("cenY"), cast(float)qf("cenZ"));
}

double centerAlong(Vec3 axis) { return dotD(center(), axis); }

void resetForTube() {
    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset empty failed: " ~ r.toString);
    cmd("history.clear");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera set failed: " ~ r.toString);
    cmd("tool.set " ~ TOOL);
    // params_ is STICKY across tool.set on/off cycles (/api/reset resets the
    // document, not tool state); the Idle-click handler re-zeroes cen/outer/
    // inner/height on a fresh drag, but NOT segments/axis/cap. Pin those back
    // to their ctor defaults so every unittest block in this file starts from
    // a known baseline.
    cmd("tool.attr " ~ TOOL ~ " segments 24");
    cmd("tool.attr " ~ TOOL ~ " axis 1");
    cmd("tool.attr " ~ TOOL ~ " cap true");
}

void dragPixels(int x0, int y0, int x1, int y1, int steps = 16) {
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, steps), BASE);
    import core.thread : Thread;
    import core.time : dur;
    Thread.sleep(dur!"msecs"(120));
}

void playKeyZ(int mod) {
    import std.format : format;
    auto cam = fetchCamera(BASE);
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":50.000,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":%d,"repeat":0}` ~ "\n"
      ~ `{"t":60.000,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":%d,"repeat":0}`,
        cam.vpX, cam.vpY, cam.width, cam.height, mod, mod);
    playAndWait(log, BASE);
}

void playCtrlZ() { playKeyZ(64); }

void projectOrDie(Vec3 p, out int x, out int y, string label) {
    auto vp = viewportFromCamera(fetchCamera(BASE));
    float fx, fy;
    assert(projectToWindow(p, vp, fx, fy), label ~ " projects behind camera");
    x = cast(int)fx;
    y = cast(int)fy;
}

void dragWorldHandle(Vec3 handle, Vec3 axis, double pixels = 80.0, int steps = 16) {
    auto vp = viewportFromCamera(fetchCamera(BASE));
    float hx, hy, ax, ay;
    assert(projectToWindow(handle, vp, hx, hy), "handle projects behind camera");
    assert(projectToWindow(handle + axis, vp, ax, ay), "axis projects behind camera");
    double dx = ax - hx;
    double dy = ay - hy;
    double len = (dx * dx + dy * dy) ^^ 0.5;
    assert(len > 1e-6, "projected handle axis is degenerate");
    int x0 = cast(int)hx;
    int y0 = cast(int)hy;
    int x1 = cast(int)(hx + dx / len * pixels);
    int y1 = cast(int)(hy + dy / len * pixels);
    dragPixels(x0, y0, x1, y1, steps);
}

unittest { // Three-stage construction drag: outer radius, height, inner radius
    resetForTube();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");

    // Stage 1: DrawingOuter -> OuterSet.
    dragPixels(cx, cy, cx + 150, cy + 140);
    double outer0 = qf("outerRadius");
    assert(outer0 > 0.1, "outer drag should create outerRadius, got " ~ outer0.to!string);
    assert(approx(qf("innerRadius"), outer0 * 0.5, 1e-3),
        "OuterSet should auto-seed innerRadius = outer*0.5, got " ~ qf("innerRadius").to!string);
    assert(approx(qf("height"), 0.0), "outer-radius stage should leave height at 0");

    // Stage 2: DrawingHeight -> HeightSet.
    Vec3 cenBeforeHeight = center();
    auto f = planeFrame();
    dragPixels(cx, cy, cx, cy - 100);
    double h1 = qf("height");
    assert(h1 > 0.25, "height drag should create a positive height, got " ~ h1.to!string);
    assert(approx(qf("outerRadius"), outer0, 1e-3), "height drag must not change outerRadius");
    // Box-style anchored-opposite: the anchored face stays fixed, so the
    // center shift along planeNormal equals exactly half the new height.
    double shift = fabs(centerAlong(f.normal) - dotD(cenBeforeHeight, f.normal));
    assert(approx(shift, h1 * 0.5, 1e-2),
        "center shift along the construction normal should equal height/2: shift="
        ~ shift.to!string ~ " height/2=" ~ (h1 * 0.5).to!string);

    // Stage 3: DrawingInner -> InnerSet. Click a point 30% of outerRadius
    // from center, in-plane -- updateInnerRadiusFromHit reads it straight
    // off the click point (no drag needed).
    Vec3 cen2 = center();
    Vec3 innerTarget = cen2 + f.axis1 * cast(float)(outer0 * 0.3);
    int ix, iy;
    projectOrDie(innerTarget, ix, iy, "inner-radius click target");
    dragPixels(ix, iy, ix, iy, 1);
    assert(approx(qf("innerRadius"), outer0 * 0.3, 1e-2),
        "inner-radius click should set innerRadius ~= outer*0.3, got " ~ qf("innerRadius").to!string);

    // Commit: default segments=24, cap=true were never touched by the drags
    // -> 4*S = 96 verts / 96 faces (matches test_primitive_tube.d's own
    // default-count assertion; the interactive commit calls the same
    // buildTube(mesh, params_)).
    cmd("tool.set " ~ TOOL ~ " off");
    assert(vertCount() == 96, "committed tube: expected 96 verts, got " ~ vertCount().to!string);
    assert(faceCount() == 96, "committed tube: expected 96 faces, got " ~ faceCount().to!string);
}

unittest { // Mover-handle drag (InnerSet only) moves the center; no size handles exist
    resetForTube();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);   // OuterSet
    dragPixels(cx, cy, cx, cy - 100);         // HeightSet
    double outer0 = qf("outerRadius");
    auto f = planeFrame();
    Vec3 cen = center();
    Vec3 innerTarget = cen + f.axis1 * cast(float)(outer0 * 0.3);
    int ix, iy;
    projectOrDie(innerTarget, ix, iy, "inner-radius click target");
    dragPixels(ix, iy, ix, iy, 1);            // InnerSet, tool stays active, mover now shown

    Vec3 c0 = center();
    double cAxis0 = centerAlong(f.axis2);
    dragWorldHandle(c0, f.axis2);
    double cAxis1 = centerAlong(f.axis2);
    assert(cAxis1 > cAxis0 + 0.05,
        "mover handle should move the center along axis2: before=" ~ cAxis0.to!string
        ~ " after=" ~ cAxis1.to!string);

    cmd("tool.set " ~ TOOL ~ " off");
}

unittest { // Tool Properties (tool.attr) round-trip for every param, incl. bool cap
    resetForTube();
    cmd("tool.attr " ~ TOOL ~ " cenX 1.25");
    cmd("tool.attr " ~ TOOL ~ " cenY 0.75");
    cmd("tool.attr " ~ TOOL ~ " cenZ -0.5");
    cmd("tool.attr " ~ TOOL ~ " outerRadius 2.0");
    cmd("tool.attr " ~ TOOL ~ " innerRadius 1.0");
    cmd("tool.attr " ~ TOOL ~ " height 3.0");
    cmd("tool.attr " ~ TOOL ~ " segments 8");
    cmd("tool.attr " ~ TOOL ~ " axis 0");
    cmd("tool.attr " ~ TOOL ~ " cap false");
    assert(approx(qf("cenX"), 1.25), "cenX panel write failed");
    assert(approx(qf("cenY"), 0.75), "cenY panel write failed");
    assert(approx(qf("cenZ"), -0.5), "cenZ panel write failed");
    assert(approx(qf("outerRadius"), 2.0), "outerRadius panel write failed");
    assert(approx(qf("innerRadius"), 1.0), "innerRadius panel write failed");
    assert(approx(qf("height"), 3.0), "height panel write failed");
    assert(qi("segments") == 8, "segments panel write failed");
    assert(qs("axis") == "x", "axis panel write failed, got " ~ qs("axis"));
    assert(qb("cap") == false, "cap panel write failed");
    cmd("tool.attr " ~ TOOL ~ " cap true");
    assert(qb("cap") == true, "cap panel write-back failed");
    cmd("tool.set " ~ TOOL ~ " off");
}

unittest { // Undo ladder: baseline at HeightSet, first live entry at InnerSet, drop collapses
    resetForTube();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);   // OuterSet: not yet committable (state<HeightSet)
    assert(undoLen() == 0, "outer-radius stage alone should create no live undo step");

    dragPixels(cx, cy, cx, cy - 100);         // HeightSet: first committable state (baseline)
    assert(undoLen() == 0,
        "reaching the first committable state (HeightSet) should not itself create a live undo step");
    double outer0 = qf("outerRadius");
    double innerAtBaseline = qf("innerRadius");

    auto f = planeFrame();
    Vec3 cen = center();
    Vec3 innerTarget = cen + f.axis1 * cast(float)(outer0 * 0.3);
    int ix, iy;
    projectOrDie(innerTarget, ix, iy, "inner-radius click target");
    dragPixels(ix, iy, ix, iy, 1);            // InnerSet: a real change to an already-committable tube
    assert(!approx(qf("innerRadius"), innerAtBaseline, 1e-3),
        "inner-radius stage should have changed innerRadius from the HeightSet baseline");
    assert(undoLen() == 1, "inner-radius construction should create one live undo step");

    playCtrlZ();
    assert(approx(qf("innerRadius"), innerAtBaseline, 1e-3),
        "Ctrl+Z after inner-radius creation should return to the HeightSet-seeded innerRadius");
    assert(undoLen() == 0, "inner-radius undo should pop its live entry");

    // Second Ctrl+Z (from the HeightSet baseline) cancels the whole tool.
    playCtrlZ();
    assert(!activeQueryOk(), "second Ctrl+Z should also deactivate " ~ TOOL);
    cmd("tool.set " ~ TOOL ~ " off");
    assert(undoLen() == 0, "cancelled tube tool should leave no history entry");
    assert(vertCount() == 0, "cancelled tube tool should leave no pending geometry");

    // Redo the full sequence, then confirm drop collapses live edits.
    resetForTube();
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);
    dragPixels(cx, cy, cx, cy - 100);
    double sz = qf("outerRadius");
    Vec3 cen2 = center();
    Vec3 target2 = cen2 + planeFrame().axis1 * cast(float)(sz * 0.3);
    projectOrDie(target2, ix, iy, "inner-radius click target 2");
    dragPixels(ix, iy, ix, iy, 1);
    assert(undoLen() == 1, "inner-radius construction should again be one live undo step");
    cmd("tool.attr " ~ TOOL ~ " segments 6");
    assert(undoLen() == 2, "a further live property edit should be a second active step");
    cmd("tool.set " ~ TOOL ~ " off");
    assert(undoLen() == 1, "drop should collapse live tube edits into one entry");
    assert(vertCount() > 0, "tube drop should commit mesh geometry");
    playCtrlZ();
    assert(undoLen() == 0, "post-drop Ctrl+Z should pop the single tube entry");
    assert(vertCount() == 0, "post-drop Ctrl+Z should remove the committed tube");
}
