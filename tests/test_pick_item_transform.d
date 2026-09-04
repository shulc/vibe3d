// Task 0617 Stage 6 — the end-to-end acceptance test
// (doc/picking_item_transform_plan.md).
//
// Stages 0-4 each proved ONE mechanism in isolation (a cull flips, a
// candidate is emitted in world, a distance stays a world distance). None of
// them proves the whole chain from a click to a selection survives intact on
// a transformed layer. This file is that end-to-end proof, and it is
// SPECIFIC: a click at the pixel where an element is DRAWN must select THAT
// element — not "something", not "the count changed".
//
// This is a SOURCE-BACKED test (imports `math` and `document` at column 0,
// see run_test.d:isSourceBackedTest) so it can build the exact composed
// matrix the app itself uses (`document.ItemXform.composedMatrix()`) and
// project with the app's own `math.projectToWindow`/`transformPoint` rather
// than a hand-duplicated formula that could quietly drift from the app's.
//
// Every case authors its transform through `layer.attr` (the well-behaved,
// undoable writer — commands/layer/commands.d:LayerAttr), never by poking
// fields, per the task brief.
//
// Run via: ./run_test.d pick_item_transform

import http_client : testBaseUrl, getJson, postJson;
import std.net.curl;
import std.json;
import std.conv      : to;
import std.math      : sqrt, PI;
import std.format    : format;
import std.algorithm : canFind;
import core.thread    : Thread;
import core.time      : dur;

import math     : Vec3, Viewport, ModelSpace, transformPoint, projectToWindow,
                  lookAt, perspectiveMatrix, matMul4, dot, cross;
import document : ItemXform;

// buildDragLog/playAndWait pulled in by NAME only — drag_helpers also
// defines its own Vec3/Viewport, so a blanket import would collide with the
// math.* types used everywhere below.
import drag_helpers : buildDragLog, playAndWait;

void main() {}

alias BASE = testBaseUrl;

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
    auto j = postJson("/api/reset", "");
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
}

void setCamera(float az, float el, float dist) {
    auto r = postJson("/api/camera",
        format(`{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f}`, az, el, dist));
    assert("error" !in r, "/api/camera failed: " ~ r.toString);
}

// Write one component of a layer's item transform through `layer.attr` —
// the panel-dispatch shape, undoable, coalescing. NEVER poke Layer.xform
// directly (that would bypass the exact writer this task's bug report named).
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

// Same fovY/near/far the live camera uses (view.d:579-581) — verified
// against the same recipe tests/drag_helpers.d has used for years.
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

bool project(Vec3 world, const ref Viewport vp, out float px, out float py) {
    float ndcZ;
    return projectToWindow(world, vp, px, py, ndcZ);
}

double dist(float ax, float ay, float bx, float by) {
    double dx = ax - bx, dy = ay - by;
    return sqrt(dx * dx + dy * dy);
}

// ---------------------------------------------------------------------------
// Model fetch
// ---------------------------------------------------------------------------

Vec3[] fetchVerts(int layer = 0) {
    Vec3[] r;
    foreach (v; getJson("/api/model?layer=" ~ layer.to!string)["vertices"].array)
        r ~= Vec3(cast(float) v.array[0].floating,
                  cast(float) v.array[1].floating,
                  cast(float) v.array[2].floating);
    return r;
}

struct EdgeRef { int a, b; }
EdgeRef[] fetchEdges(int layer = 0) {
    EdgeRef[] r;
    foreach (e; getJson("/api/model?layer=" ~ layer.to!string)["edges"].array)
        r ~= EdgeRef(cast(int) e.array[0].integer, cast(int) e.array[1].integer);
    return r;
}

int[][] fetchFaces(int layer = 0) {
    int[][] r;
    foreach (f; getJson("/api/model?layer=" ~ layer.to!string)["faces"].array) {
        int[] face;
        foreach (vi; f.array) face ~= cast(int) vi.integer;
        r ~= face;
    }
    return r;
}

int findEdgeIndex(EdgeRef[] edges, int a, int b) {
    foreach (i, e; edges)
        if ((e.a == a && e.b == b) || (e.a == b && e.b == a)) return cast(int) i;
    assert(false, format("no edge (%d,%d) in /api/model", a, b));
}

// Find a face that is genuinely visible (GPU-pick self-consistent) at the
// CURRENT (identity, pre-transform) camera+geometry. Every other target in
// this file (vertex, edge, face) is derived from this ONE lookup so a click/
// lasso test is never aimed at a hidden or silhouette-grazing element by
// accident.
int findFrontFace(int[][] faces, Vec3[] verts, const ref Viewport vp) {
    foreach (fi, f; faces) {
        Vec3 c = Vec3(0, 0, 0);
        foreach (vi; f) c += verts[vi];
        c = c / cast(float) f.length;
        float px, py;
        if (!project(c, vp, px, py)) continue;
        auto r = getJson(format("/api/pick?x=%d&y=%d&engine=gpu", cast(int) px, cast(int) py));
        if (r["faceIndex"].integer == fi) return cast(int) fi;
    }
    assert(false, "no front-facing face found at the current camera");
}

