// Task 0619 — tool-internal aiming must honour the item transform.
// doc/tool_aiming_item_transform_plan.md, §Testing Strategy.
//
// 0617 fixed the SHARED pick paths (GPU ID buffer, BVH, lasso, hover,
// background snap, the constraint stage). This file is the acceptance proof
// for the OTHER family: a tool that projects or ray-tests mesh coordinates
// ITSELF, bypassing those paths. On a layer with a non-trivial `ItemXform`
// such a tool aims at where the geometry would sit at IDENTITY, not where it
// is drawn.
//
// Stage 1 lands case **T1** (Drag Weld, aiming kind "Pixel", §1.1). Later
// stages add T2-T7, P1-P6 and F1 here.
//
// This is a SOURCE-BACKED test (it imports `math` and `document` at column 0,
// see run_test.d:isSourceBackedTest) so it can build the exact composed matrix
// the app itself uses (`document.ItemXform.composedMatrix()`) and project with
// the app's own `math.projectToWindowFull` — the SAME function the tool calls
// internally — rather than a hand-duplicated formula that could drift.
//
// Run via: ./run_test.d tool_aim_item_transform

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv      : to;
import std.math      : sqrt, PI, fabs;
import std.format    : format;
import core.thread   : Thread;
import core.time     : dur;

import math     : Vec3, Viewport, transformPoint, projectToWindow,
                  projectToWindowFull, lookAt, perspectiveMatrix,
                  ModelSpace, screenPointToRay, rayPlaneIntersect,
                  closestPointOnSegmentToRay, dot, cross, normalize;
import document : ItemXform;

// buildDragLog/playAndWait pulled in by NAME only — drag_helpers defines its
// own Vec3/Viewport, so a blanket import would collide with the math.* types.
import drag_helpers : buildDragLog, playAndWait;

void main() {}

alias BASE = testBaseUrl;

// DragWeldTool's own pick radius (source/tools/edit/drag_weld.d
// PICK_RADIUS_PX). The fixture guards below are stated in terms of it: a
// decoy must be INSIDE it for the wrong implementation, and every real
// vertex must be OUTSIDE it, or the case cannot separate the two laws.
enum float PICK_RADIUS_PX = 12.0f;

// ---------------------------------------------------------------------------
// HTTP plumbing
// ---------------------------------------------------------------------------


JSONValue cmd(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "ok" || j["status"].str == "success",
        "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void waitIdle() {
    for (int i = 0; i < 200; ++i) {
        auto s = getJson("/api/play-events/status");
        auto f = "finished" in s;
        if (f is null || f.type != JSONType.FALSE) { Thread.sleep(dur!"msecs"(120)); return; }
        Thread.sleep(dur!"msecs"(10));
    }
}

void resetScene() {
    waitIdle();
    auto j = postJson("/api/command", commandBody("scene.reset"));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
}

void loadMesh(Vec3[] verts, int[][] faces) {
    string vs;
    foreach (i, v; verts)
        vs ~= format("%s[%.9f,%.9f,%.9f]", i ? "," : "", v.x, v.y, v.z);
    string fs;
    foreach (i, f; faces) {
        fs ~= i ? "," : "";
        fs ~= "[";
        foreach (k, vi; f) fs ~= format("%s%d", k ? "," : "", vi);
        fs ~= "]";
    }
    auto j = postJson("/api/command", commandBody("scene.loadMesh", `{"vertices":[` ~ vs ~ `],"faces":[` ~ fs ~ `]}`));
    assert(j["status"].str == "ok", "/api/load-mesh failed: " ~ j.toString);
}

void setCamera(float az, float el, float dist) {
    auto r = postJson("/api/camera",
        format(`{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f}`, az, el, dist));
    assert("error" !in r, "/api/camera failed: " ~ r.toString);
}

// Write one component of a layer's item transform through `layer.attr` — the
// panel-dispatch shape, undoable, coalescing. NEVER poke Layer.xform directly
// (that would bypass the exact writer this task's bug report named).
void setAttr(int layer, string attr, double v) {
    cmd("layer.attr " ~ layer.to!string ~ " " ~ attr ~ " " ~ v.to!string);
}

void setXform(int layer, Vec3 pos, Vec3 rotDeg, Vec3 scl) {
    setAttr(layer, "pos.x", pos.x); setAttr(layer, "pos.y", pos.y); setAttr(layer, "pos.z", pos.z);
    setAttr(layer, "rot.x", rotDeg.x); setAttr(layer, "rot.y", rotDeg.y); setAttr(layer, "rot.z", rotDeg.z);
    setAttr(layer, "scl.x", scl.x); setAttr(layer, "scl.y", scl.y); setAttr(layer, "scl.z", scl.z);
}

// The SAME composed matrix the app computes for this layer — via the real
// `document.ItemXform.composedMatrix()`, not a re-derivation.
float[16] composed(Vec3 pos, Vec3 rotDeg, Vec3 scl) {
    ItemXform xf;
    xf.pos = pos; xf.rot = rotDeg; xf.scl = scl;
    return xf.composedMatrix();
}

// ---------------------------------------------------------------------------
// Camera / projection (the app's own math.d functions — no duplicated formula)
// ---------------------------------------------------------------------------

struct CamInfo { Vec3 eye, focus; int width, height, vpX, vpY; }

CamInfo fetchCam() {
    auto j = getJson("/api/camera");
    CamInfo c;
    c.eye    = Vec3(cast(float) j["eye"]["x"].floating,
                    cast(float) j["eye"]["y"].floating,
                    cast(float) j["eye"]["z"].floating);
    c.focus  = Vec3(cast(float) j["focus"]["x"].floating,
                    cast(float) j["focus"]["y"].floating,
                    cast(float) j["focus"]["z"].floating);
    c.width  = cast(int) j["width"].integer;
    c.height = cast(int) j["height"].integer;
    c.vpX    = cast(int) j["vpX"].integer;
    c.vpY    = cast(int) j["vpY"].integer;
    return c;
}

// Same fovY/near/far the live camera uses (view.d) — the recipe
// tests/drag_helpers.d and tests/test_pick_item_transform.d both use.
Viewport buildViewport(CamInfo c) {
    Viewport vp;
    vp.view   = lookAt(c.eye, c.focus, Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(45.0f * PI / 180.0f,
                                  cast(float) c.width / c.height, 0.001f, 100.0f);
    vp.width  = c.width;
    vp.height = c.height;
    vp.x      = c.vpX;
    vp.y      = c.vpY;
    vp.eye    = c.eye;
    vp.focus  = c.focus;
    return vp;
}

bool projectOnScreen(Vec3 world, const ref Viewport vp, out float px, out float py) {
    float ndcZ;
    return projectToWindow(world, vp, px, py, ndcZ);
}

double dist(float ax, float ay, float bx, float by) {
    double dx = ax - bx, dy = ay - by;
    return sqrt(dx * dx + dy * dy);
}

Vec3[] fetchVerts(int layer = 0) {
    Vec3[] r;
    foreach (v; getJson("/api/model?layer=" ~ layer.to!string)["vertices"].array)
        r ~= Vec3(cast(float) v.array[0].floating,
                  cast(float) v.array[1].floating,
                  cast(float) v.array[2].floating);
    return r;
}

bool hasVertexNear(Vec3[] verts, Vec3 p, float tol = 1e-3f) {
    foreach (v; verts) if ((v - p).length <= tol) return true;
    return false;
}

// ---------------------------------------------------------------------------
// A faithful re-run of DragWeldTool.pickNearestVertex_ (drag_weld.d:203) in
// EITHER space, so the fixture's guards are stated in the tool's own terms —
// same `projectToWindowFull`, same "nearest wins" rule, same exclusion.
//
//   `M == null`  -> the WRONG law: project the raw local coordinate through
//                   the world viewport (what the tool did before this task).
//   `M != null`  -> the CORRECT law: project the DRAWN point.
//
// Returns the winning index (or -1 when nothing is inside `radius`) and, via
// `outRunnerUp`, the pixel distance of the next-nearest candidate — which is
// what proves the winner is unambiguous rather than a coin flip.
// ---------------------------------------------------------------------------
int nearestVertexPx(Vec3[] verts, const float[16]* M, const ref Viewport vp,
                    float sx, float sy, int exclude, float radius,
                    out double outBest, out double outRunnerUp)
{
    outBest = double.infinity;
    outRunnerUp = double.infinity;
    int best = -1;
    foreach (i, v; verts) {
        if (cast(int) i == exclude) continue;
        Vec3 p = (M is null) ? v : transformPoint(*M, v);
        float px, py, ndcZ;
        if (!projectToWindowFull(p, vp, px, py, ndcZ)) continue;
        double d = dist(px, py, sx, sy);
        if (d < outBest) { outRunnerUp = outBest; outBest = d; best = cast(int) i; }
        else if (d < outRunnerUp) outRunnerUp = d;
    }
    return (outBest <= radius) ? best : -1;
}

// ===========================================================================
// T1 — Drag Weld, aiming kind **Pixel** (§1.1).
//
// THE PAIR THIS CASE ASSERTS, and the wrong implementation it separates:
//
//   correct law  project `M * v_local` (i.e. compose M into the viewport)
//   wrong  law   project `v_local` through the WORLD viewport  <- pre-0619 HEAD
//
// The fixture is built so the two laws weld DIFFERENT PAIRS, not so that one
// of them merely misses. Four separate triangles:
//
//   A, B  the real geometry. `vTgt = A[0]`, `vSrc = B[0]` — the pair a user
//         who clicks the DRAWN vertices means to weld.
//   C, D  two decoys placed at the exact LOCAL coordinates `M*vTgt` and
//         `M*vSrc`. Their IDENTITY-pose projections therefore land exactly on
//         the two click pixels, so the WRONG law picks THEM.
//
// A weld between C[0] and D[0] is valid (separate faces, no shared vertices),
// so the wrong law does not fail loudly — it quietly welds the wrong pair and
// leaves the same vertex COUNT behind. That is why every assertion below is
// about which POSITION survived, never about the count alone.
//
// Anti-vacuity, all asserted before the gesture is played:
//   * the drawn and identity pixels of both targets differ by > 20 px;
//   * under the CORRECT law the intended vertex is the nearest and the
//     runner-up is outside the tool's 12 px pick radius;
//   * under the WRONG law the DECOY is inside that radius and the intended
//     vertex is outside it.
// If any of those stops holding, the case fails loudly instead of going
// quietly vacuous.
// ===========================================================================

// The transform. Asymmetric on every axis the law touches: a translation on
// all three axes, a rotation on all three, and a NON-UNIFORM scale. A cube at
// the origin under a 90-degree rotation or a mirror-only transform would map
// its own vertex SET to itself and could not separate these laws at all
// (0617's retro — that fixture shipped a bug).
enum Vec3 T1_POS = Vec3( 1.60f, -0.70f,  0.45f);
enum Vec3 T1_ROT = Vec3(12.0f,  40.0f,  -8.0f);
enum Vec3 T1_SCL = Vec3( 1.70f,  1.00f,  0.60f);

// Two disjoint triangles, deliberately asymmetric in x, y and z.
enum Vec3[6] T1_BASE = [
    Vec3(-1.20f,  0.35f, -0.90f),   // 0 — vTgt
    Vec3(-0.40f,  0.90f, -1.10f),   // 1
    Vec3(-0.80f, -0.20f, -0.50f),   // 2
    Vec3( 0.90f, -0.55f,  0.70f),   // 3 — vSrc
    Vec3( 1.50f,  0.15f,  0.40f),   // 4
    Vec3( 1.10f, -0.95f,  1.20f),   // 5
];

enum int VTGT = 0;
enum int VSRC = 3;
enum int DTGT = 6;   // decoy at M*vTgt
enum int DSRC = 9;   // decoy at M*vSrc

// Build the 12-vertex / 4-triangle fixture for a given M.
void t1BuildFixture(float[16] M, out Vec3[] verts, out int[][] faces) {
    verts = T1_BASE.dup;
    Vec3 dTgt = transformPoint(M, T1_BASE[VTGT]);
    Vec3 dSrc = transformPoint(M, T1_BASE[VSRC]);
    // The two extra corners of each decoy triangle are pushed far enough out
    // that they cannot themselves be mistaken for the decoy under either law
    // (the guards below check it rather than trusting the number).
    verts ~= [dTgt, dTgt + Vec3(0.70f, 0.30f, 0.0f), dTgt + Vec3(0.20f, -0.85f, 0.40f)];
    verts ~= [dSrc, dSrc + Vec3(0.70f, 0.30f, 0.0f), dSrc + Vec3(0.20f, -0.85f, 0.40f)];
    faces = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [9, 10, 11]];
}

