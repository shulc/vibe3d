// Interactive BoxTool smoke/regression coverage for announcement QA:
//   1. first click+drag creates a flat base,
//   2. second click+drag creates height,
//   3. viewport handles can edit the live box,
//   4. Tool Properties / tool.attr edits update live parameters,
//   5. Ctrl+Z steps active live edits and drop collapses history.

import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs, cos, fabs, PI, sin;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";

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
    auto r = postJson("/api/command", "tool.attr prim.cube " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query " ~ attr ~ " failed: " ~ r.toString);
    return r["value"].floating;
}

long qi(string attr) {
    auto r = postJson("/api/command", "tool.attr prim.cube " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query " ~ attr ~ " failed: " ~ r.toString);
    return r["value"].integer;
}

bool activeBoxQueryOk() {
    auto r = postJson("/api/command", "tool.attr prim.cube sizeX ?");
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

Vec3 crossD(Vec3 a, Vec3 b) {
    return Vec3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x);
}

Vec3 subD(JSONValue a, JSONValue b) {
    return Vec3(
        cast(float)(a.array[0].floating - b.array[0].floating),
        cast(float)(a.array[1].floating - b.array[1].floating),
        cast(float)(a.array[2].floating - b.array[2].floating));
}

Vec3 committedFaceNormal(long faceIndex) {
    auto m = getJson("/api/model");
    auto f = m["faces"].array[faceIndex].array;
    auto verts = m["vertices"].array;
    assert(f.length >= 3, "face must have at least 3 vertices");
    auto v0 = verts[cast(size_t)f[0].integer];
    auto v1 = verts[cast(size_t)f[1].integer];
    auto v2 = verts[cast(size_t)f[2].integer];
    return crossD(subD(v1, v0), subD(v2, v0));
}

Vec3 vertexAt(JSONValue model, size_t index) {
    auto v = model["vertices"].array[index].array;
    return Vec3(cast(float)v[0].floating,
                cast(float)v[1].floating,
                cast(float)v[2].floating);
}

Vec3 cameraBack() {
    auto vp = viewportFromCamera(fetchCamera(BASE));
    return Vec3(vp.view[2], vp.view[6], vp.view[10]);
}

struct BoxFrame {
    Vec3 normal;
    Vec3 axis1;
    Vec3 axis2;
    Vec3 planeNormal;
    Vec3 planeAxis1;
    Vec3 planeAxis2;
}

BoxFrame boxFrame() {
    auto vp = viewportFromCamera(fetchCamera(BASE));
    BoxFrame f;
    float avx = fabs(vp.view[2]);
    float avy = fabs(vp.view[6]);
    float avz = fabs(vp.view[10]);
    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    if (avx >= avy && avx >= avz) {
        float s = dotD(camBack, Vec3(1, 0, 0)) >= 0.0 ? 1.0f : -1.0f;
        f.normal = Vec3(s, 0, 0);
        f.axis1  = Vec3(0, 1, 0);
        f.axis2  = Vec3(0, 0, 1);
    } else if (avy >= avx && avy >= avz) {
        float s = dotD(camBack, Vec3(0, 1, 0)) >= 0.0 ? 1.0f : -1.0f;
        f.normal = Vec3(0, s, 0);
        f.axis1  = Vec3(1, 0, 0);
        f.axis2  = Vec3(0, 0, 1);
    } else {
        float s = dotD(camBack, Vec3(0, 0, 1)) >= 0.0 ? 1.0f : -1.0f;
        f.normal = Vec3(0, 0, s);
        f.axis1  = Vec3(1, 0, 0);
        f.axis2  = Vec3(0, 1, 0);
    }

    float aA = fabs(dot(camBack, f.axis1));
    float aN = fabs(dot(camBack, f.normal));
    float aZ = fabs(dot(camBack, f.axis2));
    if (aA >= aN && aA >= aZ) {
        f.planeNormal = Vec3(1, 0, 0);
        f.planeAxis1  = Vec3(0, 1, 0);
        f.planeAxis2  = Vec3(0, 0, 1);
    } else if (aN >= aA && aN >= aZ) {
        f.planeNormal = Vec3(0, 1, 0);
        f.planeAxis1  = Vec3(1, 0, 0);
        f.planeAxis2  = Vec3(0, 0, 1);
    } else {
        f.planeNormal = Vec3(0, 0, 1);
        f.planeAxis1  = Vec3(1, 0, 0);
        f.planeAxis2  = Vec3(0, 1, 0);
    }
    return f;
}

Vec3 toWorldP(BoxFrame f, Vec3 p) {
    return f.axis1 * p.x + f.normal * p.y + f.axis2 * p.z;
}

Vec3 toWorldD(BoxFrame f, Vec3 d) {
    return f.axis1 * d.x + f.normal * d.y + f.axis2 * d.z;
}

double sizeAlong(Vec3 axis) {
    if (abs(axis.x) > 0.5f) return qf("sizeX");
    if (abs(axis.y) > 0.5f) return qf("sizeY");
    return qf("sizeZ");
}

double centerAlong(Vec3 axis) {
    return dotD(center(), axis);
}

void resetForBox() {
    resetForBoxCamera(1.1);
}

void resetForBoxCamera(double elevation) {
    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset empty failed: " ~ r.toString);
    cmd("history.clear");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":` ~ elevation.to!string ~ `,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera set failed: " ~ r.toString);
    cmd("tool.set prim.cube");
}

