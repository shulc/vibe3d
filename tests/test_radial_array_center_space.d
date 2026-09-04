// The Radial Array tool's centre, in the space the array is BUILT in.
// (Task 0660 — the other side of task 0645's seam.)
//
// ── WHAT THIS PINS ────────────────────────────────────────────────────────
//
// `Mesh.radialArrayFaces` pivots the LAYER'S OWN stored vertex coordinates.
// The off-handle click that repositions the pivot resolves against the
// construction plane, which is a WORLD plane however the view orients it
// (task 0661). Writing that world hit into the tool's `center` unconverted
// builds the array around the clicked point's image under the IDENTITY matrix
// — so on a layer with an item transform the copies turn about a point nobody
// clicked.
//
// This file asserts the POSITIONS OF THE PRODUCED COPIES against the clicked
// point, on a layer whose item transform carries translation AND rotation AND a
// different scale on all three axes.
//
// ── THE TWO TRAPS THE FIXTURE IS SHAPED AROUND ────────────────────────────
//
// 1. AN IDENTITY TRANSFORM SHOWS NOTHING. World and layer coordinates coincide
//    there, so every candidate reading of the centre aliases onto every other
//    and the whole question disappears. Hence the stand below. Rotation alone
//    would let `M` pass for `M^-T`; a uniform scale would let one axis's gain
//    pass for another's; a translation alone would leave every direction
//    question invisible. All three are present.
//
// 2. "THE ARRAY WAS BUILT" PASSES TODAY. The bug builds a perfectly good radial
//    array — just about the wrong point. Counting faces, or asserting that the
//    vertex count grew, measures nothing at all here. So the centre is RECOVERED
//    FROM THE COPIES and compared against the clicked point:
//
//      a half-turn about a principal axis through `c` maps a point to its
//      reflection through the axis LINE, so the midpoint of every
//      source/copy pair lies ON that line. Four pairs give four independent
//      estimates of the two in-plane components of `c`, exactly, with no
//      dependence on the radius, on the camera, or on float rounding beyond
//      the mesh's own storage.
//
// ── HOW THE CLICKED POINT IS KNOWN WITHOUT RECONSTRUCTING THE RAY ─────────
//
// `screenToConstructionPlane`'s answer depends only on the viewport and the
// workplane stage, never on the mesh or the layer. So the SAME pixel is clicked
// on two stands that differ ONLY in their item transform:
//
//   * on the IDENTITY stand the conversion under test is the identity, so the
//     tool's own reported centre IS the world hit — measured by the engine
//     with the engine's own cached viewport, no test-side ray inversion, no
//     camera reconstruction, nothing to drift, and no assumption about WHICH
//     plane the view picked;
//   * the TRANSFORMED stand's recovered centre must then be `M^-1` of it.
//
// The copies are what the assertion is made on; the reported parameter is only
// how the clicked point becomes known, and each block cross-checks the two
// against each other on the identity stand before trusting either.
//
// The named wrong reading — the world hit written through unconverted — is
// built here too and refused by a reported margin. A broken test-side `M^-1`
// would match NEITHER candidate, so the leg validates itself; block 0 checks it
// against the matrix the engine publishes before any tool is involved.
//
// ── WHICH VIEW, AND WHY IT MATTERS ────────────────────────────────────────
//
// A perspective 3/4 view (azimuth 0.9, elevation 0.5) — which plane that makes
// the construction plane is deliberately NOT assumed anywhere below; the
// clicked point is measured, never predicted. Block 5 needs its own view for a
// reason that IS about the geometry, and says so in place.

import http_client : testBaseUrl, getJson, postJson;
import std.net.curl : get, post;
import std.json;
import std.math   : fabs, sqrt, sin, cos, PI;
import std.format : format;
import std.conv   : to;
import core.thread : Thread;
import core.time   : dur;

import drag_helpers;   // Vec3, CameraState, fetchCamera, viewportFromCamera,
                       // projectToWindow, gizmoSize, buildDragLog, playAndWait

void main() {}

alias BASE = testBaseUrl;
enum string TOOL = "mesh.radialArrayTool";

// --------------------------------------------------------------------------
// HTTP plumbing
// --------------------------------------------------------------------------


void cmd(string argstring) {
    auto r = postJson("/api/command", argstring);
    assert("status" in r && (r["status"].str == "ok" || r["status"].str == "success"),
           format("cmd `%s` failed: %s", argstring, r.toString()));
}

// The handle registry is rebuilt on every interactive draw, and the tool's
// cached viewport is written there too — a press must follow a frame.
void settle() { Thread.sleep(dur!"msecs"(200)); }

double num(JSONValue v) {
    return (v.type == JSONType.integer)  ? cast(double) v.integer
         : (v.type == JSONType.uinteger) ? cast(double) v.uinteger
                                         : v.floating;
}