unittest { // T1: Drag Weld welds the DRAWN pair, not the identity-pose pair
    resetScene();

    float[16] M = composed(T1_POS, T1_ROT, T1_SCL);
    Vec3[] verts; int[][] faces;
    t1BuildFixture(M, verts, faces);
    loadMesh(verts, faces);

    // Order matters: /api/load-mesh dispatches scene.loadMesh, which may
    // reframe the camera — so the transform and the camera are both set
    // AFTER the geometry is in place, and the viewport is read after that.
    setXform(0, T1_POS, T1_ROT, T1_SCL);
    setCamera(0.55f, 0.32f, 11.0f);

    auto cam = fetchCam();
    auto vp  = buildViewport(cam);

    // `/api/model` returns raw LOCAL coordinates — the same array the tool
    // iterates. Re-read it rather than trusting what we posted.
    Vec3[] local = fetchVerts();
    assert(local.length == 12, format("fixture must load 12 vertices, got %d", local.length));

    // ---- the two click pixels: where the intended vertices are DRAWN ----
    Vec3 tgtDrawn = transformPoint(M, local[VTGT]);
    Vec3 srcDrawn = transformPoint(M, local[VSRC]);
    float tgtPx, tgtPy, srcPx, srcPy, tgtIdPx, tgtIdPy, srcIdPx, srcIdPy;
    assert(projectOnScreen(tgtDrawn,     vp, tgtPx,   tgtPy),   "drawn target off-screen");
    assert(projectOnScreen(srcDrawn,     vp, srcPx,   srcPy),   "drawn source off-screen");
    assert(projectOnScreen(local[VTGT],  vp, tgtIdPx, tgtIdPy), "identity target off-screen");
    assert(projectOnScreen(local[VSRC],  vp, srcIdPx, srcIdPy), "identity source off-screen");

    // (1) The transform must actually move the pixels, or nothing is measured.
    assert(dist(tgtPx, tgtPy, tgtIdPx, tgtIdPy) > 20.0,
        format("transform does not separate drawn/identity TARGET pixels (%.1f px) — vacuous",
               dist(tgtPx, tgtPy, tgtIdPx, tgtIdPy)));
    assert(dist(srcPx, srcPy, srcIdPx, srcIdPy) > 20.0,
        format("transform does not separate drawn/identity SOURCE pixels (%.1f px) — vacuous",
               dist(srcPx, srcPy, srcIdPx, srcIdPy)));

    // (2) Under the CORRECT law the intended vertices win unambiguously.
    double best, runnerUp;
    int gotSrc = nearestVertexPx(local, &M, vp, srcPx, srcPy, -1, PICK_RADIUS_PX, best, runnerUp);
    assert(gotSrc == VSRC, format("drawn-space press should elect v%d, elects %d", VSRC, gotSrc));
    assert(runnerUp > PICK_RADIUS_PX,
        format("drawn-space press is ambiguous: runner-up at %.1f px is inside the %.0f px "
               ~ "pick radius", runnerUp, PICK_RADIUS_PX));
    int gotTgt = nearestVertexPx(local, &M, vp, tgtPx, tgtPy, VSRC, PICK_RADIUS_PX, best, runnerUp);
    assert(gotTgt == VTGT, format("drawn-space release should elect v%d, elects %d", VTGT, gotTgt));
    assert(runnerUp > PICK_RADIUS_PX,
        format("drawn-space release is ambiguous: runner-up at %.1f px", runnerUp));

    // (3) Under the WRONG law the DECOYS win — this is what makes the case
    //     discriminating rather than merely "the wrong impl misses".
    int wrongSrc = nearestVertexPx(local, null, vp, srcPx, srcPy, -1, PICK_RADIUS_PX, best, runnerUp);
    assert(wrongSrc == DSRC,
        format("fixture broken: identity-space press should elect the decoy v%d, elects %d",
               DSRC, wrongSrc));
    assert(runnerUp > PICK_RADIUS_PX,
        format("identity-space press is ambiguous: runner-up at %.1f px", runnerUp));
    int wrongTgt = nearestVertexPx(local, null, vp, tgtPx, tgtPy, DSRC, PICK_RADIUS_PX, best, runnerUp);
    assert(wrongTgt == DTGT,
        format("fixture broken: identity-space release should elect the decoy v%d, elects %d",
               DTGT, wrongTgt));
    assert(runnerUp > PICK_RADIUS_PX,
        format("identity-space release is ambiguous: runner-up at %.1f px", runnerUp));

    // ---- drive the gesture ----
    cmd("select.typeFrom vertex");     // before tool.set: a type flip drops the tool
    cmd("tool.set mesh.dragWeld on");
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cast(int) srcPx, cast(int) srcPy,
                             cast(int) tgtPx, cast(int) tgtPy, 20));
    cmd("tool.set mesh.dragWeld off");

    Vec3[] after = fetchVerts();

    // ---- assert the PAIR that merged, never the count alone ----
    assert(after.length == 11,
        format("expected 11 vertices after one weld, got %d", after.length));
    assert(!hasVertexNear(after, T1_BASE[VSRC]),
        format("the DRAWN source vertex %s must be gone — it is the one the user "
               ~ "dragged; still present means the tool aimed at the identity pose",
               vecStr(T1_BASE[VSRC])));
    assert(hasVertexNear(after, T1_BASE[VTGT]),
        format("the DRAWN target vertex %s must survive the weld", vecStr(T1_BASE[VTGT])));
    // The decoys must be untouched: welding THEM is exactly what the wrong
    // law does, and it leaves the same vertex count behind.
    assert(hasVertexNear(after, local[DSRC]),
        format("decoy %s was welded — the tool aimed in the identity pose",
               vecStr(local[DSRC])));
    assert(hasVertexNear(after, local[DTGT]),
        format("decoy %s must be untouched", vecStr(local[DTGT])));
}

unittest { // T1 (pair, second half): the IDENTITY-pose pixels must weld nothing
    // The mandatory companion to the case above (§Testing, "assert the pair"):
    // a tool that aims correctly must ALSO stop hitting the place the geometry
    // is not drawn. Without this half, an implementation that projects through
    // BOTH spaces and takes whichever hits would pass the first case.
    resetScene();

    float[16] M = composed(T1_POS, T1_ROT, T1_SCL);
    Vec3[] verts; int[][] faces;
    t1BuildFixture(M, verts, faces);
    loadMesh(verts, faces);
    setXform(0, T1_POS, T1_ROT, T1_SCL);
    setCamera(0.55f, 0.32f, 11.0f);

    auto cam   = fetchCam();
    auto vp    = buildViewport(cam);
    Vec3[] local = fetchVerts();
    assert(local.length == 12);

    float tgtIdPx, tgtIdPy, srcIdPx, srcIdPy;
    assert(projectOnScreen(local[VTGT], vp, tgtIdPx, tgtIdPy), "identity target off-screen");
    assert(projectOnScreen(local[VSRC], vp, srcIdPx, srcIdPy), "identity source off-screen");

    // Guard: in the DRAWN space (the space the tool must be aiming in) there
    // is nothing within the pick radius of either identity pixel — so a
    // correct tool cannot consume this gesture at all, and "no weld" is a
    // prediction rather than an accident.
    double best, runnerUp;
    int drawnAtIdSrc = nearestVertexPx(local, &M, vp, srcIdPx, srcIdPy, -1,
                                       PICK_RADIUS_PX, best, runnerUp);
    assert(drawnAtIdSrc == -1,
        format("fixture broken: a drawn vertex (v%d, %.1f px) sits on the identity source "
               ~ "pixel, so this half cannot distinguish anything", drawnAtIdSrc, best));

    cmd("select.typeFrom vertex");
    cmd("tool.set mesh.dragWeld on");
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cast(int) srcIdPx, cast(int) srcIdPy,
                             cast(int) tgtIdPx, cast(int) tgtIdPy, 20));
    cmd("tool.set mesh.dragWeld off");

    Vec3[] after = fetchVerts();
    assert(after.length == 12,
        format("a gesture over the IDENTITY-pose pixels must weld nothing; "
               ~ "vertex count went 12 -> %d", after.length));
    assert(hasVertexNear(after, T1_BASE[VSRC]),
        "the real source vertex must survive a gesture aimed where nothing is drawn");
}

string vecStr(Vec3 v) { return format("(%.3f,%.3f,%.3f)", v.x, v.y, v.z); }

// ===========================================================================
// Stage 2 + Stage 3 cases — the RayPlane family (§1.2) and the Closest
// family (§1.3).
//
// The two families are deliberately in ONE file because their laws are
// OPPOSITE and a reader who sees only one of them will generalise the wrong
// way:
//
//   RayPlane (tack, magnet, stroke extrude)  -> resolve in the LAYER'S LOCAL
//       space. The plane test is exact in either space; local is chosen
//       because the CONSUMER writes local vertex coordinates.
//   Closest (edge slice, loop slice)         -> resolve in WORLD space. The
//       closest-approach election is NOT affine-invariant, so the space is
//       forced: the user aims at the rail as it is drawn. The ratio that
//       comes back is affine-invariant, so it needs no back-transform.
//
// Every case below states the wrong implementation it separates and asserts a
// NUMBER (a position or a ratio) that reads differently under it — never a
// count, and never "the tool did something".
// ===========================================================================

// The shared transform for the Stage 2/3 cases. Asymmetric on every axis the
// laws touch: translation on all three, rotation on all three (and no
// multiple of 90 degrees — a quarter turn maps a box's vertex set to itself),
// and a scale that is non-uniform on all three. The non-uniformity is
// load-bearing twice over: §1.3's election coincides with the local one under
// a uniform scale, and `toLocalNormal` (M^T) coincides with `toLocalDir`
// (M^-1) under a pure rotation.
enum Vec3 AIM_POS = Vec3( 0.90f, -0.45f,  0.30f);
enum Vec3 AIM_ROT = Vec3(13.0f,  38.0f,  -9.0f);
enum Vec3 AIM_SCL = Vec3( 1.70f,  0.55f,  0.60f);

// The app's own ModelSpace for that transform — via `document.ItemXform`, the
// same type the layer holds, so `m`/`mInv` are the matrices the tool sees.
ModelSpace aimSpaceOf(Vec3 pos, Vec3 rotDeg, Vec3 scl) {
    ItemXform xf;
    xf.pos = pos; xf.rot = rotDeg; xf.scl = scl;
    return xf.modelSpace();
}

// The cursor ray at pixel (px,py), in BOTH spaces: world as `screenPointToRay`
// builds it, and local as §1.2 requires (origin through M^-1, direction
// through M^-1's linear part, deliberately NOT renormalized).
void aimRays(const ref Viewport vp, const ModelSpace ms, float px, float py,
             out Vec3 oW, out Vec3 dW, out Vec3 oL, out Vec3 dL)
{
    screenPointToRay(px, py, vp, oW, dW);
    oL = ms.toLocalPoint(oW);
    dL = ms.toLocalDir(dW);
}

// The ray/plane meet, with the plane given by three points ON it. Note the
// normal's LENGTH and SIGN both cancel out of `rayPlaneIntersect`, so this
// depends on the plane alone and not on how the mesh happens to compute a
// face normal — the prediction cannot drift from the implementation.
Vec3 planeHit(Vec3 o, Vec3 d, Vec3 p0, Vec3 p1, Vec3 p2) {
    Vec3 n = cross(p1 - p0, p2 - p0);
    Vec3 hit;
    assert(rayPlaneIntersect(o, d, p0, n, hit), "ray must meet the plane");
    return hit;
}

// --- HTTP odds and ends the Stage 2/3 cases need ---------------------------

