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

import std.net.curl;
import std.json;
import std.conv      : to;
import std.math      : sqrt, PI, fabs;
import std.format    : format;
import core.thread   : Thread;
import core.time     : dur;

import math     : Vec3, Viewport, transformPoint, projectToWindow,
                  projectToWindowFull, lookAt, perspectiveMatrix;
import document : ItemXform;

// buildDragLog/playAndWait pulled in by NAME only — drag_helpers defines its
// own Vec3/Viewport, so a blanket import would collide with the math.* types.
import drag_helpers : buildDragLog, playAndWait;

void main() {}

enum string BASE = "http://localhost:8080";

// DragWeldTool's own pick radius (source/tools/edit/drag_weld.d
// PICK_RADIUS_PX). The fixture guards below are stated in terms of it: a
// decoy must be INSIDE it for the wrong implementation, and every real
// vertex must be OUTSIDE it, or the case cannot separate the two laws.
enum float PICK_RADIUS_PX = 12.0f;

// ---------------------------------------------------------------------------
// HTTP plumbing
// ---------------------------------------------------------------------------

JSONValue getJson(string path) { return parseJSON(cast(string) get(BASE ~ path)); }
JSONValue postJson(string path, string body_) { return parseJSON(cast(string) post(BASE ~ path, body_)); }

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
    auto j = postJson("/api/reset", "");
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
    auto j = postJson("/api/load-mesh", `{"vertices":[` ~ vs ~ `],"faces":[` ~ fs ~ `]}`);
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
