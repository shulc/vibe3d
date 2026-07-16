// Interactive SphereTool regression coverage (task 0414 Phase 0).
//
// Recorded against UNMODIFIED main as the byte-stability oracle for the
// PrimitiveCreateTool base-class extraction (0407 sec A.D2). Sphere shares
// the cylinder family's 5-stage machine + sizeX/Y/Z model, but the task's
// own code-diff survey (Sec 1a of the plan) flags THREE real divergences
// from the cylinder-family's onMouse*/handle body that a careless reuse of
// the shared mid-layer would silently erase:
//   (a) the Idle-click does NOT set params_.axis from the construction
//       plane normal (sphere.d:788-792) -- axis stays at its sticky value.
//   (b) the DrawingHeight non-uniform second-drag branch keeps the CENTER
//       FIXED at baseAnchor and writes the FULL |signedH| as the radius --
//       unlike the cylinder family's box-style anchored-opposite drag
//       (center shifts, radius = signedH/2). This divergence is NOT listed
//       in the plan's Phase-5 override table (only applySizeDelta and
//       worldSize/setWorldSize are) -- tracing sphere.d:973-992 against
//       cylinder.d:580-604 side by side confirms it is real, so this test
//       makes it an explicit, executable assertion for whoever lands
//       Phase 5.
//   (c) the radius-handle drag (applyRadiusDelta, sphere.d:1317-1327) is
//       SYMMETRIC around a fixed center (no anchored-opposite, no
//       flip-through) -- this one IS in the plan's override table.
// This test also confirms the volumetric-vs-flat preview gate's DOWNSTREAM
// effect (final committed vertex/face counts match the Globe builder
// exactly, same numbers test_primitive_sphere.d's headless path asserts).
//
// Post-Phase-0 correction (still against the SAME oracle -- unmodified
// main reproduces the pre-fix symptom identically, confirmed by live
// probing, so this was a hand-trace bug in how Stage 2 clicks, not a
// 0414 regression): Stage 2's mousedown must not land exactly on Stage
// 1's own click point, or it silently grabs a degenerate zero-height
// size handle instead of starting the height drag. See dragHeightStage()
// below for the full mechanism and task 0414's log for how it was traced
// (live server probing via tests/drag_helpers.d against a `run_test.d
// --keep`-held instance, comparing screen-projected handle positions
// against the click point).

import std.conv : to;
import std.json;
import std.math : fabs;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "prim.sphere";

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

// IntEnum params (axis, method) read back as their wire-tag STRING
// (params.d paramToJson), even though writes also accept a raw integer.
string qs(string attr) {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query " ~ attr ~ " failed: " ~ r.toString);
    return r["value"].str;
}

enum string[3] AXIS_TAG = ["x", "y", "z"];

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

double sizeAlong(Vec3 axis) {
    if (fabs(axis.x) > 0.5f) return qf("sizeX");
    if (fabs(axis.y) > 0.5f) return qf("sizeY");
    return qf("sizeZ");
}

Vec3 center() {
    return Vec3(cast(float)qf("cenX"), cast(float)qf("cenY"), cast(float)qf("cenZ"));
}

double centerAlong(Vec3 axis) { return dotD(center(), axis); }