void selectIndices(string mode, int[] idx) {
    string s;
    foreach (i, v; idx) s ~= format("%s%d", i ? "," : "", v);
    auto r = postJson("/api/command", commandBody("mesh.select", format(`{"mode":"%s","indices":[%s]}`, mode, s)));
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

void setCameraAt(float az, float el, float dist, Vec3 focus) {
    auto r = postJson("/api/camera",
        format(`{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,` ~
               `"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
               az, el, dist, focus.x, focus.y, focus.z));
    assert("error" !in r, "/api/camera failed: " ~ r.toString);
}

JSONValue toolState() { return getJson("/api/tool/state"); }

// A stationary hover (no button) — settles g_hoveredFace/Edge/Vertex before a
// press, exactly as tests/test_tack_tool.d does.
string hoverOnlyLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    foreach (i; 0 .. 6)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            40.0 + i * 25.0, x, y);
    return log;
}

// A discrete LEFT click (down + up, no motion between).
string clickOnlyLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    log ~= format(`{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", x, y);
    log ~= format(`{"t":110.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", x, y);
    return log;
}

// Hover at (hx,hy), then press there and drag to (x1,y1) with `steps` motion
// events, then release. The 200 ms gap before the press is what lets the
// render loop run its hover pick (the recipe tests/test_magnet_drag.d uses).
string hoverThenDragLog(int vpX, int vpY, int vpW, int vpH,
                        int hx, int hy, int x1, int y1, int steps)
{
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    foreach (i; 0 .. 4)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            20.0 + i * 40.0, hx, hy);
    log ~= format(`{"t":260.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", hx, hy);
    int lastX = hx, lastY = hy;
    foreach (i; 1 .. steps + 1) {
        int x = hx + cast(int)((cast(double)(x1 - hx) * i) / steps);
        int y = hy + cast(int)((cast(double)(y1 - hy) * i) / steps);
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            260.0 + i * 50.0, x, y, x - lastX, y - lastY);
        lastX = x; lastY = y;
    }
    log ~= format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
                  260.0 + (steps + 1) * 50.0, x1, y1);
    return log;
}

// ===========================================================================
// T3 — Tack, aiming kind **RayPlane** (§1.2).
//
// THE PAIR:
//   correct law  the cursor ray is carried into the LAYER'S LOCAL space and
//                met with the target face's (local) plane -> a LOCAL hit
//   wrong  law   the WORLD ray is met with the LOCAL plane   <- pre-0619 HEAD
//
// WHY IT READS A NUMBER. `computeTackTransform` sets the translation to
// `clickedPoint - R*srcCentroid`, so after the commit the source face's
// centroid IS the hit, exactly. `R` is built from two LOCAL face normals and
// is identical under both laws — so the whole difference between them lands
// on one observable position, which `/api/model` reports directly.
//
// DISCRIMINATING INPUT: the click sits on the DRAWN target face's centroid,
// whose local pre-image is the local target centroid. The wrong law meets the
// same local plane with the world ray and lands somewhere else entirely; the
// guard below asserts the two predictions are far apart before driving
// anything, so the case cannot go quietly vacuous.
//
// ORACLE (R11): `/api/model` — a position readout, not the two-sided identity
// picker, and no facing/winding question is asked of it.
// ===========================================================================

// Source island = face 0 (verts 0..2), well away in -X so it never occludes
// the target and is never the face under the cursor. Target island = face 1
// (verts 3..5), a large triangle lying roughly in the y=0 plane so a camera
// with a healthy elevation sees it face-on rather than edge-on.
enum Vec3[6] T3_BASE = [
    Vec3(-3.20f,  1.05f, -0.55f),   // 0 — source
    Vec3(-2.55f,  1.62f,  0.20f),   // 1
    Vec3(-2.90f,  0.70f,  0.85f),   // 2
    Vec3( 0.60f, -0.15f, -1.40f),   // 3 — target
    Vec3( 2.60f, -0.05f, -0.30f),   // 4
    Vec3( 0.90f,  0.10f,  1.50f),   // 5
];

unittest { // T3: Tack lands the island where the cursor meets the DRAWN face
    resetScene();

    float[16] M = composed(AIM_POS, AIM_ROT, AIM_SCL);
    const ModelSpace ms = aimSpaceOf(AIM_POS, AIM_ROT, AIM_SCL);

    // The drawn target centroid — the camera focus, so the framing does not
    // depend on where the transform happens to put the geometry.
    Vec3 tgtCentLocal = (T3_BASE[3] + T3_BASE[4] + T3_BASE[5]) * (1.0f / 3.0f);
    Vec3 tgtCentDrawn = transformPoint(M, tgtCentLocal);

    // Establish the camera BEFORE the geometry so the winding decision below
    // can use the real eye: /api/load-mesh reframes the camera, and the
    // explicit focus here is what makes the re-set afterwards reproduce it.
    setCameraAt(0.62f, 0.85f, 8.0f, tgtCentDrawn);
    auto cam0 = fetchCam();

    // Choose the target triangle's WINDING so the drawn face points at the
    // eye. Whether the pick culls by winding or by which side the eye is on,
    // a face that turns its back on the camera is not pickable — and which
    // way "back" is depends on the transform, so it is decided here rather
    // than baked into the fixture.
    Vec3 d3 = transformPoint(M, T3_BASE[3]);
    Vec3 d4 = transformPoint(M, T3_BASE[4]);
    Vec3 d5 = transformPoint(M, T3_BASE[5]);
    Vec3 nDrawn = cross(d4 - d3, d5 - d3);
    bool flip = dot(nDrawn, cam0.eye - tgtCentDrawn) < 0.0f;
    int[][] faces = flip ? [[0, 1, 2], [3, 5, 4]] : [[0, 1, 2], [3, 4, 5]];

    // Fixture guard: the target must not be edge-on, or the hover pick is a
    // coin flip and the plane meet is ill-conditioned.
    float facing = dot(normalize(nDrawn), normalize(cam0.eye - tgtCentDrawn));
    assert(facing > 0.3f || facing < -0.3f,
        format("target face is edge-on to the camera (|cos| = %.3f) — reframe the fixture",
               facing < 0 ? -facing : facing));

    loadMesh(T3_BASE.dup, faces);
    setXform(0, AIM_POS, AIM_ROT, AIM_SCL);
    setCameraAt(0.62f, 0.85f, 8.0f, tgtCentDrawn);

    auto cam = fetchCam();
    auto vp  = buildViewport(cam);
    Vec3[] local = fetchVerts();
    assert(local.length == 6, format("fixture must load 6 vertices, got %d", local.length));

    // ---- the click pixel: the DRAWN target centroid ----
    float cx, cy, idx_, idy_;
    assert(projectOnScreen(tgtCentDrawn,  vp, cx, cy),   "drawn target centroid off-screen");
    assert(projectOnScreen(tgtCentLocal,  vp, idx_, idy_), "identity target centroid off-screen");

    // (1) VACUITY: the transform must move the target's pixel.
    assert(dist(cx, cy, idx_, idy_) > 20.0,
        format("transform does not separate drawn/identity target pixels (%.1f px) — vacuous",
               dist(cx, cy, idx_, idy_)));

    // ---- the two predictions, both derived here, neither by re-running the tool ----
    Vec3 oW, dW, oL, dL;
    aimRays(vp, ms, cast(float)cast(int)cx, cast(float)cast(int)cy, oW, dW, oL, dL);
    Vec3 hitCorrect = planeHit(oL, dL, local[3], local[4], local[5]);  // local ray, local plane
    Vec3 hitWrong   = planeHit(oW, dW, local[3], local[4], local[5]);  // world ray, local plane

    // (2) VACUITY: the two laws must land the island in materially different
    //     places, or the assertion below could not tell them apart.
    assert((hitCorrect - hitWrong).length > 0.5f,
        format("the two laws predict nearly the same hit (%.4f apart) — vacuous",
               (hitCorrect - hitWrong).length));
    // Sanity: clicking the drawn centroid's pixel must recover the LOCAL
    // centroid, since that is the point it is the drawing of. (Integer pixel
    // rounding is the only slack.)
    assert((hitCorrect - tgtCentLocal).length < 0.08f,
        format("predicted local hit %s should be the local target centroid %s",
               vecStr(hitCorrect), vecStr(tgtCentLocal)));

    // ---- drive: select the source face, arm the tool, hover, click ----
    selectIndices("polygons", [0]);
    cmd("tool.set mesh.tack");

    playAndWait(hoverOnlyLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cast(int)cx, cast(int)cy));
    Thread.sleep(dur!"msecs"(150));
    auto st = toolState();
    assert(st["sourceFace"].integer == 0,
        "tack did not capture the selected source face: " ~ st.toString);
    assert(st["hoveredTargetFace"].integer == 1,
        "the click pixel does not hover the target face — reframe the fixture: " ~ st.toString);

    playAndWait(clickOnlyLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cast(int)cx, cast(int)cy));
    Thread.sleep(dur!"msecs"(200));
    cmd("tool.set mesh.tack off");

    Vec3[] after = fetchVerts();
    assert(after.length == 6, format("tack must not change topology, got %d verts", after.length));

    // ---- the assertion: WHERE the island landed ----
    Vec3 landed = (after[0] + after[1] + after[2]) * (1.0f / 3.0f);
    assert((landed - hitCorrect).length < 0.08f,
        format("tack landed the island at %s; the DRAWN-space hit is %s and the "
               ~ "identity-pose hit is %s (|landed-correct| = %.4f)",
               vecStr(landed), vecStr(hitCorrect), vecStr(hitWrong),
               (landed - hitCorrect).length));
    // The pair's other half, stated as a number rather than implied.
    assert((landed - hitWrong).length > 0.5f,
        format("tack landed at the IDENTITY-pose hit %s — the tool aimed with the "
               ~ "world ray against a local plane", vecStr(hitWrong)));
}

// ===========================================================================
// T4 — Magnet, aiming kind **RayPlane** (§1.2), plus the `toLocalNormal`
// discriminator the tack case cannot carry.
//
// THE THREE LAWS THIS CASE SEPARATES:
//   correct     local ray  x  plane(anchor_local, M^T * camForward)
//   wrong (1)   world ray  x  plane(anchor_local, camForward)   <- pre-0619
//   wrong (2)   local ray  x  plane(anchor_local, M^-1 * camForward)
//               — `toLocalDir` used to carry a NORMAL. Identical to the
//               correct law under any pure rotation, so ONLY the non-uniform
//               scale in AIM_SCL makes this half of the case measurable.
//
// WHY IT READS A NUMBER. `attractToPoint` moves a vertex to
// `pos + (target-pos)*clamp(w*strength,0,1)`; the grabbed vertex is in the
// falloff's anchor ring so `w == 1`, and the drag below is longer than
// MagnetTool's 150 px strength ramp so `strength == 1`. The anchor therefore
// lands EXACTLY on `target_`, which is the ray/plane hit under test.
//
// ORACLE (R11): `/api/model` — a position.
// ===========================================================================

enum Vec3[4] T4_BASE = [
    Vec3(-1.30f, -0.20f, -1.10f),   // 0
    Vec3( 1.45f, -0.05f, -0.85f),   // 1
    Vec3( 0.35f,  0.15f,  1.55f),   // 2 <- the grabbed vertex
    Vec3(-1.80f,  0.30f,  1.20f),   // 3
];
enum int T4_ANCHOR = 2;

unittest { // T4: Magnet pulls the vertex to the cursor on the DRAWN surface
    resetScene();

    float[16] M = composed(AIM_POS, AIM_ROT, AIM_SCL);
    const ModelSpace ms = aimSpaceOf(AIM_POS, AIM_ROT, AIM_SCL);
    Vec3 anchorDrawn = transformPoint(M, T4_BASE[T4_ANCHOR]);

    setCameraAt(0.55f, 0.75f, 8.0f, anchorDrawn);
    auto cam0 = fetchCam();

    // Winding chosen at runtime so the drawn surface faces the eye — a vertex
    // on a surface turned away from the camera is not hover-pickable, and
    // which way "away" is depends on the transform.
    Vec3 d0 = transformPoint(M, T4_BASE[0]);
    Vec3 d1 = transformPoint(M, T4_BASE[1]);
    Vec3 d2 = transformPoint(M, T4_BASE[2]);
    Vec3 cen = (d0 + d1 + d2) * (1.0f / 3.0f);
    bool flip = dot(cross(d1 - d0, d2 - d0), cam0.eye - cen) < 0.0f;
    int[][] faces = flip ? [[0, 2, 1], [0, 3, 2]] : [[0, 1, 2], [0, 2, 3]];

    loadMesh(T4_BASE.dup, faces);
    setXform(0, AIM_POS, AIM_ROT, AIM_SCL);
    setCameraAt(0.55f, 0.75f, 8.0f, anchorDrawn);

    auto cam = fetchCam();
    auto vp  = buildViewport(cam);
    Vec3[] local = fetchVerts();
    assert(local.length == 4, format("fixture must load 4 vertices, got %d", local.length));

    float gx, gy, ix, iy;
    assert(projectOnScreen(anchorDrawn,          vp, gx, gy), "drawn anchor off-screen");
    assert(projectOnScreen(local[T4_ANCHOR],     vp, ix, iy), "identity anchor off-screen");
    assert(dist(gx, gy, ix, iy) > 20.0,
        format("transform does not separate drawn/identity anchor pixels (%.1f px) — vacuous",
               dist(gx, gy, ix, iy)));

    // No other DRAWN vertex may sit near the grab pixel, or the hover pick is
    // ambiguous and the case measures nothing.
    foreach (i, v; local) {
        if (cast(int)i == T4_ANCHOR) continue;
        float px, py;
        if (!projectOnScreen(transformPoint(M, v), vp, px, py)) continue;
        assert(dist(px, py, gx, gy) > 40.0,
            format("drawn v%d is only %.1f px from the grab pixel — ambiguous fixture",
                   i, dist(px, py, gx, gy)));
    }

    // The drag: > 150 px so MagnetTool's strength ramp saturates at 1.0 and
    // the anchor lands EXACTLY on the resolved target.
    int x0 = cast(int)gx, y0 = cast(int)gy;
    int x1 = x0 + 170,    y1 = y0 - 70;

    Vec3 oW, dW, oL, dL;
    aimRays(vp, ms, cast(float)x1, cast(float)y1, oW, dW, oL, dL);
    Vec3 fwdWorld = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
    Vec3 anchorL  = local[T4_ANCHOR];

    Vec3 hitCorrect, hitWrong1, hitWrong2;
    assert(rayPlaneIntersect(oL, dL, anchorL, ms.toLocalNormal(fwdWorld), hitCorrect));
    assert(rayPlaneIntersect(oW, dW, anchorL, fwdWorld,                   hitWrong1));
    assert(rayPlaneIntersect(oL, dL, anchorL, ms.toLocalDir(fwdWorld),    hitWrong2));

    assert((hitCorrect - hitWrong1).length > 0.5f,
        format("vacuous: the pre-0619 law predicts the same landing (%.4f apart)",
               (hitCorrect - hitWrong1).length));
    assert((hitCorrect - hitWrong2).length > 0.15f,
        format("vacuous: carrying the plane normal with M^-1 predicts the same landing "
               ~ "(%.4f apart) — AIM_SCL is not non-uniform enough",
               (hitCorrect - hitWrong2).length));

    cmd("select.typeFrom vertex");
    cmd("tool.set xfrm.magnet");
    playAndWait(hoverThenDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 x0, y0, x1, y1, 12));
    Thread.sleep(dur!"msecs"(200));
    cmd("tool.set xfrm.magnet off");

    Vec3[] after = fetchVerts();
    assert(after.length == 4, format("magnet must not change topology, got %d", after.length));
    Vec3 got = after[T4_ANCHOR];

    assert((got - anchorL).length > 0.2f,
        format("the grabbed vertex did not move at all (still %s) — the hover pick "
               ~ "never resolved, so nothing was measured", vecStr(got)));
    assert((got - hitCorrect).length < 0.05f,
        format("magnet landed v%d at %s; drawn-space target %s, pre-0619 target %s, "
               ~ "M^-1-normal target %s", T4_ANCHOR, vecStr(got), vecStr(hitCorrect),
               vecStr(hitWrong1), vecStr(hitWrong2)));
    assert((got - hitWrong1).length > 0.5f,
        format("magnet landed on the pre-0619 target %s", vecStr(hitWrong1)));
    assert((got - hitWrong2).length > 0.15f,
        format("magnet landed on the M^-1-carried-normal target %s", vecStr(hitWrong2)));
}

// ===========================================================================
// T5 — Stroke Extrude, aiming kind **RayPlane** (§1.2).
//
// THE PAIR: the same three laws as T4 (the plane normal is again the camera
// forward, a WORLD direction that needs `M^T`), but on a DIFFERENT anchor —
// a face centroid rather than a picked vertex — which is the half the plan
// calls out: "the seeded anchor is local and every subsequent point is world
// today; a partial fix (ray fixed, anchor not) leaves the FIRST span wrong."
//
// WHY IT READS A NUMBER. With Align to Path OFF, `extrudeAlongPath` is a
// pure translation per span, and the per-span translations telescope: the cap
// sits at `v_i + (tip - anchor)` for every corner `i` of the swept face. So
// the whole difference between the laws is one displacement, readable as a
// vertex position in `/api/model`.
//
// ORACLE (R11): `/api/model` — positions.
// ===========================================================================

enum Vec3[4] T5_BASE = [
    Vec3(-1.15f, -0.10f, -0.95f),   // 0
    Vec3( 1.35f,  0.05f, -0.70f),   // 1
    Vec3( 1.05f, -0.15f,  1.30f),   // 2
    Vec3(-0.85f,  0.20f,  1.10f),   // 3
];

// Distance from point `p` to the segment [a,b] (2D, pixels).
double distToSeg(double px, double py, double ax, double ay, double bx, double by) {
    double vx = bx - ax, vy = by - ay;
    double len2 = vx * vx + vy * vy;
    double t = len2 > 1e-9 ? ((px - ax) * vx + (py - ay) * vy) / len2 : 0.0;
    if (t < 0) t = 0; else if (t > 1) t = 1;
    double qx = ax + vx * t, qy = ay + vy * t;
    return sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy));
}

