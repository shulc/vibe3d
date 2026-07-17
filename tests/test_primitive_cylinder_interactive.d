// Interactive CylinderTool regression coverage (task 0414 Phase 0).
//
// Recorded against UNMODIFIED main as the byte-stability oracle for the
// PrimitiveCreateTool base-class extraction (0407 sec A.D2): cylinder is
// the "family" representative (cone/capsule share its onMouse*/handle-rig
// body verbatim, per the task's code-diff survey), so this test exercises
// the full interaction surface a refactor could silently change:
//   1. two-stage construction drag (flat ellipse -> extruded cylinder),
//      asserting the live params after EACH stage and the final committed
//      geometry (vertex/face counts + positions).
//   2. size-handle drag: box-style anchored-opposite growth (the opposite
//      face stays fixed => center shift == size growth, exactly).
//   3. mover-handle drag moves the center.
//   4. Tool Properties (tool.attr) round-trip for every param.
//   5. Undo ladder: the whole construction/edit session is preview-only
//      (no undo entries from any stage or from live property edits);
//      dropping the tool creates exactly one "Create Cylinder" entry;
//      a Ctrl+Z pressed DURING an uncommitted session cancels the whole
//      live edit outright (no commit, no undo entry) instead of peeling a
//      step, and keeps the tool armed for a fresh gesture (task 0430
//      keep-alive, reference-measured); undo after drop removes the whole
//      committed primitive.

import std.conv : to;
import std.json;
import std.math : fabs;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "prim.cylinder";

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

// IntEnum params (axis) serialise their READ side as the wire-tag STRING
// (params.d paramToJson: `case IntEnum: return JSONValue(e.wireTag)`), even
// though the WRITE side (injectParamsInto) also accepts a raw integer. Use
// this instead of qi() for "axis".
string qs(string attr) {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query " ~ attr ~ " failed: " ~ r.toString);
    return r["value"].str;
}

bool activeQueryOk() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " sizeX ?");
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

// Mirrors choosePlane()'s mostFacingAxis pick (tools/create_common.d) for
// the UNROTATED default workplane (axis1=X, normal=Y, axis2=Z) used by
// every test here (no workplane.edit call) -- so this is exactly the
// construction plane the tool itself will pick for a given camera.
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

double sizeAlong(Vec3 axis) {
    if (fabs(axis.x) > 0.5f) return qf("sizeX");
    if (fabs(axis.y) > 0.5f) return qf("sizeY");
    return qf("sizeZ");
}

Vec3 center() {
    return Vec3(cast(float)qf("cenX"), cast(float)qf("cenY"), cast(float)qf("cenZ"));
}

double centerAlong(Vec3 axis) { return dotD(center(), axis); }

