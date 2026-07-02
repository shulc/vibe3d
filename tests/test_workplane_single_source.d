// Workplane single-source refactor (task 0189) — coverage that isn't
// already pinned by test_commands_workplane.d / test_acen_auto_relocate.d /
// test_primitive_box_interactive.d:
//
//   A. Headless no-pipe: currentWorkplaneFrame() returns the world-XZ
//      default (the one fallback identity).
//   B. Non-auto: currentWorkplaneFrame() reads the live WorkplaneStage
//      basis + center through the stage-owned accessor (no g_pipeCtx-side
//      identity block left to diverge from it) — and tracks a live edit.
//   C. Non-auto mover center-drag (dragAxis==3) lies ON the construction
//      plane — the intentional, fixtured behaviour change of Phase 4.
//      Camera is deliberately placed so the OLD per-drag derivation would
//      have picked the workplane axis1 instead of the workplane normal
//      (the adversarial case the fix closes).
//   D. Same invariant in AUTO mode, where the precomputed normal and the
//      per-drag derivation are provably the same value by construction —
//      a lightweight "still holds" companion to the existing (unmodified)
//      auto-mode center-drag sub-test in test_primitive_box_interactive.d.
//   E. Box's per-branch SIGN survives the mostFacingAxis extraction: two
//      antipodal cameras (through the same focus, along the same rotated
//      workplane axis1 direction) must commit ANTIPARALLEL base-polygon
//      normals, each still facing its own camera.
//
// A/B are pure-D (no running vibe3d, mirrors test_xform_matrix_kernel.d).
// C/D/E drive the real HTTP API against `vibe3d --test`, duplicating the
// small subset of test_primitive_box_interactive.d's helpers needed here
// (not importing that file, so this binary doesn't also pull its own
// unittests in — see test_acen_auto_relocate.d for the same convention).

import std.math    : PI, cos, sin, sqrt, fabs;
import std.json;
import std.format  : format;
import std.conv    : to;
import std.net.curl : get, post;

// Top-level (column-0) imports of these three project modules — beyond
// pulling the symbols, this is what flags this binary as "source-backed"
// to run_test.d's compile-mode detector (isSourceBackedTest scans for a
// leading `import toolpipe.`/`tools.` line), so it gets linked against the
// full project instead of the bare-path std-only compile line.
import tools.create_common       : currentWorkplaneFrame;
import toolpipe.pipeline         : g_pipeCtx, ToolPipeContext;
import toolpipe.stages.workplane : WorkplaneStage;

import M = math;

void main() {}

// ---------------------------------------------------------------------------
// A / B — pure-D, no HTTP, no running vibe3d.
// ---------------------------------------------------------------------------

private bool approxV(M.Vec3 a, M.Vec3 b, float eps = 1e-5f) {
    return fabs(a.x - b.x) < eps && fabs(a.y - b.y) < eps && fabs(a.z - b.z) < eps;
}

unittest { // A: headless no-pipe -> world-XZ default
    g_pipeCtx = null;   // this process never runs app.d's init — defensive
    auto f = currentWorkplaneFrame();
    assert(f.isAuto, "no-pipe frame must report isAuto=true");
    assert(approxV(f.normal, M.Vec3(0, 1, 0)), "no-pipe normal should be +Y");
    assert(approxV(f.axis1,  M.Vec3(1, 0, 0)), "no-pipe axis1 should be +X");
    assert(approxV(f.axis2,  M.Vec3(0, 0, 1)), "no-pipe axis2 should be +Z");
    assert(approxV(f.origin, M.Vec3(0, 0, 0)), "no-pipe origin should be 0");
}

unittest { // B: non-auto -> stage's live basis + center, via the stage accessor
    scope(exit) g_pipeCtx = null;   // don't leak into any later unittest

    auto ctx = new ToolPipeContext();
    auto wp  = new WorkplaneStage();
    // Add FIRST: pipeline.add -> plug() calls op.reset(), which returns a
    // freshly-plugged stage to auto. Configure AFTER add (the production
    // contract — stages are registered once, then driven via commands), so
    // the mode survives; this also exercises the live-read the accessor
    // promises (a post-add edit is visible with no re-add).
    ctx.pipeline.add(wp);
    g_pipeCtx = ctx;
    bool ok  = wp.setAttr("mode", "worldX");   // isAuto=false, rotation=(0,0,-90)
    assert(ok, "setAttr mode worldX should be accepted");

    auto f = currentWorkplaneFrame();
    M.Vec3 en, ea1, ea2;
    wp.currentBasis(en, ea1, ea2);

    assert(!f.isAuto, "worldX must report isAuto=false");
    assert(approxV(f.normal, en),  "frame.normal must equal the stage's live basis");
    assert(approxV(f.axis1,  ea1), "frame.axis1 must equal the stage's live basis");
    assert(approxV(f.axis2,  ea2), "frame.axis2 must equal the stage's live basis");
    assert(approxV(f.origin, wp.center), "frame.origin must equal the stage's center");

    // A second edit (offset) must be visible immediately — proves the
    // accessor reads LIVE state, not a value captured at add()-time.
    wp.offsetBy(0, 0.7f);
    auto f2 = currentWorkplaneFrame();
    assert(approxV(f2.origin, M.Vec3(0.7f, 0, 0)),
        "frame.origin must track a live stage edit");
}