// --------------------------------------------------------------------------
// The stand: a unit cube, its top face (index 4) selected as the array source.
// --------------------------------------------------------------------------
immutable double[3][8] CUBE = [
    [-0.5, -0.5, -0.5], [ 0.5, -0.5, -0.5], [ 0.5,  0.5, -0.5], [-0.5,  0.5, -0.5],
    [-0.5, -0.5,  0.5], [ 0.5, -0.5,  0.5], [ 0.5,  0.5,  0.5], [-0.5,  0.5,  0.5],
];
immutable int[4][6] FACES = [
    [4, 5, 6, 7],   // 0  front  +Z
    [1, 0, 3, 2],   // 1  back   -Z
    [5, 1, 2, 6],   // 2  right  +X
    [0, 4, 7, 3],   // 3  left   -X
    [7, 6, 2, 3],   // 4  top    +Y   <- the operand
    [0, 1, 5, 4],   // 5  bottom -Y
];
enum int TOP_FACE = 4;

// Translation AND rotation AND a DIFFERENT scale on all three axes — see trap 1.
immutable double[3] ITEM_POS = [ 2.5, -1.25,  0.75];
immutable double[3] ITEM_ROT = [20.0,  40.0,  65.0];   // degrees, applied ZYX
immutable double[3] ITEM_SCL = [ 2.0,   3.0,   0.5];

// Fixed explicitly so neither stand inherits whatever framing /api/load-mesh's
// reframe left behind — the two stands are the same question asked twice and
// must be looked at from exactly the same place.
enum double CAM_AZ = 0.9, CAM_EL = 0.5, CAM_DIST = 8.0;

// --------------------------------------------------------------------------
// The item matrix and its inverse, composed here from the order document.d
// declares (M = T(pos) . Rz.Ry.Rx . S, pivot 0). An independent formula, not a
// copy of the engine's answer; block 0 scores it against the published matrix.
// --------------------------------------------------------------------------
double d2r(double d) { return d * PI / 180.0; }

double[3][3] rotMatrix() {
    double cx = cos(d2r(ITEM_ROT[0])), sx = sin(d2r(ITEM_ROT[0]));
    double cy = cos(d2r(ITEM_ROT[1])), sy = sin(d2r(ITEM_ROT[1]));
    double cz = cos(d2r(ITEM_ROT[2])), sz = sin(d2r(ITEM_ROT[2]));
    return [
        [ cz*cy,  cz*sy*sx - sz*cx,  cz*sy*cx + sz*sx],
        [ sz*cy,  sz*sy*sx + cz*cx,  sz*sy*cx - cz*sx],
        [   -sy,             cy*sx,             cy*cx],
    ];
}

double[16] composeItemMatrix() {
    auto R = rotMatrix();
    double[16] m;                       // L = R * diag(scl), column-major
    foreach (c; 0 .. 3)
        foreach (r; 0 .. 3)
            m[c*4 + r] = R[r][c] * ITEM_SCL[c];
    m[3] = m[7] = m[11] = 0;
    m[12] = ITEM_POS[0]; m[13] = ITEM_POS[1]; m[14] = ITEM_POS[2]; m[15] = 1;
    return m;
}

double[3] toWorldPoint(const double[3] p) {
    auto m = composeItemMatrix();
    return [m[0]*p[0] + m[4]*p[1] + m[ 8]*p[2] + m[12],
            m[1]*p[0] + m[5]*p[1] + m[ 9]*p[2] + m[13],
            m[2]*p[0] + m[6]*p[1] + m[10]*p[2] + m[14]];
}
double[3] toWorldDir(const double[3] v) {
    auto m = composeItemMatrix();
    return [m[0]*v[0] + m[4]*v[1] + m[ 8]*v[2],
            m[1]*v[0] + m[5]*v[1] + m[ 9]*v[2],
            m[2]*v[0] + m[6]*v[1] + m[10]*v[2]];
}

// M^-1 = S^-1 . R^T . T(-pos), written out rather than inverted numerically so
// a bug in it cannot be a bug copied from the engine.
double[3] toLocalPoint(const double[3] w) {
    auto R = rotMatrix();
    double[3] d = [w[0] - ITEM_POS[0], w[1] - ITEM_POS[1], w[2] - ITEM_POS[2]];
    double[3] o;
    foreach (i; 0 .. 3)                          // R^T row i = R column i
        o[i] = (R[0][i]*d[0] + R[1][i]*d[1] + R[2][i]*d[2]) / ITEM_SCL[i];
    return o;
}

double sq(double v) { return v * v; }

double dist3(const double[3] a, const double[3] b) {
    double dx = a[0]-b[0], dy = a[1]-b[1], dz = a[2]-b[2];
    return sqrt(dx*dx + dy*dy + dz*dz);
}
double len3(const double[3] v) { return sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]); }
double[3] unit3(const double[3] v) {
    double l = len3(v);
    assert(l > 1e-9, "cannot normalise a zero vector");
    return [v[0]/l, v[1]/l, v[2]/l];
}
Vec3 v3(const double[3] p) {
    return Vec3(cast(float)p[0], cast(float)p[1], cast(float)p[2]);
}

