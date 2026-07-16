// Interactive TorusTool regression coverage (task 0414 Phase 0).
//
// Recorded against UNMODIFIED main as the byte-stability oracle for the
// PrimitiveCreateTool base-class extraction (0407 sec A.D2). Torus has its
// own 2-scalar model (majorRadius/minorRadius, not sizeX/Y/Z) and its own
// per-stage math (torus.d), but shares the infra rig (mover/size-handle
// arbiter/idle-snap/commit-snapshot) byte-for-byte with the cylinder
// family -- this test exercises exactly the surface that infra sharing
// could silently break, PLUS the torus-specific handle routing (axis
// handle -> minorRadius, perpendicular handles -> majorRadius, no center
// shift ever -- unlike the cylinder family's anchored-opposite drag).
//
//   1. two-stage construction drag (major loop, then tube thickness),
//      asserting live params after EACH stage and final committed geometry.
//   2. size-handle drag: axis handle grows minorRadius, perpendicular
//      handle grows majorRadius, center NEVER moves (discriminates against
//      an accidental reuse of the cylinder-family's anchored-opposite math).
//   3. mover-handle drag moves the center.
//   4. Tool Properties (tool.attr) round-trip for every param.
//   5. Undo ladder, including the PRAVKA-2 zero-minor-delta commit guard
//      case: a second drag that ends at minorRadius == 0 must NOT commit
//      and must NOT grow the undo stack on drop (this hits the MinorSet
//      arm of willCommit(), which is already false there).
//   6. MajorSet degenerate-minor commit guard (found in review after
//      Phase 5 landed): willCommit() is UNCONDITIONALLY true at MajorSet
//      (its first disjunct never looks at minorRadius), so a live
//      size-handle drag that clamps minorRadius to 0 WITHOUT leaving
//      MajorSet must still not commit a degenerate torus -- a case the
//      zero-minor-delta case above does not exercise (that one reaches
//      MinorSet, where willCommit() itself is false).

import std.conv : to;
import std.json;
import std.math : fabs;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "prim.torus";

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

enum string[3] AXIS_TAG = ["x", "y", "z"];

bool activeQueryOk() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " majorRadius ?");
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