// ---------------------------------------------------------------------------
// C / D / E — HTTP-driven, against a running `vibe3d --test`.
// ---------------------------------------------------------------------------

import drag_helpers;   // Vec3/Viewport/dot/cross/normalize + drag/projection helpers

enum string BASE = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(BASE ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(BASE ~ path, body_));
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

Vec3 localCenter() {
    return Vec3(cast(float)qf("cenX"), cast(float)qf("cenY"), cast(float)qf("cenZ"));
}

long vertCount() { return getJson("/api/model")["vertexCount"].integer; }
long faceCount() { return getJson("/api/model")["faceCount"].integer; }

Vec3 vertexAt(JSONValue model, size_t index) {
    auto v = model["vertices"].array[index].array;
    return Vec3(cast(float)v[0].floating, cast(float)v[1].floating, cast(float)v[2].floating);
}

Vec3 committedFaceNormal(long faceIndex) {
    auto m = getJson("/api/model");
    auto f = m["faces"].array[faceIndex].array;
    assert(f.length >= 3, "face must have at least 3 vertices");
    auto v0 = vertexAt(m, cast(size_t)f[0].integer);
    auto v1 = vertexAt(m, cast(size_t)f[1].integer);
    auto v2 = vertexAt(m, cast(size_t)f[2].integer);
    return cross(v1 - v0, v2 - v0);
}

void dragPixels(int x0, int y0, int x1, int y1, int steps = 16) {
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, steps), BASE);
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(120));
}

void projectOrDie(Vec3 p, out int x, out int y, string label) {
    auto vp = viewportFromCamera(fetchCamera(BASE));
    float fx, fy;
    assert(projectToWindow(p, vp, fx, fy), label ~ " projects behind camera");
    x = cast(int)fx;
    y = cast(int)fy;
}

float vlen(Vec3 v) { return sqrt(v.x*v.x + v.y*v.y + v.z*v.z); }

string fd(double v) { return format("%.6f", v); }

// -------------------------------------------------------------------------
// C — non-auto mover center-drag lies ON the construction plane.
// -------------------------------------------------------------------------
//
// Shared rotated-workplane setup (also used by E): rotZ=35 deg, a non-
// origin center, and a camera placed exactly along the rotated frame's
// axis1 direction (elevation angle == rotation angle) — the adversarial
// camera for which the OLD per-drag derivation (mostFacingAxis over
// axis1/normal/axis2) would have picked axis1, not the workplane normal.
// `azOffset`/`elSign` let a caller place the SAME camera at the antipodal
// point through the focus (az+PI, el negated) — used by E to flip the
// sign of dot(camBack, axis1) while keeping axis1 equally dominant.

enum double kRotDeg = 35.0;
enum double kRotRad = kRotDeg * PI / 180.0;
enum Vec3 kWpCenter = Vec3(0.35f, -0.20f, 0.15f);

// World image of a LOCAL workplane-space point for the rotZ=kRotDeg frame
// (axis1=(cos,sin,0), normal=(-sin,cos,0), axis2=(0,0,1), origin=kWpCenter).
Vec3 rotatedWpToWorld(Vec3 local) {
    Vec3 axis1  = Vec3(cast(float)cos(kRotRad), cast(float)sin(kRotRad), 0.0f);
    Vec3 normal = Vec3(cast(float)(-sin(kRotRad)), cast(float)cos(kRotRad), 0.0f);
    Vec3 axis2  = Vec3(0, 0, 1);
    return kWpCenter + axis1 * local.x + normal * local.y + axis2 * local.z;
}