// --------------------------------------------------------------------------
// Stand construction. `transformed == false` writes the IDENTITY transform
// explicitly (not "leaves it alone") so neither stand can inherit the other's.
// --------------------------------------------------------------------------
void buildStand(bool transformed) {
    buildStandScaledY(transformed, ITEM_SCL[1]);
}
void buildStandScaledY(bool transformed, double sclY) {
    buildStandFull(transformed, sclY, CAM_AZ, CAM_EL);
}

void buildStandFull(bool transformed, double sclY, double az, double el) {
    auto r = postJson("/api/reset", "{}");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString());

    string verts = "[";
    foreach (i, p; CUBE)
        verts ~= (i ? "," : "") ~ format("[%.10g,%.10g,%.10g]", p[0], p[1], p[2]);
    verts ~= "]";
    string faces = "[";
    foreach (i, f; FACES) {
        faces ~= (i ? ",[" : "[");
        foreach (k, vi; f) faces ~= (k ? "," : "") ~ vi.to!string;
        faces ~= "]";
    }
    faces ~= "]";
    auto lm = postJson("/api/load-mesh", format(`{"vertices":%s,"faces":%s}`, verts, faces));
    assert(lm["status"].str == "ok", "load-mesh failed: " ~ lm.toString());

    static immutable string[3] ax = ["x", "y", "z"];
    foreach (i; 0 .. 3) {
        double s = (i == 1) ? sclY : ITEM_SCL[i];
        cmd(format("layer.attr 0 pos.%s %.10g", ax[i], transformed ? ITEM_POS[i] : 0.0));
        cmd(format("layer.attr 0 rot.%s %.10g", ax[i], transformed ? ITEM_ROT[i] : 0.0));
        cmd(format("layer.attr 0 scl.%s %.10g", ax[i], transformed ? s : 1.0));
        cmd(format("layer.attr 0 pivot.%s 0", ax[i]));
    }

    // AFTER load-mesh (which reframes), and identical on both stands.
    auto cr = postJson("/api/camera", format(
        `{"azimuth":%.10g,"elevation":%.10g,"distance":%.10g,"roll":0,` ~
        `"focus":{"x":%.10g,"y":%.10g,"z":%.10g}}`,
        az, el, CAM_DIST, ITEM_POS[0], ITEM_POS[1], ITEM_POS[2]));
    assert("status" !in cr || cr["status"].str != "error",
           "camera set failed: " ~ cr.toString());

    postJson("/api/select", format(`{"mode":"polygons","indices":[%d]}`, TOP_FACE));
    settle();
}

// --------------------------------------------------------------------------
// Arming the tool. count=2 + angle=360 makes the single copy a HALF-TURN,
// which is the configuration whose centre is recoverable in closed form (see
// `recoverCentre`). offset=0 keeps the copy in the rotation plane; weld=0
// keeps the four new vertices at indices 8..11 (the weld pass is the only
// thing in the kernel that renumbers).
// --------------------------------------------------------------------------
void armTool(string axis) {
    cmd("tool.set " ~ TOOL ~ " on");
    cmd("tool.attr " ~ TOOL ~ " count 2");
    cmd("tool.attr " ~ TOOL ~ " axis " ~ axis);
    cmd("tool.attr " ~ TOOL ~ " angle 360");
    cmd("tool.attr " ~ TOOL ~ " offset 0");
    cmd("tool.attr " ~ TOOL ~ " weld 0");
    settle();   // a draw() frame, so the press has a cached viewport + handles
}

void dropTool() { cmd("tool.set " ~ TOOL ~ " off"); }

double readFloatParam(string pname) {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " " ~ pname ~ " ?");
    assert(r["status"].str == "ok", pname ~ " read failed: " ~ r.toString());
    return num(r["value"]);
}

double[3] readCentreParam() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " center ?");
    assert(r["status"].str == "ok", "centre read failed: " ~ r.toString());
    auto a = r["value"].array;
    return [num(a[0]), num(a[1]), num(a[2])];
}

// A press and release on the same pixel: the off-handle branch of
// onMouseButtonDown, which is the write site under test.
void clickAt(const ref CameraState cam, int px, int py) {
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             px, py, px, py, 1), BASE);
    settle();
}

// GET /api/tool/handles -> the screen anchor of one part.
bool handleScreen(int part, out double sx, out double sy) {
    auto j = getJson("/api/tool/handles");
    if (j["handles"].type == JSONType.null_) return false;
    foreach (p; j["handles"]["parts"].array) {
        if (cast(int) p["part"].integer != part) continue;
        if (p["screen"].type == JSONType.null_) return false;
        sx = num(p["screen"].array[0]);
        sy = num(p["screen"].array[1]);
        return true;
    }
    return false;
}
double pixDist(double ax, double ay, double bx, double by) {
    return sqrt((ax-bx)*(ax-bx) + (ay-by)*(ay-by));
}