void resetForTorus() {
    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset empty failed: " ~ r.toString);
    cmd("history.clear");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera set failed: " ~ r.toString);
    cmd("tool.set " ~ TOOL);
    // params_ is STICKY across tool.set on/off cycles (/api/reset resets the
    // document, not tool state); the Idle-click handler re-zeroes cen/major/
    // minorRadius on a fresh drag, but NOT majorSegments/minorSegments/axis.
    // Pin those back to their ctor defaults so every unittest block in this
    // file starts from a known baseline.
    cmd("tool.attr " ~ TOOL ~ " majorSegments 24");
    cmd("tool.attr " ~ TOOL ~ " minorSegments 12");
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

unittest { // Two-stage construction drag: major loop, then tube thickness
    resetForTorus();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");

    // Stage 1: DrawingMajor -> MajorSet.
    dragPixels(cx, cy, cx + 150, cy + 140);
    double major0 = qf("majorRadius");
    assert(major0 > 0.1, "major drag should create majorRadius, got " ~ major0.to!string);
    // Mouse-up auto-seeds minorRadius = majorRadius * 0.25 (torus.d:379).
    assert(approx(qf("minorRadius"), major0 * 0.25, 1e-3),
        "MajorSet should auto-seed minorRadius = major*0.25, got " ~ qf("minorRadius").to!string
        ~ " expected " ~ (major0 * 0.25).to!string);

    // Stage 2: DrawingMinor -> MinorSet (thicken the tube).
    dragPixels(cx, cy, cx, cy - 60);
    double minor1 = qf("minorRadius");
    assert(minor1 > 0.0, "minor drag should produce a positive minorRadius, got " ~ minor1.to!string);
    assert(approx(qf("majorRadius"), major0, 1e-3),
        "minor drag must not change majorRadius: before=" ~ major0.to!string
        ~ " after=" ~ qf("majorRadius").to!string);

    // Commit: defaults majorSegments=24 minorSegments=12 were never touched
    // by the drags -> V=F=24*12=288 (matches test_primitive_torus.d's own
    // default-count assertion; the interactive commit calls the same
    // buildTorus(mesh, params_)).
    cmd("tool.set " ~ TOOL ~ " off");
    assert(vertCount() == 288, "committed torus: expected 288 verts, got " ~ vertCount().to!string);
    assert(faceCount() == 288, "committed torus: expected 288 faces, got " ~ faceCount().to!string);
}

unittest { // Size-handle routing: axis handle -> minorRadius, perp handle -> majorRadius, center fixed
    resetForTorus();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);   // DrawingMajor -> MajorSet
    dragPixels(cx, cy, cx, cy - 60);          // DrawingMinor -> MinorSet, tool stays active

    Vec3 c0 = center();
    double major0 = qf("majorRadius");
    double minor0 = qf("minorRadius");

    // The Idle-click sets params_.axis = worldAxisIdxOf(planeNormal) (same
    // as the cylinder family) -- derive it dynamically from the SAME
    // camera-facing pick the tool made, rather than assuming a fixed world
    // axis, so this test is robust to whichever plane the camera picked.
    auto f = planeFrame();
    int axisIdx = f.normal.x > 0.5f ? 0 : (f.normal.y > 0.5f ? 1 : 2);
    assert(qs("axis") == AXIS_TAG[axisIdx],
        "torus should auto-set axis from the construction-plane normal, got "
        ~ qs("axis") ~ " expected " ~ AXIS_TAG[axisIdx]);

    // The axis-aligned handle sits at cen + normal*minorRadius -- drives
    // minorRadius, NOT majorRadius.
    dragWorldHandle(c0 + f.normal * cast(float)minor0, f.normal);
    assert(qf("minorRadius") > minor0 + 0.02,
        "axis handle should grow minorRadius: before=" ~ minor0.to!string
        ~ " after=" ~ qf("minorRadius").to!string);
    assert(approx(qf("majorRadius"), major0, 1e-3),
        "axis handle must not change majorRadius");
    Vec3 c1 = center();
    assert(approx(c1.x, c0.x) && approx(c1.y, c0.y) && approx(c1.z, c0.z),
        "torus handle drag must never shift the center (no anchored-opposite for torus)");

    // A perpendicular handle sits at cen + axis1*(majorRadius+minorRadius)
    // -- drives majorRadius.
    double minor1 = qf("minorRadius");
    Vec3 c2 = center();
    dragWorldHandle(c2 + f.axis1 * cast(float)(major0 + minor1), f.axis1);
    assert(qf("majorRadius") > major0 + 0.02,
        "perpendicular handle should grow majorRadius: before=" ~ major0.to!string
        ~ " after=" ~ qf("majorRadius").to!string);
    assert(approx(qf("minorRadius"), minor1, 1e-3),
        "perpendicular handle must not change minorRadius");
    Vec3 c3 = center();
    assert(approx(c3.x, c2.x) && approx(c3.y, c2.y) && approx(c3.z, c2.z),
        "torus perpendicular handle drag must never shift the center either");

    // Mover handle: drag along an in-plane construction axis, center follows.
    Vec3 c4 = center();
    double cAxis0 = centerAlong(f.axis1);
    dragWorldHandle(c4, f.axis1);
    double cAxis1 = centerAlong(f.axis1);
    assert(cAxis1 > cAxis0 + 0.05,
        "mover handle should move the center along axis1: before=" ~ cAxis0.to!string
        ~ " after=" ~ cAxis1.to!string);

    cmd("tool.set " ~ TOOL ~ " off");
}

unittest { // Tool Properties (tool.attr) round-trip for every param
    resetForTorus();
    cmd("tool.attr " ~ TOOL ~ " cenX 1.25");
    cmd("tool.attr " ~ TOOL ~ " cenY 0.75");
    cmd("tool.attr " ~ TOOL ~ " cenZ -0.5");
    cmd("tool.attr " ~ TOOL ~ " majorRadius 2.0");
    cmd("tool.attr " ~ TOOL ~ " minorRadius 0.4");
    cmd("tool.attr " ~ TOOL ~ " majorSegments 10");
    cmd("tool.attr " ~ TOOL ~ " minorSegments 6");
    cmd("tool.attr " ~ TOOL ~ " axis 0");
    assert(approx(qf("cenX"), 1.25), "cenX panel write failed");
    assert(approx(qf("cenY"), 0.75), "cenY panel write failed");
    assert(approx(qf("cenZ"), -0.5), "cenZ panel write failed");
    assert(approx(qf("majorRadius"), 2.0), "majorRadius panel write failed");
    assert(approx(qf("minorRadius"), 0.4), "minorRadius panel write failed");
    assert(qi("majorSegments") == 10, "majorSegments panel write failed");
    assert(qi("minorSegments") == 6, "minorSegments panel write failed");
    assert(qs("axis") == "x", "axis panel write failed, got " ~ qs("axis"));
    cmd("tool.set " ~ TOOL ~ " off");
}