void resetRotatedWorkplaneBox(double azOffset, double elSign) {
    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset empty failed: " ~ r.toString);
    cmd("history.clear");

    double az = PI / 2.0 + azOffset;
    double el = elSign * kRotRad;

    auto cam = postJson("/api/camera",
        `{"azimuth":` ~ fd(az) ~ `,"elevation":` ~ fd(el) ~ `,"distance":4.0,`
        ~ `"focus":{"x":` ~ fd(kWpCenter.x)
        ~ `,"y":` ~ fd(kWpCenter.y)
        ~ `,"z":` ~ fd(kWpCenter.z) ~ `}}`);
    assert(cam["status"].str == "ok", "camera set failed: " ~ cam.toString);

    cmd("workplane.edit cenX:" ~ fd(kWpCenter.x)
        ~ " cenY:" ~ fd(kWpCenter.y)
        ~ " cenZ:" ~ fd(kWpCenter.z)
        ~ " rotX:0 rotY:0 rotZ:" ~ fd(kRotDeg));
    cmd("tool.set prim.cube");
}

unittest { // C: non-auto mover center-drag stays on the workplane plane
    resetRotatedWorkplaneBox(0.0, 1.0);   // az=PI/2, el=+kRotRad

    // A base-only drag already activates the mover (BoxState.BaseSet), but
    // at that point the box has zero height, so the bottom height handle
    // (heightH[0], positioned at the base centroid) sits at EXACTLY the
    // same world point as the mover's centerBox (also the base centroid).
    // onMouseButtonDown checks height handles before the mover (see
    // box.d's "Height handles ... priority over mover centerBox" —
    // pre-existing, unrelated to this task), so a click dead-center at
    // this stage would grab the height handle instead of the mover and
    // exercise a completely different (height-axis) drag. Establish a
    // throwaway non-zero height first so the mover's centerBox is no
    // longer coincident with either height handle, THEN click the
    // (recomputed) center to genuinely hit dragAxis==3.
    int cx, cy;
    projectOrDie(kWpCenter, cx, cy, "rotated workplane center");
    dragPixels(cx, cy, cx + 100, cy + 90);

    int dcx, dcy;
    projectOrDie(rotatedWpToWorld(localCenter()), dcx, dcy, "base centroid (height decouple)");
    dragPixels(dcx, dcy, dcx + 40, dcy - 40, 8);

    Vec3 normal = Vec3(cast(float)(-sin(kRotRad)), cast(float)cos(kRotRad), 0.0f);

    // Click at the mover's WORLD center (mover.centerBox is checked before
    // the arrows in moverHitTest, so a click dead-center hits dragAxis==3)
    // and drag by an arbitrary screen offset unrelated to any workplane axis.
    Vec3 worldBefore = rotatedWpToWorld(localCenter());
    int hx, hy;
    projectOrDie(worldBefore, hx, hy, "mover center (before)");
    dragPixels(hx, hy, hx + 47, hy - 63, 12);

    Vec3 worldAfter = rotatedWpToWorld(localCenter());
    Vec3 delta = worldAfter - worldBefore;

    assert(vlen(delta) > 0.02f,
        "center-plane drag should have moved the mover; |delta|=" ~ vlen(delta).to!string);

    float offPlane = fabs(dot(delta, normal));
    assert(offPlane < 0.05f,
        "non-auto center-plane drag must stay ON the workplane (dot with normal "
        ~ "should be ~0); got " ~ offPlane.to!string);

    cmd("tool.set prim.cube off");
    cmd("workplane.reset");
}

// -------------------------------------------------------------------------
// D — same invariant in AUTO mode (precomputed normal == derived normal
// by construction; a lightweight regression companion).
// -------------------------------------------------------------------------

struct AutoBP { Vec3 normal, axis1, axis2; }

AutoBP pickAutoBP(const ref Viewport vp) {
    float avx = fabs(vp.view[2]), avy = fabs(vp.view[6]), avz = fabs(vp.view[10]);
    if (avx >= avy && avx >= avz)      return AutoBP(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1));
    else if (avy >= avx && avy >= avz) return AutoBP(Vec3(0,1,0), Vec3(1,0,0), Vec3(0,0,1));
    else                                 return AutoBP(Vec3(0,0,1), Vec3(1,0,0), Vec3(0,1,0));
}

Vec3 autoToWorld(AutoBP bp, Vec3 local) {
    return bp.axis1 * local.x + bp.normal * local.y + bp.axis2 * local.z;
}