enum int PART_OFFSET = 0;
enum int PART_ANGLE  = 1;

// --------------------------------------------------------------------------
// Recover the array's rotation centre FROM THE COPIES.
//
// The kernel appends the copy's vertices in the order it walks the source
// faces' corners, so with only face 4 (corners 7,6,2,3) in the mask the copy of
// vertex 7 is vertex 8, of 6 is 9, of 2 is 10, of 3 is 11.
//
// A half-turn about the principal axis `axisIdx` through `c` reflects every
// point through the axis LINE: the on-axis coordinate is untouched, and each of
// the two in-plane coordinates satisfies `src + copy == 2c`. Four pairs, four
// independent estimates, no radius and no camera anywhere in it.
//
// The returned component at `axisIdx` is NaN and is not an oversight: a rotation
// about an axis cannot observe where the centre sits ALONG that axis. That is
// why block 2 repeats the whole measurement about X.
// --------------------------------------------------------------------------
double[3] recoverCentre(int axisIdx) {
    auto m  = getJson("/api/model");
    auto vs = m["vertices"].array;
    assert(vs.length == 12, format(
        "expected 12 vertices (8 cage + one 4-corner copy), got %d — the "
        ~ "off-handle click did not rebuild the array from the selected face",
        vs.length));

    double[3] vtx(size_t i) {
        auto a = vs[i].array;
        return [num(a[0]), num(a[1]), num(a[2])];
    }

    static immutable int[4] SRC = [7, 6, 2, 3];
    static immutable int[4] CPY = [8, 9, 10, 11];
    double[3] sum = [0, 0, 0];
    double[3] first;
    double worst = 0;
    foreach (k; 0 .. 4) {
        double[3] s = vtx(SRC[k]), c = vtx(CPY[k]);
        assert(fabs(s[axisIdx] - c[axisIdx]) < 1e-4, format(
            "copy %d moved ALONG the rotation axis (%g -> %g) — the copies are "
            ~ "not the half-turn this recovery assumes", k, s[axisIdx], c[axisIdx]));
        double[3] est = [0, 0, 0];
        foreach (i; 0 .. 3)
            if (i != axisIdx) est[i] = 0.5 * (s[i] + c[i]);
        if (k == 0) first = est;
        foreach (i; 0 .. 3) if (i != axisIdx) {
            double d = fabs(est[i] - first[i]);
            if (d > worst) worst = d;
            sum[i] += est[i];
        }
    }
    assert(worst < 1e-4, format(
        "the four source/copy pairs disagree on the centre by %g — the copies "
        ~ "are not a single rigid half-turn about one point", worst));

    double[3] c;
    foreach (i; 0 .. 3) c[i] = (i == axisIdx) ? double.nan : sum[i] / 4.0;
    return c;
}

// The pixel every block clicks. Built by projecting a world point near the
// stand so it is on screen and away from the handles, then rounded to the
// integer pixel an SDL event actually carries. WHICH world point the engine
// resolves from it is never assumed here — that is measured off the identity
// stand, so the choice of construction plane cannot leak into the assertions.
void clickPixel(const ref CameraState cam, out int px, out int py) {
    auto vp = viewportFromCamera(cam);
    double[3] target = [ITEM_POS[0] + 2.0, 0.0, ITEM_POS[2] + 2.0];
    float fx, fy;
    assert(projectToWindow(v3(target), vp, fx, fy),
           "the click target projects behind the camera");
    px = cast(int) fx;
    py = cast(int) fy;
    assert(px > 4 && py > 4 && px < cam.vpX + cam.width - 4 && py < cam.vpY + cam.height - 4,
           format("the click pixel (%d,%d) is off the viewport", px, py));
}

// A press must land on NEITHER handle, or it hauls a parameter instead of
// repositioning the centre — and the offset haul rebuilds the array too, so the
// vertex count alone would not catch it. 30 px clears both grab bands.
void assertClickMissesHandles(int px, int py) {
    double sx, sy;
    if (handleScreen(PART_OFFSET, sx, sy))
        assert(pixDist(px, py, sx, sy) > 30.0, format(
            "the click pixel (%d,%d) is %.1f px from the offset arrow's grab "
            ~ "point — it would haul offset instead of moving the centre",
            px, py, pixDist(px, py, sx, sy)));
    if (handleScreen(PART_ANGLE, sx, sy))
        assert(pixDist(px, py, sx, sy) > 30.0, format(
            "the click pixel (%d,%d) is %.1f px from the angle cube — it would "
            ~ "haul angle instead of moving the centre",
            px, py, pixDist(px, py, sx, sy)));
}