unittest { // Undo ladder including the zero-minor-delta commit guard (PRAVKA 2 gate)
    resetForTorus();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);      // DrawingMajor -> MajorSet baseline
    double major0 = qf("majorRadius");
    double seededMinor = qf("minorRadius");

    dragPixels(cx, cy, cx, cy - 60);             // DrawingMinor -> MinorSet
    assert(undoLen() == 1, "minor-thickness construction should create one live undo step");
    playCtrlZ();
    assert(approx(qf("minorRadius"), seededMinor, 1e-3),
        "Ctrl+Z after minor-thickness creation should return to the MajorSet-seeded minorRadius");
    assert(undoLen() == 0, "minor-thickness undo should pop its live entry");

    // Second Ctrl+Z (from the MajorSet baseline) cancels the whole tool --
    // there is no earlier live entry to peel.
    playCtrlZ();
    assert(!activeQueryOk(), "second Ctrl+Z should also deactivate " ~ TOOL);
    cmd("tool.set " ~ TOOL ~ " off");
    assert(undoLen() == 0, "cancelled torus tool should leave no history entry");
    assert(vertCount() == 0, "cancelled torus tool should leave no pending geometry");

    // PRAVKA 2 gate: a second drag that lands EXACTLY back at minorRadius==0
    // (a zero-delta drag on the height plane) must NOT commit on drop and
    // must NOT create an undo entry. This lands in MinorSet with
    // willCommit()==false (the MinorSet arm requires minorRadius>1e-5),
    // so commitValid() is trivially false too (short-circuits on
    // willCommit()) -- both the geometry gate AND the snapshot/record
    // skeleton skip here, matching the pre-refactor commitTorus() call
    // guard never firing at all for this state. Contrast with the
    // "MajorSet degenerate-minor commit guard" unittest below, where
    // willCommit()==true (unconditional at MajorSet) but commitValid()
    // is false -- a genuinely different code path this case does NOT
    // exercise (a post-review fix; see that unittest's comment).
    resetForTorus();
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);      // MajorSet
    // Click to enter DrawingMinor, then release at the SAME pixel (zero
    // motion) so the height-plane projection stays at signedH == 0.
    dragPixels(cx, cy, cx, cy, 1);
    assert(approx(qf("minorRadius"), 0.0, 1e-4),
        "zero-motion minor drag should leave minorRadius at 0, got " ~ qf("minorRadius").to!string);
    size_t preDropUndo = undoLen();
    cmd("tool.set " ~ TOOL ~ " off");
    assert(undoLen() == preDropUndo,
        "dropping with minorRadius==0 must not create a new undo entry (no-commit)");
    assert(vertCount() == 0,
        "dropping with minorRadius==0 must not add any geometry to the scene");
}