// NOTE on an approach that was tried and abandoned: an earlier version of
// this file computed a candidate mirror-case face via the app's OWN local
// test — `dot(faceNormal, p0Local - ms.toLocalPoint(eyeWorld)) >= 0`,
// XOR'd with `ms.mirrored` (at the time, the exact formula in app.d's lasso
// `frontFacing()`, snap.d's `faceVisible`, and mesh.d's `visibleVertices`).
// Cross-checked against `/api/pick`'s independent, already-Stage-1-fixed GPU
// depth oracle, that formula picked the WRONG face under a mirror on this
// mesh: every face confirmed as the genuinely nearest/visible surface by
// `/api/pick` computed as winding-BACK, and vice versa — a clean,
// reproducible, complementary split, verified across two unrelated
// transforms and hand-confirmed algebraically (`vpLocal.eye` is already
// `M⁻¹·eyeWorld`, which alone preserves the correct front/back answer for
// ANY invertible `M` including a mirror — the `ms.mirrored` XOR on top of
// that was a second, redundant correction that flipped a right answer
// wrong). Live proof: commenting out the one `if (ms.mirrored) backFacing =
// !backFacing;` line in app.d's lasso closure made the live lasso correctly
// select exactly the depth-confirmed face with a tight box, for both faces
// tried. FIXED as of this task's follow-up: the flip has been removed from
// all three sites (app.d, snap.d, mesh.d), and math.d's `ModelSpace`
// carries the corrected reasoning. `findFrontFaceDrawn` below (the
// depth-only oracle, not the winding formula) is what M1/M2/M3 actually
// use — kept as the ground truth even post-fix, since it is independent of
// the app's own front-facing code by construction.

// Find a face that is GENUINELY, PHYSICALLY the nearest/visible surface at
// its own drawn centroid, under an ARBITRARY (possibly mirrored) transform
// — `findFrontFace` above, adapted to project through `M` instead of
// assuming identity. This is the depth/occlusion oracle: it does not care
// about winding, so it is a trustworthy, independent ground truth for
// "would a user actually see and be able to click this face here" even on a
// mirrored layer — the same GPU ID-buffer depth test `findFrontFace` already
// trusts, just evaluated post-transform.
int findFrontFaceDrawn(int[][] faces, Vec3[] verts, const ref Viewport vp, float[16] M) {
    foreach (fi, f; faces) {
        Vec3 c = Vec3(0, 0, 0);
        foreach (vi; f) c += verts[vi];
        c = c / cast(float) f.length;
        Vec3 cDrawn = transformPoint(M, c);
        float px, py;
        if (!project(cDrawn, vp, px, py)) continue;
        auto r = getJson(format("/api/pick?x=%d&y=%d&engine=gpu", cast(int) px, cast(int) py));
        if (r["faceIndex"].integer == fi) return cast(int) fi;
    }
    assert(false, "no depth-visible face found under this (drawn) transform");
}

// ---------------------------------------------------------------------------
// Event logs: a plain click (LMB down+up, no drag) and an RMB lasso over an
// explicit pixel path.
// ---------------------------------------------------------------------------

string clickLog(CamInfo c, int x, int y) {
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
      ~ `{"t":100.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        c.vpX, c.vpY, c.width, c.height, x, y, x, y);
}

string lassoLog(CamInfo c, float[] xs, float[] ys) {
    assert(xs.length >= 3 && xs.length == ys.length);
    string s = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        c.vpX, c.vpY, c.width, c.height);
    double t = 50.0;
    s ~= format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
                t, cast(int) xs[0], cast(int) ys[0]);
    foreach (i; 1 .. xs.length) {
        t += 50.0;
        s ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":4,"mod":0}` ~ "\n",
                    t, cast(int) xs[i], cast(int) ys[i]);
    }
    t += 50.0;
    s ~= format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
                t, cast(int) xs[$ - 1], cast(int) ys[$ - 1]);
    return s;
}

float[] rectXs(float minX, float maxX) { return [minX, maxX, maxX, minX]; }
float[] rectYs(float minY, float maxY) { return [minY, minY, maxY, maxY]; }

// Bounding box (+margin) of a face's cage vertices, projected either through
// the layer transform (`drawn=true`) or as raw local coordinates
// (`drawn=false` — the identity pose). Returns ok=false if any corner is
// off-camera.
struct BBoxPx { float minX, maxX, minY, maxY; bool ok; }
BBoxPx faceBBoxPx(int[] face, Vec3[] verts, float[16] M, const ref Viewport vp,
                 bool drawn, float margin) {
    BBoxPx b;
    bool first = true;
    foreach (vi; face) {
        Vec3 local = verts[vi];
        Vec3 w = drawn ? transformPoint(M, local) : local;
        float px, py;
        if (!project(w, vp, px, py)) return BBoxPx.init;
        if (first) { b.minX = b.maxX = px; b.minY = b.maxY = py; first = false; }
        else {
            if (px < b.minX) b.minX = px; if (px > b.maxX) b.maxX = px;
            if (py < b.minY) b.minY = py; if (py > b.maxY) b.maxY = py;
        }
    }
    b.minX -= margin; b.maxX += margin; b.minY -= margin; b.maxY += margin;
    b.ok = true;
    return b;
}

bool bboxOverlap(BBoxPx a, BBoxPx b) {
    return a.minX < b.maxX && a.maxX > b.minX && a.minY < b.maxY && a.maxY > b.minY;
}

int[] selVerts() { return intArr(getJson("/api/selection")["selectedVertices"]); }
int[] selEdges() { return intArr(getJson("/api/selection")["selectedEdges"]); }
int[] selFaces() { return intArr(getJson("/api/selection")["selectedFaces"]); }
int[] intArr(JSONValue j) { int[] r; foreach (e; j.array) r ~= cast(int) e.integer; return r; }

void enableSubpatchPreview() {
    cmd("mesh.subpatch_toggle");
    Thread.sleep(dur!"msecs"(200)); // let the preview rebuild + GPU upload land
}

// ===========================================================================
// CASE GROUP 1 — click paths: vertex, edge (synthesized click log) and face
// (both pick engines), on a TRANSLATED primary. Every case is a
// drawn-selects / identity-does-not PAIR (requirement 5).
// ===========================================================================