void resetForRotatedWorkplaneBox() {
    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset empty failed: " ~ r.toString);
    cmd("history.clear");

    enum double deg = 35.0;
    enum double rz = deg * PI / 180.0;
    Vec3 wpCenter = Vec3(0.35f, -0.20f, 0.15f);

    // Put the camera on rotated workplane axis1, not on the workplane normal.
    // Box should use the workplane as a local coordinate frame and select the
    // most camera-facing local construction plane inside that frame.
    auto cam = postJson("/api/camera",
        `{"azimuth":1.57079632679,"elevation":0.6108652382,"distance":4.0,`
        ~ `"focus":{"x":` ~ wpCenter.x.to!string
        ~ `,"y":` ~ wpCenter.y.to!string
        ~ `,"z":` ~ wpCenter.z.to!string ~ `}}`);
    assert(cam["status"].str == "ok", "camera set failed: " ~ cam.toString);

    cmd("workplane.edit cenX:" ~ wpCenter.x.to!string
        ~ " cenY:" ~ wpCenter.y.to!string
        ~ " cenZ:" ~ wpCenter.z.to!string
        ~ " rotX:0 rotY:0 rotZ:" ~ deg.to!string);
    cmd("tool.set prim.cube");
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
    auto cam = fetchCamera(BASE);
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":50.000,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":%d,"repeat":0}` ~ "\n"
      ~ `{"t":60.000,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":%d,"repeat":0}`,
        cam.vpX, cam.vpY, cam.width, cam.height, mod, mod);
    playAndWait(log, BASE);
}

void playCtrlZ() { playKeyZ(64); }
void playCtrlShiftZ() { playKeyZ(65); }

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

Vec3 center() {
    return Vec3(cast(float)qf("cenX"), cast(float)qf("cenY"), cast(float)qf("cenZ"));
}