// ==========================================================================
// 0. The fixture checks itself, before any tool is involved: the hand-composed
//    matrix reproduces the one the engine publishes, the hand-written inverse
//    really inverts it, and the two candidate readings this file separates are
//    genuinely distinct points.
//
//    Without this, every assertion below could be scoring a wrong matrix
//    against itself.
// ==========================================================================
unittest {
    buildStand(true);

    auto arr = getJson("/api/layers")["layers"].array[0]["xform"]["matrix"].array;
    auto mine = composeItemMatrix();
    double worst = 0;
    foreach (i; 0 .. 16) {
        double d = fabs(mine[i] - num(arr[i]));
        if (d > worst) worst = d;
    }
    assert(worst < 1e-5, format(
        "the fixture's item matrix disagrees with the engine's by %g", worst));

    // The inverse inverts.
    double[3] p = [0.37, -1.9, 2.4];
    assert(dist3(toLocalPoint(toWorldPoint(p)), p) < 1e-9,
           "the fixture's M^-1 does not invert its M");

    // ...and the two readings of a world point near the stand are far apart, so
    // "the copies matched the right one" is a real statement.
    double[3] w = [ITEM_POS[0] + 2.0, 0.0, ITEM_POS[2] + 2.0];
    double sep = dist3(toLocalPoint(w), w);
    assert(sep > 1.0, format(
        "the correct and the identity-pose readings of the clicked point are "
        ~ "only %g apart — this stand cannot separate them", sep));
}

// ==========================================================================
// 1. THE DEFECT. Same pixel, two stands. The identity stand's copies report
//    the world hit the engine resolved; the transformed stand's copies must
//    turn about `M^-1` of that same point, not about the point itself.
//
//    Axis Y — pins the centre's X and Z.
// ==========================================================================
unittest {
    // --- the identity stand measures the clicked point ---------------------
    buildStand(false);
    auto cam = fetchCamera(BASE);
    int px, py;
    clickPixel(cam, px, py);

    armTool("Y");
    assertClickMissesHandles(px, py);
    double[3] beforeC = readCentreParam();
    clickAt(cam, px, py);
    double[3] afterC = readCentreParam();
    assert(dist3(beforeC, afterC) > 1e-4, format(
        "the click did not move the centre at all (%s -> %s) — it was swallowed "
        ~ "before the reposition branch", beforeC.to!string, afterC.to!string));

    double[3] hit = recoverCentre(1);
    // On the identity stand the reported parameter IS the world hit, so the
    // recovery closes the loop against the tool's own reading.
    assert(fabs(hit[0] - afterC[0]) < 1e-4 && fabs(hit[2] - afterC[2]) < 1e-4,
           format("recovery %s disagrees with the tool's own centre %s on the "
                  ~ "identity stand", hit.to!string, afterC.to!string));
    dropTool();

    // --- the transformed stand answers the same question -------------------
    buildStand(true);
    auto cam2 = fetchCamera(BASE);
    int px2, py2;
    clickPixel(cam2, px2, py2);
    assert(px2 == px && py2 == py, format(
        "the two stands did not resolve the same click pixel (%d,%d) vs (%d,%d) "
        ~ "— the cameras differ and the comparison is void", px, py, px2, py2));

    armTool("Y");
    assertClickMissesHandles(px, py);
    clickAt(cam2, px, py);
    double[3] got = recoverCentre(1);

    // The world hit, whole. On the identity stand `toLocalPos` is the identity,
    // so the tool's own reported centre IS the point the construction plane
    // resolved — all three components, with no assumption about WHICH plane
    // that was. (Task 0661 made the plane follow the view, so "it is the world
    // floor, therefore Y is 0" stopped being true; the recovery above still
    // cross-checks the two components the copies can see against it.)
    double[3] world = afterC;
    double[3] right = toLocalPoint(world);   // where the clicked point IS
    double[3] wrong = world;                 // its image under the identity matrix

    double errRight = sqrt(sq(got[0]-right[0]) + sq(got[2]-right[2]));
    double errWrong = sqrt(sq(got[0]-wrong[0]) + sq(got[2]-wrong[2]));

    assert(errRight < 2e-3, format(
        "the copies turn about (%.6f, _, %.6f); the clicked point is at "
        ~ "(%.6f, _, %.6f) in layer coordinates — off by %g",
        got[0], got[2], right[0], right[2], errRight));
    assert(errWrong > 0.5, format(
        "the correct and the identity-pose centres are only %g apart here — "
        ~ "this click cannot separate them", errWrong));
    dropTool();
}