void resetForSphere() {
    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset empty failed: " ~ r.toString);
    cmd("history.clear");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera set failed: " ~ r.toString);
    cmd("tool.set " ~ TOOL);
    // params_ is STICKY across tool.set on/off cycles (/api/reset resets the
    // document, not tool state); the Idle-click handler re-zeroes cen/sizeX/
    // Y/Z on a fresh drag, but NOT method/sides/segments/axis/order. Pin
    // those back to their ctor defaults so every unittest block in this file
    // starts from a known baseline -- AND so this test's axis-independence
    // assertions (divergence (a)) are meaningful (axis must read "y" no
    // matter which plane the camera auto-picked).
    cmd("tool.attr " ~ TOOL ~ " method 0");
    cmd("tool.attr " ~ TOOL ~ " sides 24");
    cmd("tool.attr " ~ TOOL ~ " segments 24");
    cmd("tool.attr " ~ TOOL ~ " axis 1");
    cmd("tool.attr " ~ TOOL ~ " order 2");
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

// Stage 2 (BaseSet -> DrawingHeight) must NOT click exactly at (cx, cy).
// After Stage 1 the disc's plane-normal-axis size is EXACTLY 0, so
// updateSizeHandlers() places that axis's size-handle PAIR (and the
// mover's centerBox) at the disc's own center -- i.e. exactly (cx, cy),
// since Stage 1's flat ellipse is centered on its own click point (the
// world origin, per projectOrDie below). onMouseButtonDown's
// `state >= BaseSet` branch tries tryGrabHandles() BEFORE the
// state==BaseSet branch that starts the real height drag -- a mousedown
// dead-center on that degenerate (sub-pixel) handle silently grabs it
// instead of transitioning to DrawingHeight, so `state` never leaves
// BaseSet. This is invisible for cylinder/cone/capsule (buildInto is a
// pure function of sizeX/Y/Z there, so a stray handle-grab that still
// raises the matching axis produces identical final geometry) but NOT
// for sphere, whose buildInto is gated on isVolumetricEligible()
// (state >= DrawingHeight || dragUniform): a state stuck at BaseSet means
// deactivate() commits the flat n-gon branch instead of buildByMethod().
// Confirmed empirically (live server probing) against BOTH this branch
// and unmodified main -- same click sequence produces the same wrong
// flat 24-vert/1-face commit on both, so this was a Phase-0
// test-authorship bug (the interactive tests were hand-traced without
// ever running, see the task's Phase-0 log), not a 0414 regression. A
// small clearance in a direction empirically clear of the mover's own
// arrow-shaft hit-boxes (-X measured safe; +X and -Y graze arrowX's /
// arrowY's pick geometry) is enough, since the degenerate handle's own
// screen hit-box is sub-pixel.
void dragHeightStage(int cx, int cy, int dy = 100) {
    dragPixels(cx - 15, cy, cx - 15, cy - dy);
}

unittest { // Two-stage construction drag + the two Idle/DrawingHeight divergences
    resetForSphere();

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

    // Divergence (a): unlike cylinder/cone/capsule/torus/tube, sphere's
    // Idle-click does NOT auto-set axis from the construction plane normal
    // (alignAxisOnFirstClick is a documented no-op override) -- axis must
    // stay at "y" (pinned in resetForSphere) regardless of which plane the
    // camera picked.
    assert(qs("axis") == "y",
        "sphere must NOT auto-set axis from the construction plane, got " ~ qs("axis"));

    Vec3 centerAfterStage1 = center();

    // Stage 2: DrawingHeight -> HeightSet (extrude the ellipse into a sphere).
    // See dragHeightStage()'s doc comment for why this must NOT click at
    // (cx, cy) itself.
    dragHeightStage(cx, cy);
    double h1 = sizeAlong(f.normal);
    assert(h1 > 0.25, "height drag should create normal-axis radius, got " ~ h1.to!string);

    // Divergence (b): the DrawingHeight branch keeps the center FIXED at the
    // stage-1 anchor -- unlike the cylinder family's anchored-opposite drag,
    // which shifts the center by half the height delta. This is the key
    // discriminator against an incorrect Phase-5 reuse of the shared
    // mid-layer's onMouseMotion body.
    Vec3 centerAfterStage2 = center();
    assert(approx(centerAfterStage2.x, centerAfterStage1.x, 1e-3)
        && approx(centerAfterStage2.y, centerAfterStage1.y, 1e-3)
        && approx(centerAfterStage2.z, centerAfterStage1.z, 1e-3),
        "sphere's second (height) drag must NOT move the center: before="
        ~ centerAfterStage1.x.to!string ~ "," ~ centerAfterStage1.y.to!string ~ ","
        ~ centerAfterStage1.z.to!string ~ " after=" ~ centerAfterStage2.x.to!string ~ ","
        ~ centerAfterStage2.y.to!string ~ "," ~ centerAfterStage2.z.to!string);

    // Commit: defaults sides=24 segments=24 method=globe were pinned by
    // resetForSphere and never touched by the drags -> Globe topology
    // verts=(N-1)*S+2=554, faces=N*S=576 (matches test_primitive_sphere.d's
    // own default-count assertion; the interactive commit path calls the
    // same buildSphereGlobe(mesh, params_) via buildByMethod).
    cmd("tool.set " ~ TOOL ~ " off");
    assert(vertCount() == 554, "committed sphere: expected 554 verts, got " ~ vertCount().to!string);
    assert(faceCount() == 576, "committed sphere: expected 576 faces, got " ~ faceCount().to!string);
}

unittest { // Radius-handle drag is SYMMETRIC (no anchored-opposite) + mover moves center
    resetForSphere();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);
    dragHeightStage(cx, cy);   // BaseSet -> HeightSet, tool stays active

    // axis stays "y" (divergence (a)) so worldAxisToOrig is the identity
    // permutation -- radius handles sit at fixed WORLD +-X/+-Y/+-Z, same as
    // the cylinder family's SIZE_AXES.
    Vec3 c0 = center();
    double sx0 = qf("sizeX");
    dragWorldHandle(Vec3(c0.x + cast(float)sx0, c0.y, c0.z), Vec3(1, 0, 0));
    double sx1 = qf("sizeX");
    assert(sx1 > sx0 + 0.05,
        "+X radius handle should grow sizeX: before=" ~ sx0.to!string ~ " after=" ~ sx1.to!string);

    // Divergence (c): applyRadiusDelta is symmetric -- the center must NOT
    // move at all (contrast with cylinder's anchored-opposite drag, which
    // shifts cenX by exactly the size growth).
    Vec3 c1 = center();
    assert(approx(c1.x, c0.x, 1e-3) && approx(c1.y, c0.y, 1e-3) && approx(c1.z, c0.z, 1e-3),
        "sphere radius-handle drag must never shift the center: before="
        ~ c0.x.to!string ~ "," ~ c0.y.to!string ~ "," ~ c0.z.to!string
        ~ " after=" ~ c1.x.to!string ~ "," ~ c1.y.to!string ~ "," ~ c1.z.to!string);

    // Mover handle: drag along an in-plane construction axis, center follows.
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
    resetForSphere();
    // cen/size/sides/segments/order first -- axis is written and verified
    // SEPARATELY below, since writing it triggers onParamChanged("axis")'s
    // world-extent-preserving re-permutation of sizeX/Y/Z (sphere.d:674-693)
    // and would invalidate a naive "still equals what I wrote" check on them.
    cmd("tool.attr " ~ TOOL ~ " cenX 1.25");
    cmd("tool.attr " ~ TOOL ~ " cenY 0.75");
    cmd("tool.attr " ~ TOOL ~ " cenZ -0.5");
    cmd("tool.attr " ~ TOOL ~ " sizeX 2.0");
    cmd("tool.attr " ~ TOOL ~ " sizeY 1.5");
    cmd("tool.attr " ~ TOOL ~ " sizeZ 1.25");
    cmd("tool.attr " ~ TOOL ~ " sides 8");
    cmd("tool.attr " ~ TOOL ~ " segments 10");
    cmd("tool.attr " ~ TOOL ~ " order 3");
    assert(approx(qf("cenX"), 1.25), "cenX panel write failed");
    assert(approx(qf("cenY"), 0.75), "cenY panel write failed");
    assert(approx(qf("cenZ"), -0.5), "cenZ panel write failed");
    assert(approx(qf("sizeX"), 2.0), "sizeX panel write failed");
    assert(approx(qf("sizeY"), 1.5), "sizeY panel write failed");
    assert(approx(qf("sizeZ"), 1.25), "sizeZ panel write failed");
    assert(qi("sides") == 8, "sides panel write failed");
    assert(qi("segments") == 10, "segments panel write failed");
    assert(qi("order") == 3, "order panel write failed");

    cmd("tool.attr " ~ TOOL ~ " axis 2");
    assert(qs("axis") == "z", "axis panel write failed, got " ~ qs("axis"));

    cmd("tool.attr " ~ TOOL ~ " method 1");
    assert(qs("method") == "qball", "method panel write failed, got " ~ qs("method"));
    cmd("tool.attr " ~ TOOL ~ " method 0");
    assert(qs("method") == "globe", "method panel write-back failed, got " ~ qs("method"));

    cmd("tool.set " ~ TOOL ~ " off");
}