// Distance from `p` to the 3D segment [a,b].
float distToSeg3(Vec3 p, Vec3 a, Vec3 b) {
    Vec3  ab = b - a;
    float l2 = dot(ab, ab);
    float t  = l2 > 1e-9f ? dot(p - a, ab) / l2 : 0.0f;
    if (t < 0) t = 0; else if (t > 1) t = 1;
    return (p - (a + ab * t)).length;
}

unittest { // T5: the stroke's path is resolved against the DRAWN surface
    resetScene();

    float[16] M = composed(AIM_POS, AIM_ROT, AIM_SCL);
    const ModelSpace ms = aimSpaceOf(AIM_POS, AIM_ROT, AIM_SCL);

    Vec3 anchorL = (T5_BASE[0] + T5_BASE[1] + T5_BASE[2] + T5_BASE[3]) * 0.25f;
    Vec3 anchorDrawn = transformPoint(M, anchorL);

    setCameraAt(0.48f, 0.80f, 8.0f, anchorDrawn);
    auto cam0 = fetchCam();
    Vec3 d0 = transformPoint(M, T5_BASE[0]);
    Vec3 d1 = transformPoint(M, T5_BASE[1]);
    Vec3 d2 = transformPoint(M, T5_BASE[2]);
    bool flip = dot(cross(d1 - d0, d2 - d0), cam0.eye - anchorDrawn) < 0.0f;
    int[][] faces = flip ? [[0, 3, 2, 1]] : [[0, 1, 2, 3]];

    loadMesh(T5_BASE.dup, faces);
    setXform(0, AIM_POS, AIM_ROT, AIM_SCL);
    setCameraAt(0.48f, 0.80f, 8.0f, anchorDrawn);

    auto cam = fetchCam();
    auto vp  = buildViewport(cam);
    Vec3[] local = fetchVerts();
    assert(local.length == 4, format("fixture must load 4 vertices, got %d", local.length));

    float gx, gy, ix, iy;
    assert(projectOnScreen(anchorDrawn, vp, gx, gy), "drawn face centroid off-screen");
    assert(projectOnScreen(anchorL,     vp, ix, iy), "identity face centroid off-screen");
    assert(dist(gx, gy, ix, iy) > 20.0,
        format("transform does not separate drawn/identity centroid pixels (%.1f px) — vacuous",
               dist(gx, gy, ix, iy)));

    int x0 = cast(int)gx, y0 = cast(int)gy;
    int x1 = x0 + 150,    y1 = y0 - 55;

    Vec3 oW, dW, oL, dL;
    aimRays(vp, ms, cast(float)x1, cast(float)y1, oW, dW, oL, dL);
    Vec3 fwdWorld = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
    Vec3 tipCorrect, tipWrong;
    assert(rayPlaneIntersect(oL, dL, anchorL, ms.toLocalNormal(fwdWorld), tipCorrect));
    assert(rayPlaneIntersect(oW, dW, anchorL, fwdWorld,                   tipWrong));
    Vec3 dCorrect = tipCorrect - anchorL;
    Vec3 dWrong   = tipWrong   - anchorL;

    assert(dCorrect.length > 0.3f, "the stroke must actually displace the cap");
    // The wrong law's landing must not merely be a SHORTER version of the
    // right one: the sweep leaves a ring of vertices all along
    // [v, v+dCorrect], so a colinear wrong answer would coincide with an
    // intermediate ring and prove nothing.
    assert(distToSeg3(local[0] + dWrong, local[0], local[0] + dCorrect) > 0.3f,
        format("vacuous: the pre-0619 cap lands on the correct sweep's own band "
               ~ "(offset %.4f)",
               distToSeg3(local[0] + dWrong, local[0], local[0] + dCorrect)));

    selectIndices("polygons", [0]);
    cmd("tool.set tool.strokeExtrude");
    // Align to Path OFF: with it on, a path that turns rotates the band about
    // its own centroid and the telescoping identity this case reads no longer
    // holds. The aiming law under test is unaffected either way.
    cmd("tool.attr tool.strokeExtrude alignToPath false");
    playAndWait(hoverThenDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 x0, y0, x1, y1, 10));
    Thread.sleep(dur!"msecs"(250));
    cmd("tool.set tool.strokeExtrude off");

    Vec3[] after = fetchVerts();
    assert(after.length > 4,
        format("the stroke produced no geometry (still %d verts) — nothing was measured",
               after.length));

    foreach (i; 0 .. 4) {
        Vec3 want  = local[i] + dCorrect;
        Vec3 wrong = local[i] + dWrong;
        assert(hasVertexNear(after, want, 0.06f),
            format("no cap vertex at %s for corner %d — the tool resolved the stroke "
                   ~ "against the identity pose (which would put it at %s)",
                   vecStr(want), i, vecStr(wrong)));
        assert(!hasVertexNear(after, wrong, 0.06f),
            format("a cap vertex sits at the pre-0619 landing %s for corner %d",
                   vecStr(wrong), i));
    }
}

// ===========================================================================
// The Closest family (§1.3) — the ONE aiming kind whose correct space is
// WORLD, and the reason it is in the same file as the RayPlane cases above.
//
// A closest-approach election between a cursor ray and a mesh segment is NOT
// affine-invariant: under a non-uniform `M` the nearest point of the LOCAL
// rail to the local ray maps to a DIFFERENT point than the nearest point of
// the WORLD rail to the world ray. The user scrubs along the rail as it is
// DRAWN, so world is the election the cursor means. What comes back is a
// RATIO along the rail, and an affine map preserves ratios along a line — so
// the world `t` is directly the local `t` the kernel wants.
//
// Both cases below therefore assert the opposite of the RayPlane cases:
// the produced ratio must equal the WORLD election and must NOT equal the
// local one. Both are invisible at identity and under uniform scale, which is
// why AIM_SCL is non-uniform and why each case guards the two predictions
// apart before driving anything.
// ===========================================================================

// An asymmetric box: the ±0.5 cube's vertex/face layout with every corner
// nudged, so no rotation or mirror can map its vertex set onto itself.
enum Vec3[8] BOX_BASE = [
    Vec3(-0.62f, -0.55f, -0.48f),   // 0
    Vec3(-0.51f, -0.44f,  0.66f),   // 1
    Vec3(-0.58f,  0.47f, -0.60f),   // 2
    Vec3(-0.45f,  0.63f,  0.52f),   // 3
    Vec3( 0.66f, -0.49f, -0.57f),   // 4
    Vec3( 0.53f, -0.61f,  0.44f),   // 5
    Vec3( 0.48f,  0.58f, -0.45f),   // 6
    Vec3( 0.61f,  0.51f,  0.63f),   // 7
];
enum int[][] BOX_FACES = [
    [0, 2, 6, 4], [1, 5, 7, 3], [0, 1, 3, 2],
    [4, 6, 7, 5], [2, 3, 7, 6], [0, 4, 5, 1],
];

// Every undirected edge of BOX_FACES, deduplicated — the same set
// `Mesh.rebuildEdges` derives, computed here so the fixture guards can talk
// about "every OTHER edge" without needing edge INDICES over the wire.
int[2][] boxEdges() {
    int[2][] es;
    foreach (f; BOX_FACES) {
        foreach (k; 0 .. f.length) {
            int a = f[k], b = f[(k + 1) % f.length];
            int lo = a < b ? a : b, hi = a < b ? b : a;
            bool seen = false;
            foreach (e; es) if (e[0] == lo && e[1] == hi) { seen = true; break; }
            if (!seen) es ~= [lo, hi];
        }
    }
    return es;
}

// The closest-approach ratio of the cursor ray against the segment [a,b],
// using the app's OWN `closestPointOnSegmentToRay` and the app's own
// re-projection — the exact expression both slice tools run, so the
// prediction cannot drift from the implementation it is checking the SPACE of.
float railRatio(Vec3 a, Vec3 b, Vec3 o, Vec3 d) {
    Vec3  hit = closestPointOnSegmentToRay(a, b, o, d);
    Vec3  ab  = b - a;
    float den = dot(ab, ab);
    return den > 1e-12f ? dot(hit - a, ab) / den : 0.5f;
}

// How far `t` is from `u`, allowing for the rail being oriented either way
// (`seedRail` picks its (a,b) order from a face winding, so a ratio measured
// against the other order reads `1-t`).
float ratioGap(float t, float u) {
    float g0 = t - u,          g1 = t - (1.0f - u);
    if (g0 < 0) g0 = -g0;
    if (g1 < 0) g1 = -g1;
    return g0 < g1 ? g0 : g1;
}

// ===========================================================================
// T6 — Edge Slice, aiming kind **Closest** (§1.3).
//
// THE PAIR:
//   correct law  elect on the WORLD rail (`M*a`, `M*b`) -> t_world
//   wrong  law   elect on the LOCAL rail (a, b)         -> t_local  <- pre-0619
//
// The ratio is read straight off `/api/tool/state`'s `pointT` with Snap Value
// set to 0, so nothing quantizes the number between the election and the
// assertion.
//
// DISCRIMINATING INPUT: an edge whose two endpoints differ in DEPTH from the
// camera. On a fronto-parallel edge the two elections agree and the case is
// vacuous — so the guard below asserts the predictions differ before driving.
//
// ORACLE (R11): `/api/tool/state` — a scalar the tool computed. It is not the
// identity picker and asks no facing question.
// ===========================================================================

enum int T6_EDGE_A = 2;
enum int T6_EDGE_B = 6;   // a top edge running in +X, tilted in Y and Z

unittest { // T6: the cut point elects on the DRAWN rail, not the local one
    resetScene();

    float[16] M = composed(AIM_POS, AIM_ROT, AIM_SCL);
    const ModelSpace ms = aimSpaceOf(AIM_POS, AIM_ROT, AIM_SCL);

    Vec3 boxCentreDrawn;
    {
        Vec3 s = Vec3(0, 0, 0);
        foreach (v; BOX_BASE) s = s + v;
        boxCentreDrawn = transformPoint(M, s * (1.0f / 8.0f));
    }

    loadMesh(BOX_BASE.dup, BOX_FACES.dup);
    setXform(0, AIM_POS, AIM_ROT, AIM_SCL);
    setCameraAt(0.70f, 0.55f, 5.5f, boxCentreDrawn);

    auto cam = fetchCam();
    auto vp  = buildViewport(cam);
    Vec3[] local = fetchVerts();
    assert(local.length == 8, format("fixture must load 8 vertices, got %d", local.length));

    Vec3 aDrawn = transformPoint(M, local[T6_EDGE_A]);
    Vec3 bDrawn = transformPoint(M, local[T6_EDGE_B]);
    float ax, ay, bx, by;
    assert(projectOnScreen(aDrawn, vp, ax, ay), "drawn rail endpoint A off-screen");
    assert(projectOnScreen(bDrawn, vp, bx, by), "drawn rail endpoint B off-screen");

    // VACUITY (1): the transform must move the rail's pixels.
    float iax, iay;
    assert(projectOnScreen(local[T6_EDGE_A], vp, iax, iay), "identity rail endpoint off-screen");
    assert(dist(ax, ay, iax, iay) > 20.0,
        format("transform does not separate drawn/identity rail pixels (%.1f px) — vacuous",
               dist(ax, ay, iax, iay)));

    // Click at ~25% along the DRAWN rail.
    int cxi = cast(int)(ax + (bx - ax) * 0.25f);
    int cyi = cast(int)(ay + (by - ay) * 0.25f);

    // VACUITY (2): no OTHER drawn edge may pass near that pixel, or the hover
    // pick could latch a different rail and the number would mean nothing.
    foreach (e; boxEdges()) {
        if ((e[0] == T6_EDGE_A && e[1] == T6_EDGE_B) || (e[0] == T6_EDGE_B && e[1] == T6_EDGE_A))
            continue;
        float p0x, p0y, p1x, p1y;
        if (!projectOnScreen(transformPoint(M, local[e[0]]), vp, p0x, p0y)) continue;
        if (!projectOnScreen(transformPoint(M, local[e[1]]), vp, p1x, p1y)) continue;
        double dd = distToSeg(cxi, cyi, p0x, p0y, p1x, p1y);
        assert(dd > 12.0,
            format("drawn edge (%d,%d) passes %.1f px from the click — ambiguous fixture",
                   e[0], e[1], dd));
    }

    Vec3 oW, dW, oL, dL;
    aimRays(vp, ms, cast(float)cxi, cast(float)cyi, oW, dW, oL, dL);
    float tWorld = railRatio(aDrawn, bDrawn, oW, dW);
    float tLocal = railRatio(local[T6_EDGE_A], local[T6_EDGE_B], oW, dW);

    // VACUITY (3): the two elections must differ, or the case cannot separate
    // them. This is the assertion a fronto-parallel edge fails.
    float gap = tWorld - tLocal; if (gap < 0) gap = -gap;
    assert(gap > 0.03f,
        format("the world and local elections agree (t_world %.4f vs t_local %.4f) — "
               ~ "pick a rail with more depth variation", tWorld, tLocal));
    assert(tWorld > 0.02f && tWorld < 0.98f,
        format("t_world %.4f is against an endpoint — the clamp would mask the law", tWorld));

    cmd("select.typeFrom edge");
    cmd("tool.set mesh.edgeSliceTool");
    cmd("tool.attr mesh.edgeSliceTool snap 0");   // no quantization between election and readout
    playAndWait(hoverOnlyLog(cam.vpX, cam.vpY, cam.width, cam.height, cxi, cyi));
    Thread.sleep(dur!"msecs"(150));
    auto stHover = toolState();
    assert(stHover["hoveredEdge"].integer >= 0,
        "the click pixel hovers no edge — reframe the fixture: " ~ stHover.toString);

    playAndWait(clickOnlyLog(cam.vpX, cam.vpY, cam.width, cam.height, cxi, cyi));
    Thread.sleep(dur!"msecs"(150));
    auto st = toolState();
    assert(st["activePoint"].integer == 0,
        "edge slice did not latch a chain point: " ~ st.toString);
    float got = cast(float) st["pointT"].floating;
    cmd("tool.set mesh.edgeSliceTool off");

    assert(fabs(got - tWorld) < 0.02f,
        format("edge slice produced t = %.4f; the DRAWN-rail election is %.4f and the "
               ~ "identity-pose election is %.4f", got, tWorld, tLocal));
    assert(fabs(got - tLocal) > 0.03f,
        format("edge slice produced the IDENTITY-pose election t = %.4f", got));
}