unittest { // Box click+drag base, height, handles, and params
    resetForBox();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");

    // 1. First click+drag creates a flat base on the XZ plane.
    dragPixels(cx, cy, cx + 150, cy + 140);
    auto f = boxFrame();
    double s1Base = sizeAlong(f.planeAxis1);
    double s2Base = sizeAlong(f.planeAxis2);
    double hBase  = sizeAlong(f.planeNormal);
    assert(s1Base > 0.25, "base drag should create axis1 size, got " ~ s1Base.to!string);
    assert(s2Base > 0.25, "base drag should create axis2 size, got " ~ s2Base.to!string);
    assert(approx(hBase, 0.0), "base should stay flat on plane normal, got " ~ hBase.to!string);

    // 2. Second click+drag creates height.
    dragPixels(cx, cy, cx, cy - 100);
    double hHeight = sizeAlong(f.planeNormal);
    assert(hHeight > 0.25, "height drag should create normal size, got " ~ hHeight.to!string);

    // 3a. Edge handle: drag one side outward, base size grows.
    Vec3 c0 = center();
    double s10 = sizeAlong(f.planeAxis1);
    Vec3 edgeLocal = c0 + f.planeAxis1 * cast(float)(s10 * 0.5);
    dragWorldHandle(toWorldP(f, edgeLocal), toWorldD(f, f.planeAxis1));
    double s11 = sizeAlong(f.planeAxis1);
    assert(s11 > s10 + 0.05,
        "edge handle should grow axis1 size: before=" ~ s10.to!string ~
        " after=" ~ s11.to!string);

    // 3b. Height handle: drag along plane normal, height grows. The second
    // construction drag may place the visible "top" on either side of the
    // base depending on the signed projection, so try both face-center handles.
    Vec3 c1 = center();
    double h0 = sizeAlong(f.planeNormal);
    Vec3 topLocal = c1 + f.planeNormal * cast(float)(h0 * 0.5);
    dragWorldHandle(toWorldP(f, topLocal), toWorldD(f, f.planeNormal));
    double h1 = sizeAlong(f.planeNormal);
    if (!(h1 > h0 + 0.05)) {
        Vec3 c1b = center();
        Vec3 bottomLocal = c1b - f.planeNormal * cast(float)(h0 * 0.5);
        dragWorldHandle(toWorldP(f, bottomLocal), toWorldD(f, f.planeNormal * -1.0f));
        h1 = sizeAlong(f.planeNormal);
    }
    assert(h1 > h0 + 0.05,
        "height handle should grow normal size: before=" ~ h0.to!string ~
        " after=" ~ h1.to!string);

    // 3c. Center move handle: drag along plane axis1, center moves.
    Vec3 c2 = center();
    double cAxis0 = centerAlong(f.planeAxis1);
    dragWorldHandle(toWorldP(f, c2), toWorldD(f, f.planeAxis1));
    double cAxis1 = centerAlong(f.planeAxis1);
    assert(cAxis1 > cAxis0 + 0.05,
        "center handle should move along axis1: before=" ~ cAxis0.to!string ~
        " after=" ~ cAxis1.to!string);

    // 4/5. Tool Properties path: all core numeric params round-trip and
    // re-evaluate the live preview parameters.
    cmd("tool.attr prim.cube cenX 1.25");
    cmd("tool.attr prim.cube cenY 0.75");
    cmd("tool.attr prim.cube cenZ -0.5");
    cmd("tool.attr prim.cube sizeX 2.0");
    cmd("tool.attr prim.cube sizeY 1.5");
    cmd("tool.attr prim.cube sizeZ 1.25");
    cmd("tool.attr prim.cube segmentsX 2");
    cmd("tool.attr prim.cube segmentsY 3");
    cmd("tool.attr prim.cube segmentsZ 4");
    assert(approx(qf("cenX"), 1.25), "cenX panel write failed");
    assert(approx(qf("cenY"), 0.75), "cenY panel write failed");
    assert(approx(qf("cenZ"), -0.5), "cenZ panel write failed");
    assert(approx(qf("sizeX"), 2.0), "sizeX panel write failed");
    assert(approx(qf("sizeY"), 1.5), "sizeY panel write failed");
    assert(approx(qf("sizeZ"), 1.25), "sizeZ panel write failed");
    assert(qi("segmentsX") == 2, "segmentsX panel write failed");
    assert(qi("segmentsY") == 3, "segmentsY panel write failed");
    assert(qi("segmentsZ") == 4, "segmentsZ panel write failed");

    cmd("tool.set prim.cube off");
}

void assertBaseOnlyCommitCreatesOneCameraFacingPolygon(double elevation) {
    resetForBoxCamera(elevation);

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);
    cmd("tool.set prim.cube off");

    assert(vertCount() == 4,
        "base-only commit should create 4 vertices, got " ~ vertCount().to!string);
    assert(faceCount() == 1,
        "base-only commit should create exactly one polygon, got " ~ faceCount().to!string);
    Vec3 n = committedFaceNormal(0);
    double facing = dotD(n, cameraBack());
    assert(facing > 0.0,
        "base polygon should face the camera; dot(normal,cameraBack)=" ~ facing.to!string);
}

unittest { // Box base-only commit creates one camera-facing polygon
    assertBaseOnlyCommitCreatesOneCameraFacingPolygon(1.1);
    assertBaseOnlyCommitCreatesOneCameraFacingPolygon(-1.1);
}

unittest { // Box base-only commit follows a rotated workplane
    resetForRotatedWorkplaneBox();

    enum double deg = 35.0;
    enum double rz = deg * PI / 180.0;
    Vec3 wpCenter = Vec3(0.35f, -0.20f, 0.15f);
    Vec3 expectedNormal = Vec3(cast(float)cos(rz), cast(float)sin(rz), 0);

    int cx, cy;
    projectOrDie(wpCenter, cx, cy, "rotated workplane center");
    dragPixels(cx, cy, cx + 150, cy + 140);
    cmd("tool.set prim.cube off");

    assert(vertCount() == 4,
        "rotated workplane base should create 4 vertices, got " ~ vertCount().to!string);
    assert(faceCount() == 1,
        "rotated workplane base should create exactly one polygon, got " ~ faceCount().to!string);

    auto m = getJson("/api/model");
    foreach (i; 0 .. 4) {
        Vec3 v = vertexAt(m, i);
        double dist = dotD(v - wpCenter, expectedNormal);
        assert(approx(dist, 0.0, 1e-3),
            "vertex " ~ i.to!string ~
            " is off the rotated construction plane: signed dist=" ~ dist.to!string);
    }

    Vec3 n = normalize(committedFaceNormal(0));
    double aligned = abs(dotD(n, expectedNormal));
    assert(aligned > 0.999,
        "base polygon normal should align with the rotated construction normal, dot="
        ~ aligned.to!string);
    assert(dotD(committedFaceNormal(0), cameraBack()) > 0.0,
        "rotated workplane base polygon should face the camera");
}