void resetForCylinder() {
    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset empty failed: " ~ r.toString);
    cmd("history.clear");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera set failed: " ~ r.toString);
    cmd("tool.set " ~ TOOL);
    // params_ is STICKY across tool.set on/off cycles (by design -- /api/reset
    // resets the document, not tool state) and cenX/Y/Z + sizeX/Y/Z are the
    // only fields the Idle-click handler re-zeroes on a fresh drag. Pin the
    // rest back to their ctor defaults so every unittest block in this file
    // starts from a known baseline regardless of what an earlier block (e.g.
    // the tool.attr round-trip test) left behind.
    cmd("tool.attr " ~ TOOL ~ " sides 24");
    cmd("tool.attr " ~ TOOL ~ " segments 1");
    cmd("tool.attr " ~ TOOL ~ " axis 1");
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

// ---------------------------------------------------------------------------
// Winding regression (task 0424): pickMostFacingPlane's X-dominant and
// Z-dominant camera cases (create_common.d) both return a LEFT-handed basis
// triple (det(frame.toWorld upper-left 3x3) = -1) -- transforming the
// builders' fixed local-space CCW winding through that frame mirrors every
// new face's normal to point inward. Every unittest above uses the oblique
// Y-dominant camera from resetForCylinder() (azimuth=0.4, elevation=1.1),
// which always lands on pickMostFacingPlane's Y-dominant case (det=+1) and
// so never exercised this. resetForCylinderFrontCam() below swaps in a
// near-dead-on "front" camera (azimuth/elevation close to 0) that stays
// safely Z-dominant while avoiding the exact az=0/el=0 degenerate case
// (where the height-drag auxiliary plane's in-plane residual is exactly
// zero -- see setupHeightPlane() in primitive_create_tool.d).
// ---------------------------------------------------------------------------

void resetForCylinderFrontCam() {
    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset empty failed: " ~ r.toString);
    cmd("history.clear");
    r = postJson("/api/camera",
        `{"azimuth":0.08,"elevation":0.08,"distance":4.0,"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera set failed: " ~ r.toString);
    cmd("tool.set " ~ TOOL);
    // Same sticky-param pin as resetForCylinder() -- see its comment above.
    cmd("tool.attr " ~ TOOL ~ " sides 24");
    cmd("tool.attr " ~ TOOL ~ " segments 1");
    cmd("tool.attr " ~ TOOL ~ " axis 1");
}

// JSON-model geometry helpers -- same Newell-normal formula as
// tests/test_edge_bevel.d's faceNormal()/faceCentroid(), reimplemented here
// against drag_helpers.Vec3 (this file already pulls that in for camera/drag
// math) rather than that file's own double-precision V3.
Vec3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return Vec3(cast(float)a[0].floating, cast(float)a[1].floating, cast(float)a[2].floating);
}

Vec3 meshCentroid(JSONValue m) {
    size_t n = m["vertices"].array.length;
    Vec3 c = Vec3(0, 0, 0);
    foreach (i; 0 .. n) c = c + vert(m, i);
    return c / cast(float)n;
}

Vec3 faceCentroid(JSONValue m, JSONValue faceArr) {
    auto idx = faceArr.array;
    Vec3 c = Vec3(0, 0, 0);
    foreach (k; 0 .. idx.length) c = c + vert(m, cast(size_t)idx[k].integer);
    return c / cast(float)idx.length;
}

// Newell face normal (not normalized).
Vec3 faceNormal(JSONValue m, JSONValue faceArr) {
    auto idx = faceArr.array;
    auto n   = idx.length;
    Vec3 nm = Vec3(0, 0, 0);
    foreach (k; 0 .. n) {
        auto vi = vert(m, cast(size_t)idx[k].integer);
        auto vj = vert(m, cast(size_t)idx[(k + 1) % n].integer);
        nm.x += (vi.y - vj.y) * (vi.z + vj.z);
        nm.y += (vi.z - vj.z) * (vi.x + vj.x);
        nm.z += (vi.x - vj.x) * (vi.y + vj.y);
    }
    return nm;
}

unittest { // Two-stage construction drag: flat disk, then extruded cylinder
    resetForCylinder();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");

    // Stage 1: DrawingBase -> BaseSet (flat ellipse on the construction plane).
    dragPixels(cx, cy, cx + 150, cy + 140);
    auto f = planeFrame();
    double s1 = sizeAlong(f.axis1);
    double s2 = sizeAlong(f.axis2);
    double h0 = sizeAlong(f.normal);
    assert(s1 > 0.25, "base drag should create axis1 radius, got " ~ s1.to!string);
    assert(s2 > 0.25, "base drag should create axis2 radius, got " ~ s2.to!string);
    assert(approx(h0, 0.0), "base should stay flat on the plane normal, got " ~ h0.to!string);
    string axisTag = qs("axis");
    assert(axisTag == "x" || axisTag == "y" || axisTag == "z",
        "axis param should be set from the plane normal, got " ~ axisTag);

    // Stage 2: DrawingHeight -> HeightSet (extrude into a cylinder).
    dragPixels(cx, cy, cx, cy - 100);
    double h1 = sizeAlong(f.normal);
    assert(h1 > 0.25, "height drag should create normal-axis radius, got " ~ h1.to!string);

    // Commit and check final geometry: defaults sides=24 segments=1 were
    // never touched by the drags -> (segments+1)*sides = 48 verts,
    // 2 + segments*sides = 26 faces (matches test_primitive_cylinder.d's
    // own default-count assertion, since the interactive commit path calls
    // the exact same buildCylinder(mesh, params_)).
    cmd("tool.set " ~ TOOL ~ " off");
    assert(vertCount() == 48, "committed cylinder: expected 48 verts, got " ~ vertCount().to!string);
    assert(faceCount() == 26, "committed cylinder: expected 26 faces, got " ~ faceCount().to!string);
}

unittest { // Size-handle drag (box-style anchored-opposite) + mover-handle drag
    resetForCylinder();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);
    dragPixels(cx, cy, cx, cy - 100);   // BaseSet -> HeightSet, tool stays active

    // Size handles are fixed WORLD +-X/+-Y/+-Z (SIZE_AXES), independent of
    // which construction plane the camera picked.
    Vec3 c0 = center();
    double sx0 = qf("sizeX");
    dragWorldHandle(Vec3(c0.x + cast(float)sx0, c0.y, c0.z), Vec3(1, 0, 0));
    double sx1 = qf("sizeX");
    assert(sx1 > sx0 + 0.05,
        "+X size handle should grow sizeX: before=" ~ sx0.to!string ~ " after=" ~ sx1.to!string);
    Vec3 c1 = center();
    assert(approx(c1.x - c0.x, sx1 - sx0, 1e-3),
        "anchored-opposite invariant: center shift should equal size growth exactly, "
        ~ "shift=" ~ (c1.x - c0.x).to!string ~ " growth=" ~ (sx1 - sx0).to!string);
    assert(approx(c1.y, c0.y) && approx(c1.z, c0.z),
        "+X handle drag must not move cenY/cenZ");

    // Mover handle (centerBox at the object center): drag along one of the
    // in-plane construction axes and confirm the center follows.
    auto f = planeFrame();
    Vec3 c2 = center();
    double cAxis0 = centerAlong(f.axis1);
    dragWorldHandle(c2, f.axis1);
    double cAxis1 = centerAlong(f.axis1);
    assert(cAxis1 > cAxis0 + 0.05,
        "mover handle should move the center along axis1: before=" ~ cAxis0.to!string
        ~ " after=" ~ cAxis1.to!string);

    cmd("tool.set " ~ TOOL ~ " off");
}

unittest { // Tool Properties (tool.attr) round-trip for every param
    resetForCylinder();
    cmd("tool.attr " ~ TOOL ~ " cenX 1.25");
    cmd("tool.attr " ~ TOOL ~ " cenY 0.75");
    cmd("tool.attr " ~ TOOL ~ " cenZ -0.5");
    cmd("tool.attr " ~ TOOL ~ " sizeX 2.0");
    cmd("tool.attr " ~ TOOL ~ " sizeY 1.5");
    cmd("tool.attr " ~ TOOL ~ " sizeZ 1.25");
    cmd("tool.attr " ~ TOOL ~ " sides 8");
    cmd("tool.attr " ~ TOOL ~ " segments 3");
    cmd("tool.attr " ~ TOOL ~ " axis 2");
    assert(approx(qf("cenX"), 1.25), "cenX panel write failed");
    assert(approx(qf("cenY"), 0.75), "cenY panel write failed");
    assert(approx(qf("cenZ"), -0.5), "cenZ panel write failed");
    assert(approx(qf("sizeX"), 2.0), "sizeX panel write failed");
    assert(approx(qf("sizeY"), 1.5), "sizeY panel write failed");
    assert(approx(qf("sizeZ"), 1.25), "sizeZ panel write failed");
    assert(qi("sides") == 8, "sides panel write failed");
    assert(qi("segments") == 3, "segments panel write failed");
    assert(qs("axis") == "z", "axis panel write failed, got " ~ qs("axis"));
    cmd("tool.set " ~ TOOL ~ " off");
}

unittest { // Undo ladder: preview-only through the whole session; commit happens at deactivate
    resetForCylinder();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);
    auto f = planeFrame();
    assert(approx(sizeAlong(f.normal), 0.0), "base should start flat before height undo test");
    assert(undoLen() == 0, "base construction (BaseSet) is preview-only -- no undo entry yet");

    dragPixels(cx, cy, cx, cy - 100);
    assert(sizeAlong(f.normal) > 0.25, "height drag should create height before undo");
    assert(undoLen() == 0, "height construction (HeightSet) is still preview-only");

    // Live property edits during the session are ALSO preview-only --
    // PrimitiveCreateTool has no per-gesture in-session recording (that is
    // a box.d-specific feature: its own recordInSession/BoxLiveEditCommand
    // machinery, never inherited here). /api/history stays static for the
    // whole session, changing only at deactivate().
    cmd("tool.attr " ~ TOOL ~ " sizeX 2.25");
    assert(approx(qf("sizeX"), 2.25), "sizeX write before drop failed");
    assert(undoLen() == 0, "a live property edit mid-session creates no undo entry");
    cmd("tool.attr " ~ TOOL ~ " sizeY 1.5");
    assert(undoLen() == 0, "further live property edits still create no undo entry");

    // Dropping the tool commits the whole session as exactly one undo entry.
    cmd("tool.set " ~ TOOL ~ " off");
    assert(undoLen() == 1, "drop should collapse the whole live cylinder session into one entry");
    assert(vertCount() > 0, "cylinder drop should commit mesh geometry");
    playCtrlZ();
    assert(undoLen() == 0, "post-drop Ctrl+Z should pop the single cylinder entry");
    assert(vertCount() == 0, "post-drop Ctrl+Z should remove the committed cylinder");
}

unittest { // Mid-session Ctrl+Z cancels the whole edit outright (tool stays armed), even at the bare BaseSet baseline
    resetForCylinder();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);
    auto f = planeFrame();
    assert(approx(sizeAlong(f.normal), 0.0), "first drag should leave a flat base");
    assert(undoLen() == 0, "reaching BaseSet alone should create no undo entry");

    // willCommit() is unconditionally true at BaseSet (a flat disk is
    // already a committable primitive) -- so even here, without ever
    // starting the height drag, a single Ctrl+Z press cancels the whole
    // live edit in one step (PrimitiveCreateTool has no per-gesture
    // in-session recording to peel one step at a time -- see tool.d's
    // hasUncommittedEdit()/cancelUncommittedEdit() and edit_session.d's
    // navigate()). Since task 0430 (keep-alive, reference-measured) the
    // cancel no longer drops the tool: it stays armed for a fresh gesture.
    playCtrlZ();
    assert(activeQueryOk(),
        "Ctrl+Z at the bare BaseSet baseline must cancel the edit but keep " ~ TOOL ~ " armed");
    // A REAL deactivate on the now-live Idle tool: willCommit() is false,
    // so it commits nothing and records nothing.
    cmd("tool.set " ~ TOOL ~ " off");
    assert(undoLen() == 0, "cancelling at BaseSet should leave no history entry");
    assert(vertCount() == 0, "cancelling at BaseSet should leave no pending cylinder to commit");
}

unittest { // Keep-alive composition (task 0430, capture-measured): cancel -> prior history -> fresh gesture
    // The full measured press sequence: with PRIOR committed history and an
    // open create edit, Ctrl+Z #1 cancels ONLY the open edit (the press is
    // consumed by navigate()'s cancel branch: tool armed, prior history
    // untouched); Ctrl+Z #2 steps the prior history on the still-live
    // tool; a fresh drag then opens a new gesture cleanly. One press fewer
    // than the reference's count to prior history -- vibe3d has no
    // tool-state undo records to no-op through (documented press-mapping
    // divergence, task 0430 D2).
    resetForCylinder();

    // Prior history: one full committed cylinder cycle.
    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);
    dragPixels(cx, cy, cx, cy - 100);
    cmd("tool.set " ~ TOOL ~ " off");
    assert(undoLen() == 1, "prior cycle should commit exactly one entry");
    long v1 = vertCount();
    assert(v1 > 0, "prior cycle should commit mesh geometry");

    // Re-arm and open a new uncommitted edit (flat base -- preview-only).
    cmd("tool.set " ~ TOOL);
    dragPixels(cx, cy, cx + 150, cy + 140);
    assert(undoLen() == 1, "an open preview-only edit must not add history entries");

    // Ctrl+Z #1: cancels ONLY the open edit; the tool survives (keep-alive)
    // and prior history / committed geometry are untouched.
    playCtrlZ();
    assert(activeQueryOk(), "Ctrl+Z #1 must keep " ~ TOOL ~ " armed (keep-alive)");
    assert(undoLen() == 1, "Ctrl+Z #1 must not touch prior history");
    assert(vertCount() == v1, "Ctrl+Z #1 must not touch committed geometry");

    // Ctrl+Z #2: no open edit left -> the same navigate() call falls
    // through to a plain history.undo() + resyncSession() on the LIVE tool.
    playCtrlZ();
    assert(activeQueryOk(), "Ctrl+Z #2 must keep " ~ TOOL ~ " armed while stepping history");
    assert(undoLen() == 0, "Ctrl+Z #2 should pop the prior committed entry");
    assert(vertCount() == 0, "Ctrl+Z #2 should remove the prior committed cylinder");

    // Fresh drag: a brand-new BASE gesture. This discriminates a real
    // reset-to-Idle from a leaked BaseSet: had the cancelled session
    // leaked, this same drag would be interpreted as a HEIGHT drag and
    // grow sizeAlong(normal).
    dragPixels(cx, cy, cx + 150, cy + 140);
    auto f = planeFrame();
    assert(approx(sizeAlong(f.normal), 0.0),
        "fresh drag after keep-alive must open a NEW flat base, not extrude the cancelled one");
    assert(qf("sizeX") > 0.25,
        "fresh drag should build a real base (live attr reads on the kept-alive tool)");
    assert(undoLen() == 0, "the fresh gesture is preview-only -- still no history entries");

    // Commit-at-deactivate (task 0414) is intact on the re-gestured session.
    cmd("tool.set " ~ TOOL ~ " off");
    assert(undoLen() == 1, "dropping the re-gestured base should commit exactly one entry");
    assert(vertCount() > 0, "dropping the re-gestured base should commit geometry");
}

unittest { // Winding regression (task 0424): Z-dominant "front" camera must
           // still commit an outward-wound cylinder, matching BoxTool's
           // pre-existing left-handed-frame correction.
    resetForCylinderFrontCam();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);   // Stage 1: flat base ellipse
    dragPixels(cx, cy, cx, cy - 100);          // Stage 2: extrude height
    cmd("tool.set " ~ TOOL ~ " off");

    // Same default sides=24/segments=1 as the Y-camera construction-drag
    // test above -> identical committed topology (48 verts / 26 faces) when
    // the drag succeeds; only the camera differs, isolating the winding
    // regression from any geometry-count divergence.
    assert(vertCount() == 48,
        "front-camera cylinder: expected 48 verts, got " ~ vertCount().to!string);
    assert(faceCount() == 26,
        "front-camera cylinder: expected 26 faces, got " ~ faceCount().to!string);

    auto model = getJson("/api/model");
    Vec3 mc = meshCentroid(model);
    foreach (fi, f; model["faces"].array) {
        Vec3 n  = faceNormal(model, f);
        Vec3 fc = faceCentroid(model, f);
        double d = dotD(n, fc - mc);
        assert(d > 0,
            "face " ~ fi.to!string ~ " normal points INWARD under a Z-dominant "
            ~ "camera (left-handed auto-workplane frame, task 0424): dot="
            ~ d.to!string);
    }
}