// ===========================================================================
// T7 — Loop Slice, aiming kind **Closest** (§1.3).
//
// Same pair and same law as T6, on the other slice tool: `seedA_`/`seedB_`
// are raw `mesh.vertices[]` reads (the field's comment claimed "world-space"
// until this task), and the scrub elects against them.
//
// The produced ratio is read from `/api/tool/state`'s `position`. `seedRail`
// takes its (a,b) order from a face winding, so the ratio can legitimately
// come back as `1-t`; `ratioGap` allows for that and the guard below requires
// the WORLD election to be distinct from the local one under BOTH orderings,
// so the allowance cannot launder a wrong answer.
//
// ORACLE (R11): `/api/tool/state` — a scalar; no facing question.
// ===========================================================================

enum int T7_EDGE_A = 2;
enum int T7_EDGE_B = 6;

unittest { // T7: the loop scrub elects on the DRAWN rail
    resetScene();

    float[16] M = composed(AIM_POS, AIM_ROT, AIM_SCL);
    const ModelSpace ms = aimSpaceOf(AIM_POS, AIM_ROT, AIM_SCL);

    Vec3 boxCentreDrawn;
    {
        Vec3 s = Vec3(0, 0, 0);
        foreach (v; BOX_BASE) s = s + v;
        boxCentreDrawn = transformPoint(M, s * (1.0f / 8.0f));
    }

    loadMesh(BOX_BASE.dup, BOX_FACES.dup);
    setXform(0, AIM_POS, AIM_ROT, AIM_SCL);
    setCameraAt(0.70f, 0.55f, 5.5f, boxCentreDrawn);

    auto cam = fetchCam();
    auto vp  = buildViewport(cam);
    Vec3[] local = fetchVerts();
    assert(local.length == 8);

    Vec3 aDrawn = transformPoint(M, local[T7_EDGE_A]);
    Vec3 bDrawn = transformPoint(M, local[T7_EDGE_B]);
    float ax, ay, bx, by, iax, iay;
    assert(projectOnScreen(aDrawn, vp, ax, ay), "drawn rail endpoint A off-screen");
    assert(projectOnScreen(bDrawn, vp, bx, by), "drawn rail endpoint B off-screen");
    assert(projectOnScreen(local[T7_EDGE_A], vp, iax, iay), "identity rail endpoint off-screen");
    assert(dist(ax, ay, iax, iay) > 20.0,
        format("transform does not separate drawn/identity rail pixels (%.1f px) — vacuous",
               dist(ax, ay, iax, iay)));

    // Press at 20% along the drawn rail, scrub to 65% of it.
    int px0 = cast(int)(ax + (bx - ax) * 0.20f);
    int py0 = cast(int)(ay + (by - ay) * 0.20f);
    int px1 = cast(int)(ax + (bx - ax) * 0.65f);
    int py1 = cast(int)(ay + (by - ay) * 0.65f);

    foreach (e; boxEdges()) {
        if ((e[0] == T7_EDGE_A && e[1] == T7_EDGE_B) || (e[0] == T7_EDGE_B && e[1] == T7_EDGE_A))
            continue;
        float q0x, q0y, q1x, q1y;
        if (!projectOnScreen(transformPoint(M, local[e[0]]), vp, q0x, q0y)) continue;
        if (!projectOnScreen(transformPoint(M, local[e[1]]), vp, q1x, q1y)) continue;
        double dd = distToSeg(px0, py0, q0x, q0y, q1x, q1y);
        assert(dd > 12.0,
            format("drawn edge (%d,%d) passes %.1f px from the press — ambiguous fixture",
                   e[0], e[1], dd));
    }

    Vec3 oW, dW, oL, dL;
    aimRays(vp, ms, cast(float)px1, cast(float)py1, oW, dW, oL, dL);
    float tWorld = railRatio(aDrawn, bDrawn, oW, dW);
    float tLocal = railRatio(local[T7_EDGE_A], local[T7_EDGE_B], oW, dW);

    // The world election must be distinct from the local one under BOTH rail
    // orientations, so the `1-t` allowance below cannot accept a wrong answer.
    assert(ratioGap(tWorld, tLocal) > 0.04f,
        format("the two elections agree up to rail orientation (t_world %.4f, "
               ~ "t_local %.4f) — vacuous", tWorld, tLocal));
    assert(tWorld > 0.05f && tWorld < 0.95f,
        format("t_world %.4f sits in scrubPosition's clamp band", tWorld));

    cmd("select.typeFrom edge");
    cmd("tool.set mesh.loopSliceTool");
    playAndWait(hoverThenDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 px0, py0, px1, py1, 10));
    Thread.sleep(dur!"msecs"(200));
    auto st = toolState();
    assert(st["armed"].type == JSONType.true_,
        "loop slice never armed — the hover pick found no seed edge: " ~ st.toString);
    assert(st["seedEdge"].integer >= 0, "no seed edge: " ~ st.toString);
    float got = cast(float) st["position"].floating;
    cmd("tool.set mesh.loopSliceTool off");

    assert(ratioGap(got, tWorld) < 0.02f,
        format("loop slice scrubbed to %.4f; the DRAWN-rail election is %.4f (or %.4f "
               ~ "reversed) and the identity-pose election is %.4f",
               got, tWorld, 1.0f - tWorld, tLocal));
    assert(ratioGap(got, tLocal) > 0.04f,
        format("loop slice scrubbed to the IDENTITY-pose election %.4f", got));
}

// ===========================================================================
// The Topology Pen family — Stages 4a and 4b.
//
// The topology pen had ONE projection helper (`projectPt`) shared by 161 call
// sites, whose parameter was named `world` and which was handed a raw
// `mesh.vertices[...]` by most of them. Stage 4a split it in two by SPACE and
// classified every site; Stage 4b fixed the half a rename cannot reach — the
// values that cross spaces without their NAME changing (a ray/plane meet, a
// closest-point election, and three landings that write a world point into a
// local vertex array).
//
// The four cases below are one per law, not one per site: per-site coverage
// is delivered by the compile gate (`AimViewport` cannot be produced without
// a `ModelSpace`, and `projectLocalPt`/`projectWorldPt` differ in the TYPE of
// their viewport), and these cases are what catch a whole law implemented
// wrongly.
//
// P6a/P6b (the orientation admission, §1.4) are NOT here: they need to read a
// predicate that has no HTTP observable which can express all three candidate
// laws, so they live as module unittests in
// `tests/unit/tools/edit/topology_pen/gestures_test.d`,
// where the guide can be constructed directly and its own aim ray read back.
// ===========================================================================

// The pen's press-pick reach — `constraint.d`'s kTopoPenPressPickNominalPx,
// times `viewPixelScale` which is 1.0. Every fixture guard below is stated in
// terms of it: a decoy must be INSIDE it for the wrong law, and the intended
// element must be OUTSIDE it for the wrong law, or the case cannot separate.
enum float PEN_PICK_PX = 8.0f;

// The box vertex P1 aims at, and the box edge P2 aims at. They share a corner
// so ONE decoy quad serves both cases.
enum int PEN_VK = 2;
enum int PEN_EA = 2, PEN_EB = 6;

// Decoy indices in the fixture built by `penBuildFixture`.
enum int PEN_DA = 8;    // sits at the LOCAL coordinate M*box[PEN_EA]
enum int PEN_DB = 9;    // sits at the LOCAL coordinate M*box[PEN_EB]

// The box, plus a decoy quad whose first two corners are placed at the LOCAL
// coordinates `M*box[PEN_EA]` and `M*box[PEN_EB]`. Their IDENTITY-pose
// projections therefore land exactly on the two DRAWN pixels of the box's own
// vertex/edge — so the pre-0619 law does not merely miss, it elects a
// different REAL element, and the reported index (never a count, never a -1)
// is what separates the laws.
void penBuildFixture(float[16] M, out Vec3[] verts, out int[][] faces) {
    verts = BOX_BASE.dup;
    Vec3 dA = transformPoint(M, BOX_BASE[PEN_EA]);
    Vec3 dB = transformPoint(M, BOX_BASE[PEN_EB]);
    // The decoy quad's far side is pushed well clear so its OWN corners can
    // never be the nearest thing to either click pixel under either law; the
    // guards below check that rather than trusting the offset.
    Vec3 off = Vec3(0.15f, -1.30f, 0.65f);
    verts ~= [dA, dB, dB + off, dA + off];
    faces = BOX_FACES.dup;
    faces ~= [PEN_DA, PEN_DB, PEN_DB + 2, PEN_DA + 2];
}

// A faithful re-run of `findSourceVertex` (the pen's tool.d) in EITHER space.
// `M == null` is the pre-0619 law (project the raw local coordinate through
// the world viewport); `M != null` is the correct one (project the DRAWN
// point). Returns the elected index or -1, plus the winner's and runner-up's
// pixel distances so the fixture can prove the election is unambiguous.
int penNearestVertex(Vec3[] verts, const float[16]* M, const ref Viewport vp,
                     float sx, float sy, out double outBest, out double outRunnerUp)
{
    outBest = double.infinity; outRunnerUp = double.infinity;
    int best = -1;
    foreach (i, v; verts) {
        Vec3 p = (M is null) ? v : transformPoint(*M, v);
        float px, py, ndcZ;
        if (!projectToWindowFull(p, vp, px, py, ndcZ)) continue;
        double d = dist(px, py, sx, sy);
        if (d < outBest) { outRunnerUp = outBest; outBest = d; best = cast(int) i; }
        else if (d < outRunnerUp) outRunnerUp = d;
    }
    return (outBest <= PEN_PICK_PX) ? best : -1;
}

// The same for `findRingSeedEdge`: nearest projected SEGMENT, by 2D
// point-to-segment distance. Returns the winning vertex PAIR (or [-1,-1]).
int[2] penNearestEdge(Vec3[] verts, int[2][] edges, const float[16]* M,
                      const ref Viewport vp, float sx, float sy,
                      out double outBest, out double outRunnerUp)
{
    outBest = double.infinity; outRunnerUp = double.infinity;
    int[2] best = [-1, -1];
    foreach (e; edges) {
        Vec3 a = (M is null) ? verts[e[0]] : transformPoint(*M, verts[e[0]]);
        Vec3 b = (M is null) ? verts[e[1]] : transformPoint(*M, verts[e[1]]);
        float ax, ay, bx, by;
        if (!projectOnScreen(a, vp, ax, ay)) continue;
        if (!projectOnScreen(b, vp, bx, by)) continue;
        double d = distToSeg(sx, sy, ax, ay, bx, by);
        if (d < outBest) { outRunnerUp = outBest; outBest = d; best = [e[0], e[1]]; }
        else if (d < outRunnerUp) outRunnerUp = d;
    }
    return (outBest <= PEN_PICK_PX) ? best : [-1, -1];
}

// Every undirected edge of the fixture, in the SAME order `Mesh.rebuildEdges`
// derives them (first appearance while walking faces in order, each face's
// corners in winding order) — so an edge INDEX reported over the wire can be
// mapped back to a vertex pair without trusting a second copy of the mesh.
int[2][] fixtureEdges(int[][] faces) {
    int[2][] es;
    foreach (f; faces) {
        foreach (k; 0 .. f.length) {
            int a = f[k], b = f[(k + 1) % f.length];
            int lo = a < b ? a : b, hi = a < b ? b : a;
            bool seen = false;
            foreach (e; es) if (e[0] == lo && e[1] == hi) { seen = true; break; }
            if (!seen) es ~= [lo, hi];
        }
    }
    return es;
}

// `/api/model`'s own edge list for a layer — the authority for what an edge
// INDEX means, read back rather than assumed.
int[2][] fetchEdges(int layer = 0) {
    int[2][] r;
    foreach (e; getJson("/api/model?layer=" ~ layer.to!string)["edges"].array)
        r ~= [cast(int) e.array[0].integer, cast(int) e.array[1].integer];
    return r;
}