// ==========================================================================
// 2. The component a Y-axis array cannot see. A half-turn about X pins the
//    centre's Y and Z, so the two blocks together pin all three.
//
//    This is not a duplicate of block 1: `center_.y` is entirely inert under a
//    Y-axis radial array, so block 1 would pass unchanged if the fix converted
//    only the two components it can observe.
// ==========================================================================
unittest {
    // --- identity stand, half-turn about X: the world hit's Y and Z ---------
    buildStand(false);
    auto cam = fetchCamera(BASE);
    int px, py;
    clickPixel(cam, px, py);

    armTool("X");
    assertClickMissesHandles(px, py);
    double[3] beforeC = readCentreParam();
    clickAt(cam, px, py);
    double[3] world = readCentreParam();     // identity stand ⇒ the world hit
    assert(dist3(beforeC, world) > 1e-4, format(
        "the click did not move the centre at all (%s -> %s)",
        beforeC.to!string, world.to!string));

    // The copies must agree with the tool's own reading on the two components
    // an X-axis half-turn can see — the same closing of the loop block 1 does,
    // and the check that the recovery is measuring the array and not a
    // coincidence.
    double[3] hitYZ = recoverCentre(0);
    assert(fabs(hitYZ[1] - world[1]) < 1e-4 && fabs(hitYZ[2] - world[2]) < 1e-4,
           format("recovery %s disagrees with the tool's own centre %s on the "
                  ~ "identity stand", hitYZ.to!string, world.to!string));
    dropTool();

    // --- transformed stand, half-turn about X -------------------------------
    buildStand(true);
    armTool("X");
    assertClickMissesHandles(px, py);
    clickAt(cam, px, py);
    double[3] got = recoverCentre(0);
    dropTool();

    double[3] right = toLocalPoint(world);
    double[3] wrong = world;

    double errRight = sqrt(sq(got[1]-right[1]) + sq(got[2]-right[2]));
    double errWrong = sqrt(sq(got[1]-wrong[1]) + sq(got[2]-wrong[2]));

    assert(errRight < 2e-3, format(
        "about X the copies turn about (_, %.6f, %.6f); the clicked point is at "
        ~ "(_, %.6f, %.6f) in layer coordinates — off by %g",
        got[1], got[2], right[1], right[2], errRight));
    assert(errWrong > 0.5, format(
        "the correct and the identity-pose centres are only %g apart here", errWrong));
}

// ==========================================================================
// 3. The handle bank went with the centre. Task 0645's law: the handle a tool
//    draws and the gain of the drag that handle drives are one quantity in two
//    roles and must be converted together — half of this cut would leave the
//    array turning about the clicked point while the arrow that hauls its
//    offset still floated at the identity pose.
//
//    Both candidate arrow anchors are built and projected HERE, so a broken
//    test-side projection would match neither.
// ==========================================================================
unittest {
    buildStand(true);
    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    int px, py;
    clickPixel(cam, px, py);

    armTool("Y");
    assertClickMissesHandles(px, py);
    clickAt(cam, px, py);

    double[3] c = readCentreParam();     // LAYER coordinates, after the fix

    // The drawn reading: anchor at M*c, arm along the local +Y axis lifted
    // through the item matrix. `Arrow` reports 70% along a shaft spanning
    // arm/6 .. arm, i.e. 1/6 + 0.7*5/6 = 0.75 of the arm from the anchor.
    double[3] anchorW = toWorldPoint(c);
    double[3] dirW    = unit3(toWorldDir([0.0, 1.0, 0.0]));
    // The identity-pose reading: the same construction with no matrix at all.
    double[3] anchorI = c;
    double[3] dirI    = [0.0, 1.0, 0.0];

    void arrowPixel(const double[3] anchor, const double[3] dir,
                    out double ox, out double oy)
    {
        float arm = gizmoSize(v3(anchor), vp);
        double[3] grab = [anchor[0] + dir[0]*arm*0.75,
                          anchor[1] + dir[1]*arm*0.75,
                          anchor[2] + dir[2]*arm*0.75];
        float fx, fy;
        assert(projectToWindow(v3(grab), vp, fx, fy), "arrow grab is off-camera");
        ox = fx; oy = fy;
    }

    double dx, dy, ix, iy;
    arrowPixel(anchorW, dirW, dx, dy);
    arrowPixel(anchorI, dirI, ix, iy);

    double sx, sy;
    assert(handleScreen(PART_OFFSET, sx, sy),
           "the offset arrow reported no screen anchor — /api/tool/handles is "
           ~ "the only view of a handle's SPACE from outside the process");

    double toDrawn    = pixDist(sx, sy, dx, dy);
    double toIdentity = pixDist(sx, sy, ix, iy);
    double separation = pixDist(dx, dy, ix, iy);

    assert(separation > 40.0, format(
        "the two candidate arrow anchors are only %.1f px apart — this camera "
        ~ "cannot separate them", separation));
    assert(toDrawn < 6.0, format(
        "the offset arrow is at (%.1f, %.1f); the geometry as DRAWN puts it at "
        ~ "(%.1f, %.1f) — %.1f px away (identity pose is at (%.1f, %.1f))",
        sx, sy, dx, dy, toDrawn, ix, iy));
    assert(toIdentity > 25.0, format(
        "the offset arrow is only %.1f px from the identity-pose anchor "
        ~ "(%.1f, %.1f) — it is still being placed in layer coordinates",
        toIdentity, ix, iy));

    // The angle cube is a second, independent placement (its tangent is rotated
    // in LAYER space and then lifted, where the arrow's axis is lifted
    // directly), so it gets its own assertion rather than riding on the arrow's.
    double[3] tangentW = unit3(toWorldDir([0.0, 0.0, 1.0]));   // axis Y, angle 360 deg
    float armC = gizmoSize(v3(anchorW), vp);
    double[3] cubeW = [anchorW[0] + tangentW[0]*armC*0.85,
                       anchorW[1] + tangentW[1]*armC*0.85,
                       anchorW[2] + tangentW[2]*armC*0.85];
    float cfx, cfy;
    assert(projectToWindow(v3(cubeW), vp, cfx, cfy), "angle cube is off-camera");

    double asx, asy;
    assert(handleScreen(PART_ANGLE, asx, asy), "the angle cube reported no anchor");
    double cubeErr = pixDist(asx, asy, cfx, cfy);
    assert(cubeErr < 8.0, format(
        "the angle cube is at (%.1f, %.1f); the drawn geometry puts it at "
        ~ "(%.1f, %.1f) — %.1f px away", asx, asy, cfx, cfy, cubeErr));

    dropTool();
}