unittest { // click: vertex + edge, translation-only transform
    resetScene();
    setCamera(0.5f, 0.3f, 9.0f);

    auto cam    = fetchCam();
    auto vp     = buildViewport(cam);
    auto verts  = fetchVerts();
    auto edges  = fetchEdges();
    auto faces  = fetchFaces();
    int fi      = findFrontFace(faces, verts, vp);
    int vk      = faces[fi][0];
    int vk2     = faces[fi][1];
    int ek      = findEdgeIndex(edges, vk, vk2);

    Vec3 pos = Vec3(1.3f, -0.8f, 0.5f);
    Vec3 rot = Vec3(0, 0, 0);
    Vec3 scl = Vec3(1, 1, 1);
    setXform(0, pos, rot, scl);
    float[16] M = composed(pos, rot, scl);

    // ---- vertex ----
    Vec3 vLocal = verts[vk];
    Vec3 vDrawn = transformPoint(M, vLocal);
    float dpx, dpy, ipx, ipy;
    assert(project(vDrawn, vp, dpx, dpy), "drawn vertex pixel off-camera");
    assert(project(vLocal, vp, ipx, ipy), "identity vertex pixel off-camera");
    assert(dist(dpx, dpy, ipx, ipy) > 20.0,
        "chosen transform does not separate drawn/identity vertex pixels — case would be vacuous");

    cmd("select.typeFrom vertex");
    playAndWait(clickLog(cam, cast(int) dpx, cast(int) dpy));
    assert(canFind(selVerts(), vk),
        format("click at DRAWN vertex pixel (%.0f,%.0f) must select v%d, got %s",
               dpx, dpy, vk, selVerts()));

    playAndWait(clickLog(cam, cast(int) ipx, cast(int) ipy));
    assert(!canFind(selVerts(), vk),
        format("click at IDENTITY-pose pixel (%.0f,%.0f) must NOT select v%d, got %s",
               ipx, ipy, vk, selVerts()));

    // ---- edge ----
    Vec3 mid      = (verts[vk] + verts[vk2]) * 0.5f;
    Vec3 midDrawn = transformPoint(M, mid);
    assert(project(midDrawn, vp, dpx, dpy), "drawn edge midpoint off-camera");
    assert(project(mid,      vp, ipx, ipy), "identity edge midpoint off-camera");
    assert(dist(dpx, dpy, ipx, ipy) > 20.0,
        "chosen transform does not separate drawn/identity edge pixels — case would be vacuous");

    cmd("select.typeFrom edge");
    playAndWait(clickLog(cam, cast(int) dpx, cast(int) dpy));
    assert(canFind(selEdges(), ek),
        format("click at DRAWN edge-midpoint pixel (%.0f,%.0f) must select e%d, got %s",
               dpx, dpy, ek, selEdges()));

    playAndWait(clickLog(cam, cast(int) ipx, cast(int) ipy));
    assert(!canFind(selEdges(), ek),
        format("click at IDENTITY-pose pixel (%.0f,%.0f) must NOT select e%d, got %s",
               ipx, ipy, ek, selEdges()));
}

unittest { // click: face via BOTH pick engines (bvh + gpu), translation-only transform
    resetScene();
    setCamera(0.5f, 0.3f, 9.0f);

    auto cam   = fetchCam();
    auto vp    = buildViewport(cam);
    auto verts = fetchVerts();
    auto faces = fetchFaces();
    int fi     = findFrontFace(faces, verts, vp);

    Vec3 pos = Vec3(1.3f, -0.8f, 0.5f);
    Vec3 rot = Vec3(0, 0, 0);
    Vec3 scl = Vec3(1, 1, 1);
    setXform(0, pos, rot, scl);
    float[16] M = composed(pos, rot, scl);

    Vec3 centroid = Vec3(0, 0, 0);
    foreach (vi; faces[fi]) centroid += verts[vi];
    centroid = centroid / cast(float) faces[fi].length;

    Vec3 cDrawn = transformPoint(M, centroid);
    float dpx, dpy, ipx, ipy;
    assert(project(cDrawn,   vp, dpx, dpy), "drawn face centroid off-camera");
    assert(project(centroid, vp, ipx, ipy), "identity face centroid off-camera");
    assert(dist(dpx, dpy, ipx, ipy) > 20.0,
        "chosen transform does not separate drawn/identity face pixels — case would be vacuous");

    int bvhDrawn = cast(int) getJson(
        format("/api/pick?x=%d&y=%d&engine=bvh", cast(int) dpx, cast(int) dpy))["faceIndex"].integer;
    int gpuDrawn = cast(int) getJson(
        format("/api/pick?x=%d&y=%d&engine=gpu", cast(int) dpx, cast(int) dpy))["faceIndex"].integer;
    assert(bvhDrawn == fi, format("BVH pick at drawn pixel expected f%d, got %d", fi, bvhDrawn));
    assert(gpuDrawn == fi, format("GPU pick at drawn pixel expected f%d, got %d", fi, gpuDrawn));

    int bvhIdent = cast(int) getJson(
        format("/api/pick?x=%d&y=%d&engine=bvh", cast(int) ipx, cast(int) ipy))["faceIndex"].integer;
    int gpuIdent = cast(int) getJson(
        format("/api/pick?x=%d&y=%d&engine=gpu", cast(int) ipx, cast(int) ipy))["faceIndex"].integer;
    assert(bvhIdent != fi, format("BVH pick at identity pixel must NOT be f%d, got %d", fi, bvhIdent));
    assert(gpuIdent != fi, format("GPU pick at identity pixel must NOT be f%d, got %d", fi, gpuIdent));
}