bool samePair(int[2] a, int[2] b) {
    return (a[0] == b[0] && a[1] == b[1]) || (a[0] == b[1] && a[1] == b[0]);
}

// One stationary hover — settles the pen's hover indicator without arming
// anything.
string penHoverLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    foreach (i; 0 .. 4)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            20.0 + i * 30.0, x, y);
    return log;
}

// Load the box+decoy fixture, transform layer 0, frame the camera on the
// DRAWN box, and arm the pen. Returns the live viewport and the local verts.
void penSetup(out float[16] M, out ModelSpace ms, out CamInfo cam,
              out Viewport vp, out Vec3[] local, out int[][] faces)
{
    resetScene();
    M  = composed(AIM_POS, AIM_ROT, AIM_SCL);
    ms = aimSpaceOf(AIM_POS, AIM_ROT, AIM_SCL);

    Vec3[] verts;
    penBuildFixture(M, verts, faces);
    loadMesh(verts, faces);
    setXform(0, AIM_POS, AIM_ROT, AIM_SCL);

    Vec3 boxCentre = Vec3(0, 0, 0);
    foreach (v; BOX_BASE) boxCentre = boxCentre + v;
    setCameraAt(0.70f, 0.55f, 7.0f, transformPoint(M, boxCentre * (1.0f / 8.0f)));

    cam   = fetchCam();
    vp    = buildViewport(cam);
    local = fetchVerts();
    assert(local.length == 12, format("fixture must load 12 vertices, got %d", local.length));
}

// ===========================================================================
// P1 — Topology Pen hover, aiming kind **Pixel** (§1.1). STAGE 4a.
//
// THE PAIR:
//   correct law  project `M * v_local` (compose M into the viewport)
//   wrong  law   project `v_local` through the WORLD viewport   <- pre-0619
//
// DISCRIMINATING INPUT: decoy vertex `PEN_DA` sits at the LOCAL coordinate
// `M * box[PEN_VK]`, so its identity-pose projection lands EXACTLY on the
// pixel where box vertex `PEN_VK` is DRAWN. The wrong law therefore reports a
// different vertex INDEX rather than reporting nothing — which is why every
// assertion here is about identity, not about a count or a -1.
//
// ORACLE (R11): `/api/tool/state`'s `hoverIndicator.grabElem` / `.grabIndex`
// — the pen's OWN resolution (`resolveGrabTarget` -> `findSourceVertex` /
// `findRingSeedEdge` / `pressVertexVetoed`), not the two-sided GPU identity
// picker, and no facing question is asked of it.
// ===========================================================================

unittest { // P1: the pen's hover names the DRAWN vertex, not the identity-pose one
    float[16] M; ModelSpace ms; CamInfo cam; Viewport vp; Vec3[] local; int[][] faces;
    penSetup(M, ms, cam, vp, local, faces);

    float dx_, dy_, ix_, iy_;
    assert(projectOnScreen(transformPoint(M, local[PEN_VK]), vp, dx_, dy_),
        "the drawn target vertex is off-screen");
    assert(projectOnScreen(local[PEN_VK], vp, ix_, iy_),
        "the identity-pose target vertex is off-screen");

    // VACUITY (1): the transform must actually move the pixel.
    assert(dist(dx_, dy_, ix_, iy_) > 20.0,
        format("transform does not separate drawn/identity pixels (%.1f px) — vacuous",
               dist(dx_, dy_, ix_, iy_)));

    immutable int cx = cast(int) dx_, cy = cast(int) dy_;

    // VACUITY (2): under the CORRECT law the intended vertex wins outright.
    double best, runner;
    int okPick = penNearestVertex(local, &M, vp, cx, cy, best, runner);
    assert(okPick == PEN_VK,
        format("drawn-space hover should elect v%d, elects %d", PEN_VK, okPick));
    assert(runner > PEN_PICK_PX,
        format("drawn-space hover is ambiguous: runner-up at %.1f px is inside the %.0f px "
               ~ "reach", runner, PEN_PICK_PX));

    // VACUITY (3): under the WRONG law a DIFFERENT REAL vertex is elected —
    // the decoy — and the intended one is out of reach entirely.
    int badPick = penNearestVertex(local, null, vp, cx, cy, best, runner);
    assert(badPick == PEN_DA,
        format("the pre-0619 law must elect the decoy v%d here, elects %d — the fixture "
               ~ "no longer separates the two laws", PEN_DA, badPick));
    {
        float bx, by;
        assert(projectOnScreen(local[PEN_VK], vp, bx, by));
        assert(dist(bx, by, cx, cy) > PEN_PICK_PX,
            "the intended vertex is inside the pre-0619 law's reach — vacuous");
    }

    cmd("tool.set mesh.topoPen on");
    cmd("tool.attr mesh.topoPen mode move");
    playAndWait(penHoverLog(cam.vpX, cam.vpY, cam.width, cam.height, cx, cy));
    Thread.sleep(dur!"msecs"(150));
    auto hi = toolState()["hoverIndicator"];

    assert(hi["overMesh"].type == JSONType.true_,
        "the drawn-vertex pixel must be over the mesh: " ~ hi.toString);
    assert(hi["grabElem"].str == "vertex",
        "a hover on a drawn corner must promise the VERTEX; got " ~ hi["grabElem"].str);
    assert(hi["grabIndex"].integer == PEN_VK,
        format("the pen promised v%d; the DRAWN vertex is v%d and the identity-pose "
               ~ "election is the decoy v%d",
               hi["grabIndex"].integer, PEN_VK, PEN_DA));

    // THE PAIR'S OTHER HALF: at the IDENTITY-pose pixel the pen must NOT
    // report the intended vertex. Under the pre-0619 law it reports exactly
    // that, at zero pixel distance.
    playAndWait(penHoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                            cast(int) ix_, cast(int) iy_));
    Thread.sleep(dur!"msecs"(150));
    auto hi2 = toolState()["hoverIndicator"];
    cmd("tool.set mesh.topoPen off");
    assert(!(hi2["grabElem"].str == "vertex" && hi2["grabIndex"].integer == PEN_VK),
        "the pen answered the intended vertex at its IDENTITY-pose pixel — it is still "
        ~ "aiming at where the layer would sit at identity: " ~ hi2.toString);
}

// ===========================================================================
// P2 — Topology Pen press-pick on an EDGE, aiming kind **Pixel** (§1.1).
// STAGE 4a. Same pair as P1, on `findRingSeedEdge` instead of
// `findSourceVertex`, and with the vertex clause deliberately out of reach so
// the edge clause is what answers.
//
// DISCRIMINATING INPUT: the decoy quad's `PEN_DA`-`PEN_DB` side is the pair
// of LOCAL coordinates `M*box[PEN_EA]`, `M*box[PEN_EB]`, so its identity-pose
// projection lies along the DRAWN box edge. A wrong implementation therefore
// reports a different edge INDEX, not -1.
//
// ORACLE (R11): the same `hoverIndicator` pair, mapped from an edge index
// back to a vertex pair through `/api/model`'s own `edges` array.
// ===========================================================================

unittest { // P2: the pen's edge pick elects on the DRAWN edge
    float[16] M; ModelSpace ms; CamInfo cam; Viewport vp; Vec3[] local; int[][] faces;
    penSetup(M, ms, cam, vp, local, faces);

    int[2][] wireEdges = fetchEdges(0);
    int[2][] predEdges = fixtureEdges(faces);
    assert(wireEdges.length == predEdges.length,
        format("edge count disagreement: wire %d, predicted %d",
               wireEdges.length, predEdges.length));

    Vec3 aD = transformPoint(M, local[PEN_EA]);
    Vec3 bD = transformPoint(M, local[PEN_EB]);
    float ax, ay, bx, by;
    assert(projectOnScreen(aD, vp, ax, ay), "drawn edge endpoint A off-screen");
    assert(projectOnScreen(bD, vp, bx, by), "drawn edge endpoint B off-screen");

    // 40% along the drawn edge — far enough from both corners that the vertex
    // clause cannot fire (asserted below), which is what makes this an EDGE
    // case rather than a second copy of P1.
    immutable int cx = cast(int)(ax + (bx - ax) * 0.40f);
    immutable int cy = cast(int)(ay + (by - ay) * 0.40f);

    // VACUITY (1): the transform moves the pixel.
    {
        float iax, iay;
        assert(projectOnScreen(local[PEN_EA], vp, iax, iay), "identity endpoint off-screen");
        assert(dist(ax, ay, iax, iay) > 20.0,
            format("transform does not separate drawn/identity edge pixels (%.1f px) — vacuous",
                   dist(ax, ay, iax, iay)));
    }

    // VACUITY (2): no vertex is within reach under EITHER law, so the edge
    // clause is what both laws answer with.
    {
        double b0, r0;
        assert(penNearestVertex(local, &M,   vp, cx, cy, b0, r0) < 0,
            "a drawn vertex is inside the pick reach — this would be a vertex case");
        assert(penNearestVertex(local, null, vp, cx, cy, b0, r0) < 0,
            "an identity-pose vertex is inside the pick reach — ambiguous fixture");
    }

    // VACUITY (3): the two laws elect DIFFERENT REAL edges.
    double best, runner;
    int[2] okEdge  = penNearestEdge(local, predEdges, &M,   vp, cx, cy, best, runner);
    assert(samePair(okEdge, [PEN_EA, PEN_EB]),
        format("drawn-space pick should elect edge (%d,%d), elects (%d,%d)",
               PEN_EA, PEN_EB, okEdge[0], okEdge[1]));
    assert(runner > PEN_PICK_PX,
        format("drawn-space edge pick is ambiguous: runner-up at %.1f px", runner));
    int[2] badEdge = penNearestEdge(local, predEdges, null, vp, cx, cy, best, runner);
    assert(samePair(badEdge, [PEN_DA, PEN_DB]),
        format("the pre-0619 law must elect the decoy edge (%d,%d) here, elects (%d,%d)",
               PEN_DA, PEN_DB, badEdge[0], badEdge[1]));

    cmd("tool.set mesh.topoPen on");
    cmd("tool.attr mesh.topoPen mode move");
    playAndWait(penHoverLog(cam.vpX, cam.vpY, cam.width, cam.height, cx, cy));
    Thread.sleep(dur!"msecs"(150));
    auto hi = toolState()["hoverIndicator"];
    cmd("tool.set mesh.topoPen off");

    assert(hi["grabElem"].str == "edge",
        "a hover along a drawn edge, clear of every corner, must promise the EDGE; got "
        ~ hi["grabElem"].str);
    immutable long ei = hi["grabIndex"].integer;
    assert(ei >= 0 && ei < wireEdges.length,
        format("reported edge index %d is out of range", ei));
    int[2] gotPair = wireEdges[cast(size_t) ei];
    assert(samePair(gotPair, [PEN_EA, PEN_EB]),
        format("the pen promised edge (%d,%d); the DRAWN edge is (%d,%d) and the "
               ~ "identity-pose election is the decoy (%d,%d)",
               gotPair[0], gotPair[1], PEN_EA, PEN_EB, PEN_DA, PEN_DB));
}

// ===========================================================================
// P3 — Topology Pen Place, aiming kind **Landing** (§1.5). STAGE 4b.
//
// Not an aiming kind at all: the same defect one call deeper. The CONS stage
// publishes its raycast hit in WORLD space (0617), against a BACKGROUND
// layer; `mesh.addVertex` stores a coordinate in the PRIMARY layer's LOCAL
// array. The pen used to hand the world hit straight to `addVertex`.
//
// THE PAIR:
//   correct law  the stored coordinate is `M_primary^-1 * hit_world`
//   wrong  law   the stored coordinate is `hit_world`             <- pre-0619
//
// DISCRIMINATING INPUT: the primary and the background carry DIFFERENT
// transforms (the background is identity, the primary is not) — without that
// the two laws are indistinguishable, which is why this case cannot be built
// on a single-layer scene.
//
// The expected hit is computed here from the app's own `screenPointToRay` and
// `rayPlaneIntersect` against the background quad's plane — an independent
// prediction, never a second server reading compared against the first.
//
// ORACLE (R11): `/api/model?layer=1` — a stored position. No facing question.
// ===========================================================================

// A big background quad in the y = -1.2 plane, wide enough that the centre
// pixel's ray lands well inside it (asserted below, not assumed).
enum Vec3[4] P3_BG = [
    Vec3(-6.0f, -1.20f, -6.0f),
    Vec3( 6.0f, -1.20f, -6.0f),
    Vec3( 6.0f, -1.20f,  6.0f),
    Vec3(-6.0f, -1.20f,  6.0f),
];

Vec3[] fetchVertsLayer(int layer) { return fetchVerts(layer); }