unittest { // D: auto mover center-drag also stays on the camera-facing plane
    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset empty failed: " ~ r.toString);
    cmd("history.clear");
    auto cam = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,"focus":{"x":0,"y":0,"z":0}}`);
    assert(cam["status"].str == "ok", "camera set failed: " ~ cam.toString);
    cmd("tool.set prim.cube");

    int cx, cy;
    projectOrDie(Vec3(0, 0, 0), cx, cy, "origin");
    dragPixels(cx, cy, cx + 120, cy + 100);

    auto vp = viewportFromCamera(fetchCamera(BASE));
    auto bp = pickAutoBP(vp);

    // As in C: a base-only drag leaves height==0, so heightH[0] (bottom
    // face handle) sits at the exact same world point as the mover's
    // centerBox, and height handles win onMouseButtonDown's priority
    // check. Establish a throwaway non-zero height first so the
    // subsequent center click unambiguously hits dragAxis==3 instead of
    // silently turning into a height-axis drag (verified empirically: an
    // undecoupled click here moves ONLY cenY by exactly the reported
    // "offPlane" delta — i.e. it's a height drag, not a plane drag).
    int dcx, dcy;
    projectOrDie(autoToWorld(bp, localCenter()), dcx, dcy, "base centroid (height decouple)");
    dragPixels(dcx, dcy, dcx + 40, dcy - 40, 8);

    Vec3 worldBefore = autoToWorld(bp, localCenter());
    int hx, hy;
    projectOrDie(worldBefore, hx, hy, "auto mover center (before)");
    dragPixels(hx, hy, hx + 51, hy - 39, 12);

    Vec3 worldAfter = autoToWorld(bp, localCenter());
    Vec3 delta = worldAfter - worldBefore;

    assert(vlen(delta) > 0.02f,
        "auto center-plane drag should have moved the mover; |delta|=" ~ vlen(delta).to!string);

    float offPlane = fabs(dot(delta, bp.normal));
    assert(offPlane < 0.05f,
        "auto center-plane drag must stay on the camera-facing plane (dot with "
        ~ "normal should be ~0); got " ~ offPlane.to!string);

    cmd("tool.set prim.cube off");
}

// -------------------------------------------------------------------------
// E — box's per-branch SIGN survives the mostFacingAxis extraction.
// -------------------------------------------------------------------------

unittest { // E: box signed-plane lock — antipodal cameras commit antiparallel normals
    Vec3 axis1 = Vec3(cast(float)cos(kRotRad), cast(float)sin(kRotRad), 0.0f);

    void commitAndReadNormal(double azOffset, double elSign,
                             out Vec3 normal, out Vec3 camBack) {
        resetRotatedWorkplaneBox(azOffset, elSign);
        auto vp = viewportFromCamera(fetchCamera(BASE));
        camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);

        int cx, cy;
        projectOrDie(kWpCenter, cx, cy, "rotated workplane center");
        dragPixels(cx, cy, cx + 100, cy + 90);
        cmd("tool.set prim.cube off");
        assert(vertCount() == 4, "base-only commit should create 4 vertices, got " ~ vertCount().to!string);
        assert(faceCount() == 1, "base-only commit should create exactly one polygon, got " ~ faceCount().to!string);
        normal = normalize(committedFaceNormal(0));
    }

    // Camera A: az=PI/2, el=+kRotRad (matches the existing rotated-workplane
    // fixture in test_primitive_box_interactive.d).
    Vec3 nA, camBackA;
    commitAndReadNormal(0.0, 1.0, nA, camBackA);

    // Camera B: the antipode through the same focus (az+PI, el negated) —
    // dot(camBack, axis1) flips sign while axis1 stays equally dominant.
    Vec3 nB, camBackB;
    commitAndReadNormal(PI, -1.0, nB, camBackB);

    // Both commits picked the axis1 branch (magnitude alignment).
    assert(fabs(dot(nA, axis1)) > 0.999f,
        "camera A's committed normal should align with workplane axis1, dot=" ~ dot(nA, axis1).to!string);
    assert(fabs(dot(nB, axis1)) > 0.999f,
        "camera B's committed normal should align with workplane axis1, dot=" ~ dot(nB, axis1).to!string);

    // The sign flips between the two antipodal cameras — proving box's
    // per-branch sign wasn't stripped by the mostFacingAxis extraction.
    assert(dot(nA, nB) < -0.99f,
        "antipodal cameras must commit ANTIPARALLEL normals (sign preserved); dot="
        ~ dot(nA, nB).to!string);

    // Each commit still faces its OWN camera (the existing "always faces
    // camera" invariant, reused as a sanity check on the sign convention).
    assert(dot(nA, camBackA) > 0.0f, "camera A's base polygon should face its camera");
    assert(dot(nB, camBackB) > 0.0f, "camera B's base polygon should face its camera");
}