// ===========================================================================
// CASE GROUP 2 — a rotation + non-uniform-scale transform (requirement 1's
// second transform), reused as the DOUBLE-APPLY discriminator (requirement 4,
// R10): five call sites fold the item matrix internally; handing them an
// already-composed viewport applies it twice. M^2 is chosen to project far
// enough from M that a double-apply lands the pick somewhere else entirely,
// not merely a few pixels off.
// ===========================================================================

unittest { // click vertex under rotation+non-uniform-scale; M^2 vs M anti-vacuity guard
    resetScene();
    setCamera(0.5f, 0.3f, 9.0f);

    auto cam   = fetchCam();
    auto vp    = buildViewport(cam);
    auto verts = fetchVerts();
    auto faces = fetchFaces();
    int fi     = findFrontFace(faces, verts, vp);
    int vk     = faces[fi][0];

    Vec3 pos = Vec3(0.4f, -0.3f, 0.5f);
    Vec3 rot = Vec3(24, 50, -16);
    Vec3 scl = Vec3(1.7f, 0.55f, 1.3f);
    setXform(0, pos, rot, scl);
    float[16] M  = composed(pos, rot, scl);
    float[16] M2 = matMul4(M, M);

    Vec3 vLocal = verts[vk];
    Vec3 vOnce  = transformPoint(M,  vLocal);
    Vec3 vTwice = transformPoint(M2, vLocal);

    float oncePx, oncePy, twicePx, twicePy, identPx, identPy;
    assert(project(vOnce,  vp, oncePx,  oncePy),  "M*v off-camera");
    assert(project(vTwice, vp, twicePx, twicePy), "M^2*v off-camera");
    assert(project(vLocal, vp, identPx, identPy), "identity v off-camera");

    // Anti-vacuity per the plan: a double application must land somewhere
    // VISIBLY different from a single one, or this case proves nothing.
    assert(dist(oncePx, oncePy, twicePx, twicePy) > 30.0,
        "M and M^2 project too close together to discriminate a double-apply");
    assert(dist(oncePx, oncePy, identPx, identPy) > 20.0,
        "chosen transform does not separate drawn/identity pixels — case would be vacuous");

    cmd("select.typeFrom vertex");
    playAndWait(clickLog(cam, cast(int) oncePx, cast(int) oncePy));
    assert(canFind(selVerts(), vk),
        format("click at the SINGLY-transformed (drawn) pixel (%.0f,%.0f) must select v%d, got %s "
             ~ "— a double-apply would instead draw it at (%.0f,%.0f)",
               oncePx, oncePy, vk, selVerts(), twicePx, twicePy));

    playAndWait(clickLog(cam, cast(int) identPx, cast(int) identPy));
    assert(!canFind(selVerts(), vk),
        format("click at the identity-pose pixel must NOT select v%d, got %s", vk, selVerts()));
}

// ===========================================================================
// CASE GROUP 3 — lasso, all six branches enumerated individually (L1-L6).
// Reuses ONE translation-only transform and ONE front face; each branch pairs
// a DRAWN-region lasso (positive) with an IDENTITY-region lasso (negative).
// The margin absorbs subpatch-preview's Catmull-Clark corner smoothing (the
// preview vertex is not at the cage's raw projected pixel); the convex-hull
// property of the subdivision scheme guarantees every preview child of a
// face stays within that face's cage-vertex bounding box — empirically
// confirmed live against the running preview mesh (a 5px margin already
// fully enclosed the preview face at this camera), so the 45/25px margins
// below are comfortable slack, not a bare minimum. The test viewport here is
// only 650x544, so the translation below was not guessed: it was found by
// grid-searching the app's own `faceBBoxPx` projection over a range of
// translations and picking one whose drawn/identity windows clear each
// other by >120px on-camera (buildLassoFixture's own guard re-derives and
// re-checks this on every run, so a future camera/geometry change cannot
// silently make the case vacuous without failing loudly).
// ===========================================================================

struct LassoFixture {
    CamInfo   cam;
    Viewport  vp;
    Vec3[]    verts;
    EdgeRef[] edges;
    int[][]   faces;
    int       fi, vk, vk2, ek;
    float[16] M;
    BBoxPx    drawnBox, identBox;
}

LassoFixture buildLassoFixture(float margin) {
    resetScene();
    setCamera(0.5f, 0.3f, 9.0f);

    LassoFixture fx;
    fx.cam   = fetchCam();
    fx.vp    = buildViewport(fx.cam);
    fx.verts = fetchVerts();
    fx.edges = fetchEdges();
    fx.faces = fetchFaces();
    fx.fi    = findFrontFace(fx.faces, fx.verts, fx.vp);
    // NOT faces[fi][0]/[1]: at this transform, cage vertex faces[fi][0]'s
    // Catmull-Clark LIMIT point (corner-smoothed, depends on the vertex's
    // whole 1-ring, not just this one face) lands somewhere this camera
    // angle self-occludes in the GPU visibility FBO — confirmed live
    // (cage-mode pick of the same vertex succeeds; only the PREVIEW pick
    // fails, and only for that one corner of the four). faces[fi][1]/[2]
    // stayed GPU-visible in preview at every margin tried, so the fixture
    // targets that pair instead of blindly trusting corner 0.
    fx.vk    = fx.faces[fx.fi][1];
    fx.vk2   = fx.faces[fx.fi][2];
    fx.ek    = findEdgeIndex(fx.edges, fx.vk, fx.vk2);

    Vec3 pos = Vec3(-3.0f, -1.5f, 2.0f);
    Vec3 rot = Vec3(0, 0, 0);
    Vec3 scl = Vec3(1, 1, 1);
    setXform(0, pos, rot, scl);
    fx.M = composed(pos, rot, scl);

    fx.drawnBox = faceBBoxPx(fx.faces[fx.fi], fx.verts, fx.M, fx.vp, true,  margin);
    fx.identBox = faceBBoxPx(fx.faces[fx.fi], fx.verts, fx.M, fx.vp, false, margin);
    assert(fx.drawnBox.ok, "drawn face bbox off-camera");
    assert(fx.identBox.ok, "identity face bbox off-camera");
    assert(!bboxOverlap(fx.drawnBox, fx.identBox),
        "drawn/identity lasso windows overlap — chosen transform/margin is too small to discriminate");
    return fx;
}