unittest { // P3: Place stores the LOCAL pre-image of the world hit
    resetScene();

    // Layer 0 = background quad (identity). Layer 1 = the empty primary the
    // pen edits, carrying the transform.
    loadMesh(P3_BG.dup, [[0, 1, 2, 3]]);
    cmd("layer.add name:Edit");
    setXform(1, AIM_POS, AIM_ROT, AIM_SCL);

    setCameraAt(0.35f, 0.62f, 9.0f, Vec3(0, -1.2f, 0));
    auto cam = fetchCam();
    auto vp  = buildViewport(cam);

    const ModelSpace ms = aimSpaceOf(AIM_POS, AIM_ROT, AIM_SCL);

    immutable int cx = cam.vpX + cam.width / 2;
    immutable int cy = cam.vpY + cam.height / 2;

    Vec3 oW, dW;
    screenPointToRay(cast(float) cx, cast(float) cy, vp, oW, dW);
    Vec3 hitWorld;
    assert(rayPlaneIntersect(oW, dW, P3_BG[0], Vec3(0, 1, 0), hitWorld),
        "the centre-pixel ray must meet the background plane");
    // ...and inside the quad, or the raycast would miss the facet entirely.
    assert(hitWorld.x > -5.0f && hitWorld.x < 5.0f && hitWorld.z > -5.0f && hitWorld.z < 5.0f,
        format("the centre-pixel hit (%.3f,%.3f,%.3f) is outside the background quad",
               hitWorld.x, hitWorld.y, hitWorld.z));

    Vec3 expectedLocal = ms.toLocalPoint(hitWorld);

    // VACUITY: the two laws must predict positions far apart, or storing the
    // world point would be indistinguishable from storing its pre-image.
    assert((expectedLocal - hitWorld).length > 0.5f,
        format("the local pre-image %s and the world hit %s are only %.3f apart — vacuous",
               expectedLocal, hitWorld, (expectedLocal - hitWorld).length));

    assert(fetchVertsLayer(1).length == 0, "the primary layer must start empty");

    cmd("tool.set mesh.topoPen on");
    cmd("tool.attr mesh.topoPen mode point");   // the place-on-empty gesture
    playAndWait(clickOnlyLog(cam.vpX, cam.vpY, cam.width, cam.height, cx, cy));
    Thread.sleep(dur!"msecs"(200));
    cmd("tool.set mesh.topoPen off");

    Vec3[] placed = fetchVertsLayer(1);
    assert(placed.length == 1,
        format("Place must add exactly one vertex to the primary; got %d", placed.length));

    // The pixel is integer-quantised and the tool re-derives its own ray, so
    // a small tolerance is inherent; it is an order of magnitude below the
    // vacuity gap above.
    assert((placed[0] - expectedLocal).length < 0.05f,
        format("Place stored %s; the LOCAL pre-image of the world hit is %s and the raw "
               ~ "world hit is %s", placed[0], expectedLocal, hitWorld));
    assert((placed[0] - hitWorld).length > 0.4f,
        format("Place stored the RAW WORLD hit %s — the value never came back into the "
               ~ "layer's own space", placed[0]));

    assert(fetchVertsLayer(0).length == 4, "the background layer must be untouched");
}

// ===========================================================================
// P5 — Topology Pen Add Loop, aiming kind **Closest** (§1.3). STAGE 4b.
//
// THE PAIR:
//   correct law  elect on the WORLD rail (`M*a`, `M*b`) -> t_world
//   wrong  law   elect on the LOCAL rail (a, b)         -> t_local  <- pre-0619
//
// `seedRail` fills `seedRailA_`/`seedRailB_` from raw `m.vertices[]` (their
// field comment said "world-space endpoints" until this task) and
// `ratioOnSegment` elected against them directly. The election is not
// affine-invariant, so the two answers genuinely differ under a non-uniform
// scale — and the ratio that comes back IS affine-invariant, which is why no
// back-transform is needed once the election is done in the right space.
//
// DISCRIMINATING INPUT: a seed edge whose endpoints differ in DEPTH. On a
// fronto-parallel rail the two elections agree; the guard below asserts they
// differ under BOTH rail orientations before anything is driven.
//
// ORACLE (R11): `/api/tool/state`'s `addLoopRatio` — a scalar the tool
// computed. No facing question.
//
// SATURATING RED, stated rather than dressed up. The deliberate-break check
// for this case (elect on the local rail) reads **1.0000** against the
// correct 0.7000 — and 1.0 is the top of `ratioOnSegment`'s own `[0,1]`
// clamp. On this fixture the local rail sits far enough off the world ray
// that its nearest point is an ENDPOINT, so the wrong law is indistinguishable
// from any other law that overshoots the rail. The negative assertion below
// is therefore NOT what carries this case; the positive one is — it pins the
// exact drawn-rail election (0.70 of the rail, the pixel the drag ended on),
// which no overshooting law can produce. Reducing the transform until the
// local election lands in range would also collapse the two elections onto
// each other, which is the vacuity this case's guard (3) forbids.
// ===========================================================================

enum uint P5_LSHIFT = 0x0001;   // KMOD_LSHIFT — the Add Loop gesture's modifier