unittest { // Box active undo steps live edits; drop collapses to one history entry
    resetForBox();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);
    auto f = boxFrame();
    double baseHeight = sizeAlong(f.planeNormal);
    assert(approx(baseHeight, 0.0), "base should start flat before height undo test");
    dragPixels(cx, cy, cx, cy - 100);
    double createdHeight = sizeAlong(f.planeNormal);
    assert(createdHeight > 0.25, "height drag should create height before undo");
    assert(undoLen() == 1, "height construction should create one live undo step");
    playCtrlZ();
    assert(approx(sizeAlong(f.planeNormal), 0.0, 1e-3),
        "Ctrl+Z after height creation should return to the flat base");
    assert(undoLen() == 0, "height construction undo should pop its live entry");
    dragPixels(cx, cy, cx, cy - 100);
    size_t liveFloor = undoLen();
    assert(liveFloor == 1, "recreated height should be one live step above base");

    // A Tool Properties edit is one live undo step; the tool remains active.
    double sx0 = qf("sizeX");
    cmd("tool.attr prim.cube sizeX 2.25");
    assert(approx(qf("sizeX"), 2.25), "sizeX write before undo failed");
    assert(undoLen() == liveFloor + 1, "live property edit should create one in-session entry");
    playCtrlZ();
    assert(approx(qf("sizeX"), sx0),
        "Ctrl+Z should undo only the property edit: before=" ~ sx0.to!string ~
        " after=" ~ qf("sizeX").to!string);
    assert(undoLen() == liveFloor, "live property undo should pop its in-session entry");
    playCtrlShiftZ();
    assert(approx(qf("sizeX"), 2.25),
        "Ctrl+Shift+Z should redo the live property edit");
    assert(undoLen() == liveFloor + 1, "live property redo should restore one in-session entry");
    playCtrlZ();
    assert(approx(qf("sizeX"), sx0),
        "Ctrl+Z after live redo should undo the property edit, not cancel the tool");
    assert(undoLen() == liveFloor, "live property undo after redo should pop its entry");

    // A handle drag is also one live undo step, not a full tool cancel.
    double s10 = sizeAlong(f.planeAxis1);
    Vec3 edgeLocal = center() + f.planeAxis1 * cast(float)(s10 * 0.5);
    dragWorldHandle(toWorldP(f, edgeLocal), toWorldD(f, f.planeAxis1));
    double s11 = sizeAlong(f.planeAxis1);
    assert(s11 > s10 + 0.05, "edge handle did not change size before undo");
    assert(undoLen() == liveFloor + 1, "live handle drag should create one in-session entry");
    playCtrlZ();
    double s12 = sizeAlong(f.planeAxis1);
    assert(approx(s12, s10, 1e-3),
        "Ctrl+Z should undo only the handle drag: before=" ~ s10.to!string ~
        " after=" ~ s12.to!string);
    assert(undoLen() == liveFloor, "live handle undo should pop its in-session entry");

    // Multiple live edits collapse into the single Create Box entry on drop.
    cmd("tool.attr prim.cube sizeX 2.0");
    cmd("tool.attr prim.cube sizeY 1.5");
    assert(undoLen() == liveFloor + 2, "two live property edits should be two active steps");
    cmd("tool.set prim.cube off");
    assert(undoLen() == 1, "drop should collapse live box edits into one entry");
    assert(vertCount() > 0, "box drop should commit mesh geometry");
    playCtrlZ();
    assert(undoLen() == 0, "post-drop Ctrl+Z should pop the single box entry");
    assert(vertCount() == 0, "post-drop Ctrl+Z should remove the committed box");
}

unittest { // Box Ctrl+Z ladder: height -> base -> no pending box
    resetForBox();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);
    auto f = boxFrame();
    assert(approx(sizeAlong(f.planeNormal), 0.0),
        "first drag should leave a flat base before height");

    dragPixels(cx, cy, cx, cy - 100);
    assert(sizeAlong(f.planeNormal) > 0.25,
        "second drag should create height before undo ladder");
    assert(undoLen() == 1, "height creation should be one active undo step");

    playCtrlZ();
    assert(approx(sizeAlong(f.planeNormal), 0.0, 1e-3),
        "first Ctrl+Z should remove height and restore the base");
    assert(undoLen() == 0, "height undo should leave no active history entry");

    playCtrlZ();
    assert(!activeBoxQueryOk(),
        "second Ctrl+Z should also deactivate prim.cube");
    cmd("tool.set prim.cube off");
    assert(undoLen() == 0,
        "second Ctrl+Z should cancel the base without creating history");
    assert(vertCount() == 0,
        "second Ctrl+Z should leave no pending box to commit on tool drop");
}