void lassoAt(CamInfo cam, BBoxPx b) {
    playAndWait(lassoLog(cam, rectXs(b.minX, b.maxX), rectYs(b.minY, b.maxY)));
}

unittest { // L1: Polygons / subpatch PREVIEW
    auto fx = buildLassoFixture(45.0f);
    enableSubpatchPreview();
    cmd("select.typeFrom polygon");

    lassoAt(fx.cam, fx.drawnBox);
    assert(canFind(selFaces(), fx.fi),
        format("L1: lasso over the DRAWN (preview) face region must select cage face f%d, got %s",
               fx.fi, selFaces()));

    lassoAt(fx.cam, fx.identBox);
    assert(!canFind(selFaces(), fx.fi),
        format("L1: lasso over the IDENTITY-pose region must NOT select f%d, got %s",
               fx.fi, selFaces()));
}

unittest { // L2: Polygons / cage
    auto fx = buildLassoFixture(25.0f);
    cmd("select.typeFrom polygon");

    lassoAt(fx.cam, fx.drawnBox);
    assert(canFind(selFaces(), fx.fi),
        format("L2: lasso over the DRAWN (cage) face region must select f%d, got %s",
               fx.fi, selFaces()));

    lassoAt(fx.cam, fx.identBox);
    assert(!canFind(selFaces(), fx.fi),
        format("L2: lasso over the IDENTITY-pose region must NOT select f%d, got %s",
               fx.fi, selFaces()));
}

unittest { // L3: Vertices / subpatch PREVIEW
    auto fx = buildLassoFixture(45.0f);
    enableSubpatchPreview();
    cmd("select.typeFrom vertex");

    lassoAt(fx.cam, fx.drawnBox);
    assert(canFind(selVerts(), fx.vk),
        format("L3: lasso over the DRAWN (preview) face region must select cage vertex v%d, got %s",
               fx.vk, selVerts()));

    lassoAt(fx.cam, fx.identBox);
    assert(!canFind(selVerts(), fx.vk),
        format("L3: lasso over the IDENTITY-pose region must NOT select v%d, got %s",
               fx.vk, selVerts()));
}

unittest { // L4: Vertices / cage
    auto fx = buildLassoFixture(25.0f);
    cmd("select.typeFrom vertex");

    lassoAt(fx.cam, fx.drawnBox);
    assert(canFind(selVerts(), fx.vk),
        format("L4: lasso over the DRAWN (cage) face region must select v%d, got %s",
               fx.vk, selVerts()));

    lassoAt(fx.cam, fx.identBox);
    assert(!canFind(selVerts(), fx.vk),
        format("L4: lasso over the IDENTITY-pose region must NOT select v%d, got %s",
               fx.vk, selVerts()));
}

unittest { // L5: Edges / subpatch PREVIEW
    auto fx = buildLassoFixture(45.0f);
    enableSubpatchPreview();
    cmd("select.typeFrom edge");

    lassoAt(fx.cam, fx.drawnBox);
    assert(canFind(selEdges(), fx.ek),
        format("L5: lasso over the DRAWN (preview) face region must select cage edge e%d, got %s",
               fx.ek, selEdges()));

    lassoAt(fx.cam, fx.identBox);
    assert(!canFind(selEdges(), fx.ek),
        format("L5: lasso over the IDENTITY-pose region must NOT select e%d, got %s",
               fx.ek, selEdges()));
}

unittest { // L6: Edges / cage
    auto fx = buildLassoFixture(25.0f);
    cmd("select.typeFrom edge");

    lassoAt(fx.cam, fx.drawnBox);
    assert(canFind(selEdges(), fx.ek),
        format("L6: lasso over the DRAWN (cage) face region must select e%d, got %s",
               fx.ek, selEdges()));

    lassoAt(fx.cam, fx.identBox);
    assert(!canFind(selEdges(), fx.ek),
        format("L6: lasso over the IDENTITY-pose region must NOT select e%d, got %s",
               fx.ek, selEdges()));
}

// ===========================================================================
// CASE GROUP 4 — mirror (requirement 3 / R4 / §3.8): one case per
// front-facing cull. A mirrored (`det(M) < 0`) transform flips apparent
// winding, so a local-space front-facing test disagrees with what is drawn
// unless the mirror XOR is applied. M1/M2 pin the two LASSO culls
// (app.d:4658 preview, app.d:4688 cage); M3 pins the two BACKGROUND culls
// (snap.d faceVisible, mesh.d visibleVertices).
// ===========================================================================