// Shift+MMB press then drag, with NO release: `addLoopRatio` is arm state and
// a release commits and clears it.
string mmbDragNoReleaseLog(int vpX, int vpY, int vpW, int vpH,
                           int x0, int y0, int x1, int y1, int steps)
{
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    log ~= format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":2,"x":%d,"y":%d,"clicks":1,"mod":%u}` ~ "\n",
        x0, y0, P5_LSHIFT);
    int lastX = x0, lastY = y0;
    foreach (i; 1 .. steps + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,` ~
            `"state":2,"mod":%u}` ~ "\n",
            50.0 + i * 40.0, x, y, x - lastX, y - lastY, P5_LSHIFT);
        lastX = x; lastY = y;
    }
    return log;
}

string mmbReleaseLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH)
      ~ format(`{"t":20.000,"type":"SDL_MOUSEBUTTONUP","btn":2,"x":%d,"y":%d,"clicks":1,"mod":%u}` ~ "\n",
               x, y, P5_LSHIFT);
}

unittest { // P5: Add Loop's ratio elects on the DRAWN rail
    resetScene();

    float[16] M = composed(AIM_POS, AIM_ROT, AIM_SCL);
    const ModelSpace ms = aimSpaceOf(AIM_POS, AIM_ROT, AIM_SCL);

    Vec3 boxCentre = Vec3(0, 0, 0);
    foreach (v; BOX_BASE) boxCentre = boxCentre + v;

    loadMesh(BOX_BASE.dup, BOX_FACES.dup);
    setXform(0, AIM_POS, AIM_ROT, AIM_SCL);
    setCameraAt(0.70f, 0.55f, 5.5f, transformPoint(M, boxCentre * (1.0f / 8.0f)));

    auto cam = fetchCam();
    auto vp  = buildViewport(cam);
    Vec3[] local = fetchVerts();
    assert(local.length == 8, format("fixture must load 8 vertices, got %d", local.length));
    // Read the edge table BEFORE anything is driven: the release below COMMITS
    // the loop cut, which appends vertices and rewrites the edge array, so an
    // index resolved afterwards would name a different pair.
    int[2][] wireEdges = fetchEdges(0);
    assert(wireEdges.length == 12, format("the box must have 12 edges, got %d", wireEdges.length));

    Vec3 aDrawn = transformPoint(M, local[T6_EDGE_A]);
    Vec3 bDrawn = transformPoint(M, local[T6_EDGE_B]);
    float ax, ay, bx, by, iax, iay;
    assert(projectOnScreen(aDrawn, vp, ax, ay), "drawn rail endpoint A off-screen");
    assert(projectOnScreen(bDrawn, vp, bx, by), "drawn rail endpoint B off-screen");
    assert(projectOnScreen(local[T6_EDGE_A], vp, iax, iay), "identity rail endpoint off-screen");

    // VACUITY (1): the transform moves the rail's pixels.
    assert(dist(ax, ay, iax, iay) > 20.0,
        format("transform does not separate drawn/identity rail pixels (%.1f px) — vacuous",
               dist(ax, ay, iax, iay)));

    // Press at 20% along the DRAWN rail, drag to 70% of it.
    immutable int px0 = cast(int)(ax + (bx - ax) * 0.20f);
    immutable int py0 = cast(int)(ay + (by - ay) * 0.20f);
    immutable int px1 = cast(int)(ax + (bx - ax) * 0.70f);
    immutable int py1 = cast(int)(ay + (by - ay) * 0.70f);

    // VACUITY (2): no OTHER drawn edge passes near the press, or the seed
    // pick could latch a different rail and the ratio would mean nothing.
    foreach (e; boxEdges()) {
        if (samePair([e[0], e[1]], [T6_EDGE_A, T6_EDGE_B])) continue;
        float q0x, q0y, q1x, q1y;
        if (!projectOnScreen(transformPoint(M, local[e[0]]), vp, q0x, q0y)) continue;
        if (!projectOnScreen(transformPoint(M, local[e[1]]), vp, q1x, q1y)) continue;
        double dd = distToSeg(px0, py0, q0x, q0y, q1x, q1y);
        assert(dd > 10.0,
            format("drawn edge (%d,%d) passes %.1f px from the press — ambiguous fixture",
                   e[0], e[1], dd));
    }

    Vec3 oW, dW, oL, dL;
    aimRays(vp, ms, cast(float) px1, cast(float) py1, oW, dW, oL, dL);
    float tWorld = railRatio(aDrawn, bDrawn, oW, dW);
    float tLocal = railRatio(local[T6_EDGE_A], local[T6_EDGE_B], oW, dW);

    // VACUITY (3): the elections must differ under BOTH rail orientations —
    // `seedRail` takes its (a,b) order from a face winding, so the answer may
    // legitimately arrive as `1-t` and `ratioGap` must not launder a wrong one.
    assert(ratioGap(tWorld, tLocal) > 0.04f,
        format("the world and local elections agree up to rail orientation "
               ~ "(t_world %.4f, t_local %.4f) — pick a rail with more depth variation",
               tWorld, tLocal));
    assert(tWorld > 0.05f && tWorld < 0.95f,
        format("t_world %.4f is against an endpoint — the [0,1] clamp would mask the law",
               tWorld));

    cmd("tool.set mesh.topoPen on");
    playAndWait(mmbDragNoReleaseLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                    px0, py0, px1, py1, 10));
    Thread.sleep(dur!"msecs"(200));
    auto st = toolState();
    // Clean up the arm before any assertion can abort the block.
    playAndWait(mmbReleaseLog(cam.vpX, cam.vpY, cam.width, cam.height, px1, py1));
    Thread.sleep(dur!"msecs"(150));
    cmd("tool.set mesh.topoPen off");

    assert(st["addLoopArmed"].type == JSONType.true_,
        "Add Loop never armed — the press found no ring seed edge: " ~ st.toString);
    immutable long seed = st["addLoopSeed"].integer;
    assert(seed >= 0 && seed < wireEdges.length, format("seed edge %d out of range", seed));
    assert(samePair(wireEdges[cast(size_t) seed], [T6_EDGE_A, T6_EDGE_B]),
        format("Add Loop seeded edge (%d,%d), not the drawn rail (%d,%d) — this case is "
               ~ "about the RATIO, so a wrong seed makes it meaningless",
               wireEdges[cast(size_t) seed][0], wireEdges[cast(size_t) seed][1],
               T6_EDGE_A, T6_EDGE_B));

    immutable float got = cast(float) st["addLoopRatio"].floating;
    assert(ratioGap(got, tWorld) < 0.03f,
        format("Add Loop tracked ratio %.4f; the DRAWN-rail election is %.4f (or %.4f "
               ~ "reversed) and the identity-pose election is %.4f",
               got, tWorld, 1.0f - tWorld, tLocal));
    // The negative half. NOTE it is weak on this fixture — see the block
    // comment: the local election saturates at the clamp, so this cannot
    // separate "elected on the local rail" from "overshot for any other
    // reason". The assertion above is the one with the discriminating power.
    assert(ratioGap(got, tLocal) > 0.04f,
        format("Add Loop tracked the IDENTITY-pose election %.4f (saturating: t_local is "
               ~ "%.4f, at the [0,1] clamp)", got, tLocal));
}

// ===========================================================================
// VERIFIED BY MUTATION. Each wrong implementation below was applied to the
// green tree, built, and run; the observed failure is recorded beside it, and
// the tree was restored and re-run green afterwards.
//
//   F1 — `http_providers.d`'s weights block composed `ModelSpace.world()`
//        instead of `primaryModelSpace()` (the pre-0619 law for this path).
//        RED: `weights=[0,0,0,0, 0.761, 0.588, 0.772, 0.628]` — the two sets
//        exactly SWAPPED: the four targets dropped to zero and the four
//        decoys, which sit at the targets' identity-pose pixels, took the
//        weight. Not "a bit off": the other set entirely.
//
//   F2 — `TransformTool.dragAimSpace()` composed `ModelSpace.world()`.
//        RED: `moved=[0, 0, 0, 0, 1.896, 1.419, 1.850, 1.552]` — the drag
//        deformed the decoys and left the targets untouched. This is the
//        mutation F1 CANNOT see: the reporting block and the deform kernel
//        compose their aim spaces separately.
//
//   F3 — `FalloffStage.autoSize`'s Screen branch composed
//        `ModelSpace.world()` while `screenWeight` stayed correct (the HALF
//        conversion). RED: `weights=[0,0,0,0,0,0,0,0]` — the auto-sized disc
//        was placed on the identity-pose selection while the weights were
//        measured on the drawn one, so nothing at all was weighted.
// ===========================================================================

// ===========================================================================
// F1 — Screen falloff, aiming kind **Pixel** (§1.1).
//
// THE PAIR THIS CASE ASSERTS, and the wrong implementation it separates:
//
//   correct law  project `M * v_local` — the screen disc weights the vertices
//                it is DRAWN over
//   wrong  law   project `v_local` through the WORLD viewport  <- pre-0619
//
// The fixture makes the two laws select **disjoint** vertex sets, not merely
// overlapping ones (the plan's F1 requirement — a transform that leaves the
// two footprints overlapping proves nothing). Two quads:
//
//   TGT   quads 0-3. The geometry a user aiming at the drawn disc means to
//         weight.
//   DEC   quads 4-7, planted at the LOCAL coordinates `M * TGT[i]`. Their
//         identity-pose projections therefore land exactly where TGT's DRAWN
//         projections land, so the WRONG law weights THEM and not TGT.
//
// The observable is `/api/toolpipe/eval`'s `falloffWeights` block — one
// weight per vertex, in mesh vertex order. It is the per-vertex value the
// deform kernels multiply by, so this is the quantity itself and not a proxy.
//
// Anti-vacuity, asserted before any weight is read:
//   * TGT's drawn and identity pixels differ by > 20 px;
//   * every TGT vertex is INSIDE the disc under the correct law;
//   * every TGT vertex is OUTSIDE it under the wrong law, and every DEC
//     vertex is the other way round.
// If any of that stops holding the case fails loudly instead of going quiet.
// ===========================================================================

enum Vec3 F1_POS = Vec3( 2.50f, -1.20f,  0.80f);
enum Vec3 F1_ROT = Vec3(10.0f,  35.0f,  -6.0f);
enum Vec3 F1_SCL = Vec3( 1.50f,  1.00f,  0.70f);

// A small, deliberately skew quad — no two corners share a coordinate, so it
// cannot map onto itself under the transform above.
enum Vec3[4] F1_TGT = [
    Vec3(-0.95f,  0.22f, -0.58f),
    Vec3(-0.73f,  0.30f, -0.50f),
    Vec3(-0.81f,  0.08f, -0.39f),
    Vec3(-1.00f,  0.00f, -0.53f),
];

enum float F1_RADIUS_PX = 35.0f;

/// Weight-carrying vertices, by index, from a `falloffWeights` array.
bool[] f1Carrying(JSONValue ev, size_t n) {
    assert("falloffWeights" in ev,
        "/api/toolpipe/eval has no falloffWeights block — the screen falloff "
        ~ "never reached the stage: " ~ ev.toString);
    auto ws = ev["falloffWeights"].array;
    assert(ws.length == n,
        format("falloffWeights has %d entries, mesh has %d vertices",
               ws.length, n));
    bool[] r;
    r.length = n;
    foreach (i, w; ws) r[i] = (cast(double) w.floating) > 1e-6;
    return r;
}

unittest { // F1: the screen disc weights the vertices it is DRAWN over
    resetScene();

    float[16] M = composed(F1_POS, F1_ROT, F1_SCL);

    // TGT then DEC; DEC's local coordinate is TGT's drawn position.
    Vec3[] verts;
    foreach (v; F1_TGT) verts ~= v;
    foreach (v; F1_TGT) verts ~= transformPoint(M, v);
    int[][] faces = [[0, 1, 2, 3], [4, 5, 6, 7]];
    loadMesh(verts, faces);

    // /api/load-mesh may reframe, so the transform and camera go on after it.
    setXform(0, F1_POS, F1_ROT, F1_SCL);
    setCamera(0.55f, 0.30f, 13.0f);

    auto cam = fetchCam();
    auto vp  = buildViewport(cam);

    // The disc is centred on the DRAWN centroid of TGT.
    float cx = 0, cy = 0;
    foreach (v; F1_TGT) {
        float px, py;
        assert(projectOnScreen(transformPoint(M, v), vp, px, py),
            "fixture: every drawn target corner must be on screen");
        cx += px * 0.25f; cy += py * 0.25f;
    }

    // --- anti-vacuity, all before a single weight is read -----------------
    foreach (i, v; F1_TGT) {
        float dx, dy, ix, iy;
        assert(projectOnScreen(transformPoint(M, v), vp, dx, dy));
        assert(projectOnScreen(v, vp, ix, iy),
            "fixture: the identity-pose corner must also be on screen, or the "
            ~ "wrong law would merely fail to project and measure nothing");
        assert(dist(dx, dy, ix, iy) > 20.0,
            format("vacuous fixture: target %d projects to the same pixel "
                   ~ "under both laws (%.1f px apart)", i, dist(dx, dy, ix, iy)));
        assert(dist(dx, dy, cx, cy) < F1_RADIUS_PX,
            format("fixture: drawn target %d is %.1f px from the disc centre, "
                   ~ "outside the %.0f px radius", i, dist(dx, dy, cx, cy),
                   F1_RADIUS_PX));
        assert(dist(ix, iy, cx, cy) > F1_RADIUS_PX,
            format("vacuous fixture: identity-pose target %d is INSIDE the "
                   ~ "disc (%.1f px), so both laws would weight it", i,
                   dist(ix, iy, cx, cy)));
    }
    foreach (i, v; F1_TGT) {
        Vec3 dec = transformPoint(M, v);       // the decoy's LOCAL coordinate
        float dx, dy, ix, iy;
        assert(projectOnScreen(transformPoint(M, dec), vp, dx, dy),
            "fixture: every drawn decoy corner must be on screen");
        assert(projectOnScreen(dec, vp, ix, iy));
        assert(dist(ix, iy, cx, cy) < F1_RADIUS_PX,
            format("fixture: identity-pose decoy %d is %.1f px out — the wrong "
                   ~ "law must weight the decoys, or the case only proves the "
                   ~ "targets are weighted and not that the OTHER set is not",
                   i, dist(ix, iy, cx, cy)));
        assert(dist(dx, dy, cx, cy) > F1_RADIUS_PX,
            format("vacuous fixture: drawn decoy %d is INSIDE the disc "
                   ~ "(%.1f px)", i, dist(dx, dy, cx, cy)));
    }

    // --- drive ------------------------------------------------------------
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type screen");
    cmd(format("tool.pipe.attr falloff screenCx %.4f", cx));
    cmd(format("tool.pipe.attr falloff screenCy %.4f", cy));
    cmd(format("tool.pipe.attr falloff screenSize %.4f", F1_RADIUS_PX));
    Thread.sleep(dur!"msecs"(150));

    auto ev = getJson("/api/toolpipe/eval");
    auto carrying = f1Carrying(ev, verts.length);
    cmd("tool.set move off");

    // --- the pair ---------------------------------------------------------
    foreach (i; 0 .. 4)
        assert(carrying[i],
            format("target vertex %d carries no weight — the disc weighted the "
                   ~ "IDENTITY-pose footprint. weights=%s",
                   i, ev["falloffWeights"].toString));
    foreach (i; 4 .. 8)
        assert(!carrying[i],
            format("decoy vertex %d carries weight — it sits at the target's "
                   ~ "identity-pose pixel, so the disc is still projecting "
                   ~ "through the world viewport. weights=%s",
                   i, ev["falloffWeights"].toString));
}

// ===========================================================================
// F2 — Screen falloff through the DEFORM KERNEL, not the reporting block.
//
// F1 above reads `/api/toolpipe/eval`'s `falloffWeights`, which is precise
// but is produced by its own aim-space composition (`http_providers.d`). The
// weight the geometry actually moves by is composed somewhere else — the
// transform tool's `dragAimSpace()`, handed to `xform_kernels`. A conversion
// that fixed one and not the other would pass F1 and still deform the wrong
// vertices, so this case drives a real drag and reads GEOMETRY.
//
// Same fixture and the same pair: the drawn footprint and the identity-pose
// footprint are DISJOINT vertex sets, so a wrong implementation does not move
// the targets by a smaller amount — it moves the OTHER four instead.
//
// The press pixel doubles as the disc centre: MoveTool re-centres the screen
// falloff at the click (`screenFalloffSetCenter`), so no `screenCx/Cy` is set
// here and the case exercises the click-driven path a user takes.
// ===========================================================================
unittest { // F2: the drag moves the vertices the disc is DRAWN over
    resetScene();

    float[16] M = composed(F1_POS, F1_ROT, F1_SCL);
    Vec3[] verts;
    foreach (v; F1_TGT) verts ~= v;
    foreach (v; F1_TGT) verts ~= transformPoint(M, v);
    loadMesh(verts, [[0, 1, 2, 3], [4, 5, 6, 7]]);

    setXform(0, F1_POS, F1_ROT, F1_SCL);
    setCamera(0.55f, 0.30f, 13.0f);

    auto cam = fetchCam();
    auto vp  = buildViewport(cam);

    float cx = 0, cy = 0;
    foreach (v; F1_TGT) {
        float px, py;
        assert(projectOnScreen(transformPoint(M, v), vp, px, py));
        cx += px * 0.25f; cy += py * 0.25f;
    }

    // The fixture guards are F1's; re-assert only the one that makes THIS
    // case's pair meaningful — that the two footprints are disjoint.
    foreach (i, v; F1_TGT) {
        float dx, dy, ix, iy;
        assert(projectOnScreen(transformPoint(M, v), vp, dx, dy));
        assert(projectOnScreen(v, vp, ix, iy));
        assert(dist(dx, dy, cx, cy) < F1_RADIUS_PX
            && dist(ix, iy, cx, cy) > F1_RADIUS_PX,
            format("vacuous fixture: target %d is not cleanly inside-drawn / "
                   ~ "outside-identity (drawn %.1f px, identity %.1f px, "
                   ~ "radius %.0f)", i, dist(dx, dy, cx, cy),
                   dist(ix, iy, cx, cy), F1_RADIUS_PX));
    }

    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type screen");
    cmd(format("tool.pipe.attr falloff screenSize %.4f", F1_RADIUS_PX));
    Thread.sleep(dur!"msecs"(120));

    auto before = fetchVerts();
    assert(before.length == 8, "fixture: eight vertices");

    // Press ON the drawn centroid (which sets the disc centre), drag away.
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cast(int) cx, cast(int) cy,
                             cast(int) cx + 90, cast(int) cy - 40, 12));
    Thread.sleep(dur!"msecs"(200));
    auto after = fetchVerts();
    cmd("tool.set move off");

    assert(after.length == before.length, "the drag must not change the count");

    double[] moved;
    moved.length = before.length;
    foreach (i; 0 .. before.length) moved[i] = (after[i] - before[i]).length;

    string report = format("moved=%s", moved);
    foreach (i; 0 .. 4)
        assert(moved[i] > 1e-3,
            format("target vertex %d did not move — the screen disc weighted "
                   ~ "the IDENTITY-pose footprint. %s", i, report));
    foreach (i; 4 .. 8)
        assert(moved[i] < 1e-4,
            format("decoy vertex %d moved — it sits at a target's identity-pose "
                   ~ "pixel, so the disc is still projecting through the world "
                   ~ "viewport. %s", i, report));
}

// ===========================================================================
// F3 — the AUTO-SIZED screen disc lands on the drawn selection.
//
// `FalloffStage.autoSize` places the screen disc on the selection's bounding
// box when the falloff type is switched to Screen: it projects the bbox
// centroid and the eight corners to get `screenCx/Cy` and `screenSize`. The
// bbox comes from `mesh.selectionBBoxMinMax*`, which scans raw LOCAL vertices.
//
// WHY THIS NEEDS ITS OWN CASE, and why F1/F2 cannot cover it: if `autoSize`
// and `screenWeight` are BOTH wrong, their two errors cancel — the disc is
// centred on the identity-pose selection and the weights are measured there
// too, so the selection still comes out weighted. The defect this case can
// see is the HALF conversion: `screenWeight` fixed (F1/F2 force that) while
// `autoSize` still projects through the world viewport. Then the disc is
// placed at the identity-pose centroid while the weights are measured at the
// drawn positions, and the auto-sized selection gets NOTHING.
//
// Discriminating input: the selection's drawn and identity-pose centroids are
// further apart than the disc's own auto-derived radius — asserted below
// rather than assumed, because a small transform would let the mis-placed
// disc still cover the selection and the case would go vacuous.
// ===========================================================================
unittest { // F3: auto-size centres the disc on the DRAWN selection
    resetScene();

    float[16] M = composed(F1_POS, F1_ROT, F1_SCL);
    Vec3[] verts;
    foreach (v; F1_TGT) verts ~= v;
    foreach (v; F1_TGT) verts ~= transformPoint(M, v);
    loadMesh(verts, [[0, 1, 2, 3], [4, 5, 6, 7]]);

    setXform(0, F1_POS, F1_ROT, F1_SCL);
    setCamera(0.55f, 0.30f, 13.0f);

    auto cam = fetchCam();
    auto vp  = buildViewport(cam);

    // Drawn and identity-pose centroids of the TGT quad, plus the drawn
    // radius auto-size would derive from it.
    float dcx = 0, dcy = 0, icx = 0, icy = 0;
    foreach (v; F1_TGT) {
        float dx, dy, ix, iy;
        assert(projectOnScreen(transformPoint(M, v), vp, dx, dy));
        assert(projectOnScreen(v, vp, ix, iy));
        dcx += dx * 0.25f; dcy += dy * 0.25f;
        icx += ix * 0.25f; icy += iy * 0.25f;
    }
    double drawnR = 0;
    foreach (v; F1_TGT) {
        float dx, dy;
        assert(projectOnScreen(transformPoint(M, v), vp, dx, dy));
        auto d = dist(dx, dy, dcx, dcy);
        if (d > drawnR) drawnR = d;
    }
    assert(dist(dcx, dcy, icx, icy) > drawnR * 2.0,
        format("vacuous fixture: the drawn and identity-pose centroids are "
               ~ "%.1f px apart but the auto-sized radius is ~%.1f px — a disc "
               ~ "placed on the wrong one would still cover the selection",
               dist(dcx, dcy, icx, icy), drawnR));

    // Select ONLY the target quad's vertices, so the bbox auto-size reads is
    // theirs and not the whole mesh's.
    selectIndices("vertices", [0, 1, 2, 3]);
    cmd("tool.set move");
    Thread.sleep(dur!"msecs"(150));     // let the pipe publish a viewport

    // Switching the type is what triggers autoSize; no screenCx/Cy/Size here.
    cmd("tool.pipe.attr falloff type screen");
    Thread.sleep(dur!"msecs"(150));

    auto ev = getJson("/api/toolpipe/eval");
    auto carrying = f1Carrying(ev, verts.length);
    cmd("tool.set move off");

    foreach (i; 0 .. 4)
        assert(carrying[i],
            format("selected vertex %d carries no weight after auto-size — the "
                   ~ "disc was placed on the IDENTITY-pose selection while the "
                   ~ "weights are measured on the drawn one. weights=%s",
                   i, ev["falloffWeights"].toString));
}