// ==========================================================================
// 4. The GAIN moved with the handle. Task 0645's law: the position of a handle
//    and the gain of the drag it drives are one quantity in two roles, and
//    converting one without the other leaves the handle no longer tracking the
//    cursor. `offset` is a LAYER length the kernel spreads along the local
//    axis; a drag measures a WORLD length along the arm as drawn.
//
//    THE TRICK THAT MAKES THIS EXACT, with no drag math duplicated here:
//    scaling the layer along the ARRAY AXIS changes the gain and NOTHING ELSE
//    that the arrow can see.
//
//      * the centre is placed by a click, so it is the same WORLD point on both
//        stands (`M*c == worldHit` however `M` is scaled) — the arrow's anchor
//        does not move;
//      * `L*y == s*(R*y)`, so the arm's DIRECTION is independent of `s` — the
//        arrow does not turn;
//      * `gizmoSize` reads the anchor's depth, which is unchanged — the arm
//        does not change length.
//
//    So the arrow is drawn on the SAME PIXELS for s=3 and s=1 (asserted below),
//    the same press and the same 80-pixel drag produce the same world
//    displacement D, and the only thing that can differ is what `offset` is
//    written as: `D/s` with the gain converted, `D` without. The prediction is
//    therefore an exact ratio — 1/3 — and the unconverted reading is 1.
// ==========================================================================
double[3] arrowDragOffset(double sclY) {
    buildStandScaledY(true, sclY);
    auto cam = fetchCamera(BASE);
    int px, py;
    clickPixel(cam, px, py);

    armTool("Y");
    assertClickMissesHandles(px, py);
    clickAt(cam, px, py);            // the same world centre on every stand

    double gx, gy;
    assert(handleScreen(PART_OFFSET, gx, gy),
           "the offset arrow reported no grab point");
    int x0 = cast(int) gx, y0 = cast(int) gy;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x0, y0 - 80, 16), BASE);
    settle();

    double o = readFloatParam("offset");
    dropTool();
    return [o, gx, gy];
}

unittest {
    auto a = arrowDragOffset(3.0);   // |L*y| = 3
    auto b = arrowDragOffset(1.0);   // |L*y| = 1

    assert(pixDist(a[1], a[2], b[1], b[2]) < 0.5, format(
        "the two stands drew the offset arrow at different pixels — (%.2f, %.2f) "
        ~ "vs (%.2f, %.2f) — so they are not the same drag and the ratio below "
        ~ "means nothing", a[1], a[2], b[1], b[2]));
    assert(fabs(b[0]) > 1e-3, format(
        "the 80 px drag produced no offset at all (%g) — the press missed the "
        ~ "arrow, or the drag ran perpendicular to it", b[0]));

    double predicted = b[0] / 3.0;
    assert(fabs(a[0] - predicted) < 1e-3 + 1e-3 * fabs(predicted), format(
        "the same drag wrote offset=%.6f on the 3x-scaled layer; the world "
        ~ "displacement it measured is %.6f local units there, so it should "
        ~ "have written %.6f", a[0], predicted, predicted));
    assert(fabs(a[0] - b[0]) > 0.05, format(
        "the two gains differ by only %g — this stand cannot separate a "
        ~ "converted gain from an unconverted one", fabs(a[0] - b[0])));
}