unittest { // M1: lasso Polygons/preview on a MIRRORED primary
    resetScene();
    setCamera(0.5f, 0.3f, 9.0f);
    auto cam   = fetchCam();
    auto vp    = buildViewport(cam);
    auto verts = fetchVerts();
    auto faces = fetchFaces();

    Vec3 pos = Vec3(-3.0f, -1.5f, 2.0f); // same well-separated translation as buildLassoFixture
    Vec3 rot = Vec3(0, 0, 0);
    Vec3 scl = Vec3(-1, 1, 1);           // mirror on X — det(M) < 0
    setXform(0, pos, rot, scl);
    float[16] M = composed(pos, rot, scl);

    ItemXform xf; xf.pos = pos; xf.rot = rot; xf.scl = scl;
    ModelSpace ms = xf.modelSpace();
    assert(ms.mirrored, "M1: fixture transform must actually be mirrored (det<0) or the case is vacuous");

    // The face that is GENUINELY, physically visible/nearest to the camera
    // at its own drawn centroid — an independent, depth-only ground truth
    // (`findFrontFaceDrawn`, the same GPU-pick oracle `findFrontFace` uses
    // elsewhere in this file), NOT the app's own winding-based front test.
    // "a genuinely front-facing face... must still be lasso-selectable" —
    // the plan's own wording — means genuinely, i.e. what a user actually
    // sees, not "whatever the code under test happens to compute."
    int fi = findFrontFaceDrawn(faces, verts, vp, M);
    Vec3 identCentroid = Vec3(0, 0, 0);
    foreach (vi; faces[fi]) identCentroid += verts[vi];
    identCentroid = identCentroid / cast(float) faces[fi].length;

    auto drawnBox = faceBBoxPx(faces[fi], verts, M, vp, true, 45.0f);
    auto identBox = faceBBoxPx(faces[fi], verts, M, vp, false, 45.0f);
    assert(drawnBox.ok, "M1: drawn (mirrored) face bbox off-camera");
    assert(identBox.ok, "M1: identity-pose face bbox off-camera");
    assert(!bboxOverlap(drawnBox, identBox),
        "M1: drawn/identity lasso windows overlap — chosen transform/margin is too small to discriminate");

    enableSubpatchPreview();
    cmd("select.typeFrom polygon");
    lassoAt(cam, drawnBox);
    // FIXED (was KNOWN FAILING at HEAD when this file was written): app.d's
    // lasso `frontFacing()` used to XOR `ms.mirrored` on TOP of an eye
    // already transformed by `M⁻¹` (`vpLocal.eye = ms.toLocalPoint(vp.eye)`),
    // which alone already yields the correct front/back answer for ANY
    // invertible `M` including a mirror — the XOR was a second, redundant
    // correction that flipped a right answer wrong. Removing the
    // `if (ms.mirrored) backFacing = !backFacing;` line in that closure (and
    // its identical siblings in snap.d `faceVisible` and mesh.d
    // `visibleVertices`) is the fix; see math.d's `ModelSpace` doc comments
    // for why no correction is needed. Note M3 below does NOT exercise this
    // regression: removing all three sibling lines left M3's outcome
    // unchanged (still passes) for the face/transform it happens to land on
    // — M1/M2 are the discriminating guards for this bug.
    assert(canFind(selFaces(), fi),
        format("M1: a genuinely front-facing face on a MIRRORED preview primary must still be "
             ~ "lasso-selectable (the mirror flip is missing/wrong if not) — got %s", selFaces()));

    lassoAt(cam, identBox);
    assert(!canFind(selFaces(), fi),
        format("M1: lasso over the IDENTITY-pose region must NOT select f%d, got %s", fi, selFaces()));
}

unittest { // M2: lasso Polygons/cage on a MIRRORED primary
    resetScene();
    setCamera(0.5f, 0.3f, 9.0f);
    auto cam   = fetchCam();
    auto vp    = buildViewport(cam);
    auto verts = fetchVerts();
    auto faces = fetchFaces();

    Vec3 pos = Vec3(-3.0f, -1.5f, 2.0f);
    Vec3 rot = Vec3(0, 0, 0);
    Vec3 scl = Vec3(-1, 1, 1);   // mirror on X — det(M) < 0
    setXform(0, pos, rot, scl);
    float[16] M = composed(pos, rot, scl);

    ItemXform xf; xf.pos = pos; xf.rot = rot; xf.scl = scl;
    ModelSpace ms = xf.modelSpace();
    assert(ms.mirrored, "M2: fixture transform must actually be mirrored (det<0) or the case is vacuous");

    int fi = findFrontFaceDrawn(faces, verts, vp, M); // see M1's comment

    auto drawnBox = faceBBoxPx(faces[fi], verts, M, vp, true, 30.0f);
    auto identBox = faceBBoxPx(faces[fi], verts, M, vp, false, 30.0f);
    assert(drawnBox.ok, "M2: drawn (mirrored) face bbox off-camera");
    assert(identBox.ok, "M2: identity-pose face bbox off-camera");
    assert(!bboxOverlap(drawnBox, identBox),
        "M2: drawn/identity lasso windows overlap — chosen transform/margin is too small to discriminate");

    cmd("select.typeFrom polygon");
    lassoAt(cam, drawnBox);
    // Same fix as M1 — see that block's comment. Removing app.d's lasso
    // `if (ms.mirrored) backFacing = !backFacing;` makes this pass too.
    assert(canFind(selFaces(), fi),
        format("M2: a genuinely front-facing face on a MIRRORED cage primary must still be "
             ~ "lasso-selectable (the mirror flip is missing/wrong if not) — got %s", selFaces()));

    lassoAt(cam, identBox);
    assert(!canFind(selFaces(), fi),
        format("M2: lasso over the IDENTITY-pose region must NOT select f%d, got %s", fi, selFaces()));
}