unittest { // Undo ladder: preview-only through the whole session; commit happens at deactivate
    resetForSphere();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);
    auto f = planeFrame();
    assert(approx(sizeAlong(f.normal), 0.0), "base should start flat before height undo test");
    assert(undoLen() == 0, "base construction (BaseSet) is preview-only -- no undo entry yet");

    dragHeightStage(cx, cy);
    assert(sizeAlong(f.normal) > 0.25, "height drag should create height before undo");
    assert(undoLen() == 0, "height construction (HeightSet) is still preview-only");

    // Live property edits during the session are ALSO preview-only --
    // PrimitiveCreateTool has no per-gesture in-session recording (that is
    // a box.d-specific feature: its own recordInSession/BoxLiveEditCommand
    // machinery, never inherited here -- and SphereTool's own overrides,
    // task 0414 Phase 5, only touch the geometry math, not undo timing).
    // /api/history stays static for the whole session, changing only at
    // deactivate().
    cmd("tool.attr " ~ TOOL ~ " sizeX 2.25");
    assert(approx(qf("sizeX"), 2.25), "sizeX write before drop failed");
    assert(undoLen() == 0, "a live property edit mid-session creates no undo entry");
    cmd("tool.attr " ~ TOOL ~ " sizeY 1.5");
    assert(undoLen() == 0, "further live property edits still create no undo entry");

    // Dropping the tool commits the whole session as exactly one undo entry.
    cmd("tool.set " ~ TOOL ~ " off");
    assert(undoLen() == 1, "drop should collapse the whole live sphere session into one entry");
    assert(vertCount() > 0, "sphere drop should commit mesh geometry");
    playCtrlZ();
    assert(undoLen() == 0, "post-drop Ctrl+Z should pop the single sphere entry");
    assert(vertCount() == 0, "post-drop Ctrl+Z should remove the committed sphere");
}

unittest { // Mid-session Ctrl+Z cancels outright, even at the bare BaseSet baseline
    resetForSphere();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);
    auto f = planeFrame();
    assert(approx(sizeAlong(f.normal), 0.0), "first drag should leave a flat base");
    assert(undoLen() == 0, "reaching BaseSet alone should create no undo entry");

    // willCommit() is unconditionally true at BaseSet (a flat disk is
    // already a committable primitive) -- so even here, without ever
    // starting the height drag, a single Ctrl+Z press cancels the WHOLE
    // tool (PrimitiveCreateTool has no per-gesture in-session recording to
    // peel one step at a time -- see tool.d's hasUncommittedEdit()/
    // cancelUncommittedEdit() and app.d's navHistory()).
    playCtrlZ();
    assert(!activeQueryOk(), "Ctrl+Z at the bare BaseSet baseline should deactivate " ~ TOOL);
    cmd("tool.set " ~ TOOL ~ " off");
    assert(undoLen() == 0, "cancelling at BaseSet should leave no history entry");
    assert(vertCount() == 0, "cancelling at BaseSet should leave no pending sphere to commit");
}