// ==========================================================================
// 5. The angle dial tracks the CURSOR, not its identity-pose ghost.
//
//    `angle` is the sweep the kernel applies about the LOCAL principal axis,
//    and under a non-uniform item scale a local rotation is not a world
//    rotation at all — there is no world angle to convert back, so the drag has
//    to measure in layer space outright.
//
//    THE INVARIANT THAT MAKES THAT ASSERTABLE. The cube sits at
//    `centerW + unit(L*t)*r` where `t` is the local tangent at the current
//    angle. Measured in layer space, the drag drives `t` to the azimuth of the
//    cursor ray's hit on the local rotation plane — so `L*t` points along
//    `L*(hit - c)`, i.e. the cube ends up on the WORLD RAY from `centerW`
//    toward that hit. A projection maps a ray to a line, so on screen the
//    centre, the cube and the cursor become COLLINEAR. That is a statement
//    about pixels only; no ray inversion happens in this test.
//
//    Measured in world space instead, the angle is read off a plane whose
//    normal is the local axis vector used as a world normal, and the cube lands
//    somewhere off that line — which is what the `before` reading below shows
//    the scale of.
// ==========================================================================
unittest {
    // THIS BLOCK NEEDS ITS OWN VIEW, and the reason is worth stating because it
    // is a property of the stand, not a convenience. With `axis = Y` the local
    // rotation plane is the layer's XZ plane, whose world image has normal
    // `L^-T*y ∝ R*y ≈ (-0.76, 0.60, 0.26)`. The camera the other blocks share
    // looks along ≈ (-0.69, -0.48, -0.55), which is 85 degrees off that normal
    // — the ring projects to a hairline ellipse, where a half-pixel of press
    // truncation is worth tens of degrees of azimuth and the measurement below
    // is meaningless. This view faces the plane instead (the assertions are the
    // same; only the conditioning changes).
    enum double AZ5 = -1.238, EL5 = 0.638;

    buildStandFull(true, ITEM_SCL[1], AZ5, EL5);
    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    int px, py;
    clickPixel(cam, px, py);

    armTool("Y");
    assertClickMissesHandles(px, py);
    clickAt(cam, px, py);

    double[3] c       = readCentreParam();       // layer coordinates
    double[3] centerW = toWorldPoint(c);
    float cx, cy;
    assert(projectToWindow(v3(centerW), vp, cx, cy), "the centre is off-camera");

    double ax0, ay0;
    assert(handleScreen(PART_ANGLE, ax0, ay0), "the angle cube reported no anchor");
    double vx = ax0 - cx, vy = ay0 - cy;
    double spoke = sqrt(vx*vx + vy*vy);
    assert(spoke > 20.0, format(
        "the angle cube is only %.1f px from the centre — there is no spoke to "
        ~ "swing", spoke));

    // Swing the spoke ~70 degrees on screen and push the target well past the
    // ring, so "the cube followed" cannot be satisfied by it staying put.
    enum double SWING = 70.0 * PI / 180.0;
    // The INTEGER pixel the event log actually carries — comparing against the
    // float ideal would charge this measurement for a truncation the engine
    // never saw.
    int tix = cast(int)(cx + (vx*cos(SWING) - vy*sin(SWING)) * 1.5);
    int tiy = cast(int)(cy + (vx*sin(SWING) + vy*cos(SWING)) * 1.5);
    double tx = tix, ty = tiy;

    double before = readFloatParam("angle");
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cast(int) ax0, cast(int) ay0, tix, tiy, 24), BASE);
    settle();
    double after = readFloatParam("angle");
    assert(fabs(after - before) > 1.0, format(
        "angle did not move (%g -> %g) — the press hit the offset arrow or "
        ~ "nothing at all, so this block measured the wrong handle",
        before, after));

    double ax1, ay1;
    assert(handleScreen(PART_ANGLE, ax1, ay1),
           "the angle cube reported no anchor after the drag");

    // Screen angle between a spoke and the cursor direction, in degrees.
    double spokeAngle(double ux, double uy) {
        double wx = tx - cx, wy = ty - cy;
        double lu = sqrt(ux*ux + uy*uy), lw = sqrt(wx*wx + wy*wy);
        assert(lu > 1e-6 && lw > 1e-6, "degenerate spoke");
        double cth = (ux*wx + uy*wy) / (lu*lw);
        if (cth >  1.0) cth =  1.0;
        if (cth < -1.0) cth = -1.0;
        import std.math : acos;
        return acos(cth) * 180.0 / PI;
    }

    double wasOff = spokeAngle(ax0 - cx, ay0 - cy);
    double isOff  = spokeAngle(ax1 - cx, ay1 - cy);

    assert(wasOff > 30.0, format(
        "the cube already pointed within %.1f degrees of the target before the "
        ~ "drag — the swing is too small to measure anything", wasOff));
    assert(isOff < 6.0, format(
        "after the drag the cube points %.1f degrees off the cursor (it was "
        ~ "%.1f degrees off before) — the dial is not measuring in the space "
        ~ "the kernel turns in", isOff, wasOff));

    dropTool();
}