void enableVertexSnap() {
    auto r = post(BASE ~ "/api/script",
        "tool.set move\n" ~
        "tool.pipe.attr snap enabled true\n" ~
        "tool.pipe.attr snap types vertex\n" ~
        "tool.pipe.attr snap innerRange 999999\n" ~
        "tool.pipe.attr snap outerRange 999999\n");
    assert(parseJSON(cast(string) r)["status"].str == "ok", "vertex snap config failed");
}

void enablePolyCenterSnap() {
    auto r = post(BASE ~ "/api/script",
        "tool.set move\n" ~
        "tool.pipe.attr snap enabled true\n" ~
        "tool.pipe.attr snap types polyCenter\n" ~
        "tool.pipe.attr snap innerRange 999999\n" ~
        "tool.pipe.attr snap outerRange 999999\n");
    assert(parseJSON(cast(string) r)["status"].str == "ok", "polyCenter snap config failed");
}

JSONValue snapProbe(Vec3 worldTarget, int sx, int sy) {
    string body_ = format(`{"cursor":[%.6f,%.6f,%.6f],"sx":%d,"sy":%d}`,
                          worldTarget.x, worldTarget.y, worldTarget.z, sx, sy);
    return postJson("/api/snap", body_);
}

unittest { // M3: background component snap against a MIRRORED background layer
           // — pins BOTH mesh.d visibleVertices (vertex leg) and
           // snap.d faceVisible (polyCenter leg).
    resetScene();
    setCamera(0.4f, 0.3f, 8.0f);

    // Layer B: a cube, given its TRANSLATED+MIRRORED pose while still
    // ACTIVE (so /api/pick reads ITS geometry directly, and the transform
    // is already baked into what /api/pick sees). Two fixture requirements
    // beyond the original: (1) B needs a REAL translation away from A — at
    // pos=0 a mirrored cube occupies the EXACT same world volume as A's own
    // (unmirrored) cube, so "did this resolve to the background source" is
    // undecidable no matter what the mirror cull does. (2) the target face
    // must be found AFTER the mirror is applied, not before: mirroring
    // flips every face's raw winding uniformly (a mirrored object needs a
    // flipped cull convention to keep rendering correctly — the same fact
    // M1/M2 hit), so the face that was depth-visible pre-mirror is not
    // generally the one that is depth-visible post-mirror.
    cmd("layer.add name:B");
    cmd("prim.cube");
    Vec3 posB = Vec3(2.0f, 0.4f, -0.5f);
    Vec3 rotB = Vec3(0, 0, 0);
    Vec3 sclB = Vec3(-1, 1, 1); // mirror on X — det(M) < 0
    setXform(1, posB, rotB, sclB);
    float[16] MB = composed(posB, rotB, sclB);

    auto camB   = fetchCam();
    auto vpB    = buildViewport(camB);
    auto vertsB = fetchVerts(1);
    auto facesB = fetchFaces(1);
    int fiB     = findFrontFaceDrawn(facesB, vertsB, vpB, MB); // depth-confirmed AFTER the mirror
    int vkB     = facesB[fiB][0];

    // Hand primary back to A — B is now visible+deselected (derived
    // background) with a negative-determinant transform, translated clear
    // of A.
    cmd("layer.setVisible index:1 value:true");
    cmd("layer.select index:0");

    auto cam = fetchCam();
    auto vp  = buildViewport(cam);

    // ---- vertex leg: mesh.d visibleVertices ----
    Vec3 vWorld = transformPoint(MB, vertsB[vkB]);
    float dpx, dpy;
    assert(project(vWorld, vp, dpx, dpy), "M3: mirrored B vertex off-camera");

    enableVertexSnap();
    auto sr = snapProbe(vWorld, cast(int) dpx, cast(int) dpy);
    assert(sr["highlighted"].type == JSONType.TRUE,
        format("M3 (vertex leg): a genuinely (depth-)front-facing vertex on a MIRRORED background "
             ~ "layer must be visible to snap (visibleVertices mirror flip) — got %s", sr.toString));
    assert(sr["targetSource"].integer >= 1,
        format("M3 (vertex leg): snap must resolve to the BACKGROUND source, got %s", sr.toString));

    // ---- polygon-center leg: snap.d faceVisible ----
    Vec3 centroidLocal = Vec3(0, 0, 0);
    foreach (vi; facesB[fiB]) centroidLocal += vertsB[vi];
    centroidLocal = centroidLocal / cast(float) facesB[fiB].length;
    Vec3 cWorld = transformPoint(MB, centroidLocal);
    float cpx, cpy;
    assert(project(cWorld, vp, cpx, cpy), "M3: mirrored B face-centre off-camera");

    enablePolyCenterSnap();
    auto sr2 = snapProbe(cWorld, cast(int) cpx, cast(int) cpy);
    assert(sr2["highlighted"].type == JSONType.TRUE,
        format("M3 (polyCenter leg): a genuinely (depth-)front-facing face on a MIRRORED background "
             ~ "layer must be visible to snap (faceVisible mirror flip) — got %s", sr2.toString));
    assert(sr2["targetSource"].integer >= 1,
        format("M3 (polyCenter leg): snap must resolve to the BACKGROUND source, got %s", sr2.toString));
}

// ===========================================================================
// CASE GROUP 5 — background layers: general (non-mirror) transform, both the
// component-snap position (Stage 4 candidate emission, R7) and the surface
// raycast (Stage 4 item 6).
// ===========================================================================