unittest { // MajorSet degenerate-minor commit guard (review fix: commitValid() vs willCommit())
    // Discriminates the case the zero-minor-delta case above does NOT
    // cover. That one lands in MinorSet, where willCommit() itself is
    // false (net-safe regardless of any internal-guard bug). THIS case
    // stays in MajorSet, where willCommit() is TRUE UNCONDITIONALLY (its
    // first disjunct never looks at minorRadius) -- and drives minorRadius
    // to exactly 0 via a live size-handle drag (handle drags never touch
    // `state`, so the tool stays in MajorSet throughout).
    //
    // Pre-refactor commitTorus() had its own internal guard
    // (`if majorRadius<1e-5||minorRadius<1e-5 return;`, old torus.d:583)
    // that caught this. A naive fold that gated appendBuildInto() on
    // willCommit() alone would NOT -- buildTorus clamps degenerate radii
    // rather than rejecting (R floors to 1e-6, r floors to R*1e-4), so it
    // would silently commit a thin 288-vert torus here. commitValid()
    // (willCommit() && majorRadius>1e-5 && minorRadius>1e-5) restores the
    // exact pre-refactor guard -- see primitive_create_tool.d's
    // commitValid() doc and torus.d's override for the full derivation.
    //
    // Undo semantics (verified against a live instance, not assumed): the
    // per-gesture "live in-session" undo-entry mechanism visible in
    // box_interactive.d's own Undo-ladder test is a box.d-specific feature
    // (its own recordInSession/BoxLiveEditCommand machinery) that
    // PrimitiveCreateTool never inherited -- /api/history stays completely
    // static (undo:[]) for the WHOLE torus session below, construction and
    // handle-drags alike, changing only at deactivate(). At MajorSet,
    // willCommit()==true unconditionally, so deactivate()'s snapshot/record
    // skeleton still runs even though commitValid()==false skips
    // appendBuildInto() -- this records exactly ONE empty (pre==post)
    // entry, matching commitTorus() having been CALLED pre-refactor (its
    // internal guard just made it a no-op) rather than never called at
    // all. This is a genuinely different outcome from the zero-minor-delta
    // case above (no entry at all, since willCommit() itself is false
    // there) -- do not conflate the two.
    resetForTorus();

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 150, cy + 140);      // Idle -> MajorSet
    double major0 = qf("majorRadius");
    assert(major0 > 0.1, "major drag should create a healthy majorRadius");
    assert(undoLen() == 0, "reaching MajorSet alone should not create any undo entry");

    // Drag the axis-aligned (tube-thickness) size handle fully inward so
    // applySizeDelta's zero-floor clamp lands minorRadius at exactly 0,
    // all while staying in MajorSet (grabbing/releasing a handle never
    // touches `state`). -3000px vastly overshoots any reachable
    // minorRadius at this camera distance, guaranteeing the clamp fires
    // rather than merely shrinking the value.
    auto f = planeFrame();
    Vec3 cen = center();
    double minorBefore = qf("minorRadius");
    assert(minorBefore > 0.0, "MajorSet should auto-seed a positive minorRadius");
    dragWorldHandle(cen + f.normal * cast(float)minorBefore, f.normal, -3000.0);
    assert(approx(qf("minorRadius"), 0.0, 1e-4),
        "dragging the axis handle fully inward should clamp minorRadius to 0, got "
        ~ qf("minorRadius").to!string);
    assert(approx(qf("majorRadius"), major0, 1e-3),
        "the axis-handle drag must not have touched majorRadius");
    assert(undoLen() == 0,
        "a mouse-driven handle drag must not create any mid-session undo entry either "
        ~ "(PrimitiveCreateTool has no per-gesture in-session recording)");

    // Still in MajorSet (handle drags never change state) -> willCommit()
    // is unconditionally true here, so dropping runs the snapshot/record
    // skeleton (one empty entry, matching commitTorus() being CALLED
    // pre-refactor) while commitValid()==false skips appendBuildInto()
    // (matching commitTorus()'s internal early return) -- no geometry.
    cmd("tool.set " ~ TOOL ~ " off");
    assert(vertCount() == 0,
        "dropping at MajorSet with minorRadius==0 must not add any geometry to the scene "
        ~ "(buildTorus clamps degenerate radii rather than rejecting -- this is exactly the "
        ~ "case the pre-refactor commitTorus() internal guard existed to catch)");
    assert(undoLen() == 1,
        "willCommit()==true at MajorSet means the snapshot/record skeleton still runs even "
        ~ "though commitValid()==false skipped appendBuildInto() -- this records exactly one "
        ~ "empty (pre==post) entry, matching commitTorus() being CALLED pre-refactor (and "
        ~ "internally no-opping) rather than never being called at all");

    // The recorded entry must be a genuine no-op: undoing it must not
    // "destroy" a torus, it must simply leave the (already-empty) scene
    // exactly as it was.
    playCtrlZ();
    assert(vertCount() == 0, "undoing the empty degenerate-commit entry must reveal no torus");
    assert(undoLen() == 0, "the empty entry must pop cleanly like any other undo step");
}