unittest { // background component snap finds a TRANSFORMED background vertex at
           // its DRAWN world position, not its identity position.
    resetScene();
    setCamera(0.4f, 0.3f, 8.0f);

    cmd("layer.add name:B");
    cmd("prim.cube");
    auto vertsB = fetchVerts(1);

    Vec3 posB = Vec3(2.0f, 0.4f, -0.5f);
    Vec3 rotB = Vec3(0, 35, 0);
    Vec3 sclB = Vec3(1, 1, 1);
    setXform(1, posB, rotB, sclB);
    cmd("layer.setVisible index:1 value:true");
    cmd("layer.select index:0"); // A primary, B background

    auto cam = fetchCam();
    auto vp  = buildViewport(cam);
    float[16] MB = composed(posB, rotB, sclB);

    int vk = 0;
    Vec3 local = vertsB[vk];
    Vec3 drawnWorld = transformPoint(MB, local);
    float dpx, dpy, ipx, ipy;
    assert(project(drawnWorld, vp, dpx, dpy), "drawn B vertex off-camera");
    assert(project(local,      vp, ipx, ipy), "identity B vertex off-camera");
    assert(dist(dpx, dpy, ipx, ipy) > 20.0,
        "chosen background transform does not separate drawn/identity pixels");

    enableVertexSnap();

    auto srDrawn = snapProbe(drawnWorld, cast(int) dpx, cast(int) dpy);
    assert(srDrawn["highlighted"].type == JSONType.TRUE
        && srDrawn["targetSource"].integer >= 1,
        format("background vertex must be found at its DRAWN (transformed) world position, got %s",
               srDrawn.toString));

    // A's own untransformed cube sits at the SAME local coordinates as B's
    // identity pose, so probing there resolves to A (source 0) — the
    // observable proof that B is NOT (wrongly) still offering candidates at
    // its pre-transform position.
    auto srIdent = snapProbe(local, cast(int) ipx, cast(int) ipy);
    assert(srIdent["targetSource"].integer == 0,
        format("probing the IDENTITY-pose position must resolve to the ACTIVE mesh (source 0), "
             ~ "not the background layer, got %s", srIdent.toString));
}

unittest { // background surface raycast hits a TRANSFORMED background layer
           // at its DRAWN position (CONS stage, constrain.d).
    resetScene();
    setCamera(0.4f, 0.3f, 8.0f);
    cmd("tool.pipe.attr constrain enabled true");
    cmd("tool.pipe.attr constrain geometry screen");

    cmd("layer.add name:B");
    cmd("prim.cube");
    auto camB   = fetchCam();
    auto vpB    = buildViewport(camB);
    auto vertsB = fetchVerts(1);
    auto facesB = fetchFaces(1);
    int fiB     = findFrontFace(facesB, vertsB, vpB); // still active — reads B directly

    Vec3 posB = Vec3(2.0f, 0.0f, 0.0f);
    Vec3 rotB = Vec3(0, 0, 0);
    Vec3 sclB = Vec3(1, 1, 1);
    setXform(1, posB, rotB, sclB);
    cmd("layer.setVisible index:1 value:true");
    cmd("layer.select index:0"); // A primary, B background

    float[16] MB = composed(posB, rotB, sclB);
    Vec3 centroidLocal = Vec3(0, 0, 0);
    foreach (vi; facesB[fiB]) centroidLocal += vertsB[vi];
    centroidLocal = centroidLocal / cast(float) facesB[fiB].length;
    Vec3 drawnWorld = transformPoint(MB, centroidLocal);

    auto cam = fetchCam();
    auto vp  = buildViewport(cam);
    float dpx, dpy, ipx, ipy;
    assert(project(drawnWorld,    vp, dpx, dpy), "drawn B face-centre off-camera");
    assert(project(centroidLocal, vp, ipx, ipy), "identity B face-centre off-camera");
    assert(dist(dpx, dpy, ipx, ipy) > 20.0,
        "chosen background transform does not separate drawn/identity raycast pixels");

    auto hitDrawn = getJson(format("/api/surface-raycast?x=%d&y=%d", cast(int) dpx, cast(int) dpy));
    assert(hitDrawn["hit"].type == JSONType.TRUE,
        format("raycast at the DRAWN background face-centre pixel must hit, got %s", hitDrawn.toString));
    assert(hitDrawn["layer"].integer == 1,
        format("raycast hit must resolve to background layer 1, got %s", hitDrawn.toString));
    double[3] gp = [hitDrawn["point"][0].floating, hitDrawn["point"][1].floating, hitDrawn["point"][2].floating];
    double dd = sqrt((gp[0]-drawnWorld.x)^^2 + (gp[1]-drawnWorld.y)^^2 + (gp[2]-drawnWorld.z)^^2);
    // Tolerance widened from an initial 0.05: `dpx`/`dpy` are rounded to the
    // nearest INTEGER pixel (the same rounding a real mouse click has), and
    // this face sits at an oblique angle to the camera (normal (1,0,0)
    // against a 3/4 az=0.4/el=0.3 view), which magnifies half a pixel of
    // screen error into real 3D distance along the surface. 0.15 still
    // rejects the identity-pose failure mode by more than an order of
    // magnitude (that miss is ~2 world units away, not a few centimetres).
    assert(dd < 0.15,
        format("raycast hit point should be at the drawn centroid %s, got %s", drawnWorld, hitDrawn.toString));

    // The identity-pose pixel points the ray at empty space (B physically
    // moved away) — no background surface there any more.
    auto hitIdent = getJson(format("/api/surface-raycast?x=%d&y=%d", cast(int) ipx, cast(int) ipy));
    bool identHitsB = hitIdent["hit"].type == JSONType.TRUE && hitIdent["layer"].integer == 1;
    assert(!identHitsB,
        format("raycast at the IDENTITY-pose pixel must NOT hit background layer 1 there, got %s",
               hitIdent.toString));
}
